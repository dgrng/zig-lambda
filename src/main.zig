const std = @import("std");
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

fn handler(allocator: Allocator, body: []u8) anyerror![]u8 {
    _ = allocator;
    return body;
}

const Context = struct {
    request_id: []const u8,
    body: []u8,
};

const Runtime = struct {
    const Self = @This();
    allocator: Allocator,
    http_client: std.http.Client,

    // endpoints
    endpoint_next: []u8 = undefined,
    endpoint_response: []u8 = undefined,
    endpoint_error: []u8 = undefined,

    // handler
    handler: *const fn (allocator: Allocator, body: []u8) anyerror![]u8,

    fn new(allocator: Allocator, h: *const fn (allocator: Allocator, body: []u8) anyerror![]u8) @This() {
        var http_client = std.http.Client{ .allocator = allocator };
        return .{
            .allocator = allocator,
            .http_client = http_client,
            .handler = h,
        };
    }

    fn start(self: *Self) !void {
        const api_endpoint = std.os.getenv("AWS_LAMBDA_RUNTIME_API") orelse unreachable;
        try self.setEndpoint(api_endpoint);

        while (true) {
            var ctx = try self.next();
            defer self.allocator.free(ctx.body);
            defer self.allocator.free(ctx.request_id);
            var res = try self.handler(self.allocator, ctx.body);
            _ = res;
            try self.respond(&ctx, "hello world");
        }
    }

    fn next(self: *Self) !Context {
        const endpoint = try std.Uri.parse(self.endpoint_next);
        var client_headers = std.http.Headers{ .allocator = self.allocator };
        defer client_headers.deinit();
        var req = try self.http_client.request(.GET, endpoint, client_headers, .{});
        defer req.deinit();
        try req.start();
        try req.wait();
        var id = req.response.headers.getFirstValue("Lambda-Runtime-Aws-Request-Id") orelse unreachable;
        var body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024 * 10);
        return .{
            .request_id = try self.allocator.dupe(u8, id),
            .body = body,
        };
    }

    fn respond(self: *Self, ctx: *Context, body: []const u8) !void {
        const respondUrl = try std.fmt.allocPrint(self.allocator, "{s}{s}/response", .{ self.endpoint_response, ctx.request_id });
        defer self.allocator.free(respondUrl);
        var uri = try std.Uri.parse(respondUrl);
        var client_headers = std.http.Headers{ .allocator = self.allocator };
        defer client_headers.deinit();
        var req = try self.http_client.request(.POST, uri, client_headers, .{});
        req.transfer_encoding = .{ .content_length = body.len };
        defer req.deinit();
        try req.start();
        _ = try req.write(body);
        try req.finish();
        try req.wait();
    }

    fn setEndpoint(self: *Self, endoint: []const u8) !void {
        self.endpoint_next = try std.fmt.allocPrint(self.allocator, "http://{s}/2018-06-01/runtime/invocation/next", .{endoint});
        self.endpoint_response = try std.fmt.allocPrint(self.allocator, "http://{s}/2018-06-01/runtime/invocation/", .{endoint});
        self.endpoint_error = try std.fmt.allocPrint(self.allocator, "http://{s}/2018-06-01/runtime/init/error", .{endoint});
    }

    fn deinit(self: *Self) void {
        self.http_client.deinit();
        self.allocator.free(self.endpoint_next);
        self.allocator.free(self.endpoint_response);
        self.allocator.free(self.endpoint_error);
    }
};

const user_agent = "lambda-zig";
