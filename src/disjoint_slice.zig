pub fn DisjointSlice(comptime Type: type) type {
    return struct {
        const Self = @This();
        slices: []const []const Type,

        pub const DisjointIterator = struct {
            slices: []const []const Type,
            index: usize = 0,
            set: usize = 0,

            pub fn next(self: *DisjointIterator) ?Type {
                const target = blk: {
                    if (self.set < self.slices.len and self.index >= self.slices[self.set].len) {
                        // We have gone through the entirety of the current set.
                        self.set += 1;
                        self.index = 0;
                    }

                    if (self.set >= self.slices.len) {
                        // We are done.
                        return null;
                    }

                    break :blk self.slices[self.set];
                };
                defer self.index += 1;
                return target[self.index];
            }
        };

        pub fn iterator(self: *const Self) DisjointIterator {
            return .{
                .slices = self.slices,
            };
        }
    };
}
