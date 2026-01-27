const std = @import("std");

pub fn BicyclicBuffer(comptime T: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        valid: bool = true,
        buffer: []T,
        a_len: usize,
        a_head: usize,
        mutex: std.Thread.Mutex.Recursive,

        const CycleIterator = struct {
            ignore: bool,
            idx: usize,
            end: usize,
            buffer: []T,

            pub fn next(self: *CycleIterator) ?T {
                if (self.idx == self.end and !self.ignore) return null;
                self.ignore = false;
                defer self.idx = (self.idx + 1) % self.buffer.len;
                return self.buffer[self.idx];
            }

            pub fn lastIndex(self: *const CycleIterator) usize {
                return if (self.idx == 0)
                    self.buffer.len - 1
                else
                    self.idx - 1;
            }
        };

        pub fn usedIterator(self: *const Self) CycleIterator {
            const count = self.busy_count();
            const head = self.busy_head();
            const start = (head + count) % self.buffer.len;
            const end = head;
            return .{
                .ignore = start == end and count > 1,
                .buffer = self.buffer,
                .end = start,
                .idx = end,
            };
        }

        pub fn freeIterator(self: *const Self) CycleIterator {
            const start = (self.a_head + self.a_len) % self.buffer.len;
            const end = self.a_head;
            return .{
                .ignore = start == end and self.a_len > 1,
                .buffer = self.buffer,
                .end = start,
                .idx = end,
            };
        }

        pub fn init(buf: []T) Self {
            return .{
                .a_head = 0,
                .a_len = buf.len,
                .buffer = buf,
                // Justification(Recursive Mutex): Laziness.
                .mutex = std.Thread.Mutex.Recursive.init,
            };
        }

        pub fn busy_count(self: *const Self) usize {
            return self.buffer.len -| self.a_len;
        }

        pub fn busy_head(self: *const Self) usize {
            return (self.a_head + self.a_len) % self.buffer.len;
        }

        pub fn acquire(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.a_len == 0 or !self.valid) return null;

            const head = self.a_head;
            self.a_head = (self.a_head + 1) % self.buffer.len;
            self.a_len -|= 1;

            return self.buffer[head];
        }

        pub fn release(self: *Self, v: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            const in = self.find(v);
            if (in == null) return error.NotFound;

            var idx = in.?;

            const b_head = self.busy_head();
            const last = if (self.a_head == 0) self.buffer.len - 1 else self.a_head - 1;
            while (true) {
                if (idx == b_head) {
                    // Special case: We can just extend A.
                    self.a_len += 1;
                    std.debug.assert(self.a_len <= self.buffer.len);
                    return;
                } else if (idx == last) {
                    // Special case: We can just shift A back one.
                    self.a_len += 1;
                    self.a_head = last;
                    std.debug.assert(self.a_len <= self.buffer.len);
                    return;
                } else {
                    // We are not on either end. We need to swap and retry.
                    std.mem.swap(T, &self.buffer[b_head], &self.buffer[idx]);
                    idx = b_head;
                }
            }
        }

        fn find(self: *Self, v: T) ?usize {
            var it = self.usedIterator();
            while (it.next()) |e| {
                if (Context.eql(e, v)) return it.lastIndex();
            }
            return null;
        }
    };
}

pub fn Pool(comptime T: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        valid: bool = true,
        semaphore: std.Thread.Semaphore,
        timeout_ns: u64,
        buffer: BicyclicBuffer(T, Context),

        pub fn initBuffer(buf: []T, timeout_ns: u64) Self {
            return .{
                .buffer = .init(buf),
                .semaphore = std.Thread.Semaphore{ .permits = buf.len },
                .timeout_ns = timeout_ns,
            };
        }

        pub fn initPreheated(alloc: std.mem.Allocator, count: usize, timeout_ns: u64) !Self {
            const buffer = try alloc.alloc(T, count);
            return .initBuffer(buffer, timeout_ns);
        }

        pub fn cancel(self: *Self) !bool {
            self.buffer.mutex.lock();
            defer self.buffer.mutex.unlock();
            var it = self.buffer.usedIterator();
            var failed = false;
            while (it.next()) |t| {
                Context.cancel(t) catch {
                    failed = true;
                    continue;
                };
                try self.release(t);
            }

            return !failed;
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.buffer.mutex.lock();
            defer self.buffer.mutex.unlock();
            self.buffer.valid = false;
            @atomicStore(bool, &self.valid, false, .release);
            _ = self.cancel() catch false;

            for (self.buffer.buffer) |t| {
                Context.deinit(t);
            }

            alloc.free(self.buffer.buffer);
        }

        pub fn lease(self: *Self) !T {
            if (!@atomicLoad(bool, &self.valid, .acquire)) return error.Cancelled;
            try self.semaphore.timedWait(self.timeout_ns);
            if (!@atomicLoad(bool, &self.valid, .acquire)) {
                self.semaphore.post();
                return error.Cancelled;
            }

            return self.buffer.acquire() orelse error.CorruptPool;
        }

        pub fn release(self: *Self, l: T) !void {
            try self.buffer.release(l);

            self.semaphore.post();
        }
    };
}
