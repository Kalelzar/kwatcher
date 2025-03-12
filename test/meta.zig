const std = @import("std");
const kwatcher = @import("kwatcher");
const meta = kwatcher.meta;
const expect = std.testing.expect;
const expectError = std.testing.expectError;
const expectEqual = std.testing.expectEqual;

test "expect `isStruct` to succeed for structs." {
    try expect(meta.isStruct(struct {}));
}

test "expect `isStruct` to fail for pointers." {
    const v: struct {} = .{};
    try expect(!meta.isStruct(@TypeOf(&v)));
}

test "expect `isStruct` to fail for optional struct." {
    const v: ?struct {} = null;
    try expect(!meta.isStruct(@TypeOf(&v)));
}

test "expect `isStruct` to fail for error union." {
    const v: anyerror!struct {} = error.Valid;
    try expect(!meta.isStruct(@TypeOf(&v)));
    const v2: anyerror!struct {} = .{};
    try expect(!meta.isStruct(@TypeOf(&v2)));
}

test "expect `MergeStruct` to merge two structs together" {
    const A = struct { a: i32 };
    const B = struct { b: i32 };

    const C = meta.MergeStructs(A, B);
    try expect(@hasField(C, "a"));
    try expect(@hasField(C, "b"));
}

test "expect `overlaps` to correctly validate a flat struct" {
    const A = struct {
        a: i32,
        b: []const u8,
        c: ?u8 = null,
        d: *i32,
    };

    const B = struct {
        a: i32,
        b: []const u8,
        c: ?u8 = null,
        d: *i32,
    };

    try expect(comptime meta.overlaps(A, B));
    try expect(comptime meta.overlaps(B, A));
}

test "expect `overlaps` to be uni-directional (A subset B, but not B subset A)" {
    const A = struct {
        a: i32,
        b: []const u8,
    };

    const B = struct {
        a: i32,
        b: []const u8,
        c: ?u8 = null,
        d: *i32,
    };

    try expect(comptime meta.overlaps(A, B));
    try expect(!comptime meta.overlaps(B, A));
}

test "expect `overlaps` to succeed even if fields differ in optional." {
    const A = struct {
        a: ?i32,
        b: ?[]const u8,
        c: ?u8 = null,
        d: ?*i32,
    };

    const B = struct {
        a: i32,
        b: []const u8,
        c: u8,
        d: *i32,
    };

    try expect(comptime meta.overlaps(A, B));
    try expect(comptime meta.overlaps(B, A));
}

test "expect `overlaps` to follow structs and arrays." {
    const A = struct {
        a: i32,
        b: []const u8,
        c: u8,
        d: *i32,
    };

    const B = struct {
        a: A,
        b: *A,
        c: []A,
        d: ?A,
    };

    try expect(comptime meta.overlaps(B, B));
}

test "expect `overlaps` to succeed for deeply nested structs." {
    const B = struct {
        a: struct {
            b: []struct {
                c: *struct {
                    d: ?struct {
                        u: u1,
                        i: i1,
                        a: []const u8,
                    },
                },
            },
        },
    };

    try expect(comptime meta.overlaps(B, B));
}

test "expect `assertNotEmpty` to fail if an object is null" {
    const S = struct {
        s: ?i32 = null,
    };
    const s = S{};
    try expectError(
        error.Null,
        meta.assertNotEmpty(S, s),
    );
}

test "expect `assertNotEmpty` to fail if a pointer is null" {
    const S = struct {
        s: []i32 = &.{},
    };
    const s = S{};
    try expectError(
        error.EmptyPointer,
        meta.assertNotEmpty(S, s),
    );
}

test "expect `copyTo` to selectively copy only matching fields from one struct to another" {
    const A = struct {
        replace: i32 = 1,
        skip: i32 = 2,
    };

    const B = struct {
        replace: i32 = 2,
        remain: i32 = 3,
    };

    const a = A{};
    var b = B{};

    _ = meta.copyTo(A, B, a, &b);
    try expectEqual(3, b.remain);
    try expectEqual(1, b.replace);
}

test "expect `copyTo` to recursively copy only matching fields from one struct to another" {
    const A = struct {
        inner: struct {
            replace: i32 = 1,
            skip: i32 = 2,
        } = .{},
    };

    const B = struct {
        inner: struct {
            replace: i32 = 2,
            remain: i32 = 3,
        } = .{},
    };

    const a = A{};
    var b = B{};

    _ = meta.copyTo(A, B, a, &b);
    try expectEqual(3, b.inner.remain);
    try expectEqual(1, b.inner.replace);
}

test "expect `copyTo` to copy only matching fields while disregarding their optionality" {
    const A = struct {
        inner: struct {
            replace: ?i32 = 1,
            skip: i32 = 2,
        } = .{},
    };

    const B = struct {
        inner: struct {
            replace: i32 = 2,
            remain: i32 = 3,
        } = .{},
    };

    const a = A{};
    var b = B{};

    _ = meta.copyTo(A, B, a, &b);
    try expectEqual(3, b.inner.remain);
    try expectEqual(1, b.inner.replace);
}

test "expect `copyTo` to copy only fields that aren't null" {
    const A = struct {
        inner: struct {
            replace: ?i32 = null,
            skip: i32 = 2,
        } = .{},
    };

    const B = struct {
        inner: struct {
            replace: i32 = 2,
            remain: i32 = 3,
        } = .{},
    };

    const a = A{};
    var b = B{};

    _ = meta.copyTo(A, B, a, &b);
    try expectEqual(3, b.inner.remain);
    try expectEqual(2, b.inner.replace);
}

test "expect `copy` to instantiate a new struct that is a subset of another" {
    const A = struct {
        inner: struct {
            replace: ?i32 = 1,
            skip: i32 = 2,
        } = .{},
    };

    const B = struct {
        inner: struct {
            replace: i32 = 2,
            remain: i32 = 3,
        } = .{},
    };

    const a = A{};

    const b = meta.copy(A, B, a);
    try expectEqual(3, b.inner.remain);
    try expectEqual(1, b.inner.replace);
}

test "expect `merge` to produce a struct instance that is a field-wise merge of two other structs" {
    const A = struct {
        inner: struct {
            left: ?i32 = 1,
            right: i32 = 2,
        } = .{},
    };

    const B = struct {
        a: i32 = 3,
        b: i32 = 4,
    };

    const C = meta.MergeStructs(A, B);

    const a = A{};
    const b = B{};

    const c = meta.merge(A, B, C, a, b);
    try expectEqual(1, c.inner.left);
    try expectEqual(2, c.inner.right);
    try expectEqual(3, c.a);
    try expectEqual(4, c.b);
}

test "expect `typeId` to produce a fingerprint for a type that is comparable at compile-time" {
    const T = struct {};
    const a = meta.typeId(T);
    const b = meta.typeId(T);
    try expectEqual(a, b);

    const U = struct {};
    const c = meta.typeId(U);
    try expect(a != c);
}

test "expect `Return` to correctly identify the return type of a function" {
    const F = struct {
        pub fn t() i32 {
            return 1;
        }

        pub fn u() anyerror!i32 {
            return 1;
        }
    };

    try expectEqual(i32, meta.Return(F.t));
    try expectEqual(anyerror!i32, meta.Return(F.u));
}

test "expect `Result` to correctly identify the result type of a function" {
    const F = struct {
        pub fn t() i32 {
            return 1;
        }

        pub fn u() !i32 {
            return 1;
        }
    };

    try expectEqual(i32, meta.Result(F.t));
    try expectEqual(i32, meta.Result(F.u));
}

test "expect `canBeError` to correctly identify if a function can return an error" {
    const F = struct {
        pub fn t() i32 {
            return 1;
        }

        pub fn u() !i32 {
            return 1;
        }

        pub fn e() anyerror {
            return error.Test;
        }
    };

    try expect(!meta.canBeError(F.t));
    try expect(meta.canBeError(F.u));
    try expect(meta.canBeError(F.e));
}
