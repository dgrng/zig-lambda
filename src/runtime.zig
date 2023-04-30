const std = @import("std");
const Allocator = std.mem.Allocator;
const Event = @import("events.zig").Event;

// Request Context
const Context = struct {
    const Self = @This();
    allocator: Allocator,
    request_id: []const u8,
    body: []u8,
    trace_id: []const u8,
    invoked_function_arn: []const u8,

    fn deinit(self: *Self) void {
        self.allocator.free(self.request_id);
        self.allocator.free(self.body);
        self.allocator.free(self.trace_id);
        self.allocator.free(self.invoked_function_arn);
    }
};

pub fn Runtime(comptime EventType: type) type {
    return struct {
        const Self = @This();
        allocator: Allocator,
        http_client: std.http.Client,
        handler: *const fn (allocator: Allocator, event: EventType) anyerror![]const u8,

        // endpoints
        endpoint_next: []u8 = undefined,
        endpoint_response: []u8 = undefined,
        endpoint_init_error: []u8 = undefined,

        const RuntimeError = error{ InvalidEventType, NextInvokeFailed, LambdaRuntimeEnvironmentVariableNotFound };

        // handler event is freed by runtime.
        pub fn new(allocator: Allocator, handler: *const fn (allocator: Allocator, event: EventType) anyerror![]const u8) Self {
            var http_client = std.http.Client{ .allocator = allocator };
            return .{
                .allocator = allocator,
                .http_client = http_client,
                .handler = handler,
            };
        }

        pub fn start(self: *Self) !void {
            const api_endpoint = std.os.getenv("AWS_LAMBDA_RUNTIME_API") orelse return error.LambdaRuntimeEnvironmentVariableNotFound;
            try self.setEndpoint(api_endpoint);

            while (true) {
                var ctx = try self.next();
                defer ctx.deinit();
                var e = try Event(EventType).init(self.allocator, ctx.body);
                defer e.deinit();
                const res = self.handler(self.allocator, e.payload) catch |err| {
                    try self.respondError(&ctx, err);
                    continue;
                };
                try self.respond(&ctx, res);
                // todo define interface to free res.
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
            if (req.response.status != .ok) {
                return error.NextInvokeFailed;
            }
            var id = req.response.headers.getFirstValue("Lambda-Runtime-Aws-Request-Id").?;
            var trace_id = req.response.headers.getFirstValue("Lambda-Runtime-Trace-Id").?;
            var fn_arn = req.response.headers.getFirstValue("Lambda-Runtime-Invoked-Function-Arn").?;

            var body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024 * 10);
            return .{
                .allocator = self.allocator,
                .request_id = try self.allocator.dupe(u8, id),
                .trace_id = try self.allocator.dupe(u8, trace_id),
                .invoked_function_arn = try self.allocator.dupe(u8, fn_arn),
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

        fn setEndpoint(self: *Self, endpoint: []const u8) !void {
            self.endpoint_next = try std.fmt.allocPrint(self.allocator, "http://{s}/2018-06-01/runtime/invocation/next", .{endpoint});
            self.endpoint_response = try std.fmt.allocPrint(self.allocator, "http://{s}/2018-06-01/runtime/invocation/", .{endpoint});
            self.endpoint_init_error = try std.fmt.allocPrint(self.allocator, "http://{s}/2018-06-01/runtime/init/error", .{endpoint});
        }

        pub fn deinit(self: *Self) void {
            self.http_client.deinit();
            self.allocator.free(self.endpoint_next);
            self.allocator.free(self.endpoint_response);
            self.allocator.free(self.endpoint_init_error);
        }

        fn respondError(self: *Self, ctx: *Context, err: anyerror) !void {
            var payloadT: ErrorReq = .{
                .errorType = err,
            };
            const payload = try payloadT.toJsonString(self.allocator);
            defer self.allocator.free(payload);
            const url = try std.fmt.allocPrint(self.allocator, "{s}{s}/error", .{ self.endpoint_response, ctx.request_id });
            defer self.allocator.free(url);
            var uri = try std.Uri.parse(url);
            var client_headers = std.http.Headers{ .allocator = self.allocator };
            defer client_headers.deinit();
            var req = try self.http_client.request(.POST, uri, client_headers, .{});
            req.transfer_encoding = .{ .content_length = payload.len };
            defer req.deinit();
            try req.start();
            _ = try req.write(payload);
            try req.finish();
            try req.wait();
        }

        const ErrorReq = struct {
            errorType: anyerror,
            errorMessage: ?[]u8 = undefined,

            fn toJsonString(self: *@This(), allocator: Allocator) ![]const u8 {
                return try std.json.stringifyAlloc(allocator, self, .{});
            }
        };
    };
}

const user_agent = "zig-lambda";
