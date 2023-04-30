# zig-lambda

## experimental aws lambda runtime for ziglang (wip)
requires latest(master branch) zig compiler

## example:
```zig
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
```
