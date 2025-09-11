pub const Counter = struct {
    total: usize,
    updated: usize,
    template: usize,
    render: usize,
    binary: usize,
    errors: usize,
    dry_run: bool,

    pub fn new(dry: bool) Counter {
        return .{
            .total = 0,
            .updated = 0,
            .template = 0,
            .render = 0,
            .binary = 0,
            .errors = 0,
            .dry_run = dry,
        };
    }

    pub fn json(
        self: *Counter,
        stdout: @TypeOf(std.io.getStdOut().writer()),
    ) !void {
        const options = std.json.StringifyOptions{};

        try std.json.stringify(self, options, stdout);
    }
};

pub fn createDirRecursively(
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    var parts = try std.fs.path.componentIterator(path);
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const sep = std.fs.path.sep;

    const absolute = std.fs.path.isAbsolute(path);

    if (absolute) {
        try buffer.append(sep);
    }

    while (parts.next()) |component| {
        const part = component.name;
        if (part.len == 0) continue;

        if (buffer.items.len > 1 or
            (buffer.items.len == 1 and
                buffer.items[0] != sep))
        {
            try buffer.append(sep);
        }

        try buffer.appendSlice(part);
        const dir_path = buffer.items;

        if (absolute) {
            std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        } else {
            std.fs.cwd().makeDir(dir_path) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }
}

pub fn walk(
    arr: *std.ArrayListUnmanaged(Dotfile),
    allocator: std.mem.Allocator,
    config: Config.Configuration,
) !void {
    const base_abs = try std.fs.realpathAlloc(allocator, config.source);
    defer allocator.free(base_abs);

    // with base path reference
    try walkDir(
        arr,
        allocator,
        base_abs,
        base_abs,
        config.destination,
    );
}

fn walkDir(
    arr: *std.ArrayListUnmanaged(Dotfile),
    allocator: std.mem.Allocator,
    base_path: []const u8,
    current_path: []const u8,
    dest: []const u8,
) !void {
    var dir = try std.fs.openDirAbsolute(current_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |node| {
        if (isIgnored(node.name)) continue;

        const node_path = try std.fs.path.join(
            allocator,
            &.{ current_path, node.name },
        );

        const rel_path = if (std.mem.eql(u8, base_path, current_path))
            try allocator.dupe(u8, node.name)
        else blk: {
            const prefix_len = base_path.len + 1;
            if (node_path.len > prefix_len) {
                break :blk try allocator.dupe(u8, node_path[prefix_len..]);
            } else {
                break :blk try allocator.dupe(u8, node.name);
            }
        };

        const dest_path = try std.fs.path.join(
            allocator,
            &.{ dest, rel_path },
        );

        defer {
            allocator.free(node_path);
            allocator.free(rel_path);
            allocator.free(dest_path);
        }

        switch (node.kind) {
            .file => {
                const src_copy = try allocator.dupe(u8, node_path);
                const dest_copy = try allocator.dupe(u8, dest_path);
                const file = Dotfile.new(src_copy, dest_copy);
                try arr.append(allocator, file);
            },
            .directory => {
                try walkDir(arr, allocator, base_path, node_path, dest);
            },
            else => continue,
        }
    }
}

pub fn isIgnored(value: []const u8) bool {
    for (main.ignore_list) |el| {
        if (std.mem.eql(u8, el, value)) {
            return true;
        }
    }

    return false;
}

pub fn isText(data: []const u8) bool {
    if (std.unicode.utf8ValidateSlice(data)) {
        return true;
    }

    // ASCII heuristic
    var non_text_count: usize = 0;
    for (data) |c| {
        // common text whitespace
        if (c == '\n' or c == '\r' or c == '\t') continue;
        // printable range
        if (c >= 0x20 and c <= 0x7E) continue;

        non_text_count += 1;
    }

    // treat as binary if the threshold is reached
    return (non_text_count * 100 / data.len) < 10;
}

const std = @import("std");

const main = @import("main.zig");
const Config = @import("config.zig");
const Dotfile = @import("dotfile.zig");
