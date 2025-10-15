pub var LOG_FILE: []const u8 = "dfs.log";
var LOG_FILE_BUF: [std.fs.max_path_bytes]u8 = undefined;

pub const Level = enum {
    INFO,
    ERROR,
    WARNING,
};

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

pub fn cloneRepo(
    allocator: std.mem.Allocator,
    url: []const u8,
    dest: []const u8,
) !void {
    const destination = try Config.pathFormat(allocator, dest);
    defer allocator.free(destination);

    try createDirRecursively(allocator, dest);

    const command = [_][]const u8{
        "git",
        "clone",
        "--recurse-submodules",
        url,
        destination,
    };

    var proc = std.process.Child.init(&command, allocator);

    try proc.spawn();
    _ = try proc.wait();
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

// deallocate on changes
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

pub fn setLogger(allocator: std.mem.Allocator) !void {
    const state_dir = try Config.getXdgDir(allocator, Config.XdgDir.State);
    defer allocator.free(state_dir);

    try createDirRecursively(allocator, state_dir);

    LOG_FILE = try std.fmt.bufPrint(
        &LOG_FILE_BUF,
        "{s}/dfs.log",
        .{state_dir},
    );
}

pub fn log(
    comptime level: Level,
    comptime message: []const u8,
    args: anytype,
) void {
    var buf: [std.fs.max_path_bytes * 10]u8 = undefined;

    const prefix = "[" ++ comptime @tagName(level) ++ "] ";
    const timestamp_ns = std.time.nanoTimestamp();
    const timestamp = @divFloor(timestamp_ns, std.time.ns_per_s);
    const nanos: u32 = @intCast(@mod(timestamp_ns, std.time.ns_per_s));
    const epoch = std.time.epoch.EpochSeconds{
        .secs = @intCast(timestamp),
    };

    const day = epoch.getEpochDay();
    const day_seconds = epoch.getDaySeconds();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const msg = std.fmt.bufPrint(
        &buf,
        "[{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}] " ++
            prefix ++ message ++ "\n",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            nanos,
        } ++ args,
    ) catch return;

    const file = std.fs.cwd().openFile(LOG_FILE, .{
        .mode = .write_only,
    }) catch |err| f: {
        if (err == error.FileNotFound) {
            break :f std.fs.cwd().createFile(
                LOG_FILE,
                .{ .mode = 0o600 },
            ) catch return;
        }

        return;
    };

    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writeAll(msg) catch return;
}

const std = @import("std");
const builtin = @import("builtin");
const main = @import("main.zig");
const Config = @import("config.zig");
const Dotfile = @import("dotfile.zig");
