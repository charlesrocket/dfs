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
    link: usize,
    errors: usize,
    dry_run: bool,

    pub fn new(dry: bool) Counter {
        return .{
            .total = 0,
            .updated = 0,
            .template = 0,
            .render = 0,
            .binary = 0,
            .link = 0,
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
    if (!isGitPresent(core.io, core.stderr)) return error.GitFailure;

    const destination = try Config.pathFormat(allocator, dest, core.environ_map);
    defer allocator.free(destination);

    try createDirRecursively(allocator, core.io, destination);

    const command = [_][]const u8{
        "git",
        "clone",
        "--recurse-submodules",
        url,
        destination,
    };

    var proc = try std.process.spawn(core.io, .{
        .argv = &command,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });

    _ = try proc.wait(core.io);
}

pub fn createDirRecursively(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !void {
    var parts = std.fs.path.componentIterator(path);
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
            std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        } else {
            std.Io.Dir.cwd().createDir(io, dir_path, .default_dir) catch |err| switch (err) {
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
    io: std.Io,
    stderr: *std.Io.Writer,
) bool {
    const argv = &[_][]const u8{ "git", "--version" };

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |err| switch (err) {
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

    const result = child.wait(io) catch return false;

    switch (result) {
        .exited => |code| {
            if (code != 0) {
                stderr.print(
                    "{s}{s}Git binary detected but returned nonzero exit code: {d}{s}\n",
                    .{ Cli.red, Cli.bold, code, Cli.reset },
                ) catch {};

                stderr.flush() catch {};
                return false;
            }
            return true;
        },
        else => return false,
    }
}

pub fn setLogger(
    allocator: std.mem.Allocator,
    io: std.Io,
    environ: *std.process.Environ.Map,
) !void {
    const state_dir = try Config.getXdgDir(
        allocator,
        Config.XdgDir.State,
        environ,
    );

    defer allocator.free(state_dir);

    try createDirRecursively(allocator, io, state_dir);

    LOG_FILE = try std.fmt.bufPrint(
        &LOG_FILE_BUF,
        "{s}/dfs.log",
        .{state_dir},
    );
}

pub fn log(
    io: std.Io,
    comptime level: Level,
    comptime message: []const u8,
    args: anytype,
) void {
    var buf: [std.fs.max_path_bytes * 10]u8 = undefined;

    const prefix = "[" ++ comptime @tagName(level) ++ "] ";
    const now = std.Io.Clock.now(.real, io);
    const timestamp_ns = now.toNanoseconds();
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

    const file = std.Io.Dir.cwd().openFile(io, LOG_FILE, .{
        .mode = .write_only,
    }) catch |err| f: {
        if (err == error.FileNotFound) {
            break :f std.Io.Dir.cwd().createFile(
                io,
                LOG_FILE,
                .{},
            ) catch return;
        }

        return;
    };

    const stat = file.stat(io) catch return;

    var msg_buf: [4096]u8 = undefined;

    // cycle log file
    if (stat.size > LOG_SIZE_MAX) {
        file.close(io);

        var old_buf: [std.fs.max_path_bytes]u8 = undefined;
        const old_log = std.fmt.bufPrint(
            &old_buf,
            "{s}.old",
            .{LOG_FILE},
        ) catch return;

        const dir = std.Io.Dir.cwd();
        dir.deleteFile(io, old_log) catch {};

        std.Io.Dir.rename(dir, LOG_FILE, dir, old_log, io) catch return;

        const new_file = std.Io.Dir.cwd().createFile(
            io,
            LOG_FILE,
            .{},
        ) catch return;

        var file_writer = new_file.writer(io, &msg_buf);
        const writer = &file_writer.interface;

        file_writer.seekTo(stat.size) catch return;
        writer.writeAll(msg) catch return;
        writer.flush() catch return;
        new_file.close(io);
        return;
    }

    var file_writer = file.writer(io, &msg_buf);
    const writer = &file_writer.interface;

    file_writer.seekTo(0) catch return;
    writer.writeAll(msg) catch return;
    writer.flush() catch return;

    file.close(io);
}

test "isGitPresent" {
    const io = std.testing.io;

    var buf: [2048]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &buf);

    const writer = &stderr_writer.interface;
    const git_binary = isGitPresent(io, writer);

    var git_check = try std.process.spawn(io, .{
        .argv = &[_][]const u8{ "git", "--version" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });

    const git_result = try git_check.wait(io);
    const git_exists = git_result.exited == 0;
    try std.testing.expectEqual(git_exists, git_binary);
}

test log {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    {
        const message = "Log test";

        log(io, Level.INFO, message, .{});
        defer std.Io.Dir.cwd().deleteFile(io, LOG_FILE) catch {};

        const log_file = try std.Io.Dir.cwd().openFile(io, LOG_FILE, .{});
        defer log_file.close(io);

        var log_reader = log_file.reader(io, &.{});
        const log_content = try log_reader.interface.allocRemaining(
            allocator,
            .unlimited,
        );

        defer allocator.free(log_content);

        const expected = "] [INFO] Log test\n";

        try std.testing.expectStringEndsWith(log_content, expected);
    }

    {
        const message = "All WORK AND NO PLAY MAKES JACK A DULL BOY.";

        var file = try std.Io.Dir.cwd().createFile(io, LOG_FILE, .{ .truncate = true });
        var written: usize = 0;

        const buffer = try allocator.alloc(u8, message.len);
        defer allocator.free(buffer);

        @memcpy(buffer, message);

        while (written < LOG_SIZE_MAX) {
            const buf = try allocator.alloc(u8, buffer.len);
            defer allocator.free(buf);

            var output_file_writer = file.writer(io, buf);
            try output_file_writer.interface.writeAll(buffer);
            try output_file_writer.interface.flush();
            written += buffer.len;
        }

        file.close(io);

        log(io, Level.WARNING, message, .{});

        defer std.Io.Dir.cwd().deleteFile(io, "dfs.log") catch {};
        defer std.Io.Dir.cwd().deleteFile(io, "dfs.log.old") catch {};
    }
}

pub fn createTestFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    content: []const u8,
) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    const buf = try allocator.alloc(u8, content.len);
    defer allocator.free(buf);

    var output_writer = file.writer(io, buf);
    try output_writer.interface.writeAll(content);
    try output_writer.interface.flush();
}

pub fn modifyTestFile(
    path: []const u8,
    content: []const u8,
    io: std.Io,
) !void {
    // ensure mtime changes
    io.sleep(.fromMilliseconds(10), .boot) catch {};
    try createTestFile(std.testing.allocator, io, path, content);
}

const std = @import("std");
const builtin = @import("builtin");
const Core = @import("core.zig");
const Cli = @import("cli.zig");
const Config = @import("config.zig");
const Dotfile = @import("dotfile.zig");
