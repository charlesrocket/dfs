pub const XdgDir = enum {
    Config,
    Data,
    State,
    Home,
};

pub const WatcherMode = enum {
    polling,
    kqueue,
    epoll,
    auto,
};

const Icon = enum {
    bright,
    dark,
};

pub const ConfigResult = union(enum) {
    ok: Config,
    parse_error: [:0]const u8,
};

const Tray = struct {
    enabled: bool,
    icon: Icon,
    menu_icons: bool,
};

repository: []const u8,
source: []const u8,
target: []const u8,
logging: bool,
notifications: bool,
watcher: WatcherMode,
ignore_list: [][]const u8,
tray: Tray,

pub fn new(
    allocator: std.mem.Allocator,
    repository: []const u8,
    source: []const u8,
    target: ?[]const u8,
) !Config {
    // destination
    const path = if (target == null)
        try std.process.getEnvVarOwned(allocator, "HOME")
    else
        target.?;

    return .{
        .repository = repository,
        .source = source,
        .target = path,
        .logging = false,
        .notifications = false,
        .watcher = WatcherMode.auto,
        .ignore_list = &[_][]u8{},
        .tray = .{
            .enabled = true,
            .icon = .bright,
            .menu_icons = true,
        },
    };
}

pub fn write(
    self: *Config,
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    const parent_dir = std.fs.path.dirname(path);

    if (parent_dir != null) try Util.createDirRecursively(
        allocator,
        parent_dir.?,
    );

    const f = try std.fs.cwd().createFile(
        path,
        .{ .read = false, .truncate = true },
    );

    defer f.close();

    var buf: [1024]u8 = undefined;
    var file_writer = f.writer(&buf);
    const writer = &file_writer.interface;

    _ = try std.zon.stringify.serialize(
        self,
        .{},
        writer,
    );

    _ = try writer.write("\n");
    try writer.flush();
}

fn read(
    allocator: std.mem.Allocator,
    path: []const u8,
    core: *Core,
) !ConfigResult {
    const config_file = std.fs.cwd().openFile(path, .{}) catch |err|
        switch (err) {
            error.FileNotFound => {
                try core.stderr.print(
                    "{s}Config not found!{s}\nRun `dfs init`.\n",
                    .{
                        Cli.red,
                        Cli.reset,
                    },
                );

                try core.stderr.flush();
                std.process.exit(1);
            },
            else => return err,
        };

    defer config_file.close();

    const config_size: usize = @intCast((try config_file.stat()).size);
    const config_content_t = try config_file.readToEndAlloc(
        allocator,
        config_size,
    );

    defer allocator.free(config_content_t);

    var config_content = std.array_list.Managed(u8).init(allocator);
    defer config_content.deinit();

    for (config_content_t) |c| {
        try config_content.append(c);
    }

    try config_content.append(0);

    const config_data =
        config_content.items[0 .. config_content.items.len - 1 :0];

    const config = std.zon.parse.fromSlice(
        Config,
        allocator,
        config_data,
        null,
        .{ .ignore_unknown_fields = true },
    ) catch {
        const data = try allocator.dupeZ(u8, config_data);
        return ConfigResult{ .parse_error = data };
    };

    return ConfigResult{ .ok = config };
}

pub fn open(
    allocator: std.mem.Allocator,
    path: []const u8,
    core: *Core,
) !Config {
    const config_result = try read(allocator, path, core);
    const config = switch (config_result) {
        .ok => |cfg| cfg,
        .parse_error => |config_data| cfg: {
            defer allocator.free(config_data);
            try core.stderr.print("{s}{s}Updating config{s}\n", .{
                Cli.yellow,
                Cli.bold,
                Cli.reset,
            });

            Config.migrateConfig(allocator, path) catch |err| {
                try core.stderr.print("{s}{s}INVALID CONFIG{s}: {s}\n", .{
                    Cli.red,
                    Cli.bold,
                    Cli.reset,
                    path,
                });

                _ = try core.stderr.print(
                    "\n{s}{s}{s}\n\n",
                    .{ Cli.red, config_data, Cli.reset },
                );

                const example_config = try Config.new(
                    allocator,
                    "https://gibson.com/git/dotfiles",
                    "$HOME/src/dotfiles",
                    "/tmp/test",
                );

                _ = try core.stderr.write("Example:\n\n");
                _ = try std.zon.stringify.serialize(
                    example_config,
                    .{},
                    core.stderr,
                );

                _ = try core.stderr.write("\n\n");
                try core.stderr.flush();
                return err;
            };

            if (core.logs) Util.log(WARN, "Config updated!", .{});
            _ = try core.stderr.print(
                "{s}Config updated{s}\n\n",
                .{ Cli.green, Cli.reset },
            );

            try core.stderr.flush();

            const new_config_result = try Config.read(allocator, path, core);
            break :cfg new_config_result.ok;
        },
    };

    return config;
}

pub fn bootstrap(
    allocator: std.mem.Allocator,
    url: []const u8,
    core: *Core,
) !void {
    const config_home = try getXdgDir(allocator, XdgDir.Config);
    defer allocator.free(config_home);

    const config_path = try defaultConfigPath(allocator);
    defer allocator.free(config_path);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    try Util.createDirRecursively(allocator, config_home);

    var file = try std.fs.createFileAbsolute(
        config_path,
        .{ .read = false, .truncate = true },
    );

    var result_body = std.Io.Writer.Allocating.init(allocator);
    defer result_body.deinit();

    const response = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &result_body.writer,
    });

    if (response.status.class() != .success) {
        return error.UnexpectedRequestStatus;
    }

    try file.writeAll(result_body.written());
    file.close();

    const config = try open(allocator, config_path, core);
    defer std.zon.parse.free(allocator, config);
    try Util.cloneRepo(allocator, config.repository, config.source, core);
}

pub fn migrateConfig(
    allocator: std.mem.Allocator,
    config_path: []const u8,
) !void {
    const MigrationConfig = MigrationType(Config);
    const file = try std.fs.cwd().openFile(config_path, .{});
    defer file.close();

    // null-terminated
    const content = try file.readToEndAllocOptions(
        allocator,
        1024 * 1024,
        null,
        @enumFromInt(@alignOf(u8)),
        0,
    );

    defer allocator.free(content);

    const old_config = try std.zon.parse.fromSlice(
        MigrationConfig,
        allocator,
        content,
        null,
        .{},
    );

    defer std.zon.parse.free(allocator, old_config);

    var ignore_list: [][]const u8 = &[_][]const u8{};

    if (old_config.ignore_list) |v| {
        ignore_list = try allocator.alloc([]const u8, v.len);
        var i: usize = 0;
        for (v) |item| {
            ignore_list[i] = try allocator.dupe(u8, item);
            i += 1;
        }
    }

    var new_config = Config{
        .repository = if (old_config.repository) |v| v else "",
        .source = if (old_config.source) |v| v else "",
        .target = if (old_config.target) |v|
            v
        else if (old_config.destination) |v|
            v
        else
            "",
        .logging = if (old_config.logging) |v| v else false,
        .notifications = if (old_config.notifications) |v| v else false,
        .watcher = if (old_config.watcher) |v| v else WatcherMode.auto,
        .ignore_list = ignore_list,
        .tray = if (old_config.tray) |v| .{
            .enabled = v.enabled orelse true,
            .icon = v.icon orelse .bright,
            .menu_icons = v.menu_icons orelse true,
        } else .{
            .enabled = true,
            .icon = .bright,
            .menu_icons = true,
        },
    };

    try new_config.write(allocator, config_path);

    for (ignore_list) |item| {
        allocator.free(item);
    }

    allocator.free(ignore_list);
}

fn MigrationType(comptime T: type) type {
    const config_fields = std.meta.fields(T);
    // deprecated config fields
    const deprecated_field_specs = .{
        .{ .name = "destination", .type = []const u8 },
    };

    var fields: [
        config_fields.len +
            deprecated_field_specs.len
    ]std.builtin.Type.StructField =
        undefined;

    inline for (config_fields, 0..) |field, i| {
        const field_type_info = @typeInfo(field.type);
        const FieldType = switch (field_type_info) {
            .@"struct" => MigrationType(field.type),
            else => field.type,
        };

        const OptionalType = @Type(.{
            .optional = .{
                .child = FieldType,
            },
        });

        const default_value = @as(OptionalType, null);

        fields[i] = .{
            .name = field.name,
            .type = OptionalType,
            .default_value_ptr = &default_value,
            .is_comptime = false,
            .alignment = @alignOf(OptionalType),
        };
    }

    inline for (deprecated_field_specs, 0..) |spec, i| {
        const OptionalType = @Type(.{
            .optional = .{
                .child = spec.type,
            },
        });

        const default_value = @as(OptionalType, null);

        fields[config_fields.len + i] = .{
            .name = spec.name,
            .type = OptionalType,
            .default_value_ptr = &default_value,
            .is_comptime = false,
            .alignment = @alignOf(OptionalType),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

// deallocate on changes
pub fn pathFormat(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]const u8 {
    const trailing_slash = std.mem.endsWith(u8, path, "/");

    if (std.mem.startsWith(u8, path, "$HOME")) {
        const home = try getXdgDir(allocator, XdgDir.Home);
        defer allocator.free(home);

        const size = std.mem.replacementSize(u8, path, "$HOME", home);
        const new_path = try allocator.alloc(u8, size);
        defer allocator.free(new_path);

        _ = std.mem.replace(u8, path, "$HOME", home, new_path);

        const target = if (trailing_slash)
            try allocator.dupe(u8, new_path)
        else
            try std.fmt.allocPrint(allocator, "{s}/", .{new_path});

        return target;
    } else if (!trailing_slash) {
        return try std.fmt.allocPrint(allocator, "{s}/", .{path});
    } else {
        return path;
    }
}

pub fn getXdgDir(allocator: std.mem.Allocator, env_var: XdgDir) ![]const u8 {
    const path = std.process.getEnvVarOwned(
        allocator,
        switch (env_var) {
            .Config => "XDG_CONFIG_HOME",
            .Data => "XDG_DATA_HOME",
            .State => "XDG_STATE_HOME",
            .Home => "HOME",
        },
    ) catch {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);

        switch (env_var) {
            .Config => return try std.fs.path.join(allocator, &.{
                home,
                ".config",
                "dfs",
            }),
            .Data => return try std.fs.path.join(allocator, &.{
                home,
                ".local",
                "share",
                "dfs",
            }),
            .State => return try std.fs.path.join(allocator, &.{
                home,
                ".local",
                "state",
                "dfs",
            }),
            .Home => return allocator.dupe(u8, home),
        }
    };

    switch (env_var) {
        .Home => return path,
        .Config, .Data, .State => {
            defer allocator.free(path);
            return try std.fs.path.join(allocator, &.{
                path,
                "dfs",
            });
        },
    }
}

pub fn defaultConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    const config_home = try Config.getXdgDir(allocator, Config.XdgDir.Config);
    defer allocator.free(config_home);

    return try std.fmt.allocPrint(
        allocator,
        "{s}/config.zon",
        .{config_home},
    );
}

// might fail with non-default XDG env vars
test defaultConfigPath {
    const allocator = std.testing.allocator;
    const home = try getXdgDir(allocator, XdgDir.Home);
    const config_path = try defaultConfigPath(allocator);
    const expected_path = try std.fmt.allocPrint(
        allocator,
        "{s}/.config/dfs/config.zon",
        .{home},
    );

    defer {
        allocator.free(home);
        allocator.free(config_path);
        allocator.free(expected_path);
    }

    try std.testing.expectEqualStrings(expected_path, config_path);
}

test migrateConfig {
    const old_config =
        \\.{
        \\    .repository = "https://gibson.com/test",
        \\    .source = "test/root-back",
        \\    .destination = "/tmp/test",
        \\    .ignore_list = .{"foo","bar"},
        \\}
        \\
    ;

    const expected_config =
        \\.{
        \\    .repository = "https://gibson.com/test",
        \\    .source = "test/root-back",
        \\    .target = "/tmp/test",
        \\    .logging = false,
        \\    .notifications = false,
        \\    .watcher = .auto,
        \\    .ignore_list = .{ "foo", "bar" },
        \\    .tray = .{
        \\        .enabled = true,
        \\        .icon = .bright,
        \\        .menu_icons = true,
        \\    },
        \\}
        \\
    ;

    const old_file = try std.fs.cwd().createFile(
        "test/conf-old.zon",
        .{ .read = false },
    );

    try old_file.writeAll(old_config);
    old_file.close();

    try migrateConfig(std.testing.allocator, "test/conf-old.zon");

    const new_file = try std.fs.cwd().openFile("test/conf-old.zon", .{});
    const content = try new_file.readToEndAlloc(
        std.testing.allocator,
        1024,
    );

    defer std.testing.allocator.free(content);

    try std.testing.expectEqualStrings(expected_config, content);
    try std.fs.cwd().deleteFile("test/conf-old.zon");
}

test pathFormat {
    const allocator = std.testing.allocator;
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);

    {
        const result = try pathFormat(allocator, "$HOME/documents");
        const expected = try std.fmt.allocPrint(allocator, "{s}/documents/", .{home});

        defer {
            allocator.free(result);
            allocator.free(expected);
        }

        try std.testing.expectEqualStrings(expected, result);
    }

    {
        const result = try pathFormat(allocator, "$HOME/documents/");
        const expected = try std.fmt.allocPrint(allocator, "{s}/documents/", .{home});

        defer {
            allocator.free(result);
            allocator.free(expected);
        }

        try std.testing.expectEqualStrings(expected, result);
    }

    {
        const result = try pathFormat(allocator, "$HOME");
        const expected = try std.fmt.allocPrint(allocator, "{s}/", .{home});

        defer {
            allocator.free(result);
            allocator.free(expected);
        }

        try std.testing.expectEqualStrings(expected, result);
    }

    {
        const result = try pathFormat(allocator, "/tmp/foo/");
        try std.testing.expectEqualStrings("/tmp/foo/", result);
    }

    {
        const result = try pathFormat(allocator, "/tmp/foo");
        defer allocator.free(result);

        try std.testing.expectEqualStrings("/tmp/foo/", result);
    }

    {
        const result = try pathFormat(allocator, "test/foo/");
        try std.testing.expectEqualStrings("test/foo/", result);
    }

    {
        const result = try pathFormat(allocator, "test/foo");
        defer allocator.free(result);

        try std.testing.expectEqualStrings("test/foo/", result);
    }
}

const Config = @This();
const std = @import("std");
const Core = @import("core.zig");
const Cli = @import("cli.zig");
const Util = @import("util.zig");

const WARN = Util.Level.WARNING;
