pub const XdgDir = enum {
    Config,
    Data,
    Home,
};

pub const ConfigResult = union(enum) {
    ok: Configuration,
    parse_error: [:0]const u8,
};

pub const Configuration = struct {
    repository: []const u8,
    source: []const u8,
    destination: []const u8,
    ignore_list: [][]const u8,

    pub fn new(
        allocator: std.mem.Allocator,
        repository: []const u8,
        source: []const u8,
        destination: ?[]const u8,
    ) !Configuration {
        const path = if (destination == null)
            try std.process.getEnvVarOwned(allocator, "HOME")
        else
            destination.?;

        return .{
            .repository = repository,
            .source = source,
            .destination = path,
            .ignore_list = &[_][]u8{},
        };
    }

    pub fn write(
        self: *Configuration,
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
};

pub fn open(
    allocator: std.mem.Allocator,
    path: []const u8,
) !ConfigResult {
    const config_file = std.fs.cwd().openFile(path, .{}) catch |err|
        switch (err) {
            error.FileNotFound => {
                std.debug.print("{s}Config not found!{s}\nRun `dfs init`.", .{
                    Cli.red,
                    Cli.reset,
                });

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
        Configuration,
        allocator,
        config_data,
        null,
        .{},
    ) catch {
        const data = try allocator.dupeZ(u8, config_data);
        return ConfigResult{ .parse_error = data };
    };

    return ConfigResult{ .ok = config };
}

pub fn bootstrap(allocator: std.mem.Allocator, url: []const u8) !void {
    const config_home = try getXdgDir(allocator, XdgDir.Config);
    defer allocator.free(config_home);

    const config_path = try std.fmt.allocPrint(
        allocator,
        "{s}/dfs.zon",
        .{config_home},
    );

    defer allocator.free(config_path);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    try Util.createDirRecursively(allocator, config_home);

    var file = try std.fs.createFileAbsolute(
        config_path,
        .{ .read = false, .truncate = true },
    );

    defer file.close();

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

    const config = try open(allocator, config_path);
    try Util.cloneRepo(allocator, config.ok.repository, config.ok.source);
}

pub fn migrateConfig(
    allocator: std.mem.Allocator,
    config_path: []const u8,
) !void {
    const MigrationConfig = MigrationType(Configuration);
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

    var new_config = Configuration{
        .repository = if (old_config.repository) |v| v else "",
        .source = if (old_config.source) |v| v else "",
        .destination = if (old_config.destination) |v| v else "",
        .ignore_list = ignore_list,
    };

    try new_config.write(allocator, config_path);

    for (ignore_list) |item| {
        allocator.free(item);
    }

    allocator.free(ignore_list);
}

fn MigrationType(comptime T: type) type {
    const fields = std.meta.fields(T);
    var struct_fields: [fields.len]std.builtin.Type.StructField = undefined;

    inline for (fields, 0..) |field, i| {
        const OptionalType = @Type(.{
            .optional = .{
                .child = field.type,
            },
        });

        const default_value = @as(OptionalType, null);

        struct_fields[i] = .{
            .name = field.name,
            .type = OptionalType,
            .default_value_ptr = &default_value,
            .is_comptime = false,
            .alignment = @alignOf(OptionalType),
        };
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &struct_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

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
            .Home => "HOME",
        },
    ) catch {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);

        switch (env_var) {
            .Config => return try std.fs.path.join(allocator, &.{
                home,
                ".config",
            }),
            .Data => return try std.fs.path.join(allocator, &.{
                home,
                ".local",
                "share",
                "dfs",
            }),
            .Home => return allocator.dupe(u8, home),
        }
    };

    return path;
}

test migrateConfig {
    const old_config =
        \\.{
        \\    .repository = "https://gibson.com/test",
        \\    .source = "test/root-back",
        \\    .ignore_list = .{"foo","bar"},
        \\}
        \\
    ;

    const expected_config =
        \\.{
        \\    .repository = "https://gibson.com/test",
        \\    .source = "test/root-back",
        \\    .destination = "",
        \\    .ignore_list = .{ "foo", "bar" },
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

const std = @import("std");

const Cli = @import("cli.zig");
const Util = @import("util.zig");
