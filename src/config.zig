const std = @import("std");
const log = std.log.scoped(.kwatcher_config);
const c = std.c;
const klib = @import("klib");

const meta = klib.meta;
const config = klib.config;

pub const BaseConfig = struct {
    protocol: struct {
        client: struct {
            announce_message_expiration: u64 = 5,
        } = .{},
    } = .{},
    server: struct {
        host: []const u8 = "localhost",
        port: i32 = 5672,
        heartbeat: i32 = 5,
    } = .{},
    credentials: struct {
        username: []const u8,
        password: []const u8,
    },
    user: struct {
        // If left null it will be auto-generated from hostname + user name
        // Only override if you want to do some data correlation based on user id
        // such as, say, you have a Spotify/MPD watcher running on a PI since it doesn't need to be on
        // your every system as you only have one Spotify account to listen to anyway, but want to attribute
        // the spotify data to yourself.
        // Or, you have multiple of the same watcher running on the same box under the same account and you want to track them differently.
        id: ?[]const u8 = null,
    } = .{},
    config: struct {
        debug: bool = false,
        heartbeat_interval: u64 = std.time.ns_per_s * 5, //nanoseconds. TODO: Update name.
        metrics_interval_ns: u64 = std.time.ns_per_s * 5, //nanoseconds
        polling_interval: u64 = std.time.ns_per_s / 2, //nanoseconds. TODO: Update name.
        timeout: struct {
            const Self = @This();
            seconds: i32 = 60,
            microseconds: i32 = 0,

            pub fn toTimeval(self: Self) c.timeval {
                return c.timeval{
                    .sec = self.seconds,
                    .usec = self.microseconds,
                };
            }
        } = .{},
    } = .{},
};

pub fn Config(comptime Extension: type) type {
    return config.Config(BaseConfig, Extension);
}

pub const _BaseNullable = config.validate(BaseConfig, struct {
    protocol: struct {
        client: struct {
            announce_message_expiration: ?u64 = null,
        } = .{},
    } = .{},
    server: struct {
        host: ?[]const u8 = null,
        port: ?i32 = null,
        heartbeat: ?i32 = null,
    } = .{},
    credentials: struct {
        username: ?[]const u8 = null,
        password: ?[]const u8 = null,
    } = .{},
    user: struct {
        id: ?[]const u8 = null,
    } = .{},
    config: struct {
        debug: ?bool = null,
        heartbeat_interval: ?u64 = null, //nanoseconds
        metrics_interval_ns: ?u64 = null, //nanoseconds
        polling_interval: ?u64 = null, //nanoseconds
        timeout: struct {
            const Self = @This();
            seconds: ?i32 = null,
            microseconds: ?i32 = null,
        } = .{},
    } = .{},
});

pub fn findConfigFile(
    comptime ConfigType: type,
    allocator: std.mem.Allocator,
    comptime config_name: []const u8,
) !?ConfigType {
    return config.findConfigFile(
        ConfigType,
        allocator,
        "kwatcher",
        config_name,
    );
}

pub fn findConfigToUpdate(
    conf_value: anytype,
    allocator: std.mem.Allocator,
    comptime config_name: []const u8,
) !void {
    try config.findConfigFileToUpdate(
        conf_value,
        allocator,
        "kwatcher",
        config_name,
    );
}

pub fn findConfigFileWithDefaults(
    comptime ConfigType: type,
    comptime config_name: []const u8,
    arena: *std.heap.ArenaAllocator,
) !config.Config(BaseConfig, ConfigType) {
    return config.findConfigFileWithDefaults(
        BaseConfig,
        _BaseNullable,
        ConfigType,
        "kwatcher",
        "kwatcher",
        config_name,
        arena,
    );
}
