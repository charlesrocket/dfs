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
synced: ?i64,

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

fn metaFilePath(
    self: Dotfile,
    allocator: std.mem.Allocator,
    environ: *std.process.Environ.Map,
) ![]const u8 {
    const data_dir = try Config.getXdgDir(
        allocator,
        Config.XdgDir.Data,
        environ,
    );

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

fn backupPath(
    self: Dotfile,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
) ![]const u8 {
    const data_dir = try Config.getXdgDir(
        allocator,
        Config.XdgDir.Data,
        environ,
    );
    defer allocator.free(data_dir);

    // epoch for now
    const now = std.Io.Clock.now(.real, io);
    const id = now.toNanoseconds();
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

pub fn backup(self: Dotfile, allocator: std.mem.Allocator, io: std.Io, environ: *std.process.Environ.Map) !void {
    const backup_dest = try self.backupPath(allocator, io, environ);
    const index = std.mem.lastIndexOfScalar(u8, backup_dest, '/');
    const backup_target = backup_dest[0 .. index.? + 1];

    try Util.createDirRecursively(allocator, io, backup_target);

    var backup_dir = try std.Io.Dir.cwd().openDir(io, backup_target, .{
        .access_sub_paths = true,
        .iterate = false,
    });

    defer {
        allocator.free(backup_dest);
        backup_dir.close(io);
    }

    std.Io.Dir.cwd().copyFile(
        self.dest,
        std.Io.Dir.cwd(),
        backup_dest,
        io,
        .{},
    ) catch return;
}

pub fn validate(
    self: Dotfile,
    allocator: std.mem.Allocator,
    io: std.Io,
    counter: *Util.Counter,
    json: bool,
) void {
    counter.total += 1;
    const template_file = std.Io.Dir.cwd().openFile(io, self.src, .{}) catch {
        counter.errors += 1;
        std.debug.print(
            "{s}{s}ERROR | Not found:{s} {s}\n",
            .{ Cli.red, Cli.bold, Cli.reset, self.src },
        );

        return;
    };

    defer template_file.close(io);

    const template_size: usize = @intCast((template_file.stat(io) catch unreachable).size);
    var template_file_reader = template_file.reader(io, &.{});
    const template_content = template_file_reader.interface.allocRemaining(
        allocator,
        .limited(template_size),
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

pub fn recordLastSync(
    self: Dotfile,
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
) !void {
    const sync_dest = try self.metaFilePath(allocator, environ);
    defer allocator.free(sync_dest);

    const now = std.Io.Clock.now(.real, io);
    const timestamp = now.toMilliseconds();

    const index = std.mem.lastIndexOfScalar(u8, sync_dest, '/');
    const sync_dir = sync_dest[0 .. index.? + 1];

    try Util.createDirRecursively(allocator, io, sync_dir);

    const f = try std.Io.Dir.createFileAbsolute(io, sync_dest, .{
        .read = false,
        .truncate = true,
    });

    defer f.close(io);

    const record = Meta{
        .src = self.src,
        .dest = self.dest,
        .synced = timestamp,
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

    const buf = try allocator.alloc(u8, result.len);
    defer allocator.free(buf);

    var file_writer = f.writer(io, buf);
    const writer = &file_writer.interface;

    try writer.writeAll(result);
    try writer.flush();
}

pub fn lastMod(
    self: Dotfile,
    io: std.Io,
    file: File,
) ?u64 {
    const target = switch (file) {
        .Template => self.src,
        .Render => self.dest,
    };

    const stat = std.Io.Dir.cwd().statFile(io, target, .{}) catch return null;

    // compress the integer
    const result = @divFloor(
        @as(u64, @intCast(stat.mtime.toMilliseconds())),
        1000000000,
    );

    return result;
}

fn forwardSync(
    self: Dotfile,
    allocator: std.mem.Allocator,
    counter: *Util.Counter,
    template_content: []const u8,
    template_mode: usize,
    is_text: bool,
    core: *Core,
) !void {
    if (is_text) counter.render += 1 else counter.binary += 1;
    const result = if (is_text) lib.applyTemplate(
        allocator,
        core.environ_map,
        template_content,
    ) catch |err| {
        counter.errors += 1;
        try self.recordLastSync(allocator, core.io, core.environ_map);

        return err;
    } else template_content;

    defer if (is_text) allocator.free(result);

    if (!core.dry) {
        // check if any parent directory in the path is a symlink
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(path_buf[0..self.dest.len], self.dest);
        var path_len = self.dest.len;

        // check each parent directory from bottom to top
        while (std.fs.path.dirname(path_buf[0..path_len])) |parent| {
            var inner_buf: [std.fs.max_path_bytes]u8 = undefined;
            if (std.Io.Dir.cwd().readLink(core.io, parent, &inner_buf)) |_| {
                // parent directory is a symlink, delete it
                try std.Io.Dir.cwd().deleteFile(core.io, parent);

                // need to recreate the directory structure as real dirs
                try Util.createDirRecursively(
                    allocator,
                    core.io,
                    parent,
                );

                break; // only need to handle the first symlinked parent
            } else |_| {
                // not a symlink, continue checking the parent
            }

            path_len = parent.len;
        }

        var link_buf: [std.fs.max_path_bytes]u8 = undefined;
        // delete symlinks
        if (std.Io.Dir.cwd().readLink(core.io, self.dest, &link_buf)) |_| {
            try std.Io.Dir.cwd().deleteFile(core.io, self.dest);
        } else |_| {}

        const dir_name = std.fs.path.dirname(self.dest) orelse
            return error.InvalidPath;

        try Util.createDirRecursively(allocator, core.io, dir_name);

        const output_file = std.Io.Dir.cwd().openFile(
            core.io,
            self.dest,
            .{ .mode = .read_write },
        ) catch try std.Io.Dir.cwd().createFile(
            core.io,
            self.dest,
            .{
                .read = true,
                .truncate = true,
                .permissions = std.Io.File.Permissions.fromMode(@intCast(template_mode)),
            },
        );

        const output_file_size: usize = @intCast((try output_file.stat(core.io)).size);
        var output_file_reader = output_file.reader(core.io, &.{});
        const output_file_content = try output_file_reader.interface.allocRemaining(
            allocator,
            .limited(output_file_size),
        );

        defer {
            allocator.free(output_file_content);
            output_file.close(core.io);
        }

        if (!std.mem.eql(u8, output_file_content, result)) {
            const write_buf = try allocator.alloc(u8, result.len);
            defer allocator.free(write_buf);

            var output_file_writer = output_file.writer(core.io, write_buf);
            try output_file_writer.seekTo(0);
            try output_file_writer.interface.writeAll(result);
            try output_file_writer.interface.flush();
            try output_file.setLength(core.io, result.len);
            counter.updated += 1;
        }

        try self.recordLastSync(allocator, core.io, core.environ_map);
    }

    if (!core.json and (core.dry or core.verbose)) {
        if (!is_text) {
            try core.stdout.print("{s}{s}FILE | {s} >>> {s}{s}\n", .{
                Cli.blue,
                Cli.bold,
                self.src,
                self.dest,
                Cli.reset,
            });
        } else {
            try core.stdout.print("{s}{s}FILE | {s}{s}\n", .{
                Cli.yellow,
                Cli.bold,
                self.dest,
                Cli.reset,
            });
        }

        if (core.dry) {
            if (is_text)
                try core.stdout.print(
                    "{s}{s}DATA | render:\n\n{s}{s}\n{s}",
                    .{
                        Cli.yellow,
                        Cli.bold,
                        Cli.reset,
                        result,
                        assets.separator,
                    },
                )
            else
                try core.stdout.print(
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

        try core.stdout.flush();
    }
}

fn backSync(
    self: Dotfile,
    allocator: std.mem.Allocator,
    counter: *Util.Counter,
    template_content: []const u8,
    template_mode: usize,
    is_text: bool,
    core: *Core,
) !void {
    counter.template += 1;

    const rendered_file = try std.Io.Dir.cwd().openFile(
        core.io,
        self.dest,
        .{},
    );

    defer rendered_file.close(core.io);

    const rendered_size: usize = @intCast((try rendered_file
        .stat(core.io)).size);

    var rendered_reader = rendered_file.reader(core.io, &.{});

    const rendered_content = try rendered_reader.interface.allocRemaining(
        allocator,
        .limited(rendered_size),
    );

    defer allocator.free(rendered_content);

    defer if (is_text) allocator.free(rendered_content);

    const new_template = if (is_text) try lib.reverseTemplate(
        allocator,
        core.environ_map,
        rendered_content,
        template_content,
    ) else rendered_content;

    defer allocator.free(new_template);

    if (!core.dry) {
        const updated_template = std.Io.Dir.cwd().openFile(
            core.io,
            self.src,
            .{ .mode = .read_write },
        ) catch try std.Io.Dir.cwd().createFile(
            core.io,
            self.src,
            .{
                .read = false,
                .truncate = true,
                .permissions = std.Io.File.Permissions.fromMode(@intCast(template_mode)),
            },
        );

        defer updated_template.close(core.io);

        const write_buf = try allocator.alloc(u8, new_template.len);
        defer allocator.free(write_buf);

        var updated_template_writer = updated_template.writer(core.io, write_buf);

        if (is_text) {
            if (!std.mem.eql(u8, template_content, new_template)) {
                counter.updated += 1;
                try updated_template_writer.seekTo(0);
                try updated_template_writer.interface.writeAll(new_template);
                try updated_template_writer.interface.flush();
                try updated_template.setLength(core.io, new_template.len);
            }
        } else {
            if (!std.mem.eql(u8, template_content, rendered_content)) {
                counter.updated += 1;
                try updated_template_writer.seekTo(0);
                try updated_template_writer.interface.writeAll(rendered_content);
                try updated_template_writer.interface.flush();
                try updated_template.setLength(core.io, rendered_content.len);
            }
        }

        try self.recordLastSync(allocator, core.io, core.environ_map);
    }

    if (!core.json and (core.dry or core.verbose)) {
        try core.stdout.print(
            "{s}{s}FILE | {s}{s}\n",
            .{
                Cli.yellow,
                Cli.bold,
                self.src,
                Cli.reset,
            },
        );

        if (core.dry) {
            try core.stdout.print(
                "{s}{s}DATA | template:{s}{s}\n{s}",
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
    counter: *Util.Counter,
    core: *Core,
) !void {
    counter.total += 1;
    const template_file = std.Io.Dir.cwd().openFile(core.io, self.src, .{}) catch {
        counter.errors += 1;
        try core.stderr.print(
            "{s}{s}ERROR | Not found:{s} {s}\n",
            .{ Cli.red, Cli.bold, Cli.reset, self.src },
        );

        try core.stderr.flush();
        return;
    };

    defer template_file.close(core.io);

    const template_size: usize = @intCast((try template_file.stat(core.io)).size);
    var template_reader = template_file.reader(core.io, &.{});
    const template_content = try template_reader.interface.allocRemaining(
        allocator,
        .limited(template_size),
    );

    defer allocator.free(template_content);

    const template_stat = try template_file.stat(core.io);
    const template_mode: usize = @intCast(template_stat.permissions.toMode());
    const is_text = Util.isText(template_content);
    var last_sync: usize = 0;

    const data_dir = try Config.getXdgDir(
        allocator,
        Config.XdgDir.Data,
        core.environ_map,
    );

    defer allocator.free(data_dir);

    const meta_file_path = try self.metaFilePath(allocator, core.environ_map);
    defer allocator.free(meta_file_path);

    const dir_path = std.fs.path.dirname(self.dest) orelse
        return error.InvalidPath;

    try Util.createDirRecursively(allocator, core.io, dir_path);
    try Util.createDirRecursively(allocator, core.io, data_dir);

    var meta_file: ?std.Io.File = std.Io.Dir.cwd().openFile(
        core.io,
        meta_file_path,
        .{},
    ) catch |err|
        switch (err) {
            error.FileNotFound => null,
            else => return err,
        };

    defer {
        if (meta_file != null) meta_file.?.close(core.io);
    }

    if (meta_file == null) {
        const index = std.mem.lastIndexOfScalar(u8, meta_file_path, '/');
        const meta_dest = meta_file_path[0..index.?];

        if (!core.dry) {
            try self.backup(allocator, core.io, core.environ_map);
            try Util.createDirRecursively(allocator, core.io, meta_dest);
            _ = try std.Io.Dir.createFileAbsolute(
                core.io,
                meta_file_path,
                .{
                    .read = false,
                    .truncate = true,
                },
            );
        }
    }

    if (meta_file != null) {
        const meta_file_size: usize = @intCast((try meta_file.?.stat(core.io)).size);
        var meta_file_reader = meta_file.?.reader(core.io, &.{});
        const meta_content_t = try meta_file_reader.interface.allocRemaining(allocator, .limited(meta_file_size));

        defer allocator.free(meta_content_t);

        var meta_content = std.ArrayList(u8).empty;
        defer meta_content.deinit(allocator);

        for (meta_content_t) |c| {
            try meta_content.append(allocator, c);
        }

        // null-terminated
        try meta_content.append(allocator, 0);

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

    const last_modified_src = self.lastMod(core.io, File.Template) orelse 0;
    const last_modified_rend = self.lastMod(core.io, File.Render) orelse 0;

    switch (core.direction) {
        .forward => try self.forwardSync(
            allocator,
            counter,
            template_content,
            template_mode,
            is_text,
            core,
        ),
        .back => try self.backSync(
            allocator,
            counter,
            template_content,
            template_mode,
            is_text,
            core,
        ),
        .dual => {
            if ((meta_file != null) and
                (last_sync < last_modified_rend) and
                (last_modified_rend > last_modified_src))
            {
                try self.backSync(
                    allocator,
                    counter,
                    template_content,
                    template_mode,
                    is_text,
                    core,
                );
            } else {
                try self.forwardSync(
                    allocator,
                    counter,
                    template_content,
                    template_mode,
                    is_text,
                    core,
                );
            }
        },
    }
}

test processFile {
    const io = std.testing.io;
    var env_map = try std.testing.environ.createMap(std.testing.allocator);

    var counter = Util.Counter.new(false);
    var bufo: [4096]u8 = undefined;
    var bufe: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &bufo);
    var stderr_writer = std.Io.File.stderr().writer(io, &bufe);
    var core = Core.new(
        std.testing.allocator,
        io,
        &env_map,
        &stdout_writer.interface,
        &stderr_writer.interface,
    );

    errdefer {
        std.Io.Dir.cwd().deleteTree(io, "test/root2") catch unreachable;
        std.Io.Dir.cwd().deleteTree(io, "test/dest2") catch unreachable;
    }

    // dual (default)
    {
        var dotfile_d = new("test/root/testfile1", "test/dest2/testfile-unit");

        _ = try dotfile_d.processFile(
            std.testing.allocator,
            &counter,
            &core,
        );

        const file_dual = try std.Io.Dir.cwd().openFile(io, "test/dest2/testfile-unit", .{});
        const file_dual_content = try file_dual.readToEndAlloc(
            std.testing.allocator,
            1024,
        );

        file_dual.close();

        errdefer std.Io.Dir.cwd().deleteTree(io, "test/dest2") catch unreachable;
        defer std.testing.allocator.free(file_dual_content);

        const expected_dual_content =
            \\# TEST
            \\Foo
            \\
            \\val="Bar"
            \\
            \\
        ;

        try std.testing.expectEqualStrings(expected_dual_content, file_dual_content);
        try std.Io.Dir.cwd().deleteTree(io, "test/dest2");
    }

    // forward
    {
        var dotfile_f = new("test/root/testfile1", "test/dest2/testfile-unit");
        core.direction = Cli.Direction.forward;

        _ = try dotfile_f.processFile(
            std.testing.allocator,
            &counter,
            &core,
        );

        const file_fwd = try std.Io.Dir.cwd().openFile(io, "test/dest2/testfile-unit", .{});
        const file_fwd_content = try file_fwd.readToEndAlloc(
            std.testing.allocator,
            1024,
        );

        file_fwd.close(io);

        defer std.testing.allocator.free(file_fwd_content);

        const expected_fwd_content =
            \\# TEST
            \\Foo
            \\
            \\val="Bar"
            \\
            \\
        ;

        try std.testing.expectEqualStrings(expected_fwd_content, file_fwd_content);
    }

    // back
    {
        try std.Io.Dir.cwd().makeDir(io, "test/root2");
        var dotfile_b = new("test/root2/testfile1", "test/dest2/testfile-unit");
        core.direction = Cli.Direction.back;

        const template = try std.Io.Dir.cwd().createFile(
            io,
            "test/root2/testfile1",
            .{ .read = true, .truncate = false },
        );

        try template.writeAll(
            \\# TEST
            \\
        );

        template.close(io);

        const render = try std.Io.Dir.cwd().createFile(
            io,
            "test/dest2/testfile-unit",
            .{ .read = true, .truncate = true },
        );

        try render.writeAll(
            \\# TEST
            \\Foo
            \\val="Zoot"
            \\
        );

        render.close(io);

        _ = try dotfile_b.processFile(
            std.testing.allocator,
            &counter,
            &core,
        );

        const file_bwd = try std.Io.Dir.cwd().openFile(io, "test/root2/testfile1", .{});
        const file_bwd_content = try file_bwd.readToEndAlloc(
            std.testing.allocator,
            1024,
        );

        file_bwd.close(io);

        defer std.testing.allocator.free(file_bwd_content);

        const expected_bwd_content =
            \\# TEST
            \\Foo
            \\val="Zoot"
            \\
        ;

        try std.testing.expectEqualStrings(expected_bwd_content, file_bwd_content);
    }

    try std.Io.Dir.cwd().deleteTree(io, "test/root2");
    try std.Io.Dir.cwd().deleteTree(io, "test/dest2");
}

const Dotfile = @This();
const std = @import("std");
const lib = @import("lib");
const Core = @import("core.zig");
const Cli = @import("cli.zig");
const Config = @import("config.zig");
const Util = @import("util.zig");
const assets = @import("assets.zig");

const ERR = Util.Level.ERROR;
