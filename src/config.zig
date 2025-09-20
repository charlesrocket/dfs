pub const XdgDir = enum {
    Config,
    Data,
    Home,
};

pub const Configuration = struct {
    source: []const u8,
    destination: []const u8,
    ignore_list: [][]const u8,

    pub fn new(
        allocator: std.mem.Allocator,
        source: []const u8,
        destination: ?[]const u8,
    ) !Configuration {
        const path = if (destination == null)
            try std.process.getEnvVarOwned(allocator, "HOME")
        else
            destination.?;

        return .{
            .source = source,
            .destination = path,
            .ignore_list = &[_][]u8{},
        };
    }

    pub fn write(
        self: *Configuration,
        allocator: std.mem.Allocator,
        custom_path: ?[]const u8,
    ) !void {
        const path = try getXdgDir(allocator, XdgDir.Config);
        defer allocator.free(path);

        const config = try std.fmt.allocPrint(
            allocator,
            "{s}/dfs.zon",
            .{path},
        );

        defer allocator.free(config);

        try Util.createDirRecursively(allocator, path);

        const f = try std.fs.createFileAbsolute(
            if (custom_path == null) config else custom_path.?,
            .{ .read = false, .truncate = true },
        );

        defer f.close();

        var writer = f.writer();

        _ = try std.zon.stringify.serialize(
            self,
            .{},
            writer,
        );

        _ = try writer.write("\n");
    }
};

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
