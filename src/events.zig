const std = @import("std");
const Allocator = std.mem.Allocator;

pub const APIGatewayProxyRequest = struct {
    resource: []const u8,
    path: []const u8,
    httpMethod: []const u8,
    body: []const u8,
    isBase64Encoded: ?bool = null,
};

pub fn Event(comptime T: type) type {
    return struct {
        const Self = @This();
        payload: T,
        allocator: Allocator,
        json: bool = false,
        pub fn init(allocator: Allocator, body: []const u8) !Self {
            if (T == @TypeOf(body)) {
                return .{
                    .allocator = allocator,
                    .payload = body,
                };
            }
            return .{
                .allocator = allocator,
                .payload = try serialize(allocator, body),
                .json = true,
            };
        }

        fn serialize(allocator: Allocator, body: []const u8) !T {
            var stream = std.json.TokenStream.init(body);
            return try std.json.parse(T, &stream, .{ .allocator = allocator, .ignore_unknown_fields = true });
        }

        pub fn deinit(self: *Self) void {
            if (self.json) {
                std.json.parseFree(T, self.payload, .{ .allocator = self.allocator, .ignore_unknown_fields = true });
            }
        }
    };
}
