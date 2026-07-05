const std = @import("std");

/// A 32-byte trace identity per KWEV.md §5: an immutable trace identity
/// (root timestamp, root operation, user, entropy) followed by a mutable hop
/// identity (parent_span → span links). Events that share the immutable part
/// belong to one trace; each route execution is a hop with its own span.
///
/// Note the packed layout is LSB-first in the backing integer — byte-level
/// sortability (timestamp-first prefix scans) comes from the explicit
/// big-endian `toBytes` encoding, never from `@bitCast`.
pub const CorrelationID = packed struct(u256) {
    // === IMMUTABLE TRACE IDENTITY (22 bytes) ===
    timestamp: u64,
    version: u8,
    root_op_id: u32,
    user_id: u32,
    flags: u8,
    entropy: u32,

    // === MUTABLE HOP IDENTITY (10 bytes) ===
    parent_span_id: u24,
    current_op_id: u32,
    span_id: u24,

    pub const unset: CorrelationID = @bitCast(@as(u256, 0));

    pub fn isUnset(self: CorrelationID) bool {
        return @as(u256, @bitCast(self)) == 0;
    }

    /// FNV-1a-32 over an operation (route) identifier. Callable at comptime;
    /// route ids are comptime-known everywhere except cron's anonymous jobs,
    /// which hash once at registration and carry the u32.
    pub fn hash(op: []const u8) u32 {
        if (@inComptime()) {
            @setEvalBranchQuota(comptime @intCast(100 * op.len));
            return std.hash.Fnv1a_32.hash(op);
        }
        return std.hash.Fnv1a_32.hash(op);
    }

    /// Start a new trace rooted at the given (pre-hashed) operation.
    pub fn newRoot(user_id: u32, op_id: u32) CorrelationID {
        return .{
            .timestamp = @intCast(std.time.nanoTimestamp()),
            .version = 0x01,
            .root_op_id = op_id,
            .user_id = user_id,
            .flags = 0,
            .entropy = std.crypto.random.int(u32),
            .parent_span_id = 0,
            .current_op_id = op_id,
            .span_id = std.crypto.random.int(u24),
        };
    }

    /// Continue the trace into the next operation: the current span becomes
    /// the parent and this hop gets a fresh span of its own.
    pub fn hop(self: CorrelationID, op_id: u32) CorrelationID {
        var next = self;
        next.current_op_id = op_id;
        next.parent_span_id = self.span_id;
        next.span_id = std.crypto.random.int(u24);
        return next;
    }

    /// Big-endian, declaration-ordered encoding: timestamp leads, so the
    /// byte (and hex) form sorts by trace start time.
    pub fn toBytes(self: CorrelationID) [32]u8 {
        var out: [32]u8 = undefined;
        std.mem.writeInt(u64, out[0..8], self.timestamp, .big);
        out[8] = self.version;
        std.mem.writeInt(u32, out[9..13], self.root_op_id, .big);
        std.mem.writeInt(u32, out[13..17], self.user_id, .big);
        out[17] = self.flags;
        std.mem.writeInt(u32, out[18..22], self.entropy, .big);
        std.mem.writeInt(u24, out[22..25], self.parent_span_id, .big);
        std.mem.writeInt(u32, out[25..29], self.current_op_id, .big);
        std.mem.writeInt(u24, out[29..32], self.span_id, .big);
        return out;
    }

    pub fn fromBytes(bytes: [32]u8) CorrelationID {
        return .{
            .timestamp = std.mem.readInt(u64, bytes[0..8], .big),
            .version = bytes[8],
            .root_op_id = std.mem.readInt(u32, bytes[9..13], .big),
            .user_id = std.mem.readInt(u32, bytes[13..17], .big),
            .flags = bytes[17],
            .entropy = std.mem.readInt(u32, bytes[18..22], .big),
            .parent_span_id = std.mem.readInt(u24, bytes[22..25], .big),
            .current_op_id = std.mem.readInt(u32, bytes[25..29], .big),
            .span_id = std.mem.readInt(u24, bytes[29..32], .big),
        };
    }

    /// The immutable trace identity: the first 22 bytes of the encoding.
    pub fn traceId(self: CorrelationID) [22]u8 {
        return self.toBytes()[0..22].*;
    }

    pub fn sameTrace(self: CorrelationID, other: CorrelationID) bool {
        return std.mem.eql(u8, &self.traceId(), &other.traceId());
    }

    /// 64 lowercase hex characters of the big-endian encoding — the wire
    /// and display form (AMQP correlation_id, x-correlation-id, UI).
    pub fn format(self: CorrelationID, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const bytes = self.toBytes();
        try writer.print("{x}", .{&bytes});
    }

    /// Inverse of `format`: exactly 64 hex characters, else null.
    pub fn parse(text: []const u8) ?CorrelationID {
        if (text.len != 64) return null;
        var bytes: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&bytes, text) catch return null;
        return fromBytes(bytes);
    }
};

const test_id = CorrelationID{
    .timestamp = 0x0102030405060708,
    .version = 0x01,
    .root_op_id = 0xAABBCCDD,
    .user_id = 0x11223344,
    .flags = 0x02,
    .entropy = 0xDEADBEEF,
    .parent_span_id = 0x0A0B0C,
    .current_op_id = 0x55667788,
    .span_id = 0x0D0E0F,
};

test "toBytes: golden big-endian, declaration-ordered layout" {
    const expected = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, // timestamp
        0x01, // version
        0xAA, 0xBB, 0xCC, 0xDD, // root_op_id
        0x11, 0x22, 0x33, 0x44, // user_id
        0x02, // flags
        0xDE, 0xAD, 0xBE, 0xEF, // entropy
        0x0A, 0x0B, 0x0C, // parent_span_id
        0x55, 0x66, 0x77, 0x88, // current_op_id
        0x0D, 0x0E, 0x0F, // span_id
    };
    try std.testing.expectEqualSlices(u8, &expected, &test_id.toBytes());
}

test "fromBytes inverts toBytes" {
    try std.testing.expectEqual(test_id, CorrelationID.fromBytes(test_id.toBytes()));
}

test "format and parse roundtrip as hex-64" {
    var buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{f}", .{test_id});
    try std.testing.expectEqual(64, text.len);
    try std.testing.expectEqualStrings(
        "0102030405060708" ++ "01" ++ "aabbccdd" ++ "11223344" ++ "02" ++
            "deadbeef" ++ "0a0b0c" ++ "55667788" ++ "0d0e0f",
        text,
    );
    try std.testing.expectEqual(test_id, CorrelationID.parse(text).?);
}

test "parse rejects wrong lengths and non-hex" {
    try std.testing.expectEqual(null, CorrelationID.parse(""));
    try std.testing.expectEqual(null, CorrelationID.parse("0123abc"));
    try std.testing.expectEqual(null, CorrelationID.parse("zz" ** 32));
    try std.testing.expectEqual(null, CorrelationID.parse("00" ** 33));
}

test "unset semantics" {
    try std.testing.expect(CorrelationID.unset.isUnset());
    try std.testing.expect(!test_id.isUnset());
    const dflt: CorrelationID = .unset;
    try std.testing.expectEqual(@as(u256, 0), @as(u256, @bitCast(dflt)));
}

test "hash is comptime-callable and matches runtime" {
    const at_comptime = comptime CorrelationID.hash("GET /api/users");
    var buf: [32]u8 = undefined;
    const runtime_op = try std.fmt.bufPrint(&buf, "{s}", .{"GET /api/users"});
    try std.testing.expectEqual(at_comptime, CorrelationID.hash(runtime_op));
}

test "newRoot and hop preserve the trace identity and chain spans" {
    const root_op = comptime CorrelationID.hash("cron: heartbeat");
    const root = CorrelationID.newRoot(7, root_op);
    try std.testing.expect(!root.isUnset());
    try std.testing.expectEqual(0x01, root.version);
    try std.testing.expectEqual(root_op, root.root_op_id);
    try std.testing.expectEqual(root_op, root.current_op_id);
    try std.testing.expectEqual(0, root.parent_span_id);
    try std.testing.expectEqual(7, root.user_id);

    const next_op = comptime CorrelationID.hash("amqp: heartbeat_tick");
    const child = root.hop(next_op);
    try std.testing.expect(child.sameTrace(root));
    try std.testing.expectEqual(root.span_id, child.parent_span_id);
    try std.testing.expectEqual(next_op, child.current_op_id);
    try std.testing.expectEqual(root.root_op_id, child.root_op_id);

    const grandchild = child.hop(root_op);
    try std.testing.expect(grandchild.sameTrace(root));
    try std.testing.expectEqual(child.span_id, grandchild.parent_span_id);
}

comptime {
    std.testing.refAllDeclsRecursive(@This());
}
