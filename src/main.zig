const std = @import("std");
const shortener = @import("shortener.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var url_shortener = shortener.UrlShortener.init(allocator);
    defer url_shortener.deinit();

    var server = shortener.UrlShortenerServer.init(allocator, &url_shortener);
    try server.start(3000);
}
