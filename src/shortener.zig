const std = @import("std");
const json = std.json;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Allocator = std.mem.Allocator;

pub const URLEntry = struct {
    original_url: []const u8,
    created_at: u64,
    click_count: u64,

    pub fn deinit(self: *URLEntry, allocator: Allocator) void {
        allocator.free(self.original_url);
    }
};

pub const URLShortener = struct {
    const URLEntries = std.StringHashMap(URLEntry);

    allocator: Allocator,
    urls_entries: URLEntries,
    counter: u64,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .urls_entries = URLEntries.init(allocator),
            .counter = 1000, // Start from 1000 for nicer codes
        };
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.urls_entries.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.urls_entries.deinit();
    }

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
        if (self.urls_entries.contains(code)) {
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

        for (code) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
                return false;
            }
        }

        const reserved = [_][]const u8{ "api", "stats", "admin", "www", "app", "short", "url", "list" };
        for (reserved) |reserved_word| {
            if (std.ascii.eqlIgnoreCase(code, reserved_word)) {
                return false;
            }
        }

        return true;
    }

    pub const ShortenResponse = struct {
        short_url: []const u8,
        short_code: []const u8,
    };

    pub fn shortenUrl(self: *Self, url: []const u8, custom_code: ?[]const u8) !ShortenResponse {
        if (!validateUrl(url)) {
            return error.InvalidUrl;
        }

        const short_code = if (custom_code) |custom| blk: {
            if (!validateCustomCode(custom)) {
                return error.InvalidCustomCode;
            }
            if (self.urls_entries.contains(custom)) {
                return error.CustomCodeExists;
            }
            break :blk try self.allocator.dupe(u8, custom);
        } else try self.generateShortCode(url);

        const owned_url = try self.allocator.dupe(u8, url);
        const entry = URLEntry{
            .original_url = owned_url,
            .created_at = @intCast(std.time.timestamp()),
            .click_count = 0,
        };

        try self.urls_entries.put(short_code, entry);

        const short_url = try std.fmt.allocPrint(self.allocator, "http://localhost:3000/{s}", .{short_code});

        return ShortenResponse{
            .short_url = short_url,
            .short_code = short_code,
        };
    }

    pub fn getUrl(self: *Self, code: []const u8) ?*URLEntry {
        return self.urls_entries.getPtr(code);
    }

    pub fn incrementClick(self: *Self, code: []const u8) void {
        if (self.urls_entries.getPtr(code)) |entry| {
            entry.click_count += 1;
        }
    }

    pub fn getStats(self: *Self, code: []const u8) ?StatsResponse {
        if (self.urls_entries.get(code)) |entry| {
            return StatsResponse{
                .original_url = entry.original_url,
                .short_code = code,
                .click_count = entry.click_count,
                .created_at = entry.created_at,
            };
        }
        return null;
    }

    pub const StatsResponse = struct {
        original_url: []const u8,
        short_code: []const u8,
        click_count: u64,
        created_at: u64,
    };

    pub fn getAllStats(self: *Self) ![]StatsResponse {
        var urls = ArrayList(StatsResponse).init(self.allocator);

        var iterator = self.urls_entries.iterator();
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
