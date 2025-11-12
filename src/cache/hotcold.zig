const std = @import("std");
const Injector = @import("../utils/injector.zig").Injector;

pub const InterfaceType = enum {
    hotcold,
    hotcold_lru,
};

pub fn cacheInterfaceTypeMap(comptime Data: type, comptime Interface: type) InterfaceType {
    if (Interface == HotCold(Data)) {
        return .hotcold;
    } else if (Interface == HotColdLru(Data)) {
        return .hotcold_lru;
    } else {
        @compileError(std.fmt.comptimePrint(
            "Type {s} isn't a valid cache interface type.",
            .{@typeName(Interface)},
        ));
    }
}

/// A hot/cold cache that will either retrieve from cache or retrieve the element from the cold path
/// and automatically cache it.
pub fn HotCold(comptime Data: type) type {
    return struct {
        action_name: []const u8,
        key: []const u8,
        hot: ?*const fn (*Injector, *anyopaque) anyerror!Data = null,
        cold: ?*const fn (*Injector, *anyopaque) anyerror!Data = null,
        push: ?*const fn (*Injector, Data, *anyopaque) anyerror!?Data = null,

        pub fn interface(self: @This()) HotCold(Data) {
            return .{
                .action_name = self.action_name,
                .cold = self.cold,
                .hot = self.hot,
                .push = self.push,
                .key = self.key,
            };
        }
    };
}

/// A hot/cold cache that will either retrieve from cache or retrieve the element from the cold path
/// and automatically cache it.
pub fn HotColdLru(comptime Data: type) type {
    return struct {
        action_name: []const u8,
        key: []const u8,
        hot: ?*const fn (*Injector, *anyopaque) anyerror!Data = null,
        cold: ?*const fn (*Injector, *anyopaque) anyerror!Data = null,
        push: ?*const fn (*Injector, Data, *anyopaque) anyerror!?Data = null,

        pub fn interface(self: @This()) HotCold(Data) {
            return .{
                .action_name = self.action_name,
                .cold = self.cold,
                .hot = self.hot,
                .key = self.key,
                .push = self.push,
            };
        }
    };
}
