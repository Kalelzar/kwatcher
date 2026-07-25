const std = @import("std");
const builtin = @import("builtin");

/// CRC-32C (Castagnoli) — the polynomial every kwev chunk is framed with.
/// On x86_64 with SSE4.2 this uses the dedicated crc32 instruction: the std
/// table implementation runs at ~1 GB/s and dominates whole-archive reads,
/// the instruction is an order of magnitude faster. Results are identical.
/// LLVM-only: the self-hosted backend rejects the inline asm's "q" register
/// constraint, so `-Dmusl`-style self-hosted Debug builds take the table
/// path (the kwev tool proper is always ReleaseSafe+LLVM and keeps the
/// instruction).
pub const Crc32c = if (builtin.cpu.arch == .x86_64 and
    std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_2) and
    builtin.zig_backend == .stage2_llvm)
    HwCrc32c
else
    std.hash.crc.Crc32Iscsi;

const HwCrc32c = struct {
    crc: u32 = 0xffffffff,

    pub fn init() HwCrc32c {
        return .{};
    }

    pub fn update(self: *HwCrc32c, bytes: []const u8) void {
        var crc: u64 = self.crc;
        var rest = bytes;
        while (rest.len >= 8) : (rest = rest[8..]) {
            crc = asm ("crc32q %[v], %[c]"
                : [c] "=r" (-> u64),
                : [v] "r" (std.mem.readInt(u64, rest[0..8], .little)),
                  [c_in] "0" (crc),
            );
        }
        var tail: u32 = @truncate(crc);
        for (rest) |b| {
            tail = asm ("crc32b %[v], %[c]"
                : [c] "=r" (-> u32),
                : [v] "q" (b),
                  [c_in] "0" (tail),
            );
        }
        self.crc = tail;
    }

    pub fn final(self: HwCrc32c) u32 {
        return self.crc ^ 0xffffffff;
    }

    pub fn hash(input: []const u8) u32 {
        var c = init();
        c.update(input);
        return c.final();
    }
};

test "hardware CRC-32C matches std table implementation" {
    var prng = std.Random.DefaultPrng.init(0);
    var buf: [1025]u8 = undefined;
    prng.random().bytes(&buf);
    for ([_]usize{ 0, 1, 3, 7, 8, 9, 15, 16, 63, 64, 1024, 1025 }) |len| {
        try std.testing.expectEqual(std.hash.crc.Crc32Iscsi.hash(buf[0..len]), Crc32c.hash(buf[0..len]));
    }
    // Split updates must equal the one-shot hash (misaligned tail carry-over).
    var c = Crc32c.init();
    c.update(buf[0..13]);
    c.update(buf[13..100]);
    c.update(buf[100..]);
    try std.testing.expectEqual(std.hash.crc.Crc32Iscsi.hash(&buf), c.final());
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
