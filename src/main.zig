const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked) {
            @panic("leaked");
        }
    }
    const allocator = gpa.allocator();
    var runtime = Runtime.new(allocator, &handler);
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
        const api_endpoint = std.os.getenv("AWS_LAMBDA_RUNTIME_API") orelse "";
        try self.setEndpoint(api_endpoint);

        while (true) {
            const ctx = try self.next();
            defer self.allocator.free(ctx.body);
            const res = try self.handler(self.allocator, ctx.body);
            try self.respond(ctx, res);
        }
    }

    fn next(self: *Self) !Context {
        const endpoint = try std.Uri.parse(self.endpoint_next);
        var req = try self.http_client.request(endpoint, .{
            .user_agent = user_agent,
        }, .{});
        defer req.deinit();
        try req.do();
        var ch = CustomHeader.init(req.response.parser.header_bytes.items);
        var body = try req.reader().readAllAlloc(self.allocator, 1024 * 1024 * 10);
        return .{
            .request_id = try ch.get("Lambda-Runtime-Aws-Request-Id"),
            .body = body,
        };
    }

    fn respond(self: *Self, ctx: Context, body: []const u8) !void {
        const respondUrl = try std.fmt.allocPrint(self.allocator, "{s}{s}/response", .{ self.endpoint_next, ctx.request_id });
        defer self.allocator.free(respondUrl);
        var uri = try std.Uri.parse(respondUrl);
        var req = try self.http_client.request(uri, .{
            .user_agent = user_agent,
            .method = .POST,
        }, .{});
        defer req.deinit();
        // try req.writer().writeAll(body);
        try req.do();
        _ = try req.write(body);
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

test "testclient" {
    const expect = std.testing.expect;
    _ = expect;
    var http_client = std.http.Client{ .allocator = std.testing.allocator };
    defer http_client.deinit();
    const uri = try std.Uri.parse("https://grng.dev");
    var req = try http_client.request(uri, .{}, .{});
    defer req.deinit();
    try req.do();
    std.debug.print("\n{s}", .{req.response.parser.header_bytes.items});
    var ch = CustomHeader.init(req.response.parser.header_bytes.items);
    const v = try ch.get("Access-Control-Allow-Origin");
    std.debug.print("\n{s}\n", .{v});
}

const CustomHeader = struct {
    const Self = @This();
    raw_data: []u8,

    fn init(raw_header: []u8) @This() {
        return .{ .raw_data = raw_header };
    }

    pub const Headererrors = error{InvalidHttpHeader};

    fn get(self: *Self, key: []const u8) Headererrors![]const u8 {
        var itr = std.mem.tokenize(u8, self.raw_data, "\r\n");
        _ = itr.next() orelse return error.InvalidHttpHeader;
        while (itr.next()) |line| {
            if (line.len == 0) {
                continue;
            }
            var kvitr = std.mem.tokenize(u8, line, ": ");
            const k = kvitr.next() orelse return Headererrors.InvalidHttpHeader;
            if (std.ascii.eqlIgnoreCase(k, key)) {
                return kvitr.rest();
            }
        }
        return "";
    }
};
