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
        stdout: *std.Io.Writer,
    ) !void {
        var sj: std.json.Stringify = .{ .writer = stdout, .options = .{} };
        try sj.write(self);
    }
};

pub fn bootstrap(allocator: std.mem.Allocator, url: []const u8) !void {
    const config_home = try Config.getXdgDir(allocator, Config.XdgDir.Config);
    defer allocator.free(config_home);

    const config_path = try std.fmt.allocPrint(
        allocator,
        "{s}/dfs.zon",
        .{config_home},
    );

    defer allocator.free(config_path);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    try createDirRecursively(allocator, config_home);

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
}

pub fn createDirRecursively(
    allocator: std.mem.Allocator,
    path: []const u8,
) !void {
    var parts = try std.fs.path.componentIterator(path);
    var buffer = std.array_list.Managed(u8).init(allocator);
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

pub fn ensureLeadingSlash(
    allocator: std.mem.Allocator,
    path: []const u8,
) ![]const u8 {
    if (std.mem.startsWith(u8, path, "/")) {
        return path;
    }

    return try std.fmt.allocPrint(allocator, "/{s}", .{path});
}

pub fn isIgnored(value: []const u8, ignore_list: [][]const u8) bool {
    for (ignore_list) |el| {
        if (std.mem.eql(u8, el, value)) {
            return true;
        }
    }

    if (builtin.target.os.tag != .macos) {
        for (main.MAC_SPECIFIC) |el| {
            if (std.mem.eql(u8, el, value)) {
                return true;
            }
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
const builtin = @import("builtin");

const main = @import("main.zig");
const Config = @import("config.zig");
const Dotfile = @import("dotfile.zig");
