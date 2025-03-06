const std = @import("std");
const log = std.log.scoped(.kwatcher_config);
const json = std.json;
const c = std.c;

const meta = @import("meta.zig");

pub const BaseConfig = struct {
    server: struct {
        host: []const u8 = "localhost",
        port: i32 = 5672,
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
        heartbeat_interval: u64 = std.time.ns_per_s * 5, //nanoseconds
        polling_interval: i64 = std.time.us_per_s / 2, //microseconds
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

fn validate(comptime Extension: type) type {
    meta.ensureStructure(BaseConfig, Extension);
    return Extension;
}

pub const _BaseNullable = validate(struct {
    server: struct {
        host: ?[]const u8 = null,
        port: ?i32 = null,
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
        heartbeat_interval: ?u64 = null, //microseconds
        polling_interval: ?i64 = null, //microseconds
        timeout: struct {
            const Self = @This();
            seconds: ?i32 = null,
            microseconds: ?i32 = null,
        } = .{},
    } = .{},
});

const ConfigLocations = struct {
    // Add XDG Base Directory support
    pub fn getXdgConfigHome(allocator: std.mem.Allocator) !?[]const u8 {
        return fromEnv(allocator, "XDG_CONFIG_HOME");
    }

    pub fn getHome(allocator: std.mem.Allocator) !?[]const u8 {
        return fromEnv(allocator, "HOME");
    }

    fn fromEnv(allocator: std.mem.Allocator, envKey: []const u8) !?[]const u8 {
        const env = std.process.getEnvVarOwned(allocator, envKey);
        if (env) |path| {
            return path;
        } else |err| {
            switch (err) {
                error.EnvironmentVariableNotFound => {
                    return null;
                },
                else => |other_error| return other_error,
            }
        }
    }
};

fn openConfigFile(comptime ConfigType: type, allocator: std.mem.Allocator, path: []const u8) !ConfigType {
    const file = try std.fs.openFileAbsolute(
        path,
        std.fs.File.OpenFlags{ .mode = .read_only },
    );
    defer file.close();

    const stat = try file.stat();
    const max_size = stat.size;
    const contents = try file.readToEndAlloc(allocator, max_size);
    defer allocator.free(contents);

    const parsed = try json.parseFromSliceLeaky(
        ConfigType,
        allocator,
        contents,
        .{
            .allocate = .alloc_always,
        },
    );

    return parsed;
}

const LoadPaths = struct {
    paths: std.ArrayList([]u8),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, paths: std.ArrayList([]u8)) LoadPaths {
        return .{
            .allocator = allocator,
            .paths = paths,
        };
    }

    pub fn deinit(self: *const LoadPaths) void {
        for (self.paths.items) |path| {
            self.allocator.free(path);
        }

        self.paths.deinit();
    }
};

fn buildConfigPaths(allocator: std.mem.Allocator, comptime basename: []const u8) !LoadPaths {
    var paths = std.ArrayList([]u8).init(allocator);
    errdefer {
        const load_paths = LoadPaths.init(allocator, paths);
        load_paths.deinit();
    }

    const ext = ".json";
    const configPath = basename ++ ext;

    // 1. Check current directory
    const buf = try allocator.alloc(u8, 256);
    defer allocator.free(buf);
    const cwd = try std.process.getCwd(buf);
    try paths.append(try std.fs.path.join(allocator, &.{ cwd, configPath }));

    // 2. Check XDG config directory
    if (try ConfigLocations.getXdgConfigHome(allocator)) |xdg_config| {
        defer allocator.free(xdg_config);
        const xdg_path = try std.fs.path.join(allocator, &.{ xdg_config, "kwatcher", configPath });
        try paths.append(xdg_path);
    }

    // 3. Check HOME config directory
    if (try ConfigLocations.getHome(allocator)) |home_config| {
        defer allocator.free(home_config);
        const home_path = try std.fs.path.join(allocator, &.{ home_config, ".config", "kwatcher", configPath });
        try paths.append(home_path);
    }

    // 4. Check /etc for system-wide config
    try paths.append(try std.fs.path.join(allocator, &.{ "/", "etc", "kwatcher", configPath }));
    return LoadPaths.init(allocator, paths);
}

// Add validation support
fn validateConfig(config: anytype) !void {
    // Basic validation
    if (config.server.port < 0 or config.server.port > 65535) {
        return error.InvalidPort;
    }

    if (config.config.heartbeat_interval == 0) {
        return error.InvalidHeartbeat;
    }

    if (config.credentials.username.len == 0 or config.credentials.password.len == 0) {
        return error.InvalidCredentials;
    }

    // Timeout validation
    if (config.config.timeout.seconds < 0 or config.config.timeout.microseconds < 0) {
        return error.InvalidTimeout;
    }
}

pub fn findConfigFile(comptime ConfigType: type, allocator: std.mem.Allocator, comptime configName: []const u8) !?ConfigType {
    const loadPath = try buildConfigPaths(allocator, configName);
    defer loadPath.deinit();
    var result: ?ConfigType = null;

    for (loadPath.paths.items) |path| {
        result = openConfigFile(ConfigType, allocator, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |other_error| return other_error,
        };
        errdefer result.?.deinit();
        break;
    }

    return result;
}

pub fn Config(comptime Extension: type) type {
    const Result = meta.MergeStructs(BaseConfig, Extension);

    return struct {
        value: Result,

        pub fn init(result: Result) Config(Extension) {
            return .{
                .value = result,
            };
        }
    };
}

fn findConfigFileOrDefault(comptime ConfigType: type, allocator: std.mem.Allocator, comptime configName: []const u8) !ConfigType {
    return (try findConfigFile(ConfigType, allocator, configName)) orelse std.mem.zeroInit(ConfigType, .{});
}

pub fn findConfigFileWithDefaults(comptime ConfigType: type, comptime configName: []const u8, arena: *std.heap.ArenaAllocator) !Config(ConfigType) {
    const allocator = arena.allocator();

    const Extension = meta.MergeStructs(_BaseNullable, ConfigType);
    const ext = try findConfigFileOrDefault(Extension, allocator, configName);

    const base = try findConfigFileOrDefault(BaseConfig, allocator, "kwatcher");
    const Final = meta.MergeStructs(BaseConfig, ConfigType);

    const final = meta.merge(BaseConfig, Extension, Final, base, ext);

    try meta.assertNotEmpty(Final, final);
    try validateConfig(final);

    return Config(ConfigType).init(final);
}
