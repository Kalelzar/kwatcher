const std = @import("std");
const Injector = @import("../utils/injector.zig").Injector;

/// A hot/cold cache that will either retrieve from cache or retrieve the element from the cold path
/// and automatically cache it.
pub fn HotCold(comptime Data: type) type {
    return struct {
        action_name: []const u8,
        key: []const u8,
        hot: ?*const fn (*Injector, *anyopaque) anyerror!Data = null,
        cold: ?*const fn (*Injector, *anyopaque) anyerror!Data = null,
        push: ?*const fn (*Injector, Data, *anyopaque) anyerror!?Data = null,

        pub inline fn interface(self: *const @This()) HotCold(Data) {
            return self.*;
        }
    };
}
