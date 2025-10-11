pub const XdgDir = enum {
    Config,
    Data,
    Home,
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
            new_path
        else
            try std.fmt.allocPrint(allocator, "{s}/", .{new_path});

        defer if (trailing_slash) allocator.free(target);

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

const std = @import("std");

const Util = @import("util.zig");
