//! The JSON Schema of a Zig type, made from the type at compile time: of the JSON `std.json` reads as a value of it.
//! The type says what it can — the JSON type of its values; an enum's names; a slice's items; a struct's properties,
//! and the fields it requires, those with no default — and a struct says the rest in its public declaration `schema`:
//! for a field, by its name, the keywords its type does not say, such as a description or bounds, each written as
//! JSON. A keyword the field's type says is not said again there, and each name there is a field's.
//!
//!     const Read = struct {
//!         path: []const u8,
//!         limit: ?u32 = null,
//!
//!         pub const schema = .{
//!             .path = .{ .description = "The file to read" },
//!             .limit = .{ .description = "How many lines", .minimum = 1 },
//!         };
//!     };
//!
//! `of(Read)` is
//!
//!     {"type":"object","properties":{"path":{"type":"string","description":"The file to read"},
//!     "limit":{"type":"integer","description":"How many lines","minimum":1}},"required":["path"]}
const std = @import("std");

/// The JSON Schema of `T`, as JSON text.
pub inline fn of(comptime T: type) []const u8 {
    comptime {
        // Making a schema takes the compiler some steps for each of its characters.
        @setEvalBranchQuota(1_000_000);
        return object(said(T));
    }
}

/// A member of a JSON object: its name, and its value as JSON.
const Member = struct { name: []const u8, json: []const u8 };

/// What `T` says of its schema, as the schema's members.
fn said(comptime T: type) []const Member {
    if (std.meta.hasFn(T, "jsonParse")) @compileError(@typeName(T) ++ " reads its JSON its own way, which its type does not say");
    return switch (@typeInfo(T)) {
        .bool => &.{member("type", "boolean")},
        .int => &.{member("type", "integer")},
        .float => &.{member("type", "number")},
        // A null is no value to give: an optional is given as what it holds.
        .optional => |optional| said(optional.child),
        .@"enum" => |info| &.{ member("type", "string"), member("enum", info.field_names) },
        .pointer => |pointer| if (pointer.size != .slice)
            unsupported(T)
        else if (pointer.child == u8)
            &.{member("type", "string")}
        else
            &.{ member("type", "array"), .{ .name = "items", .json = object(said(pointer.child)) } },
        .@"struct" => |info| if (info.is_tuple) unsupported(T) else properties(T),
        else => unsupported(T),
    };
}

/// What struct `T` says of its schema: an object whose properties are its fields, those with no default required.
fn properties(comptime T: type) []const Member {
    const info = @typeInfo(T).@"struct";
    const declared = if (@hasDecl(T, "schema")) T.schema else .{};
    inline for (@typeInfo(@TypeOf(declared)).@"struct".field_names) |name| {
        if (!@hasField(T, name)) @compileError(@typeName(T) ++ ".schema gives " ++ name ++ ", which is no field of it");
    }
    var each: []const Member = &.{};
    var required: []const []const u8 = &.{};
    inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
        const keywords = if (@hasField(@TypeOf(declared), name)) @field(declared, name) else .{};
        each = each ++ .{Member{ .name = name, .json = property(Field, keywords, @typeName(T) ++ ".schema." ++ name) }};
        if (attrs.default_value_ptr == null) required = required ++ .{name};
    }
    const members: []const Member = &.{ member("type", "object"), .{ .name = "properties", .json = object(each) } };
    return if (required.len == 0) members else members ++ .{member("required", required)};
}

/// The schema of a field of type `Field`: what its type says, then `keywords`, as the declaration `where` gives them.
fn property(comptime Field: type, comptime keywords: anytype, comptime where: []const u8) []const u8 {
    var members = said(Field);
    inline for (@typeInfo(@TypeOf(keywords)).@"struct".field_names) |keyword| {
        inline for (members) |each| {
            if (std.mem.eql(u8, each.name, keyword)) @compileError(where ++ " gives " ++ keyword ++ ", which the field's type says");
        }
        members = members ++ .{member(keyword, @field(keywords, keyword))};
    }
    return object(members);
}

/// The member `name` whose value is `value`, written as JSON.
fn member(comptime name: []const u8, comptime value: anytype) Member {
    return .{ .name = name, .json = json(value) };
}

/// The JSON object of `members`, in their order.
fn object(comptime members: []const Member) []const u8 {
    var text: []const u8 = "{";
    for (members, 0..) |each, at| text = text ++ (if (at == 0) "" else ",") ++ json(each.name) ++ ":" ++ each.json;
    return text ++ "}";
}

fn json(comptime value: anytype) []const u8 {
    return std.fmt.comptimePrint("{f}", .{std.json.fmt(value, .{})});
}

fn unsupported(comptime T: type) noreturn {
    @compileError("no JSON Schema is made of " ++ @typeName(T));
}

test "a type's schema is what its type says of its JSON, then what its declaration gives each field" {
    const Edit = struct {
        old: []const u8,
        new: []const u8,

        pub const schema = .{ .old = .{ .description = "The text to replace" } };
    };
    const Change = struct {
        path: []const u8,
        mode: enum { fast, full } = .fast,
        limit: ?u32 = null,
        ratio: f64 = 1,
        all: bool = false,
        tags: []const []const u8 = &.{},
        edits: []const Edit,

        pub const schema = .{
            .path = .{ .description = "The file, \"quoted\"", .examples = .{"a.md"} },
            .limit = .{ .minimum = 1, .maximum = 600 },
            .edits = .{ .minItems = 1 },
        };
    };
    try std.testing.expectEqualStrings(
        \\{"type":"object","properties":{"path":{"type":"string","description":"The file, \"quoted\"","examples":["a.md"]},
    ++
        \\"mode":{"type":"string","enum":["fast","full"]},"limit":{"type":"integer","minimum":1,"maximum":600},
    ++
        \\"ratio":{"type":"number"},"all":{"type":"boolean"},"tags":{"type":"array","items":{"type":"string"}},
    ++
        \\"edits":{"type":"array","items":{"type":"object","properties":{"old":{"type":"string","description":"The text to replace"},
    ++
        \\"new":{"type":"string"}},"required":["old","new"]},"minItems":1}},"required":["path","edits"]}
    , of(Change));
    try std.testing.expectEqualStrings("{\"type\":\"object\",\"properties\":{}}", of(struct {}));
    try std.testing.expectEqualStrings("{\"type\":\"array\",\"items\":{\"type\":\"integer\"}}", of([]const i64));
}
