const std = @import("std");
const http = std.http;
const json = std.json;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const URLShortener = @import("shortener.zig").URLShortener;

pub const URLShortenerServer = struct {
    allocator: Allocator,
    shortener: *URLShortener,

    const Self = @This();

    pub fn init(allocator: Allocator, shortener: *URLShortener) Self {
        return Self{
            .allocator = allocator,
            .shortener = shortener,
        };
    }

    fn sendJsonResponse(self: *Self, request: *http.Server.Request, status: http.Status, data: anytype) !void {
        const json_string = try json.stringifyAlloc(self.allocator, data, .{});
        defer self.allocator.free(json_string);

        try request.respond(json_string, .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "application/json" },
                .{ .name = "access-control-allow-origin", .value = "*" },
                .{ .name = "access-control-allow-methods", .value = "GET, POST, OPTIONS" },
                .{ .name = "access-control-allow-headers", .value = "Content-Type" },
            },
        });
    }

    fn sendRedirect(self: *Self, request: *http.Server.Request, location: []const u8) !void {
        _ = self;
        try request.respond("", .{
            .status = .moved_permanently,
            .extra_headers = &.{
                .{ .name = "location", .value = location },
                .{ .name = "access-control-allow-origin", .value = "*" },
            },
        });
    }

    fn sendTextResponse(self: *Self, request: *http.Server.Request, status: http.Status, text: []const u8) !void {
        _ = self;
        try request.respond(text, .{
            .status = status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = "text/plain" },
                .{ .name = "access-control-allow-origin", .value = "*" },
            },
        });
    }

    pub const ErrorResponse = struct {
        error_message: []const u8,
    };

    pub fn handleRequest(self: *Self, request: *http.Server.Request) !void {
        const method = request.head.method;
        const target = request.head.target;

        print("Request: {s} {s}\n", .{ @tagName(method), target });

        // Handle CORS preflight
        if (method == .OPTIONS) {
            try self.sendTextResponse(request, .ok, "");
            return;
        }

        // Route handling
        if (method == .GET and std.mem.eql(u8, target, "/")) {
            try self.handleHealthCheck(request);
        } else if (method == .POST and std.mem.eql(u8, target, "/shorten")) {
            try self.handleShortenRequest(request);
        } else if (method == .GET and std.mem.startsWith(u8, target, "/stats/")) {
            const code = target[7..]; // Remove "/stats/"
            try self.handleStatsRequest(request, code);
        } else if (method == .GET and std.mem.eql(u8, target, "/list")) {
            try self.handleListRequest(request);
        } else if (method == .GET and target.len > 1) {
            const code = target[1..]; // Remove leading "/"
            try self.handleRedirectRequest(request, code);
        } else {
            const error_response = ErrorResponse{ .error_message = "Not found" };
            try self.sendJsonResponse(request, .not_found, error_response);
        }
    }

    fn handleHealthCheck(self: *Self, request: *http.Server.Request) !void {
        try self.sendTextResponse(request, .ok, "URL Shortener API");
    }

    pub const ShortenRequest = struct {
        url: []const u8,
        custom_code: ?[]const u8 = null,
    };

    fn handleShortenRequest(self: *Self, request: *http.Server.Request) !void {
        // Read request body
        var body_buffer: [1024 * 1024]u8 = undefined;
        const reader = try request.reader();
        const body_size = try reader.readAll(&body_buffer);
        const body = body_buffer[0..body_size];

        // Parse JSON request
        const parsed = json.parseFromSlice(ShortenRequest, self.allocator, body, .{}) catch {
            const error_response = ErrorResponse{ .error_message = "Invalid JSON" };
            try self.sendJsonResponse(request, .bad_request, error_response);
            return;
        };
        defer parsed.deinit();

        const req_data = parsed.value;

        // Process the request
        const shorten_response = self.shortener.shortenUrl(req_data.url, req_data.custom_code) catch |err| {
            const error_msg = switch (err) {
                error.InvalidUrl => "Invalid URL format",
                error.InvalidCustomCode => "Invalid custom code",
                error.CustomCodeExists => "Custom code already exists",
                else => "Internal server error",
            };
            const error_response = ErrorResponse{ .error_message = error_msg };

            const status = switch (err) {
                error.InvalidUrl, error.InvalidCustomCode => http.Status.bad_request,
                error.CustomCodeExists => http.Status.conflict,
                else => http.Status.internal_server_error,
            };

            try self.sendJsonResponse(request, status, error_response);
            return;
        };

        // Clean up allocated strings after sending response
        defer {
            self.allocator.free(shorten_response.short_url);
            // short_code is owned by the hashmap now, don't free it
        }

        try self.sendJsonResponse(request, .created, shorten_response);
    }

    fn handleRedirectRequest(self: *Self, request: *http.Server.Request, code: []const u8) !void {
        if (self.shortener.getUrl(code)) |entry| {
            self.shortener.incrementClick(code);
            try self.sendRedirect(request, entry.original_url);
        } else {
            const error_response = ErrorResponse{ .error_message = "Short code not found" };
            try self.sendJsonResponse(request, .not_found, error_response);
        }
    }

    fn handleStatsRequest(self: *Self, request: *http.Server.Request, code: []const u8) !void {
        if (self.shortener.getStats(code)) |stats| {
            try self.sendJsonResponse(request, .ok, stats);
        } else {
            const error_response = ErrorResponse{ .error_message = "Short code not found" };
            try self.sendJsonResponse(request, .not_found, error_response);
        }
    }

    fn handleListRequest(self: *Self, request: *http.Server.Request) !void {
        const all_stats = try self.shortener.getAllStats();
        defer self.allocator.free(all_stats);

        try self.sendJsonResponse(request, .ok, all_stats);
    }

    pub fn start(self: *Self, port: u16) !void {
        const address = std.net.Address.parseIp("127.0.0.1", port) catch unreachable;

        // Try the socket-based approach for Zig 0.14.1
        const socket = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        defer std.posix.close(socket);

        try std.posix.setsockopt(socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try std.posix.bind(socket, &address.any, address.getOsSockLen());
        try std.posix.listen(socket, 128);

        print("URL Shortener running on http://localhost:{}\n", .{port});
        print("API endpoints:\n", .{});
        print("  POST /shorten - Create short URL\n", .{});
        print("  GET /:code - Redirect to original URL\n", .{});
        print("  GET /stats/:code - Get URL statistics\n", .{});
        print("  GET /list - List all URLs\n", .{});
        print("\nPress Ctrl+C to stop the server.\n\n", .{});

        while (true) {
            var client_address: std.net.Address = undefined;
            var client_address_len: std.posix.socklen_t = @sizeOf(std.net.Address);

            const client_socket = std.posix.accept(socket, &client_address.any, &client_address_len, 0) catch |err| {
                print("Failed to accept connection: {}\n", .{err});
                continue;
            };
            defer std.posix.close(client_socket);

            // Create a stream from the socket
            const stream = std.net.Stream{ .handle = client_socket };
            const addr = try std.net.Address.parseIp4("127.0.0.1", 8080);
            const conn: std.net.Server.Connection = .{ .stream = stream, .address = addr };
            var read_buffer: [8192]u8 = undefined;
            var http_server = http.Server.init(conn, &read_buffer);

            while (http_server.state == .ready) {
                var request = http_server.receiveHead() catch |err| switch (err) {
                    error.HttpConnectionClosing => break,
                    else => {
                        print("Error receiving HTTP head: {}\n", .{err});
                        break;
                    },
                };

                self.handleRequest(&request) catch |err| {
                    print("Error handling request: {}\n", .{err});
                };

                // Force break after handling one request to avoid hanging
                break;
            }
        }
    }
};
