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
        timeout: struct {
            const Self = @This();
            seconds: i32 = 60,
            microseconds: i32 = 0,

            pub fn toTimeval(self: Self) c.timeval {
                return c.timeval{
                    .tv_sec = self.seconds,
                    .tv_usec = self.microseconds,
                };
            }
        } = .{},
    } = .{},
};

pub const _BaseNullable = struct {
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
        timeout: struct {
            const Self = @This();
            seconds: ?i32 = null,
            microseconds: ?i32 = null,
        } = .{},
    } = .{},
};

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

fn openConfigFile(comptime ConfigType: type, allocator: std.mem.Allocator, path: []const u8) !json.Parsed(ConfigType) {
    log.info("Attempting to load config file of type '{}' from '{s}'.", .{ ConfigType, path });
    const file = try std.fs.openFileAbsolute(
        path,
        std.fs.File.OpenFlags{ .mode = .read_only },
    );
    defer file.close();

    const stat = try file.stat();
    const max_size = stat.size;
    const contents = try file.readToEndAlloc(allocator, max_size);
    defer allocator.free(contents);

    const parsed = try json.parseFromSlice(
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
    errdefer paths.deinit();

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
        return error.InvalidConfig;
    }

    if (config.credentials.username.len == 0 or config.credentials.password.len == 0) {
        return error.InvalidConfig;
    }

    // Timeout validation
    if (config.config.timeout.seconds < 0 or config.config.timeout.microseconds < 0) {
        return error.InvalidConfig;
    }
}

pub fn findConfigFile(comptime ConfigType: type, allocator: std.mem.Allocator, comptime configName: []const u8) !json.Parsed(ConfigType) {
    const loadPath = try buildConfigPaths(allocator, configName);
    defer loadPath.deinit();
    var result: ?json.Parsed(ConfigType) = null;

    for (loadPath.paths.items) |path| {
        result = openConfigFile(ConfigType, allocator, path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |other_error| return other_error,
        };
        errdefer result.?.deinit();
        break;
    }

    if (result) |config| {
        return config;
    } else {
        return error.FileNotFound;
    }
}

pub fn ConfigMerge(comptime Extension: type) type {
    const Base = BaseConfig;
    const Child = meta.MergeStructs(_BaseNullable, Extension);
    const Result = meta.MergeStructs(Base, Extension);

    return struct {
        _base: json.Parsed(Base),
        _child: json.Parsed(Child),
        value: Result,

        pub fn init(base: json.Parsed(Base), child: json.Parsed(Child), result: Result) ConfigMerge(Extension) {
            return .{
                ._base = base,
                ._child = child,
                .value = result,
            };
        }

        pub fn deinit(self: *const ConfigMerge(Extension)) void {
            self._base.deinit();
            self._child.deinit();
        }
    };
}

pub fn findConfigFileWithDefaults(comptime ConfigType: type, allocator: std.mem.Allocator, comptime configName: []const u8) !ConfigMerge(ConfigType) {
    const Extension = meta.MergeStructs(_BaseNullable, ConfigType);
    const ext = try findConfigFile(Extension, allocator, configName);
    errdefer ext.deinit();
    const base = try findConfigFile(BaseConfig, allocator, "kwatcher");
    errdefer base.deinit();
    const Final = meta.MergeStructs(BaseConfig, ConfigType);

    const final = meta.merge(BaseConfig, Extension, Final, base.value, ext.value);

    try validateConfig(final);

    return ConfigMerge(ConfigType).init(base, ext, final);
}
