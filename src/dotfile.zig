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

pub fn deinit(self: Dotfile, allocator: std.mem.Allocator) void {
    allocator.free(self.src);
    allocator.free(self.dest);
}

fn metaFilePath(self: Dotfile, allocator: std.mem.Allocator) ![]const u8 {
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

fn backupPath(self: Dotfile, allocator: std.mem.Allocator) ![]const u8 {
    const data_dir = try Config.getXdgDir(allocator, Config.XdgDir.Data);
    defer allocator.free(data_dir);

    // epoch for now
    const id = std.time.timestamp();
    const dest = try Util.ensureLeadingSlash(allocator, self.dest);

    defer {
        if (!std.mem.eql(u8, dest, self.dest)) {
            allocator.free(dest);
        }
    }

    return try std.fmt.allocPrint(
        allocator,
        "{s}/_backups/{d}{s}",
        .{ data_dir, id, dest },
    );
}

pub fn backup(self: Dotfile, allocator: std.mem.Allocator) !void {
    const backup_dest = try self.backupPath(allocator);
    const index = std.mem.lastIndexOfScalar(u8, backup_dest, '/');
    const backup_target = backup_dest[0 .. index.? + 1];

    try Util.createDirRecursively(allocator, backup_target);

    var backup_dir = try std.fs.cwd().openDir(backup_target, .{
        .access_sub_paths = true,
        .iterate = false,
        .no_follow = false,
    });

    defer {
        allocator.free(backup_dest);
        backup_dir.close();
    }

    std.fs.cwd().copyFile(
        self.dest,
        std.fs.cwd(),
        backup_dest,
        .{ .override_mode = 0o600 },
    ) catch return;
}

pub fn validate(
    self: Dotfile,
    allocator: std.mem.Allocator,
    counter: *Util.Counter,
    json: bool,
) void {
    counter.total += 1;
    const template_file = std.fs.cwd().openFile(self.src, .{}) catch {
        counter.errors += 1;
        std.debug.print(
            "{s}{s}ERROR | Not found:{s} {s}\n",
            .{ Cli.red, Cli.bold, Cli.reset, self.src },
        );

        return;
    };

    defer template_file.close();

    const template_size: usize = @intCast((template_file.stat() catch unreachable).size);
    const template_content = template_file.readToEndAlloc(
        allocator,
        template_size,
    ) catch unreachable;

    defer allocator.free(template_content);

    if (!Util.isText(template_content)) return;

    const result = lib.validate(template_content);

    if (result.isError()) {
        counter.errors += 1;

        if (!json) {
            std.debug.print("{s}Invalid template{s} {s}\n", .{
                Cli.red,
                Cli.reset,
                self.src,
            });

            std.debug.print("Error at line {}, column {}: {s}\n", .{
                result.err.line,
                result.err.column,
                result.err.message,
            });
        }
    }
}

pub fn recordLastSync(self: Dotfile, allocator: std.mem.Allocator) !void {
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

    const result = try std.fmt.allocPrint(
        allocator,
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

    defer allocator.free(result);

    try f.writeAll(result);
}

pub fn lastMod(
    self: Dotfile,
    file: File,
) ?u64 {
    const target = switch (file) {
        .Template => self.src,
        .Render => self.dest,
    };

    const stat = std.fs.cwd().statFile(target) catch return null;

    // compress the integer
    const result = @divFloor(
        @as(u64, @intCast(stat.mtime)),
        1000000000,
    );

    return result;
}

fn forwardSync(
    self: Dotfile,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    counter: *Util.Counter,
    template_content: []const u8,
    template_mode: usize,
    is_text: bool,
    dry_run: bool,
    verbose: bool,
    json: bool,
) !void {
    if (is_text) counter.render += 1 else counter.binary += 1;
    const result = if (is_text) lib.applyTemplate(
        allocator,
        template_content,
    ) catch |err| {
        counter.errors += 1;
        try self.recordLastSync(allocator);

        return err;
    } else template_content;

    defer if (is_text) allocator.free(result);

    if (!dry_run) {
        const dir_name = std.fs.path.dirname(self.dest) orelse
            return error.InvalidPath;

        try Util.createDirRecursively(allocator, dir_name);

        const output_file = std.fs.cwd().openFile(
            self.dest,
            .{ .mode = .read_write },
        ) catch try std.fs.cwd().createFile(
            self.dest,
            .{
                .read = true,
                .truncate = true,
                .mode = @as(u16, @intCast(template_mode)),
            },
        );

        const output_file_size: usize = @intCast((try output_file.stat()).size);
        const output_file_content = try output_file.readToEndAlloc(
            allocator,
            output_file_size,
        );

        defer {
            allocator.free(output_file_content);
            output_file.close();
        }

        if (!std.mem.eql(u8, output_file_content, result)) {
            try output_file.seekTo(0);
            try output_file.writeAll(result);
            try output_file.setEndPos(result.len);
            counter.updated += 1;
        }

        try self.recordLastSync(allocator);
    }

    if (!json and (dry_run or verbose)) {
        if (!is_text) {
            try stdout.print("{s}{s}FILE | {s} >>> {s}{s}\n", .{
                Cli.blue,
                Cli.bold,
                self.src,
                self.dest,
                Cli.reset,
            });
        } else {
            try stdout.print("{s}{s}FILE | {s}{s}\n", .{
                Cli.yellow,
                Cli.bold,
                self.dest,
                Cli.reset,
            });
        }

        if (dry_run) {
            if (is_text)
                try stdout.print(
                    "{s}{s}DATA | render:{s}\n\n{s}{s}",
                    .{
                        Cli.yellow,
                        Cli.bold,
                        Cli.reset,
                        result,
                        assets.separator,
                    },
                )
            else
                try stdout.print(
                    "{s}{s}DATA | render: {s}binary{s}\n{s}",
                    .{
                        Cli.blue,
                        Cli.bold,
                        Cli.italic,
                        Cli.reset,
                        assets.separator,
                    },
                );
        }
    }
}

fn backSync(
    self: Dotfile,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    counter: *Util.Counter,
    template_content: []const u8,
    template_mode: usize,
    is_text: bool,
    dry_run: bool,
    verbose: bool,
    json: bool,
) !void {
    counter.template += 1;

    const rendered_file = try std.fs.cwd().openFile(self.dest, .{});
    defer rendered_file.close();

    const rendered_size: usize = @intCast((try rendered_file.stat()).size);
    const rendered_content = try rendered_file.readToEndAlloc(
        allocator,
        rendered_size,
    );

    defer if (is_text) allocator.free(rendered_content);

    const new_template = if (is_text) try lib.reverseTemplate(
        allocator,
        rendered_content,
        template_content,
    ) else rendered_content;

    defer allocator.free(new_template);

    if (!dry_run) {
        const updated_template = std.fs.cwd().openFile(
            self.src,
            .{ .mode = .read_write },
        ) catch try std.fs.cwd().createFile(
            self.src,
            .{
                .read = false,
                .truncate = true,
                .mode = @as(u16, @intCast(template_mode)),
            },
        );

        defer updated_template.close();

        if (is_text) {
            if (!std.mem.eql(u8, template_content, new_template)) {
                counter.updated += 1;
                try updated_template.seekTo(0);
                try updated_template.writeAll(new_template);
                try updated_template.setEndPos(new_template.len);
            }
        } else {
            if (!std.mem.eql(u8, template_content, rendered_content)) {
                counter.updated += 1;
                try updated_template.seekTo(0);
                try updated_template.writeAll(rendered_content);
                try updated_template.setEndPos(rendered_content.len);
            }
        }

        try self.recordLastSync(allocator);
    }

    if (!json and (dry_run or verbose)) {
        try stdout.print(
            "{s}{s}FILE | {s}{s}\n",
            .{
                Cli.yellow,
                Cli.bold,
                self.src,
                Cli.reset,
            },
        );

        if (dry_run) {
            try stdout.print(
                "{s}{s}DATA | template:{s}\n\n{s}{s}",
                .{
                    Cli.yellow,
                    Cli.bold,
                    Cli.reset,
                    new_template,
                    assets.separator,
                },
            );
        }
    }
}

pub fn processFile(
    self: Dotfile,
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    direction: Cli.Direction,
    counter: *Util.Counter,
    dry_run: bool,
    verbose: bool,
    json: bool,
) !void {
    counter.total += 1;
    const template_file = std.fs.cwd().openFile(self.src, .{}) catch {
        counter.errors += 1;
        std.debug.print(
            "{s}{s}ERROR | Not found:{s} {s}\n",
            .{ Cli.red, Cli.bold, Cli.reset, self.src },
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

    const template_mode = try template_file.mode();
    const is_text = Util.isText(template_content);
    var last_sync: usize = 0;

    const data_dir = try Config.getXdgDir(allocator, Config.XdgDir.Data);
    defer allocator.free(data_dir);

    const meta_file_path = try self.metaFilePath(allocator);
    defer allocator.free(meta_file_path);

    const dir_path = std.fs.path.dirname(self.dest) orelse
        return error.InvalidPath;

    try Util.createDirRecursively(allocator, dir_path);
    try Util.createDirRecursively(allocator, data_dir);

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
            try self.backup(allocator);
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

        var meta_content = std.array_list.Managed(u8).init(allocator);
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
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            counter.errors += 1;
            return err;
        };

        defer std.zon.parse.free(allocator, meta);

        last_sync = @intCast(meta.synced);
    }

    const last_modified_src = self.lastMod(File.Template) orelse 0;
    const last_modified_rend = self.lastMod(File.Render) orelse 0;

    switch (direction) {
        .forward => try self.forwardSync(
            allocator,
            stdout,
            counter,
            template_content,
            template_mode,
            is_text,
            dry_run,
            verbose,
            json,
        ),
        .back => try self.backSync(
            allocator,
            stdout,
            counter,
            template_content,
            template_mode,
            is_text,
            dry_run,
            verbose,
            json,
        ),
        .dual => {
            if ((meta_file != null) and
                (last_sync < last_modified_rend) and
                (last_modified_rend > last_modified_src))
            {
                try self.backSync(
                    allocator,
                    stdout,
                    counter,
                    template_content,
                    template_mode,
                    is_text,
                    dry_run,
                    verbose,
                    json,
                );
            } else {
                try self.forwardSync(
                    allocator,
                    stdout,
                    counter,
                    template_content,
                    template_mode,
                    is_text,
                    dry_run,
                    verbose,
                    json,
                );
            }
        },
    }
}

test processFile {
    var counter = Util.Counter.new(false);
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const writer = &stdout_writer.interface;

    errdefer {
        std.fs.cwd().deleteTree("test/root2") catch unreachable;
        std.fs.cwd().deleteTree("test/dest2") catch unreachable;
    }

    // dual
    {
        var dotfile_d = new("test/root/testfile1", "test/dest2/testfile-unit");

        _ = try dotfile_d.processFile(
            std.testing.allocator,
            writer,
            Cli.Direction.dual,
            &counter,
            false,
            false,
            false,
        );

        const file_dual = try std.fs.cwd().openFile("test/dest2/testfile-unit", .{});
        const file_dual_content = try file_dual.readToEndAlloc(
            std.testing.allocator,
            1024,
        );

        file_dual.close();

        errdefer std.fs.cwd().deleteTree("test/dest2") catch unreachable;
        defer std.testing.allocator.free(file_dual_content);

        const expected_dual_content =
            \\# TEST
            \\Foo
            \\val="Bar"
            \\
        ;

        try std.testing.expectEqualStrings(expected_dual_content, file_dual_content);
        try std.fs.cwd().deleteTree("test/dest2");
    }

    // forward
    {
        var dotfile_f = new("test/root/testfile1", "test/dest2/testfile-unit");

        _ = try dotfile_f.processFile(
            std.testing.allocator,
            writer,
            Cli.Direction.forward,
            &counter,
            false,
            false,
            false,
        );

        const file_fwd = try std.fs.cwd().openFile("test/dest2/testfile-unit", .{});
        const file_fwd_content = try file_fwd.readToEndAlloc(
            std.testing.allocator,
            1024,
        );

        file_fwd.close();

        defer std.testing.allocator.free(file_fwd_content);

        const expected_fwd_content =
            \\# TEST
            \\Foo
            \\val="Bar"
            \\
        ;

        try std.testing.expectEqualStrings(expected_fwd_content, file_fwd_content);
    }

    // back
    {
        try std.fs.cwd().makeDir("test/root2");
        var dotfile_b = new("test/root2/testfile1", "test/dest2/testfile-unit");
        const template = try std.fs.cwd().createFile(
            "test/root2/testfile1",
            .{ .read = true, .truncate = false },
        );

        try template.writeAll(
            \\# TEST
            \\
        );

        template.close();

        const render = try std.fs.cwd().createFile(
            "test/dest2/testfile-unit",
            .{ .read = true, .truncate = true },
        );

        try render.writeAll(
            \\# TEST
            \\Foo
            \\val="Zoot"
            \\
        );

        render.close();

        _ = try dotfile_b.processFile(
            std.testing.allocator,
            writer,
            Cli.Direction.back,
            &counter,
            false,
            false,
            false,
        );

        const file_bwd = try std.fs.cwd().openFile("test/root2/testfile1", .{});
        const file_bwd_content = try file_bwd.readToEndAlloc(
            std.testing.allocator,
            1024,
        );

        file_bwd.close();

        defer std.testing.allocator.free(file_bwd_content);

        const expected_bwd_content =
            \\# TEST
            \\Foo
            \\val="Zoot"
            \\
        ;

        try std.testing.expectEqualStrings(expected_bwd_content, file_bwd_content);
    }

    try std.fs.cwd().deleteTree("test/root2");
    try std.fs.cwd().deleteTree("test/dest2");
}

const Dotfile = @This();
const std = @import("std");
const lib = @import("libdfs");
const Cli = @import("cli.zig");
const Config = @import("config.zig");
const Util = @import("util.zig");
const assets = @import("assets.zig");

const ERR = Util.Level.ERROR;
