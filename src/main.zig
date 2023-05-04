const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const Context = Runtime.Context;
const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            @panic("leaked");
        }
    }
    const allocator = gpa.allocator();
    var runtime = Runtime.new(allocator, &handler);
    defer runtime.deinit();
    try runtime.start();
}

fn handler(allocator: Allocator, ctx: *const Context) anyerror!void {
    _ = allocator;
    std.log.info("body : {s}\n", .{ctx.event_payload});
    var res =
        \\ {
        \\ "message" : "ok",
        \\ "status" : 200
        \\ }
        \\
    ;
    try ctx.respond(res);
}
