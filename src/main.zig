const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const APIGatewayProxyRequest = @import("events.zig").APIGatewayProxyRequest;
const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            @panic("leaked");
        }
    }
    const allocator = gpa.allocator();
    var runtime = Runtime(APIGatewayProxyRequest).new(allocator, &handler);
    defer runtime.deinit();
    try runtime.start();
}

fn handler(allocator: Allocator, event: APIGatewayProxyRequest) anyerror![]const u8 {
    _ = allocator;
    std.log.info("method: {s}\n", .{event.httpMethod});
    std.log.info("path: {s}\n", .{event.path});
    std.log.info("body: {s}\n", .{event.body});
    return 
    \\ {
    \\ "message" : "ok",
    \\ "status" : 200
    \\ }
    \\
    ;
}
