//! Values checked against a JSON Schema, both as `std.json` parses them: types, enumerations and constants; an
//! object's properties, required members and others; an array's items, its length and uniqueness; a string's length; a
//! number's bounds and multiple; `allOf`, `anyOf`, `oneOf` and `not`; and `$ref` within the schema. A keyword it does
//! not know, such as a `format` or a `pattern`, is passed over: a value is never refused for what the check cannot
//! see.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Where a value fails its schema, as a JSON Pointer, and how.
pub const Problem = struct {
    path: []const u8,
    message: []const u8,
};

/// The problems of `value` against `schema`, each where it is; none where it matches.
pub fn problems(arena: Allocator, schema: Value, value: Value) Allocator.Error![]const Problem {
    var checker: Checker = .{ .arena = arena, .root = schema };
    try checker.check(schema, value, "");
    return checker.found.items;
}

/// Whether `value` matches `schema`.
pub fn matches(arena: Allocator, schema: Value, value: Value) Allocator.Error!bool {
    return (try problems(arena, schema, value)).len == 0;
}

/// The problems, one a line: where, then what is wrong.
pub fn shown(arena: Allocator, found: []const Problem) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (found, 0..) |problem, index| {
        if (index > 0) try out.appendSlice(arena, "; ");
        try out.print(arena, "{s} {s}", .{ if (problem.path.len == 0) "/" else problem.path, problem.message });
    }
    return out.items;
}

/// How deep `$ref` may lead before a schema is taken for one that refers to itself without end.
const max_depth = 64;

const Checker = struct {
    arena: Allocator,
    root: Value,
    found: std.ArrayList(Problem) = .empty,
    depth: usize = 0,

    fn fail(checker: *Checker, path: []const u8, comptime text: []const u8, arguments: anytype) Allocator.Error!void {
        try checker.found.append(checker.arena, .{ .path = path, .message = try std.fmt.allocPrint(checker.arena, text, arguments) });
    }

    fn check(checker: *Checker, schema: Value, value: Value, path: []const u8) Allocator.Error!void {
        switch (schema) {
            .bool => |allowed| return if (!allowed) checker.fail(path, "is not allowed", .{}),
            .object => {},
            // What is no schema says nothing.
            else => return,
        }
        const keywords = schema.object;
        if (keywords.get("$ref")) |reference| try checker.referenced(reference, value, path);
        if (keywords.get("type")) |types| if (!typeFits(types, value)) return checker.fail(path, "must be {s}", .{try typeNames(checker.arena, types)});
        if (keywords.get("enum")) |options| if (options == .array) {
            for (options.array.items) |option| {
                if (equal(option, value)) break;
            } else try checker.fail(path, "must be one of the enumerated values", .{});
        };
        if (keywords.get("const")) |constant| if (!equal(constant, value)) try checker.fail(path, "must be the constant value", .{});
        switch (value) {
            .integer, .float, .number_string => try checker.number(keywords, numberOf(value), path),
            .string => |text| try checker.string(keywords, text, path),
            .array => |array| try checker.items(keywords, array.items, path),
            .object => |object| try checker.members(keywords, object, path),
            else => {},
        }
        try checker.applicators(keywords, value, path);
    }

    fn referenced(checker: *Checker, reference: Value, value: Value, path: []const u8) Allocator.Error!void {
        if (reference != .string) return;
        const target = pointed(checker.root, reference.string) orelse return;
        if (checker.depth == max_depth) return checker.fail(path, "refers through its schema too deeply", .{});
        checker.depth += 1;
        defer checker.depth -= 1;
        try checker.check(target, value, path);
    }

    fn number(checker: *Checker, keywords: std.json.ObjectMap, given: f64, path: []const u8) Allocator.Error!void {
        if (numberIn(keywords, "minimum")) |bound| if (given < bound) try checker.fail(path, "must be >= {d}", .{bound});
        if (numberIn(keywords, "maximum")) |bound| if (given > bound) try checker.fail(path, "must be <= {d}", .{bound});
        if (numberIn(keywords, "exclusiveMinimum")) |bound| if (given <= bound) try checker.fail(path, "must be > {d}", .{bound});
        if (numberIn(keywords, "exclusiveMaximum")) |bound| if (given >= bound) try checker.fail(path, "must be < {d}", .{bound});
        if (numberIn(keywords, "multipleOf")) |factor| if (factor > 0) {
            const ratio = given / factor;
            if (@abs(ratio - @round(ratio)) > 1e-9) try checker.fail(path, "must be a multiple of {d}", .{factor});
        };
    }

    fn string(checker: *Checker, keywords: std.json.ObjectMap, text: []const u8, path: []const u8) Allocator.Error!void {
        const length = std.unicode.utf8CountCodepoints(text) catch text.len;
        if (numberIn(keywords, "minLength")) |bound| if (@as(f64, @floatFromInt(length)) < bound) try checker.fail(path, "must have at least {d} characters", .{bound});
        if (numberIn(keywords, "maxLength")) |bound| if (@as(f64, @floatFromInt(length)) > bound) try checker.fail(path, "must have at most {d} characters", .{bound});
    }

    fn items(checker: *Checker, keywords: std.json.ObjectMap, given: []const Value, path: []const u8) Allocator.Error!void {
        const count: f64 = @floatFromInt(given.len);
        if (numberIn(keywords, "minItems")) |bound| if (count < bound) try checker.fail(path, "must have at least {d} items", .{bound});
        if (numberIn(keywords, "maxItems")) |bound| if (count > bound) try checker.fail(path, "must have at most {d} items", .{bound});
        if (keywords.get("uniqueItems")) |unique| if (unique == .bool and unique.bool and !allUnique(given)) try checker.fail(path, "must have unique items", .{});
        var first: usize = 0;
        if (keywords.get("prefixItems")) |prefix| if (prefix == .array) {
            for (prefix.array.items, 0..) |schema, index| {
                if (index >= given.len) break;
                try checker.check(schema, given[index], try indexed(checker.arena, path, index));
            }
            first = prefix.array.items.len;
        };
        const each = keywords.get("items") orelse return;
        for (given, 0..) |item, index| if (index >= first) try checker.check(each, item, try indexed(checker.arena, path, index));
    }

    fn members(checker: *Checker, keywords: std.json.ObjectMap, object: std.json.ObjectMap, path: []const u8) Allocator.Error!void {
        const count: f64 = @floatFromInt(object.count());
        if (numberIn(keywords, "minProperties")) |bound| if (count < bound) try checker.fail(path, "must have at least {d} properties", .{bound});
        if (numberIn(keywords, "maxProperties")) |bound| if (count > bound) try checker.fail(path, "must have at most {d} properties", .{bound});
        if (keywords.get("required")) |required| if (required == .array) for (required.array.items) |name| {
            if (name == .string and !object.contains(name.string)) try checker.fail(path, "must have required property '{s}'", .{name.string});
        };
        const properties: ?std.json.ObjectMap = if (keywords.get("properties")) |given| (if (given == .object) given.object else null) else null;
        const others = keywords.get("additionalProperties");
        var it = object.iterator();
        while (it.next()) |member| {
            const at = try named(checker.arena, path, member.key_ptr.*);
            if (properties) |declared| if (declared.get(member.key_ptr.*)) |schema| {
                try checker.check(schema, member.value_ptr.*, at);
                continue;
            };
            if (others) |schema| {
                if (schema == .bool and !schema.bool) try checker.fail(at, "must not be present", .{}) else try checker.check(schema, member.value_ptr.*, at);
            }
        }
    }

    fn applicators(checker: *Checker, keywords: std.json.ObjectMap, value: Value, path: []const u8) Allocator.Error!void {
        if (keywords.get("allOf")) |all| if (all == .array) for (all.array.items) |schema| try checker.check(schema, value, path);
        if (keywords.get("anyOf")) |any| if (any == .array) {
            if (try checker.fitting(any.array.items, value, path) == 0) try checker.fail(path, "must match a schema in anyOf", .{});
        };
        if (keywords.get("oneOf")) |one| if (one == .array) {
            if (try checker.fitting(one.array.items, value, path) != 1) try checker.fail(path, "must match exactly one schema in oneOf", .{});
        };
        if (keywords.get("not")) |negated| {
            if (try checker.fitting(&.{negated}, value, path) == 1) try checker.fail(path, "must not match the schema in not", .{});
        }
    }

    /// How many of `schemas` `value` matches, their problems kept out of the checker's own.
    fn fitting(checker: *Checker, schemas: []const Value, value: Value, path: []const u8) Allocator.Error!usize {
        var count: usize = 0;
        for (schemas) |schema| {
            var apart: Checker = .{ .arena = checker.arena, .root = checker.root, .depth = checker.depth };
            try apart.check(schema, value, path);
            if (apart.found.items.len == 0) count += 1;
        }
        return count;
    }
};

fn allUnique(given: []const Value) bool {
    for (given, 0..) |item, index| for (given[0..index]) |earlier| if (equal(item, earlier)) return false;
    return true;
}

/// Whether two values are one, as JSON Schema has them: an object's members in any order, a number by what it is worth.
fn equal(a: Value, b: Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |value| b == .bool and b.bool == value,
        .string => |text| b == .string and std.mem.eql(u8, text, b.string),
        // What is no number is worth nothing a number equals.
        .integer, .float, .number_string => numberOf(a) == numberOf(b),
        .array => |items| b == .array and b.array.items.len == items.items.len and for (items.items, b.array.items) |left, right| {
            if (!equal(left, right)) break false;
        } else true,
        .object => |members| b == .object and b.object.count() == members.count() and objectsEqual(members, b.object),
    };
}

fn objectsEqual(a: std.json.ObjectMap, b: std.json.ObjectMap) bool {
    var it = a.iterator();
    while (it.next()) |member| {
        const other = b.get(member.key_ptr.*) orelse return false;
        if (!equal(member.value_ptr.*, other)) return false;
    }
    return true;
}

/// Whether `value` is of one of the types `types` names.
fn typeFits(types: Value, value: Value) bool {
    return switch (types) {
        .string => |name| isType(name, value),
        .array => |names| for (names.items) |name| {
            if (name == .string and isType(name.string, value)) break true;
        } else false,
        else => true,
    };
}

fn isType(name: []const u8, value: Value) bool {
    const eql = std.mem.eql;
    return switch (value) {
        .null => eql(u8, name, "null"),
        .bool => eql(u8, name, "boolean"),
        .integer => eql(u8, name, "integer") or eql(u8, name, "number"),
        .float, .number_string => eql(u8, name, "number") or (eql(u8, name, "integer") and @floor(numberOf(value)) == numberOf(value)),
        .string => eql(u8, name, "string"),
        .array => eql(u8, name, "array"),
        .object => eql(u8, name, "object"),
    };
}

fn typeNames(arena: Allocator, types: Value) Allocator.Error![]const u8 {
    if (types == .string) return types.string;
    var names: std.ArrayList([]const u8) = .empty;
    for (types.array.items) |name| if (name == .string) try names.append(arena, name.string);
    return std.mem.join(arena, " or ", names.items);
}

fn numberOf(value: Value) f64 {
    return switch (value) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        .number_string => |text| std.fmt.parseFloat(f64, text) catch std.math.nan(f64),
        else => std.math.nan(f64),
    };
}

fn numberIn(keywords: std.json.ObjectMap, name: []const u8) ?f64 {
    const given = keywords.get(name) orelse return null;
    return switch (given) {
        .integer, .float, .number_string => numberOf(given),
        else => null,
    };
}

/// The schema `reference`, a JSON Pointer within `root` such as `#/$defs/item`, points to; null where it points nowhere.
fn pointed(root: Value, reference: []const u8) ?Value {
    if (!std.mem.startsWith(u8, reference, "#")) return null;
    var at = root;
    var tokens = std.mem.tokenizeScalar(u8, reference[1..], '/');
    while (tokens.next()) |token| {
        var buffer: [256]u8 = undefined;
        const key = unescaped(&buffer, token) orelse return null;
        at = switch (at) {
            .object => |object| object.get(key) orelse return null,
            .array => |array| array.items[std.fmt.parseInt(usize, key, 10) catch return null],
            else => return null,
        };
    }
    return at;
}

/// A JSON Pointer token with `~1` as `/` and `~0` as `~`; null where it does not fit `buffer`.
fn unescaped(buffer: []u8, token: []const u8) ?[]const u8 {
    var len: usize = 0;
    var index: usize = 0;
    while (index < token.len) : (index += 1) {
        if (len == buffer.len) return null;
        var char = token[index];
        if (char == '~' and index + 1 < token.len) {
            index += 1;
            char = if (token[index] == '1') '/' else '~';
        }
        buffer[len] = char;
        len += 1;
    }
    return buffer[0..len];
}

fn indexed(arena: Allocator, path: []const u8, index: usize) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{d}", .{ path, index });
}

fn named(arena: Allocator, path: []const u8, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ path, name });
}

fn parsed(arena: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

test "a value is checked against its schema's types, members, items and bounds, each problem where it is" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const schema = try parsed(a,
        \\{"type":"object","required":["name","count"],"additionalProperties":false,
        \\ "properties":{"name":{"type":"string","minLength":2},"count":{"type":"integer","minimum":0},
        \\  "tags":{"type":"array","items":{"enum":["a","b"]},"uniqueItems":true}}}
    );
    try std.testing.expect(try matches(a, schema, try parsed(a, "{\"name\":\"ok\",\"count\":3,\"tags\":[\"a\",\"b\"]}")));
    const found = try problems(a, schema, try parsed(a, "{\"name\":1,\"count\":-1,\"tags\":[\"c\",\"c\"],\"extra\":true}"));
    try std.testing.expectEqualStrings(
        "/name must be string; /count must be >= 0; /tags must have unique items; /tags/0 must be one of the enumerated values; /tags/1 must be one of the enumerated values; /extra must not be present",
        try shown(a, found),
    );
    try std.testing.expectEqualStrings("/ must have required property 'count'", try shown(a, try problems(a, schema, try parsed(a, "{\"name\":\"ok\"}"))));
    try std.testing.expectEqualStrings("/ must be object", try shown(a, try problems(a, schema, try parsed(a, "[]"))));
}

test "applicators and references are followed, and a keyword the check does not know is passed over" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const schema = try parsed(a,
        \\{"$defs":{"id":{"type":["string","integer"]}},"type":"object",
        \\ "properties":{"id":{"$ref":"#/$defs/id"},"when":{"type":"string","format":"date-time","pattern":"^x"},
        \\  "size":{"oneOf":[{"type":"integer","multipleOf":2},{"type":"integer","maximum":3}]},"note":{"not":{"type":"null"}}}}
    );
    try std.testing.expect(try matches(a, schema, try parsed(a, "{\"id\":7,\"when\":\"later\",\"size\":4,\"note\":\"n\"}")));
    const found = try problems(a, schema, try parsed(a, "{\"id\":true,\"size\":2,\"note\":null}"));
    try std.testing.expectEqualStrings("/id must be string or integer; /size must match exactly one schema in oneOf; /note must not match the schema in not", try shown(a, found));
    try std.testing.expect(try matches(a, .{ .bool = true }, .null));
    try std.testing.expect(!try matches(a, .{ .bool = false }, .null));
}
