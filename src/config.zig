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
    repository: []const u8,
    source: []const u8,
    target: ?[]const u8,
    environ_map: *std.process.Environ.Map,
) !Config {
    // destination
    const path = if (target == null)
        // TODO handle null value
        environ_map.get("HOME")
    else
        target.?;

    return .{
        .repository = repository,
        .source = source,
        .target = path.?,
        .logging = false,
        .notifications = false,
        .watcher = WatcherMode.auto,
        .ignore_list = &[_][]u8{},
        .tray = .{
            .enabled = true,
            .icon = .bright,
        },
    };
}

pub fn write(
    self: *Config,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !void {
    const parent_dir = std.fs.path.dirname(path);

    if (parent_dir != null) try Util.createDirRecursively(
        allocator,
        io,
        parent_dir.?,
    );

    const f = try std.Io.Dir.cwd().createFile(
        io,
        path,
        .{ .read = false, .truncate = true },
    );

    defer f.close(io);

    var buf: [1024]u8 = undefined;
    var file_writer = f.writer(io, &buf);
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
    const config_file = std.Io.Dir.cwd().openFile(core.io, path, .{}) catch |err|
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

    defer config_file.close(core.io);

    const config_size: usize = @intCast((try config_file.stat(core.io)).size);

    var config_reader = config_file.reader(core.io, &.{});
    const config_content_t = try config_reader.interface.allocRemaining(
        allocator,
        .limited(config_size),
    );

    defer allocator.free(config_content_t);

    var config_content = std.ArrayList(u8).empty;
    defer config_content.deinit(allocator);

    for (config_content_t) |c| {
        try config_content.append(allocator, c);
    }

    try config_content.append(allocator, 0);

    const config_data =
        config_content.items[0 .. config_content.items.len - 1 :0];

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(allocator);

    const config = std.zon.parse.fromSlice(
        Config,
        allocator,
        config_data,
        &diag,
        .{ .ignore_unknown_fields = false },
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

            Config.migrateConfig(allocator, core.io, path) catch |err| {
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
                    "https://gibson.com/git/dotfiles",
                    "$HOME/src/dotfiles",
                    "/tmp/test",
                    core.environ_map,
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

            if (core.logs) Util.log(core.io, WARN, "Config updated!", .{});
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
    const config_home = try getXdgDir(allocator, XdgDir.Config, core.environ_map);
    defer allocator.free(config_home);

    const config_path = try defaultConfigPath(allocator, core.environ_map);
    defer allocator.free(config_path);

    var client = std.http.Client{ .allocator = allocator, .io = core.io };
    defer client.deinit();

    try Util.createDirRecursively(allocator, core.io, config_home);
    var file = try std.Io.Dir.createFileAbsolute(core.io, config_path, .{});
    defer file.close(core.io);

    var result_body = std.Io.Writer.Allocating.init(allocator);
    defer result_body.deinit();

    const response = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &result_body.writer,
    });

    if (response.status.class() != .success) {
        return error.UnexpectedRequestStatus;
    }

    const body = result_body.written();

    const buf = try allocator.alloc(u8, body.len);
    defer allocator.free(buf);

    var file_writer = file.writer(core.io, buf);
    const writer = &file_writer.interface;

    try writer.writeAll(body);
    try writer.flush();

    const config = try open(allocator, config_path, core);
    defer std.zon.parse.free(allocator, config);

    try Util.cloneRepo(allocator, config.repository, config.source, core);
}

pub fn migrateConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
) !void {
    const deprecated_field_specs = .{
        .{ .name = "destination", .type = []const u8 },
        .{ .name = "tray.menu_icons", .type = bool },
    };

    const MigrationConfig = MigrationType(Config, deprecated_field_specs);

    const raw = try std.Io.Dir.cwd().readFileAlloc(
        io,
        config_path,
        allocator,
        .unlimited,
    );

    defer allocator.free(raw);

    const content = try allocator.dupeZ(u8, raw);
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
        } else .{
            .enabled = true,
            .icon = .bright,
        },
    };
    try new_config.write(allocator, io, config_path);
    for (ignore_list) |item| {
        allocator.free(item);
    }
    allocator.free(ignore_list);
}

fn MigrationType(
    comptime T: type,
    comptime deprecated_fields: anytype,
) type {
    const config_fields = std.meta.fields(T);

    // filter fields that belong at this level
    comptime var local_count = 0;
    inline for (deprecated_fields) |spec| {
        if (std.mem.findScalar(u8, spec.name, '.') == null)
            local_count += 1;
    }

    const total = config_fields.len + local_count;

    // @Struct takes three separate arrays: names, types, attrs
    var field_names: [total][]const u8 = undefined;
    var field_types: [total]type = undefined;
    var field_attrs: [total]std.builtin.Type.StructField.Attributes = undefined;

    inline for (config_fields, 0..) |field, i| {
        const field_type_info = @typeInfo(field.type);

        // count deprecated fields that are children of this field
        comptime var nested_count = 0;
        inline for (deprecated_fields) |f| {
            const dot = comptime std.mem.findScalar(u8, f.name, '.');
            if (dot != null and std.mem.eql(
                u8,
                f.name[0..dot.?],
                field.name,
            )) {
                nested_count += 1;
            }
        }

        const FieldType = switch (field_type_info) {
            .@"struct" => blk: {
                var nested_fields: [nested_count]struct {
                    name: [:0]const u8,
                    type: type,
                } = undefined;

                comptime var j = 0;
                inline for (deprecated_fields) |f| {
                    const dot = comptime std.mem.findScalar(u8, f.name, '.');

                    if (dot != null and std.mem.eql(
                        u8,
                        f.name[0..dot.?],
                        field.name,
                    )) {
                        nested_fields[j] = .{
                            .name = @ptrCast(f.name[dot.? + 1 ..]),
                            .type = f.type,
                        };

                        j += 1;
                    }
                }

                break :blk MigrationType(field.type, nested_fields);
            },
            else => field.type,
        };

        const OptionalType = ?FieldType;
        const default_value: OptionalType = null;

        field_names[i] = field.name;
        field_types[i] = OptionalType;
        field_attrs[i] = .{ .default_value_ptr = &default_value };
    }

    comptime var di = 0;
    inline for (deprecated_fields) |f| {
        if (std.mem.findScalar(u8, f.name, '.') == null) {
            const OptionalType = ?f.type;
            const default_value: OptionalType = null;

            field_names[config_fields.len + di] = f.name;
            field_types[config_fields.len + di] = OptionalType;
            field_attrs[config_fields.len + di] = .{ .default_value_ptr = &default_value };

            di += 1;
        }
    }

    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
}

// deallocate on changes
pub fn pathFormat(
    allocator: std.mem.Allocator,
    path: []const u8,
    environ: *std.process.Environ.Map,
) ![]const u8 {
    const trailing_slash = std.mem.endsWith(u8, path, "/");

    if (std.mem.startsWith(u8, path, "$HOME")) {
        const home = try getXdgDir(allocator, XdgDir.Home, environ);
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

pub fn getXdgDir(
    allocator: std.mem.Allocator,
    env_var: XdgDir,
    environ: *std.process.Environ.Map,
) ![]const u8 {
    const path = environ.get(
        switch (env_var) {
            .Config => "XDG_CONFIG_HOME",
            .Data => "XDG_DATA_HOME",
            .State => "XDG_STATE_HOME",
            .Home => "HOME",
        },
    );

    if (path == null) {
        const home = environ.get("HOME");

        // TODO handle null value
        switch (env_var) {
            .Config => return try std.fs.path.join(allocator, &.{
                home.?,
                ".config",
                "dfs",
            }),
            .Data => return try std.fs.path.join(allocator, &.{
                home.?,
                ".local",
                "share",
                "dfs",
            }),
            .State => return try std.fs.path.join(allocator, &.{
                home.?,
                ".local",
                "state",
                "dfs",
            }),
            .Home => return allocator.dupe(u8, home.?),
        }
    }

    switch (env_var) {
        .Home => return path.?,
        .Config, .Data, .State => {
            return try std.fs.path.join(allocator, &.{
                path.?,
                "dfs",
            });
        },
    }
}

pub fn defaultConfigPath(
    allocator: std.mem.Allocator,
    environ: *std.process.Environ.Map,
) ![]const u8 {
    const config_home = try Config.getXdgDir(
        allocator,
        Config.XdgDir.Config,
        environ,
    );

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
    const environ = std.testing.environ;

    var environ_map = try std.process.Environ.createMap(environ, allocator);
    const home = try getXdgDir(allocator, XdgDir.Home, &environ_map);
    const config_path = try defaultConfigPath(allocator, &environ_map);
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
    const allocator = std.testing.allocator;
    const io = std.testing.io;

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
        \\    .tray = .{ .enabled = true, .icon = .bright },
        \\}
        \\
    ;

    const old_file = try std.Io.Dir.cwd().createFile(
        io,
        "test/conf-old.zon",
        .{ .read = false },
    );

    const buf = try allocator.alloc(u8, old_config.len);
    defer allocator.free(buf);

    var old_file_writer = old_file.writer(io, buf);
    try old_file_writer.interface.writeAll(old_config);
    try old_file_writer.interface.flush();

    old_file.close(io);

    try migrateConfig(allocator, io, "test/conf-old.zon");

    const new_file = try std.Io.Dir.cwd().openFile(io, "test/conf-old.zon", .{});
    var new_file_reader = new_file.reader(io, &.{});
    const content = try new_file_reader.interface.allocRemaining(allocator, .limited(1024));

    defer allocator.free(content);

    try std.testing.expectEqualStrings(expected_config, content);
    try std.Io.Dir.cwd().deleteFile(io, "test/conf-old.zon");
}

test pathFormat {
    const allocator = std.testing.allocator;
    const environ = std.testing.environ;
    var environ_map = try std.process.Environ.createMap(environ, allocator);

    const home = try environ.getAlloc(allocator, "HOME");
    defer allocator.free(home);

    {
        const result = try pathFormat(allocator, "$HOME/documents", &environ_map);
        const expected = try std.fmt.allocPrint(allocator, "{s}/documents/", .{home});

        defer {
            allocator.free(result);
            allocator.free(expected);
        }

        try std.testing.expectEqualStrings(expected, result);
    }

    {
        const result = try pathFormat(allocator, "$HOME/documents/", &environ_map);
        const expected = try std.fmt.allocPrint(allocator, "{s}/documents/", .{home});

        defer {
            allocator.free(result);
            allocator.free(expected);
        }

        try std.testing.expectEqualStrings(expected, result);
    }

    {
        const result = try pathFormat(allocator, "$HOME", &environ_map);
        const expected = try std.fmt.allocPrint(allocator, "{s}/", .{home});

        defer {
            allocator.free(result);
            allocator.free(expected);
        }

        try std.testing.expectEqualStrings(expected, result);
    }

    {
        const result = try pathFormat(allocator, "/tmp/foo/", &environ_map);
        try std.testing.expectEqualStrings("/tmp/foo/", result);
    }

    {
        const result = try pathFormat(allocator, "/tmp/foo", &environ_map);
        defer allocator.free(result);

        try std.testing.expectEqualStrings("/tmp/foo/", result);
    }

    {
        const result = try pathFormat(allocator, "test/foo/", &environ_map);
        try std.testing.expectEqualStrings("test/foo/", result);
    }

    {
        const result = try pathFormat(allocator, "test/foo", &environ_map);
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
