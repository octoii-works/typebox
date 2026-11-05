//! typebox: JSON Schema for Zig. A type's schema is made from the type, at compile time, so a value's type and its
//! schema are one thing written once (`of`); and a value, as `std.json` parses it, is checked against a schema
//! (`problems`, `matches`).
const std = @import("std");
const types = @import("types.zig");
const values = @import("values.zig");

pub const of = types.of;
pub const Problem = values.Problem;
pub const problems = values.problems;
pub const matches = values.matches;
pub const shown = values.shown;

test "a value is checked against its type's schema as std.json reads it as the type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Read = struct {
        path: []const u8,
        limit: ?u32 = null,

        pub const schema = .{ .limit = .{ .minimum = 1 } };
    };
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, a, of(Read), .{});
    const given = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"path\":\"a.md\",\"limit\":2}", .{});
    try std.testing.expect(try matches(a, schema, given));
    try std.testing.expectEqual(@as(?u32, 2), (try std.json.parseFromValueLeaky(Read, a, given, .{})).limit);
    const wrong = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"limit\":0}", .{});
    try std.testing.expectEqualStrings("/ must have required property 'path'; /limit must be >= 1", try shown(a, try problems(a, schema, wrong)));
}

test {
    _ = types;
    _ = values;
}
