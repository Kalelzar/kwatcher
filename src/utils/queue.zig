const std = @import("std");

/// A thread-safe generic ring buffer queue backed by a static memory buffer.
/// This queue is lock-free but it cannot push in new elements without free space.
/// If that is important to you @see StaticLenient
pub fn StaticStrict(comptime T: type) type {
    return struct {
        used: std.Thread.Semaphore,
        free: std.Thread.Semaphore,
        buffer: []T,
        header: u128 align(16), // head u64 | len u64

        const Self = @This();

        /// Initialize a new queue backed by a buffer.
        pub fn init(buffer: []T) Self {
            return .{
                .header = 0,
                .buffer = buffer,
                .used = .{ .permits = 0 },
                .free = .{ .permits = buffer.len },
            };
        }

        pub fn push(self: *Self, data: T) void {
            self.free.wait();
            defer self.used.post();

            self.pushOne(data);
        }

        pub fn tryPush(self: *Self, data: T, timeout_ns: u64) !void {
            self.free.timedWait(timeout_ns) catch return error.WouldBlock;
            defer self.used.post();

            self.pushOne(data);
        }

        fn pushOne(self: *Self, data: T) void {
            const bitmask: u64 = 0 -% @as(u64, 1);
            const old = @atomicRmw(u128, &self.header, .Add, 1, .acq_rel);
            const len: u128 = (old & bitmask);
            const head: u128 = (old & (@as(u128, bitmask) << 64)) >> 64;
            const index: u64 = @intCast((head + len) % self.buffer.len);
            self.buffer[index] = data;
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
            const bitmask: u64 = 0 -% @as(u64, 1);
            var old = @atomicLoad(u128, &self.header, .acquire);
            while (true) {
                const len: u128 = old & bitmask;
                const head: u128 = (old & (@as(u128, bitmask) << 64)) >> 64;
                const slot = self.buffer[@intCast(head % self.buffer.len)];
                const new = (len - 1) | ((head +% 1) << 64);
                if (@cmpxchgWeak(u128, &self.header, old, new, .acq_rel, .acquire)) |next| {
                    old = next;
                    continue;
                }
                return slot;
            }
        }

        /// Return if the queue is empty.
        /// This is flaky at best and is best used as a
        /// heuristic.
        pub fn empty(self: *Self) bool {
            const old = @atomicLoad(u128, &self.header, .acquire);
            const len: u64 = @truncate(old);
            return len == 0;
        }

        /// Peek at the next element in the queue if any.
        /// This is flaky at best and is best used as a
        /// heuristic.
        pub fn peek(self: *Self) ?T {
            const old = @atomicLoad(u128, &self.header, .acquire);
            const len: u64 = @truncate(old);
            if (len == 0) return null;
            const head: u64 = @truncate(old >> 64);

            return self.buffer[head % self.buffer.len];
        }

        /// Skips over the first element, requeing it to the back.
        pub fn skip(self: *Self) void {
            if (self.empty()) return;
            return self.push(self.pop());
        }
    };
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

            //FIXME: This is not the tail
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

            //FIXME: This is not the tail
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
            const head = self.buffer[headIdx];
            self.head = (self.head + 1) % self.buffer.len;
            self.len.store(currentLen - 1, .monotonic);

            return head;
        }

        /// Pop the next element in the queue if any.
        /// No memory is freed in the process.
        /// The head of the buffer is moved forward by 1 and the length is removed.
        /// If you want to block until an element is available use pop() instead.
        pub fn drain(self: *Self) ?T {
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
