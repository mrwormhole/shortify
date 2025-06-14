const std = @import("std");
const http = std.http;
const json = std.json;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

// URL entry structure
pub const UrlEntry = struct {
    original_url: []const u8,
    created_at: u64,
    click_count: u64,

    pub fn deinit(self: *UrlEntry, allocator: Allocator) void {
        allocator.free(self.original_url);
    }
};

// Request/Response structures
pub const ShortenRequest = struct {
    url: []const u8,
    custom_code: ?[]const u8 = null,
};

pub const ShortenResponse = struct {
    short_url: []const u8,
    short_code: []const u8,
};

pub const StatsResponse = struct {
    original_url: []const u8,
    short_code: []const u8,
    click_count: u64,
    created_at: u64,
};

pub const ErrorResponse = struct {
    error_message: []const u8,
};

// Main application state
pub const UrlShortener = struct {
    allocator: Allocator,
    urls: HashMap([]const u8, UrlEntry, StringContext, std.hash_map.default_max_load_percentage),
    counter: u64,

    const Self = @This();
    const StringContext = struct {
        pub fn hash(self: @This(), s: []const u8) u64 {
            _ = self;
            return std.hash_map.hashString(s);
        }

        pub fn eql(self: @This(), a: []const u8, b: []const u8) bool {
            _ = self;
            return std.mem.eql(u8, a, b);
        }
    };

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .urls = HashMap([]const u8, UrlEntry, StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .counter = 1000, // Start from 1000 for nicer codes
        };
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.urls.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.urls.deinit();
    }

    // Base62 encoding
    const BASE62_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

    fn encodeBase62(self: *Self, num: u64) ![]const u8 {
        if (num == 0) return try self.allocator.dupe(u8, "0");

        var result = ArrayList(u8).init(self.allocator);
        defer result.deinit();

        var n = num;
        while (n > 0) {
            try result.append(BASE62_CHARS[n % 62]);
            n /= 62;
        }

        // Reverse the result
        const slice = try result.toOwnedSlice();
        std.mem.reverse(u8, slice);
        return slice;
    }

    fn generateShortCode(self: *Self, url: []const u8) ![]const u8 {
        // Try counter-based approach first
        var code = try self.encodeBase62(self.counter);
        self.counter += 1;

        // Check for collisions
        if (self.urls.contains(code)) {
            self.allocator.free(code);
            // Fallback to hash-based
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});
            hasher.update(url);
            hasher.update(std.mem.asBytes(&self.counter));
            var hash: [32]u8 = undefined;
            hasher.final(&hash);

            // Use first 8 bytes as number
            var num: u64 = 0;
            for (hash[0..8], 0..) |byte, i| {
                num |= @as(u64, byte) << @intCast(i * 8);
            }

            code = try self.encodeBase62(num);
        }

        return code;
    }

    fn validateUrl(url: []const u8) bool {
        return std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://");
    }

    fn validateCustomCode(code: []const u8) bool {
        if (code.len < 3 or code.len > 20) return false;

        // Check for valid characters
        for (code) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
                return false;
            }
        }

        // Check reserved words
        const reserved = [_][]const u8{ "api", "stats", "admin", "www", "app", "short", "url", "list" };
        for (reserved) |reserved_word| {
            if (std.ascii.eqlIgnoreCase(code, reserved_word)) {
                return false;
            }
        }

        return true;
    }

    pub fn shortenUrl(self: *Self, url: []const u8, custom_code: ?[]const u8) !ShortenResponse {
        // Validate URL
        if (!validateUrl(url)) {
            return error.InvalidUrl;
        }

        // Generate or validate custom code
        const short_code = if (custom_code) |custom| blk: {
            if (!validateCustomCode(custom)) {
                return error.InvalidCustomCode;
            }
            if (self.urls.contains(custom)) {
                return error.CustomCodeExists;
            }
            break :blk try self.allocator.dupe(u8, custom);
        } else try self.generateShortCode(url);

        // Store the URL
        const owned_url = try self.allocator.dupe(u8, url);
        const entry = UrlEntry{
            .original_url = owned_url,
            .created_at = @intCast(std.time.timestamp()),
            .click_count = 0,
        };

        try self.urls.put(short_code, entry);

        const short_url = try std.fmt.allocPrint(self.allocator, "http://localhost:3000/{s}", .{short_code});

        return ShortenResponse{
            .short_url = short_url,
            .short_code = short_code,
        };
    }

    pub fn getUrl(self: *Self, code: []const u8) ?*UrlEntry {
        return self.urls.getPtr(code);
    }

    pub fn incrementClick(self: *Self, code: []const u8) void {
        if (self.urls.getPtr(code)) |entry| {
            entry.click_count += 1;
        }
    }

    pub fn getStats(self: *Self, code: []const u8) ?StatsResponse {
        if (self.urls.get(code)) |entry| {
            return StatsResponse{
                .original_url = entry.original_url,
                .short_code = code,
                .click_count = entry.click_count,
                .created_at = entry.created_at,
            };
        }
        return null;
    }

    pub fn getAllStats(self: *Self) ![]StatsResponse {
        var urls = ArrayList(StatsResponse).init(self.allocator);

        var iterator = self.urls.iterator();
        while (iterator.next()) |entry| {
            try urls.append(StatsResponse{
                .original_url = entry.value_ptr.original_url,
                .short_code = entry.key_ptr.*,
                .click_count = entry.value_ptr.click_count,
                .created_at = entry.value_ptr.created_at,
            });
        }

        return try urls.toOwnedSlice();
    }
};

// HTTP Server using std.http
pub const UrlShortenerServer = struct {
    allocator: Allocator,
    shortener: *UrlShortener,

    const Self = @This();

    pub fn init(allocator: Allocator, shortener: *UrlShortener) Self {
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
