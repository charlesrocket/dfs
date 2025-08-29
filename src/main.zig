const Dotfile = struct {
    dest: []const u8,
    src: []const u8,
    synced: ?u64,

    fn new(src: []const u8, dest: []const u8) Dotfile {
        return .{
            .dest = dest,
            .src = src,
            .synced = null,
        };
    }
};

const Meta = struct {
    src: []const u8,
    dest: []const u8,
    synced: i64,
};

// TODO use regex
const ignore_list = [_][]const u8{
    "LICENSE",
    "codecov.yml",
    "codecov.yaml",
    ".gitignore",
    ".gitmodules",
    ".github",
    ".git",
};

fn isIgnored(value: []const u8) bool {
    for (ignore_list) |el| {
        if (std.mem.eql(u8, el, value)) {
            return true;
        }
    }

    return false;
}

fn createDirRecursively(allocator: std.mem.Allocator, path: []const u8) !void {
    var parts = try std.fs.path.componentIterator(path);
    var buffer = std.ArrayList(u8).init(allocator);
    //defer buffer.deinit();

    const sep = std.fs.path.sep;

    if (std.fs.path.isAbsolute(path)) {
        try buffer.append(sep);
    }

    while (parts.next()) |component| {
        const part = component.name;
        if (part.len == 0) continue;

        if (buffer.items.len > 1 or (buffer.items.len == 1 and buffer.items[0] != sep)) {
            try buffer.append(sep);
        }

        try buffer.appendSlice(part);
        const dir_path = buffer.items;

        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

fn recordLastSync(file: Dotfile) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const sync_path = try std.fmt.bufPrint(&buf, "{s}.sync.zon", .{file.dest});
    const f = try std.fs.createFileAbsolute(sync_path, .{ .read = false, .truncate = true });
    defer f.close();

    const record = Meta{
        .src = file.src,
        .dest = file.dest,
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

fn lastMod(file: []const u8) ?u64 {
    const path = std.fs.path.dirname(file);
    const dir = std.fs.cwd().openDir(path.?, .{}) catch return null;
    const stat = dir.statFile(file) catch return null;

    // compress the integer
    const result = @divFloor(
        @as(u64, @intCast(stat.mtime)),
        1000000000,
    );

    return result;
}

fn processFile(allocator: std.mem.Allocator, file: Dotfile) !void {
    const template_file = try std.fs.cwd().openFile(file.src, .{});
    defer template_file.close();

    const template_content = try template_file.readToEndAlloc(allocator, 1024);
    const replacements = [_]lib.Replacement{
        .{ .key = "name", .value = "test NAME" },
        .{ .key = "option", .value = "test VALUE" },
    };

    var last_sync: usize = 0;
    var meta_present = true;
    const meta_file_path = try std.fmt.allocPrint(
        allocator,
        "{s}.sync.zon",
        .{file.dest},
    );

    defer allocator.free(meta_file_path);

    const dir_path = std.fs.path.dirname(file.dest) orelse return error.InvalidPath;

    try createDirRecursively(allocator, dir_path);

    const meta_file = std.fs.cwd().openFile(meta_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            meta_present = false;
            _ = try std.fs.createFileAbsolute(
                meta_file_path,
                .{ .read = false, .truncate = true },
            );

            break :blk std.fs.cwd().openFile(meta_file_path, .{}) catch unreachable;
        },

        else => return err,
    };

    defer meta_file.close();

    if (meta_present) {
        const meta_content_t = try meta_file.readToEndAlloc(allocator, 1024);
        var meta_content = std.ArrayList(u8).init(allocator);
        defer meta_content.deinit();

        for (meta_content_t) |c| {
            try meta_content.append(c);
        }

        // null-terminated
        try meta_content.append(0);

        const input = meta_content.items[0 .. meta_content.items.len - 1 :0];
        const meta = try std.zon.parse.fromSlice(
            Meta,
            allocator,
            input,
            null,
            .{},
        );

        last_sync = @intCast(meta.synced);
    }

    const last_modified = lastMod(file.dest) orelse 0;

    if (last_sync < last_modified) {
        const rendered_file = try std.fs.cwd().openFile(file.dest, .{});
        defer rendered_file.close();

        const rendered_content = try rendered_file.readToEndAlloc(allocator, 1024);
        defer allocator.free(rendered_content);

        const new_template = try lib.reverseTemplate(allocator, rendered_content, &replacements);

        const updated_template = try std.fs.createFileAbsolute(file.src, .{
            .read = false,
            .truncate = true,
        });

        defer updated_template.close();
        try updated_template.writeAll(new_template);

        std.debug.print("updated: {s}\n", .{file.src});
    }

    const result = try lib.applyTemplate(allocator, template_content, &replacements);
    const output_file = try std.fs.createFileAbsolute(file.dest, .{
        .read = false,
        .truncate = true,
    });

    try output_file.writeAll(result);
    defer output_file.close();

    try recordLastSync(file);
}

fn walk(
    arr: *std.ArrayListUnmanaged(Dotfile),
    allocator: std.mem.Allocator,
    path: []const u8,
    dest: []const u8,
) !void {
    // with base path reference
    try walkDir(arr, allocator, path, path, dest);
}

fn walkDir(
    arr: *std.ArrayListUnmanaged(Dotfile),
    allocator: std.mem.Allocator,
    base_path: []const u8,
    current_path: []const u8,
    dest: []const u8,
) !void {
    var dir = try std.fs.cwd().openDir(current_path, .{});
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |node| {
        if (isIgnored(node.name)) continue;

        const node_path = try std.fs.path.join(allocator, &.{ current_path, node.name });
        //defer allocator.free(node_path);

        const rel_path = try std.fs.path.relative(allocator, base_path, node_path);
        //defer allocator.free(rel_path);

        const dest_path = try std.fs.path.join(allocator, &.{ dest, rel_path });
        //defer allocator.free(dest_path);

        switch (node.kind) {
            .file => {
                // grab file strings
                const src_copy = try allocator.dupe(u8, node_path);
                const dest_copy = try allocator.dupe(u8, dest_path);
                const file = Dotfile.new(src_copy, dest_copy);
                try arr.append(allocator, file);
            },
            .directory => {
                try walkDir(arr, allocator, base_path, node_path, dest);
            },
            else => {
                continue;
            },
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer _ = arena.deinit();

    const dotfiles = "/home/charlie/src/dotfiles/";
    const allocator = arena.allocator();
    const destination = "/home/charlie/test/"; //try std.process.getEnvVarOwned(allocator, "HOME");
    //defer allocator.free(destination);

    var files = std.ArrayListUnmanaged(Dotfile).empty;
    //defer files.deinit(allocator);

    try walk(&files, allocator, dotfiles, destination);

    const owned_files = try files.toOwnedSlice(allocator);

    for (owned_files) |file| {
        //std.debug.print("{s}\n", .{file.src});
        //std.debug.print("{s}\n\n", .{file.dest});
        try processFile(allocator, file);
    }
}

const std = @import("std");
const lib = @import("libdfs");
const posix = std.posix;
