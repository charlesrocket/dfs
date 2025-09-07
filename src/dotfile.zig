const Meta = struct {
    src: []const u8,
    dest: []const u8,
    synced: i64,
};

dest: []const u8,
src: []const u8,
synced: ?u64,

pub fn new(src: []const u8, dest: []const u8) @This() {
    return .{
        .dest = dest,
        .src = src,
        .synced = null,
    };
}

pub fn recordLastSync(self: @This(), allocator: std.mem.Allocator) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const data_dir = try Config.getXdgDir(allocator, Config.XdgDir.Data);
    const sync_dest = try std.fmt.bufPrint(&buf, "{s}{s}.zon", .{
        data_dir,
        self.dest,
    });

    const index = std.mem.lastIndexOfScalar(u8, sync_dest, '/');
    const sync_dir = sync_dest[0 .. index.? + 1];

    try Util.createDirRecursively(allocator, sync_dir);

    const f = try std.fs.createFileAbsolute(sync_dest, .{
        .read = false,
        .truncate = true,
    });

    defer f.close();

    const record = Meta{
        .src = self.src,
        .dest = self.dest,
        .synced = std.time.timestamp(),
    };

    var writer = f.writer();
    try writer.print(
        ".{{\n" ++
            "    .src = \"{s}\",\n" ++
            "    .dest = \"{s}\",\n" ++
            "    .synced = {d},\n" ++
            "}}\n",
        .{
            record.src,
            record.dest,
            record.synced,
        },
    );
}

pub fn lastMod(self: @This()) ?u64 {
    const path = std.fs.path.dirname(self.dest);
    const dir = std.fs.cwd().openDir(path.?, .{}) catch return null;
    const stat = dir.statFile(self.dest) catch return null;

    // compress the integer
    const result = @divFloor(
        @as(u64, @intCast(stat.mtime)),
        1000000000,
    );

    return result;
}

pub fn processFile(
    self: @This(),
    allocator: std.mem.Allocator,
    stdout: @TypeOf(std.io.getStdOut().writer()),
    dry_run: bool,
    verbose: bool,
) !void {
    const template_file = try std.fs.cwd().openFile(self.src, .{});
    defer template_file.close();

    // TODO adjust buffer limit
    const template_content = try template_file.readToEndAlloc(
        allocator,
        2048 * 2048,
    );
    const is_text = Util.isText(template_content);

    if (!is_text) {
        if (dry_run or verbose) {
            try stdout.print("{s}{s}FILE | copy {s} -> {s}{s}\n", .{
                cli.blue,
                cli.bold,
                self.src,
                self.dest,
                cli.reset,
            });
        } else {
            // ensure destination directory exists
            const dir_path = std.fs.path.dirname(self.dest) orelse
                return error.InvalidPath;

            try Util.createDirRecursively(allocator, dir_path);

            const dest_file = try std.fs.createFileAbsolute(self.dest, .{
                .read = false,
                .truncate = true,
            });
            defer dest_file.close();

            try dest_file.writeAll(template_content);
            try self.recordLastSync(allocator);
        }

        return;
    }

    var last_sync: usize = 0;
    var meta_present = true;
    const data_dir = try Config.getXdgDir(allocator, Config.XdgDir.Data);
    const meta_file_path = try std.fmt.allocPrint(
        allocator,
        "{s}{s}.zon",
        .{ data_dir, self.dest },
    );

    defer allocator.free(meta_file_path);

    const dir_path = std.fs.path.dirname(self.dest) orelse
        return error.InvalidPath;

    try Util.createDirRecursively(allocator, dir_path);
    try Util.createDirRecursively(allocator, data_dir);

    // TODO maybe this is a bit too much
    const meta_file: ?std.fs.File = std.fs.cwd().openFile(
        meta_file_path,
        .{},
    ) catch |err|
        switch (err) {
            error.FileNotFound => blk: {
                meta_present = false;
                const index = std.mem.lastIndexOfScalar(u8, meta_file_path, '/');
                const meta_dest = meta_file_path[0..index.?];

                if (!dry_run) {
                    try Util.createDirRecursively(allocator, meta_dest);
                    _ = try std.fs.createFileAbsolute(
                        meta_file_path,
                        .{
                            .read = false,
                            .truncate = true,
                            .mode = 0o600,
                        },
                    );
                }

                break :blk if (dry_run)
                    null
                else
                    std.fs.cwd().openFile(meta_file_path, .{}) catch unreachable;
            },

            else => return err,
        };

    defer {
        if (meta_file != null) meta_file.?.close();
    }

    if (meta_present) {
        const meta_content_t = try meta_file.?.readToEndAlloc(allocator, 1024);
        var meta_content = std.ArrayList(u8).init(allocator);
        defer meta_content.deinit();

        for (meta_content_t) |c| {
            try meta_content.append(c);
        }

        // null-terminated
        try meta_content.append(0);

        const input = meta_content.items[0 .. meta_content.items.len - 1 :0];
        const meta = std.zon.parse.fromSlice(
            Meta,
            allocator,
            input,
            null,
            .{},
        ) catch
            return std.debug.print(
                "{s}Failed to parse ZON file:{s} {s}\n",
                .{ cli.red, cli.reset, meta_file_path },
            );

        last_sync = @intCast(meta.synced);
    }

    const last_modified = self.lastMod() orelse 0;

    if (last_sync < last_modified) {
        const rendered_file = try std.fs.cwd().openFile(self.dest, .{});
        defer rendered_file.close();

        const rendered_content = try rendered_file.readToEndAlloc(
            allocator,
            2048 * 2048,
        );
        defer allocator.free(rendered_content);

        const new_template = try lib.reverseTemplate(
            allocator,
            rendered_content,
            template_content,
        );

        if (!dry_run) {
            const updated_template = try std.fs.createFileAbsolute(
                self.src,
                .{
                    .read = false,
                    .truncate = true,
                },
            );

            defer updated_template.close();
            try updated_template.writeAll(new_template);
        }
        if (dry_run or verbose) {
            try stdout.print(
                "{s}{s}FILE | {s}{s}\n",
                .{
                    cli.yellow,
                    cli.bold,
                    self.src,
                    cli.reset,
                },
            );

            if (dry_run) {
                try stdout.print(
                    "{s}{s}FILE | new template data:{s}\n\n{s}{s}",
                    .{
                        cli.yellow,
                        cli.bold,
                        cli.reset,
                        new_template,
                        assets.separator,
                    },
                );
            }
        }
    }

    const result = try lib.applyTemplate(allocator, template_content);

    if (!dry_run) {
        const output_file = try std.fs.createFileAbsolute(self.dest, .{
            .read = false,
            .truncate = true,
        });

        try output_file.writeAll(result);
        defer output_file.close();

        try self.recordLastSync(allocator);
    }

    if (dry_run or verbose) {
        try stdout.print("{s}{s}FILE | {s}{s}\n", .{
            cli.yellow,
            cli.bold,
            self.dest,
            cli.reset,
        });

        if (dry_run) {
            if (is_text)
                try stdout.print(
                    "{s}{s}FILE | new render data:{s}\n\n{s}{s}",
                    .{
                        cli.yellow,
                        cli.bold,
                        cli.reset,
                        result,
                        assets.separator,
                    },
                )
            else
                try stdout.print(
                    "{s}{s}FILE | new render data: {s}binary{s}\n\n",
                    .{
                        cli.blue,
                        cli.bold,
                        cli.italic,
                        cli.reset,
                    },
                );
        }
    }
}

const std = @import("std");

const lib = @import("libdfs");
const cli = @import("cli.zig");
const Config = @import("config.zig");
const Util = @import("util.zig");
const assets = @import("assets.zig");
