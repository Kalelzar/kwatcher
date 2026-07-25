const std = @import("std");

/// A thread-safe generic ring buffer queue backed by a static memory buffer.
/// This queue is lock-free but it cannot push in new elements without free space.
/// If that is important to you @see StaticLenient
///
/// `Header` is the packed `head | len` word the queue's atomics operate on;
/// each half indexes the ring, so a `uN` header supports buffers up to
/// 2^(N/2 - 1) slots. Smaller headers use cheaper atomics — a u64 header
/// needs no cmpxchg16b, so it works on baseline x86_64 and the self-hosted
/// backend — but shrink the head counter's wrap period (2^(N/2) pops), which
/// is also the ABA window on the pop CAS: u32 halves wrap every 4Bi pops
/// (safe in practice), u16 halves every 65536 (do not use under contention).
pub fn StaticStrictHeader(comptime T: type, comptime Header: type) type {
    const info = @typeInfo(Header).int;
    comptime std.debug.assert(info.signedness == .unsigned);
    comptime std.debug.assert(info.bits % 2 == 0);
    const half_bits = info.bits / 2;
    const Half = std.meta.Int(.unsigned, half_bits);
    const half_mask: Header = std.math.maxInt(Half);
    return struct {
        used: std.Thread.Semaphore,
        free: std.Thread.Semaphore,
        buffer: []T,
        header: Header align(@sizeOf(Header)), // head Half | len Half
        occupancy: []u1,
        mask: usize,

        const Self = @This();

        /// Initialize a new queue backed by a buffer.
        ///
        /// `buffer.len` must be a power of two no larger than half the
        /// `Half` range (the len half must hold buffer.len inclusive, and
        /// the head half's wrap must stay divisible by buffer.len).
        pub fn init(buffer: []T, occupancy_buffer: []u1) Self {
            std.debug.assert(buffer.len == occupancy_buffer.len);
            std.debug.assert(std.math.isPowerOfTwo(buffer.len));
            std.debug.assert(buffer.len <= std.math.maxInt(Half) / 2 + 1);
            @memset(occupancy_buffer, 0);
            return .{
                .header = 0,
                .buffer = buffer,
                .occupancy = occupancy_buffer,
                .mask = buffer.len - 1,
                .used = .{ .permits = 0 },
                .free = .{ .permits = buffer.len },
            };
        }

        pub fn push(self: *Self, data: T) *T {
            self.free.wait();
            defer self.used.post();

            const i = self.pushOne(data);
            return &self.buffer[i];
        }

        pub fn tryPush(self: *Self, data: T, timeout_ns: u64) !*T {
            self.free.timedWait(timeout_ns) catch return error.WouldBlock;
            defer self.used.post();

            const i = self.pushOne(data);
            return &self.buffer[i];
        }

        fn pushOne(self: *Self, data: T) usize {
            const old = @atomicRmw(Header, &self.header, .Add, 1, .acq_rel);
            const len: Header = old & half_mask;
            const head: Header = old >> half_bits;
            const index: usize = @intCast((head + len) & @as(Header, @intCast(self.mask)));
            while (true) {
                if (@atomicLoad(u1, &self.occupancy[index], .acquire) == 1) {
                    std.atomic.spinLoopHint();
                    continue;
                }
                self.buffer[index] = data;
                @atomicStore(u1, &self.occupancy[index], 1, .release);
                return index;
            }
        }

        pub fn pop(self: *Self) T {
            self.used.wait();
            defer self.free.post();

            return self.popOne();
        }

        pub fn tryPop(self: *Self, timeout_ns: u64) ?T {
            self.used.timedWait(timeout_ns) catch return null;
            defer self.free.post();

            return self.popOne();
        }

        fn popOne(self: *Self) T {
            var old = @atomicLoad(Header, &self.header, .acquire);
            while (true) {
                const len: Header = old & half_mask;
                const head: Header = old >> half_bits;
                const index: usize = @intCast(head & @as(Header, @intCast(self.mask)));
                if (@atomicLoad(u1, &self.occupancy[index], .acquire) == 0) {
                    std.atomic.spinLoopHint();
                    continue;
                }
                const slot = self.buffer[index];
                // The shifted-out bit of a wrapping head is discarded by <<,
                // which is exactly the mod-2^half wrap the ring needs.
                const new = (len - 1) | ((head +% 1) << half_bits);
                if (@cmpxchgWeak(Header, &self.header, old, new, .acq_rel, .acquire)) |next| {
                    old = next;
                    std.atomic.spinLoopHint();
                    continue;
                }
                @atomicStore(u1, &self.occupancy[index], 0, .release);
                return slot;
            }
        }

        /// Return if the queue is empty.
        /// This is flaky at best and is best used as a
        /// heuristic.
        pub fn empty(self: *Self) bool {
            const old = @atomicLoad(Header, &self.header, .acquire);
            const len: Half = @truncate(old);
            return len == 0;
        }

        /// Peek at the next element in the queue if any.
        /// This is flaky at best and is best used as a
        /// heuristic.
        pub fn peek(self: *Self) ?T {
            const old = @atomicLoad(Header, &self.header, .acquire);
            const len: Half = @truncate(old);
            if (len == 0) return null;
            const head: usize = @intCast(old >> half_bits);

            return self.buffer[head & self.mask];
        }

        /// Skips over the first element, requeing it to the back.
        pub fn skip(self: *Self) ?*T {
            if (self.empty()) return null;
            return self.push(self.pop());
        }
    };
}

/// `StaticStrictHeader` at the default u64 header (u32 head/len halves):
/// plain 64-bit atomics — no cmpxchg16b, so baseline x86_64 and the
/// self-hosted backend both work — with a 4-billion-pop ABA window.
pub fn StaticStrict(comptime T: type) type {
    return StaticStrictHeader(T, u64);
}

/// A thread-safe generic ring buffer queue backed by a static memory buffer.
/// This queue operates under a lock (mutex) but allows writers to clobber i.e
/// To not wait for the queue to have free space before pushing but just evicting
/// The first element.
pub fn StaticLenient(comptime T: type) type {
    return struct {
        mutex: std.Thread.Mutex = .{},
        used: std.Thread.Semaphore,
        buffer: []T,
        head: usize,
        len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        const Self = @This();

        /// Initialize a new queue backed by a buffer.
        pub fn init(buffer: []T) Self {
            return .{
                .buffer = buffer,
                .head = 0,
                .used = .{ .permits = 0 },
            };
        }

        /// Return if the queue is empty.
        pub fn empty(self: *Self) bool {
            return self.len.load(.acquire) == 0;
        }

        /// Peek at the next element in the queue if any.
        pub fn peek(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const currentLen = self.len.load(.monotonic);
            if (currentLen == 0) return null;

            const headIdx = self.head;
            const head = self.buffer[headIdx];

            return head;
        }

        /// Peek at the last element in the queue if any.
        pub fn peekEnd(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const currentLen = self.len.load(.monotonic);
            if (currentLen == 0) return null;

            const tailIdx = (self.head + currentLen - 1) % self.buffer.len;
            const tail = self.buffer[tailIdx];

            return tail;
        }

        /// Peek at the next element in the queue if any. Returns pointer
        pub fn peekPtr(self: *Self) ?*T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const currentLen = self.len.load(.monotonic);
            if (currentLen == 0) return null;

            const headIdx = self.head;

            return &self.buffer[headIdx];
        }

        /// Peek at the last element in the queue if any. Returns pointer
        pub fn peekEndPtr(self: *Self) ?*T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const currentLen = self.len.load(.monotonic);
            if (currentLen == 0) return null;

            const tailIdx = (self.head + currentLen - 1) % self.buffer.len;

            return &self.buffer[tailIdx];
        }

        /// Pop the next element in the queue if any.
        /// No memory is freed in the process.
        /// The head of the buffer is moved forward by 1 and the length is removed.
        /// This will block on a semaphore for an element before returning.
        /// Null is only returned upon a spurious wake-up.
        /// If you want immediate feedback use drain() instead.
        pub fn pop(self: *Self) ?T {
            self.used.wait();
            self.mutex.lock();
            defer self.mutex.unlock();

            const currentLen = self.len.load(.monotonic);
            if (currentLen == 0) return null;

            const headIdx = self.head;
            self.head = (self.head + 1) % self.buffer.len;
            self.len.store(currentLen - 1, .monotonic);

            return self.buffer[headIdx];
        }

        /// Pop the next element in the queue if any.
        /// No memory is freed in the process.
        /// The head of the buffer is moved forward by 1 and the length is removed.
        /// If you want to block until an element is available use pop() instead.
        pub fn drain(self: *Self) ?T {
            self.used.timedWait(100) catch {
                return null;
            };
            self.mutex.lock();
            defer self.mutex.unlock();

            const currentLen = self.len.load(.monotonic);
            if (currentLen == 0) return null;

            const headIdx = self.head;
            const head = self.buffer[headIdx];
            self.head = (self.head + 1) % self.buffer.len;
            self.len.store(currentLen - 1, .monotonic);

            return head;
        }

        /// Pushes an element into the queue.
        /// If the static buffer is full, returns an error.WouldBlock.
        pub fn pushNoClobber(self: *Self, t: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const currentLen = self.len.load(.monotonic);
            if (currentLen == self.buffer.len) {
                return error.WouldBlock;
            }

            const idx = (self.head + currentLen) % self.buffer.len;
            self.buffer[idx] = t;
            self.len.store(currentLen + 1, .monotonic);
            self.used.post();
        }

        /// Pushes an element into the queue.
        /// If the static buffer is full, returns the last element and replaces it.
        pub fn push(self: *Self, t: T) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            const currentLen = self.len.load(.monotonic);
            if (currentLen == self.buffer.len) {
                const old = self.buffer[self.head];
                self.buffer[self.head] = t;
                self.head = (self.head + 1) % self.buffer.len;
                return old;
            }

            const idx = (self.head + currentLen) % self.buffer.len;
            self.buffer[idx] = t;
            self.len.store(currentLen + 1, .monotonic);
            self.used.post();
            return null;
        }

        /// Skips over the first element, requeing it to the back.
        pub fn skip(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            const currentLen = self.len.load(.monotonic);

            if (currentLen == 0) {
                return;
            }

            if (currentLen == self.buffer.len) {
                self.head = (self.head + 1) % self.buffer.len;
                return;
            }

            const idx = (self.head + currentLen) % self.buffer.len;
            self.buffer[idx] = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
        }
    };
}

// Ref all decls
comptime {
    std.testing.refAllDeclsRecursive(StaticStrict(u8));
    std.testing.refAllDeclsRecursive(StaticStrictHeader(u8, u32));
    std.testing.refAllDeclsRecursive(StaticLenient(u8));
}
