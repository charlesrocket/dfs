pub var LOG_FILE: []const u8 = "dfs.log";
const LOG_SIZE_MAX = 10 * 1024 * 1024; // 10 MB
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
    core: *Core,
) !void {
    if (!isGitPresent(allocator, core.stderr)) return error.GitFailure;

    const destination = try Config.pathFormat(allocator, dest);
    defer allocator.free(destination);

    try createDirRecursively(allocator, destination);

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
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    const sep = std.fs.path.sep;
    const absolute = std.fs.path.isAbsolute(path);

    if (absolute) {
        try buffer.append(allocator, sep);
    }

    while (parts.next()) |component| {
        const part = component.name;
        if (part.len == 0) continue;

        if (buffer.items.len > 1 or
            (buffer.items.len == 1 and
                buffer.items[0] != sep))
        {
            try buffer.append(allocator, sep);
        }

        try buffer.appendSlice(allocator, part);
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
        for (Core.MAC_SPECIFIC) |el| {
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

pub fn isGitPresent(
    allocator: std.mem.Allocator,
    stderr: *std.Io.Writer,
) bool {
    var proc = std.process.Child.init(
        &[_][]const u8{ "git", "--version" },
        allocator,
    );

    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;

    const result = proc.spawnAndWait() catch |err| switch (err) {
        error.FileNotFound => {
            stderr.print(
                "{s}{s}Git is not installed or not in $PATH{s}\n",
                .{ Cli.red, Cli.bold, Cli.reset },
            ) catch {};

            stderr.flush() catch {};
            return false;
        },
        else => return false,
    };

    if (result.Exited != 0) {
        stderr.print(
            "{s}{s}Git binary detected but returned nonzero exit code: {d}{s}\n",
            .{ Cli.red, Cli.bold, result.Exited, Cli.reset },
        ) catch {};

        stderr.flush() catch {};
        return false;
    } else {
        return true;
    }
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

    const stat = file.stat() catch return;

    // cycle log file
    if (stat.size > LOG_SIZE_MAX) {
        file.close();

        var old_buf: [std.fs.max_path_bytes]u8 = undefined;
        const old_log = std.fmt.bufPrint(
            &old_buf,
            "{s}.old",
            .{LOG_FILE},
        ) catch return;

        std.fs.cwd().deleteFile(old_log) catch {};
        std.fs.cwd().rename(LOG_FILE, old_log) catch return;

        const new_file = std.fs.cwd().createFile(
            LOG_FILE,
            .{ .mode = 0o600 },
        ) catch return;

        new_file.writeAll(msg) catch return;
        new_file.close();
        return;
    }

    file.seekFromEnd(0) catch return;
    file.writeAll(msg) catch return;
    file.close();
}

test "isGitPresent" {
    const allocator = std.testing.allocator;
    var buf: [2048]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buf);

    const writer = &stderr_writer.interface;
    const git_binary = isGitPresent(allocator, writer);
    const git_check = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "git", "--version" },
    }) catch {
        try std.testing.expect(!git_binary);
        return;
    };

    defer {
        allocator.free(git_check.stdout);
        allocator.free(git_check.stderr);
    }

    const git_exists = git_check.term.Exited == 0;
    try std.testing.expectEqual(git_exists, git_binary);
}

test log {
    const allocator = std.testing.allocator;

    {
        const message = "Log test";
        log(Level.INFO, message, .{});

        const log_file = try std.fs.cwd().openFile("dfs.log", .{});
        defer log_file.close();

        const log_size: usize = @intCast((try log_file.stat()).size);
        const log_content = try log_file.readToEndAlloc(
            allocator,
            log_size,
        );

        const expected = "] [INFO] Log test\n";

        defer {
            allocator.free(log_content);
            std.fs.cwd().deleteFile("dfs.log") catch unreachable;
        }

        try std.testing.expectStringEndsWith(log_content, expected);
    }

    {
        const message = "All WORK AND NO PLAY MAKES JACK A DULL BOY.";

        var file = try std.fs.cwd().createFile(LOG_FILE, .{ .truncate = true });
        var written: usize = 0;
        const buffer = try allocator.alloc(u8, message.len);
        defer allocator.free(buffer);

        @memcpy(buffer, message);

        while (written < LOG_SIZE_MAX) {
            try file.writeAll(buffer);
            written += buffer.len;
        }

        file.close();
        log(Level.WARNING, message, .{});
        std.fs.cwd().deleteFile("dfs.log.old") catch unreachable;
        std.fs.cwd().deleteFile("dfs.log") catch unreachable;
    }
}

pub fn createTestFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

pub fn modifyTestFile(path: []const u8, content: []const u8) !void {
    // ensure mtime changes
    std.Thread.sleep(std.time.ns_per_ms * 10);
    try createTestFile(path, content);
}

const std = @import("std");
const builtin = @import("builtin");
const Core = @import("core.zig");
const Cli = @import("cli.zig");
const Config = @import("config.zig");
const Dotfile = @import("dotfile.zig");
