pub const XdgDir = enum {
    Config,
    Data,
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
        const config = try std.fmt.allocPrint(
            allocator,
            "{s}/dfs.zon",
            .{path},
        );

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

pub fn getXdgDir(allocator: std.mem.Allocator, env_var: XdgDir) ![]const u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    const path = std.process.getEnvVarOwned(
        allocator,
        switch (env_var) {
            .Config => "XDG_CONFIG_HOME",
            .Data => "XDG_DATA_HOME",
        },
    ) catch switch (env_var) {
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
    };

    return path;
}

const std = @import("std");

const Util = @import("util.zig");
