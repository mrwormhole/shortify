const std = @import("std");
const shortener = @import("shortener.zig").URLShortener;
const server = @import("server.zig").URLShortenerServer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var shrt = shortener.init(allocator);
    defer shrt.deinit();

    var srv = server.init(allocator, &shrt);
    try srv.start(3000);
}
