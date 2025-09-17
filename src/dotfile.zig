const Meta = struct {
    src: []const u8,
    dest: []const u8,
    synced: i64,
};

const File = enum {
    Template,
    Render,
};

dest: []const u8,
src: []const u8,
synced: ?u64,

pub fn new(src: []const u8, dest: []const u8) @This() {
    return .{
        .src = src,
        .dest = dest,
        .synced = null,
    };
}

pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
    allocator.free(self.src);
    allocator.free(self.dest);
}

pub fn metaFilePath(self: @This(), allocator: std.mem.Allocator) ![]const u8 {
    const data_dir = try Config.getXdgDir(allocator, Config.XdgDir.Data);
    defer allocator.free(data_dir);

    const dest = try Util.ensureLeadingSlash(allocator, self.dest);

    defer {
        if (!std.mem.eql(u8, dest, self.dest)) {
            allocator.free(dest);
        }
    }

    return try std.fmt.allocPrint(
        allocator,
        "{s}{s}.zon",
        .{ data_dir, dest },
    );
}

pub fn recordLastSync(self: @This(), allocator: std.mem.Allocator) !void {
    const sync_dest = try self.metaFilePath(allocator);
    defer allocator.free(sync_dest);

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

pub fn lastMod(
    self: @This(),
    allocator: std.mem.Allocator,
    file: File,
) ?u64 {
    const target = switch (file) {
        .Template => self.src,
        .Render => self.dest,
    };

    const abs = std.fs.realpathAlloc(allocator, target) catch return 0;
    defer allocator.free(abs);

    const path = std.fs.path.dirname(abs);
    const dir = std.fs.openDirAbsolute(path.?, .{}) catch unreachable;
    const stat = dir.statFile(abs) catch unreachable;

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
    stdout: anytype,
    counter: *Util.Counter,
    dry_run: bool,
    verbose: bool,
    json: bool,
) !void {
    counter.total += 1;
    const source_abs = try std.fs.realpathAlloc(allocator, self.src);
    defer allocator.free(source_abs);

    const template_file = std.fs.openFileAbsolute(source_abs, .{}) catch {
        counter.errors += 1;
        std.debug.print(
            "{s}{s}ERROR | Not found:{s} {s}\n",
            .{ cli.red, cli.bold, cli.reset, self.src },
        );

        return;
    };

    defer template_file.close();

    const template_size: usize = @intCast((try template_file.stat()).size);
    const template_content = try template_file.readToEndAlloc(
        allocator,
        template_size,
    );

    defer allocator.free(template_content);

    const is_text = Util.isText(template_content);

    if (!is_text) {
        if (!json and (dry_run or verbose)) {
            try stdout.print("{s}{s}FILE | {s} >>> {s}{s}\n", .{
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

        counter.updated += 1;
        counter.binary += 1;
        return;
    }

    var last_sync: usize = 0;

    const data_dir = try Config.getXdgDir(allocator, Config.XdgDir.Data);
    defer allocator.free(data_dir);

    const meta_file_path = try self.metaFilePath(allocator);
    defer allocator.free(meta_file_path);

    const dir_path = std.fs.path.dirname(self.dest) orelse
        return error.InvalidPath;

    try Util.createDirRecursively(allocator, dir_path);
    try Util.createDirRecursively(allocator, data_dir);

    // TODO maybe this is a bit too much
    var meta_file: ?std.fs.File = std.fs.cwd().openFile(
        meta_file_path,
        .{},
    ) catch |err|
        switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

    defer {
        if (meta_file != null) meta_file.?.close();
    }

    if (meta_file == null) {
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
    }

    if (meta_file != null) {
        const meta_file_size: usize = @intCast((try meta_file.?.stat()).size);
        const meta_content_t = try meta_file.?.readToEndAlloc(
            allocator,
            meta_file_size,
        );

        defer allocator.free(meta_content_t);

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
        ) catch {
            counter.errors += 1;

            return std.debug.print(
                "{s}{s}ERROR | Failed to parse ZON file:{s} {s}\n",
                .{ cli.red, cli.bold, cli.reset, meta_file_path },
            );
        };

        defer std.zon.parse.free(allocator, meta);

        last_sync = @intCast(meta.synced);
    }

    const last_modified_src = self.lastMod(allocator, File.Template) orelse 0;
    const last_modified_rend = self.lastMod(allocator, File.Render) orelse 0;

    if ((last_sync < last_modified_rend) and
        (last_modified_rend > last_modified_src))
    {
        const rendered_file = try std.fs.cwd().openFile(self.dest, .{});
        defer rendered_file.close();

        const rendered_size: usize = @intCast((try rendered_file.stat()).size);
        const rendered_content = try rendered_file.readToEndAlloc(
            allocator,
            rendered_size,
        );

        defer allocator.free(rendered_content);

        const new_template = try lib.reverseTemplate(
            allocator,
            rendered_content,
            template_content,
        );

        defer allocator.free(new_template);

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
            try self.recordLastSync(allocator);
        }
        if (!json and (dry_run or verbose)) {
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
                    "{s}{s}DATA | template:{s}\n\n{s}{s}",
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

        counter.updated += 1;
        counter.template += 1;
    } else {
        const result = lib.applyTemplate(allocator, template_content) catch {
            counter.errors += 1;
            try self.recordLastSync(allocator);

            if (!json and (dry_run or verbose)) {
                try stdout.print("{s}{s}ERROR | {s}{s}\n", .{
                    cli.red,
                    cli.bold,
                    self.dest,
                    cli.reset,
                });
            }

            return;
        };

        defer allocator.free(result);

        if (!dry_run) {
            const dir_name = std.fs.path.dirname(self.dest) orelse
                return error.InvalidPath;

            const target_dir_abs = try std.fs.realpathAlloc(allocator, dir_name);
            defer allocator.free(target_dir_abs);

            try Util.createDirRecursively(allocator, dir_name);

            const target_path = try std.fs.path.join(
                allocator,
                &.{ target_dir_abs, std.fs.path.basename(self.dest) },
            );

            defer allocator.free(target_path);

            const output_file = try std.fs.createFileAbsolute(target_path, .{
                .read = false,
                .truncate = true,
            });

            try output_file.writeAll(result);
            defer output_file.close();

            try self.recordLastSync(allocator);
        }

        if (!json and (dry_run or verbose)) {
            try stdout.print("{s}{s}FILE | {s}{s}\n", .{
                cli.yellow,
                cli.bold,
                self.dest,
                cli.reset,
            });

            if (dry_run) {
                if (is_text)
                    try stdout.print(
                        "{s}{s}DATA | render:{s}\n\n{s}{s}",
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
                        "{s}{s}DATA | render: {s}binary{s}\n\n",
                        .{
                            cli.blue,
                            cli.bold,
                            cli.italic,
                            cli.reset,
                        },
                    );
            }
        }

        counter.updated += 1;
        counter.render += 1;
    }
}

test processFile {
    var dotfile = new("test/root/testfile1", "test/dest2/testfile-unit");
    var counter = Util.Counter.new(false);
    var buff = std.ArrayList(u8).init(std.testing.allocator);
    defer buff.deinit();

    _ = try dotfile.processFile(
        std.testing.allocator,
        buff.writer(),
        &counter,
        false,
        false,
        false,
    );

    const file = try std.fs.cwd().openFile("test/dest2/testfile-unit", .{});
    const file_content = try file.readToEndAlloc(
        std.testing.allocator,
        1024,
    );

    file.close();

    defer std.testing.allocator.free(file_content);

    const expected_content =
        \\# TEST
        \\Foo
        \\val="Bar"
        \\
    ;

    try std.testing.expectEqualStrings(expected_content, file_content);

    _ = try dotfile.processFile(
        std.testing.allocator,
        buff.writer(),
        &counter,
        false,
        false,
        false,
    );

    try std.fs.cwd().deleteTree("test/dest2");
}

const std = @import("std");

const lib = @import("libdfs");
const cli = @import("cli.zig");
const Config = @import("config.zig");
const Util = @import("util.zig");
const assets = @import("assets.zig");
