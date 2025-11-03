const KQUEUE: bool = builtin.os.tag.isBSD() or builtin.os.tag == .macos;

const File = struct {
    path: []const u8,
    mtime: i128,
    fd: ?std.posix.fd_t = null,
};

allocator: std.mem.Allocator,
mutex: std.Thread.Mutex,
files: std.array_list.Managed(File),
mode: Config.WatcherMode,
poll_interval_ms: u64,
debounce_delay_ms: u64,
last_change_time: i64 = 0,
kqueue_fd: ?std.posix.fd_t = null,

pub fn init(allocator: std.mem.Allocator, mode: Config.WatcherMode) !Watcher {
    const kq_fd = if (KQUEUE) try std.posix.kqueue() else null;
    return .{
        .allocator = allocator,
        .mutex = std.Thread.Mutex{},
        .files = std.array_list.Managed(File).init(allocator),
        .mode = mode,
        .poll_interval_ms = 5000,
        .debounce_delay_ms = 7000,
        .last_change_time = 0,
        .kqueue_fd = kq_fd,
    };
}

pub fn deinit(self: *Watcher) void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (self.files.items) |item| {
        if (item.fd) |fd| {
            std.posix.close(fd);
        }
        self.allocator.free(item.path);
    }

    if (self.kqueue_fd) |kq| {
        std.posix.close(kq);
    }

    self.files.deinit();
}

pub fn addPaths(self: *Watcher, files: []const Dotfile) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    for (files) |file| {
        try self.addPath(file.src);
        try self.addPath(file.dest);
    }
}

fn addPath(self: *Watcher, path: []const u8) !void {
    // check for duplicates
    for (self.files.items) |item| {
        if (std.mem.eql(u8, item.path, path)) return;
    }

    const path_copy = try self.allocator.dupe(u8, path);
    errdefer self.allocator.free(path_copy);

    const use_kqueue = switch (self.mode) {
        .kqueue => true,
        .polling => false,
        .auto => KQUEUE and self.kqueue_fd != null,
    };

    if (use_kqueue) {
        // try to open the file
        const fd = std.posix.open(path, .{ .ACCMODE = .RDONLY }, 0) catch |err| switch (err) {
            error.FileNotFound => {
                // file does not exist yet, add with no values
                try self.files.append(.{ .path = path_copy, .mtime = 0, .fd = null });
                return;
            },
            else => return err,
        };
        errdefer std.posix.close(fd);

        // add to kqueue
        var kev: std.posix.Kevent = undefined;
        kev.ident = @intCast(fd);
        kev.filter = std.posix.system.EVFILT.VNODE;
        kev.flags = std.posix.system.EV.ADD | std.posix.system.EV.CLEAR;
        kev.fflags = std.posix.system.NOTE.WRITE | std.posix.system.NOTE.DELETE | std.posix.system.NOTE.RENAME;
        kev.data = 0;
        kev.udata = 0;

        const changes = [_]std.posix.Kevent{kev};
        _ = try std.posix.kevent(self.kqueue_fd.?, &changes, &[_]std.posix.Kevent{}, null);

        const stat = try std.posix.fstat(fd);
        const mtime_ns = @as(i128, stat.mtime().sec) * std.time.ns_per_s + stat.mtime().nsec;
        try self.files.append(.{ .path = path_copy, .mtime = mtime_ns, .fd = fd });
    } else {
        // fallback to polling mode
        const stat = std.fs.cwd().statFile(path) catch |err| switch (err) {
            error.FileNotFound => {
                try self.files.append(.{ .path = path_copy, .mtime = 0, .fd = null });
                return;
            },
            else => return err,
        };

        try self.files.append(.{ .path = path_copy, .mtime = stat.mtime, .fd = null });
    }
}

pub fn watch(
    self: *Watcher,
    core: *Core,
    active: *bool,
    queue: *anyopaque,
) !void {
    if (core.logs) Util.log(
        .INFO,
        "Watcher in {s} mode",
        .{@tagName(self.mode)},
    );

    switch (self.mode) {
        .kqueue => try self.startKqueue(core, active, queue),
        .polling => try self.startPoll(core, active, queue),
        .auto => {
            if (KQUEUE and self.kqueue_fd != null) {
                try self.startKqueue(core, active, queue);
            } else {
                try self.startPoll(core, active, queue);
            }
        },
    }
}

fn startKqueue(
    self: *Watcher,
    core: *Core,
    active: *bool,
    queue: *anyopaque,
) !void {
    try core.stdout.print("Watcher is active (KQUEUE)\n", .{});
    try core.stdout.flush();
    try self.watchKqueue(core, active, queue);
}

fn watchKqueue(
    self: *Watcher,
    core: *Core,
    active: *bool,
    queue: *anyopaque,
) !void {
    var events: [32]std.posix.Kevent = undefined;
    const timeout = std.posix.timespec{ .sec = 1, .nsec = 0 };

    while (active.*) {
        // check for new files that were not available during addPath()
        try self.recheckMissingFiles();

        const n = std.posix.kevent(
            self.kqueue_fd.?,
            &[_]std.posix.Kevent{},
            &events,
            &timeout,
        ) catch |err| {
            if (core.logs) {
                Util.log(.ERROR, "Kqueue error: {}", .{err});
            }

            try core.stderr.print("Kqueue failed: {}\n", .{err});
            continue;
        };

        if (n > 0) {
            const now = std.time.milliTimestamp();
            const debounce_delay_ms_i64 = @as(i64, @intCast(self.debounce_delay_ms));

            if (now - self.last_change_time >= debounce_delay_ms_i64) {
                self.last_change_time = now;

                const sync_queue = @as(*SyncQueue, @ptrCast(@alignCast(queue)));
                sync_queue.mutex.lock();
                defer sync_queue.mutex.unlock();

                sync_queue.should_sync = true;

                if (core.logs) {
                    Util.log(.INFO, "File changes detected", .{});
                }
            }
        }
    }
}

fn recheckMissingFiles(self: *Watcher) !void {
    self.mutex.lock();
    defer self.mutex.unlock();

    if (!KQUEUE or self.kqueue_fd == null) return;

    for (self.files.items) |*item| {
        if (item.fd != null) continue;

        // try to open file that was previously missing
        const fd = std.posix.open(item.path, .{ .ACCMODE = .RDONLY }, 0) catch continue;
        errdefer std.posix.close(fd);

        // add to kqueue
        var kev: std.posix.Kevent = undefined;
        kev.ident = @intCast(fd);
        kev.filter = std.posix.system.EVFILT.VNODE;
        kev.flags = std.posix.system.EV.ADD | std.posix.system.EV.CLEAR;
        kev.fflags = std.posix.system.NOTE.WRITE | std.posix.system.NOTE.DELETE | std.posix.system.NOTE.RENAME;
        kev.data = 0;
        kev.udata = 0;

        const changes = [_]std.posix.Kevent{kev};
        _ = std.posix.kevent(self.kqueue_fd.?, &changes, &[_]std.posix.Kevent{}, null) catch {
            std.posix.close(fd);
            continue;
        };

        item.fd = fd;
    }
}

fn startPoll(
    self: *Watcher,
    core: *Core,
    active: *bool,
    queue: *anyopaque,
) !void {
    try core.stdout.print("Watcher is active (POLLING)\n", .{});
    try core.stdout.flush();
    try self.watchPoll(core, active, queue);
}

fn watchPoll(
    self: *Watcher,
    core: *Core,
    active: *bool,
    queue: *anyopaque,
) !void {
    const sleep_chunk_ms = 3000;
    var elapsed_ms: u64 = 0;

    while (active.*) {
        if (elapsed_ms >= self.poll_interval_ms) {
            elapsed_ms = 0;

            const has_changes = try self.checkForChanges();

            if (has_changes) {
                const now = std.time.milliTimestamp();
                const debounce_delay_ms_i64 = @as(i64, @intCast(self.debounce_delay_ms));

                if (now - self.last_change_time >= debounce_delay_ms_i64) {
                    self.last_change_time = now;

                    const sync_queue = @as(*SyncQueue, @ptrCast(@alignCast(queue)));
                    sync_queue.mutex.lock();
                    defer sync_queue.mutex.unlock();

                    sync_queue.should_sync = true;

                    if (core.logs) {
                        Util.log(.INFO, "File changes detected", .{});
                    }
                }
            }
        }

        std.Thread.sleep(sleep_chunk_ms * std.time.ns_per_ms);
        elapsed_ms += sleep_chunk_ms;
    }
}

fn checkForChanges(self: *Watcher) !bool {
    self.mutex.lock();
    defer self.mutex.unlock();

    var has_changes = false;

    for (self.files.items) |*item| {
        const stat = std.fs.cwd().statFile(item.path) catch |err| switch (err) {
            error.FileNotFound => {
                if (item.mtime != 0) {
                    has_changes = true;
                    item.mtime = 0;
                }
                continue;
            },
            else => return err,
        };

        if (stat.mtime != item.mtime) {
            has_changes = true;
            item.mtime = stat.mtime;
        }
    }

    return has_changes;
}

const Watcher = @This();
const std = @import("std");
const SyncQueue = @import("daemon.zig").SyncQueue;
const Config = @import("../config.zig");
const Dotfile = @import("../dotfile.zig");
const Core = @import("../core.zig");
const Util = @import("../util.zig");
const builtin = @import("builtin");
