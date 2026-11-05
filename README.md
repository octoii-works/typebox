# typebox

JSON Schema for Zig: a type's schema made from the type at compile time, so a value's type and its schema are one
thing written once; and values checked against a schema.

```zig
const typebox = @import("typebox");

const Read = struct {
    path: []const u8,
    limit: ?u32 = null,

    pub const schema = .{
        .path = .{ .description = "The file to read" },
        .limit = .{ .description = "How many lines", .minimum = 1 },
    };
};

const parameters = typebox.of(Read);
// {"type":"object","properties":{"path":{"type":"string","description":"The file to read"},
// "limit":{"type":"integer","description":"How many lines","minimum":1}},"required":["path"]}
```

## A type's schema

`of(T)` is the schema of the JSON `std.json` reads as a `T`, as JSON text. The type says what it can:

| Zig          | JSON Schema                                                                 |
| ------------ | --------------------------------------------------------------------------- |
| `bool`       | `{"type":"boolean"}`                                                        |
| an integer   | `{"type":"integer"}`                                                        |
| a float      | `{"type":"number"}`                                                         |
| `[]const u8` | `{"type":"string"}`                                                         |
| an enum      | `{"type":"string","enum":[its names]}`                                      |
| `[]const T`  | `{"type":"array","items":T's}`                                              |
| `?T`         | `T`'s                                                                       |
| a struct     | `{"type":"object","properties":{…},"required":[the fields with no default]}` |

A struct says the rest in its public declaration `schema`: for a field, by its name, the keywords its type does not
say — a description, bounds, a format, examples — each written as JSON. It is checked as the schema is made: a name
there that is no field, or a keyword the field's type says already, does not compile. Nor does a type with no JSON
Schema made of it: a tuple, a union, an array of fixed length, a type that reads its JSON its own way.

## Checking a value

```zig
const found = try typebox.problems(arena, schema, value);
if (found.len > 0) std.log.err("{s}", .{try typebox.shown(arena, found)});
```

`schema` and `value` are `std.json.Value`s; each problem is where it is, as a JSON Pointer, and how — `/limit must be
>= 1`. The check knows types, enumerations and constants; an object's properties, required members and others; an
array's items, its length and uniqueness; a string's length; a number's bounds and multiple; `allOf`, `anyOf`, `oneOf`
and `not`; and `$ref` within the schema. A keyword it does not know, such as a `format` or a `pattern`, is passed over:
a value is never refused for what the check cannot see.

## Using it

```sh
zig fetch --save git+https://github.com/octoii-works/typebox
```

```zig
const typebox = b.dependency("typebox", .{ .target = target, .optimize = optimize }).module("typebox");
module.addImport("typebox", typebox);
```

It needs Zig 0.17, and its standard library alone. `zig build check` formats and tests it. Under the MIT licence.
