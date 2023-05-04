const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Runtime = struct {
    allocator: Allocator,
    http_client: std.http.Client,
    handler: *const fn (allocator: Allocator, ctx: *const Context) anyerror!void,

    // endpoints
    endpoint_next: []u8 = undefined,
    endpoint_response: []u8 = undefined,
    endpoint_init_error: []u8 = undefined,

    const RuntimeError = error{ NextInvokeFailed, LambdaRuntimeEnvironmentVariableNotFound };

    pub fn new(allocator: Allocator, handler: *const fn (allocator: Allocator, ctx: *const Context) anyerror!void) Runtime {
        var http_client = std.http.Client{ .allocator = allocator };
        return .{
            .allocator = allocator,
            .http_client = http_client,
            .handler = handler,
        };
    }

    pub fn start(self: *Runtime) !void {
        const api_endpoint = std.os.getenv("AWS_LAMBDA_RUNTIME_API") orelse return error.LambdaRuntimeEnvironmentVariableNotFound;
        try self.setEndpoint(api_endpoint);
        while (true) {
            try self.next();
        }
    }

    fn next(self: *Runtime) !void {
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
        defer self.allocator.free(body);
        const ctx: Context = .{
            .rt = self,
            .request_id = id,
            .trace_id = trace_id,
            .invoked_function_arn = fn_arn,
            .event_payload = body,
        };
        self.handler(self.allocator, &ctx) catch |err| {
            try self.respondError(&ctx, err);
        };
    }

    fn respond(self: *Runtime, ctx: *const Context, body: []const u8) !void {
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

    fn setEndpoint(self: *Runtime, endpoint: []const u8) !void {
        self.endpoint_next = try std.fmt.allocPrint(self.allocator, "http://{s}/2018-06-01/runtime/invocation/next", .{endpoint});
        self.endpoint_response = try std.fmt.allocPrint(self.allocator, "http://{s}/2018-06-01/runtime/invocation/", .{endpoint});
        self.endpoint_init_error = try std.fmt.allocPrint(self.allocator, "http://{s}/2018-06-01/runtime/init/error", .{endpoint});
    }

    pub fn deinit(self: *Runtime) void {
        self.http_client.deinit();
        self.allocator.free(self.endpoint_next);
        self.allocator.free(self.endpoint_response);
        self.allocator.free(self.endpoint_init_error);
    }

    fn respondError(self: *Runtime, ctx: *const Context, err: anyerror) !void {
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

    // Request Context
    pub const Context = struct {
        rt: *Runtime,
        request_id: []const u8,
        event_payload: []const u8,
        trace_id: []const u8,
        invoked_function_arn: []const u8,

        // send te payload back
        pub fn respond(ctx: *const Context, payload: []const u8) !void {
            try ctx.rt.respond(ctx, payload);
        }
    };
};

const user_agent = "zig-lambda";
