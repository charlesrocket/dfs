const KQUEUE: bool = builtin.os.tag.isBSD() or builtin.os.tag == .macos;
const EPOLL: bool = builtin.os.tag == .linux;

const File = struct {
    path: []const u8,
    mtime: i128,
    fd: ?std.posix.fd_t = null,
    wd: ?i32 = null, // inotify watch descriptor for epoll
};

allocator: std.mem.Allocator,
mutex: std.Io.Mutex,
io: std.Io,
files: std.ArrayList(File),
mode: Config.WatcherMode,
poll_interval_ms: u64,
debounce_delay_ms: u64,
last_change_time: i64 = 0,
kqueue_fd: ?std.posix.fd_t = null,
epoll_fd: ?std.posix.fd_t = null,
inotify_fd: ?std.posix.fd_t = null,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    mode: Config.WatcherMode,
) !Watcher {
    const kq_fd = if (KQUEUE) std.posix.system.kqueue() else null;

    var epoll_fd: ?std.posix.fd_t = null;
    var inotify_fd: ?std.posix.fd_t = null;

    if (EPOLL) {
        inotify_fd = @intCast(std.os.linux.inotify_init1(std.os.linux.IN.CLOEXEC));
        errdefer if (inotify_fd) |fd| std.posix.close(fd);

        epoll_fd = @intCast(std.os.linux.epoll_create1(std.os.linux.EPOLL.CLOEXEC));
        errdefer if (epoll_fd) |fd| std.posix.close(fd);

        var event = std.os.linux.epoll_event{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .fd = inotify_fd.? },
        };

        _ = std.os.linux.epoll_ctl(
            epoll_fd.?,
            std.os.linux.EPOLL.CTL_ADD,
            inotify_fd.?,
            &event,
        );
    }

    return .{
        .allocator = allocator,
        .io = io,
        .mutex = std.Io.Mutex.init,
        .files = std.ArrayList(File).empty,
        .mode = mode,
        .poll_interval_ms = 5000,
        .debounce_delay_ms = 7000,
        .last_change_time = 0,
        .kqueue_fd = kq_fd,
        .epoll_fd = epoll_fd,
        .inotify_fd = inotify_fd,
    };
}

pub fn deinit(self: *Watcher) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    for (self.files.items) |item| {
        if (EPOLL and self.inotify_fd != null and item.wd != null) {
            _ = std.os.linux.inotify_rm_watch(self.inotify_fd.?, item.wd.?);
        }

        if (item.fd) |fd| {
            _ = std.posix.system.close(fd);
        }

        self.allocator.free(item.path);
    }

    if (self.kqueue_fd) |kq| {
        _ = std.posix.system.close(kq);
    }

    if (EPOLL) {
        if (self.inotify_fd) |fd| {
            _ = std.posix.system.close(fd);
        }

        if (self.epoll_fd) |fd| {
            _ = std.posix.system.close(fd);
        }
    }

    self.files.deinit(self.allocator);
}

pub fn addPaths(self: *Watcher, files: []const Dotfile) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

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
        .epoll => false,
        .polling => false,
        .auto => KQUEUE and self.kqueue_fd != null,
    };

    const use_epoll = switch (self.mode) {
        .kqueue => false,
        .epoll => true,
        .polling => false,
        .auto => EPOLL and self.inotify_fd != null,
    };

    if (use_kqueue and KQUEUE) {
        if (comptime KQUEUE) {
            const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    try self.files.append(
                        self.allocator,
                        .{ .path = path_copy, .mtime = 0, .fd = null },
                    );

                    return;
                },
                else => return err,
            };

            errdefer file.close(self.io);
            const fd = file.handle;

            // add to kqueue
            var kev: std.posix.Kevent = undefined;
            kev.ident = @intCast(fd);
            kev.filter = std.posix.system.EVFILT.VNODE;
            kev.flags = std.posix.system.EV.ADD | std.posix.system.EV.CLEAR;
            kev.fflags = std.posix.system.NOTE.WRITE |
                std.posix.system.NOTE.DELETE | std.posix.system.NOTE.RENAME;

            kev.data = 0;
            kev.udata = 0;

            const changes = [_]std.posix.Kevent{kev};
            _ = try std.Io.Kqueue.kevent(
                self.kqueue_fd.?,
                &changes,
                &[_]std.posix.Kevent{},
                null,
            );

            const stat = try file.stat(self.io);

            const mtime = @divFloor(
                @as(u64, @intCast(stat.mtime.toMilliseconds())),
                1000000000,
            );

            try self.files.append(self.allocator, .{
                .path = path_copy,
                .mtime = mtime,
                .fd = fd,
            });
        }
    } else if (use_epoll and EPOLL) {
        if (comptime EPOLL) {
            const path_z = try std.posix.toPosixPath(path);
            // add inotify watch
            const wd = std.os.linux.inotify_add_watch(
                self.inotify_fd.?,
                &path_z,
                std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE |
                    std.os.linux.IN.DELETE | std.os.linux.IN.MOVE,
            );

            if (wd < 0) {
                // file does not exist yet, add with no watch descriptor
                try self.files.append(
                    self.allocator,
                    .{
                        .path = path_copy,
                        .mtime = 0,
                        .fd = null,
                        .wd = null,
                    },
                );

                return;
            }

            const stat = std.Io.Dir.cwd().statFile(
                self.io,
                path,
                .{},
            ) catch |err| switch (err) {
                error.FileNotFound => {
                    try self.files.append(
                        self.allocator,
                        .{
                            .path = path_copy,
                            .mtime = 0,
                            .fd = null,
                            .wd = @intCast(wd),
                        },
                    );

                    return;
                },
                else => return err,
            };

            try self.files.append(
                self.allocator,
                .{
                    .path = path_copy,
                    .mtime = stat.mtime.toMilliseconds(),
                    .fd = null,
                    .wd = @intCast(wd),
                },
            );
        }
    } else {
        // fallback to polling mode
        // heavier on resources, but platform-agnostic
        const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try self.files.append(self.allocator, .{
                    .path = path_copy,
                    .mtime = 0,
                    .fd = null,
                });

                return;
            },
            else => return err,
        };

        try self.files.append(self.allocator, .{
            .path = path_copy,
            .mtime = stat.mtime.toMilliseconds(),
            .fd = null,
        });
    }
}

pub fn watch(
    self: *Watcher,
    core: *Core,
    active: *bool,
    queue: *anyopaque,
) !void {
    if (core.logs) Util.log(
        self.io,
        .INFO,
        "Watcher in {s} mode",
        .{@tagName(self.mode)},
    );

    switch (self.mode) {
        .kqueue => try self.startKqueue(core, active, queue),
        .epoll => try self.startEpoll(core, active, queue),
        .polling => try self.startPoll(core, active, queue),
        .auto => {
            if (KQUEUE and self.kqueue_fd != null) {
                try self.startKqueue(core, active, queue);
            } else if (EPOLL and self.epoll_fd != null) {
                try self.startEpoll(core, active, queue);
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
    if (comptime !KQUEUE) return;
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
    if (comptime !KQUEUE) return;
    var events: [32]std.posix.Kevent = undefined;

    while (active.*) {
        const n = std.Io.Kqueue.kevent(
            self.kqueue_fd.?,
            &[_]std.posix.Kevent{},
            &events,
            null,
        ) catch |err| {
            if (core.logs) {
                Util.log(self.io, .ERROR, "Kqueue error: {}", .{err});
            }

            try core.stderr.print("Kqueue failed: {}\n", .{err});
            continue;
        };

        if (n > 0) {
            const clock = std.Io.Clock.now(.real, self.io);
            const now = clock.toMilliseconds();
            const debounce_delay_ms_i64 = @as(i64, @intCast(self.debounce_delay_ms));

            if (now - self.last_change_time >= debounce_delay_ms_i64) {
                self.last_change_time = now;

                const sync_queue = @as(*SyncQueue, @ptrCast(@alignCast(queue)));
                sync_queue.mutex.lockUncancelable(self.io);
                defer sync_queue.mutex.unlock(self.io);

                if (!sync_queue.paused) {
                    sync_queue.should_sync = true;
                    sync_queue.cond.signal(self.io);
                }

                if (core.logs) {
                    Util.log(self.io, .INFO, "File changes detected", .{});
                }
            }
        }
    }
}

fn startEpoll(
    self: *Watcher,
    core: *Core,
    active: *bool,
    queue: *anyopaque,
) !void {
    if (comptime !EPOLL) return;
    try core.stdout.print("Watcher is active (EPOLL)\n", .{});
    try core.stdout.flush();
    try self.watchEpoll(core, active, queue);
}

fn watchEpoll(
    self: *Watcher,
    core: *Core,
    active: *bool,
    queue: *anyopaque,
) !void {
    if (comptime !EPOLL) return;
    var events: [32]std.os.linux.epoll_event = undefined;
    const timeout_ms: i32 = 1000;

    while (active.*) {
        // check for new files that were not available during addPath()
        try self.recheckMissingFiles();

        const n = std.os.linux.epoll_wait(
            self.epoll_fd.?,
            &events,
            events.len,
            timeout_ms,
        );

        if (n > 0) {
            // get events
            var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
            _ = std.posix.read(self.inotify_fd.?, &buf) catch continue;

            const clock = std.Io.Clock.now(.real, self.io);
            const now = clock.toMilliseconds();
            const debounce_delay_ms_i64 = @as(i64, @intCast(self.debounce_delay_ms));

            if (now - self.last_change_time >= debounce_delay_ms_i64) {
                self.last_change_time = now;

                const sync_queue = @as(*SyncQueue, @ptrCast(@alignCast(queue)));
                sync_queue.mutex.lockUncancelable(self.io);
                defer sync_queue.mutex.unlock(self.io);

                if (!sync_queue.paused) {
                    sync_queue.should_sync = true;
                    sync_queue.cond.signal(self.io);
                }

                if (core.logs) {
                    Util.log(self.io, .INFO, "File changes detected", .{});
                }
            }
        }
    }
}

pub fn recheckMissingFiles(self: *Watcher) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    if (comptime KQUEUE) {
        if (KQUEUE and self.kqueue_fd != null) {
            for (self.files.items) |*item| {
                if (item.fd != null) continue;

                // try to open file that was previously missing
                const file = std.Io.Dir.cwd().openFile(self.io, item.path, .{}) catch |err| return err;
                defer file.close(self.io);
                const fd = file.handle;

                // add to kqueue
                var kev: std.posix.system.Kevent = undefined;
                kev.ident = @intCast(fd);
                kev.filter = std.posix.system.EVFILT.VNODE;
                kev.flags = std.posix.system.EV.ADD | std.posix.system.EV.CLEAR;
                kev.fflags = std.posix.system.NOTE.WRITE | std.posix.system.NOTE.DELETE | std.posix.system.NOTE.RENAME;
                kev.data = 0;
                kev.udata = 0;

                const changes = [_]std.posix.Kevent{kev};
                _ = std.Io.Kqueue.kevent(self.kqueue_fd.?, &changes, &[_]std.posix.Kevent{}, null) catch {
                    _ = std.posix.system.close(fd);
                    continue;
                };

                item.fd = fd;
            }
        }
    }

    if (comptime EPOLL) {
        if (EPOLL and self.inotify_fd != null) {
            for (self.files.items) |*item| {
                if (item.wd != null) continue;
                const path_z = try std.posix.toPosixPath(item.path);
                // try to add inotify watch for file that was previously missing
                const wd = std.os.linux.inotify_add_watch(
                    self.inotify_fd.?,
                    &path_z,
                    std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE |
                        std.os.linux.IN.DELETE | std.os.linux.IN.MOVE,
                );

                if (wd < 0) continue;

                item.wd = @intCast(wd);
            }
        }
    }

    if (self.mode == .polling) {
        for (self.files.items) |*item| {
            // skip files that already have mtime
            if (item.mtime != 0) continue;

            // try to stat the file
            const stat = std.Io.Dir.cwd().statFile(
                self.io,
                item.path,
                .{},
            ) catch continue;

            // file now exists, update its mtime
            item.mtime = stat.mtime.toMilliseconds();
        }
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
            try self.recheckMissingFiles();

            const has_changes = try self.checkForChanges();

            if (has_changes) {
                const clock = std.Io.Clock.now(.real, self.io);
                const now = clock.toMilliseconds();
                const debounce_delay_ms_i64 = @as(i64, @intCast(self.debounce_delay_ms));

                if (now - self.last_change_time >= debounce_delay_ms_i64) {
                    self.last_change_time = now;

                    const sync_queue = @as(*SyncQueue, @ptrCast(@alignCast(queue)));
                    sync_queue.mutex.lockUncancelable(self.io);
                    defer sync_queue.mutex.unlock(self.io);

                    if (!sync_queue.paused) {
                        sync_queue.should_sync = true;
                        sync_queue.cond.signal(self.io);
                    }

                    if (core.logs) {
                        Util.log(self.io, .INFO, "File changes detected", .{});
                    }
                }
            }
        }

        core.io.sleep(.fromMilliseconds(sleep_chunk_ms), .boot) catch {};
        elapsed_ms += sleep_chunk_ms;
    }
}

fn checkForChanges(self: *Watcher) !bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    var has_changes = false;

    for (self.files.items) |*item| {
        const stat = std.Io.Dir.cwd().statFile(
            self.io,
            item.path,
            .{},
        ) catch |err| switch (err) {
            error.FileNotFound => {
                if (item.mtime != 0) {
                    has_changes = true;
                    item.mtime = 0;
                }
                continue;
            },
            else => return err,
        };

        const mtime = stat.mtime.toMilliseconds();

        if (mtime != item.mtime) {
            has_changes = true;
            item.mtime = mtime;
        }
    }

    return has_changes;
}

test "addPath" {
    const allocator = testing.allocator;
    const io = testing.io;

    // single file
    {
        const test_file = "test_watcher_single.txt";

        try Util.createTestFile(allocator, io, test_file, "initial content");
        defer std.Io.Dir.cwd().deleteFile(io, test_file) catch {};

        var watcher = try Watcher.init(allocator, io, .polling);
        defer watcher.deinit();

        try watcher.addPath(test_file);

        try testing.expect(watcher.files.items.len == 1);
        try testing.expectEqualStrings(test_file, watcher.files.items[0].path);
        try testing.expect(watcher.files.items[0].mtime > 0);
    }

    // nonexistent file
    {
        const test_file = "nonexistent_file.txt";

        var watcher = try Watcher.init(allocator, io, .polling);
        defer watcher.deinit();

        try watcher.addPath(test_file);

        try testing.expect(watcher.files.items.len == 1);
        try testing.expect(watcher.files.items[0].mtime == 0);
    }

    // multiple files
    {
        const src_file = "test_src.txt";
        const dest_file = "test_dest.txt";

        try Util.createTestFile(allocator, io, src_file, "source");
        try Util.createTestFile(allocator, io, dest_file, "dest");

        defer {
            std.Io.Dir.cwd().deleteFile(io, src_file) catch {};
            std.Io.Dir.cwd().deleteFile(io, dest_file) catch {};
        }

        var watcher = try Watcher.init(allocator, io, .polling);
        defer watcher.deinit();

        const dotfiles = [_]Dotfile{
            .{ .src = src_file, .dest = dest_file, .synced = null },
        };

        try watcher.addPaths(&dotfiles);

        try testing.expect(watcher.files.items.len == 2);
    }
}

test "checkForChanges" {
    const allocator = testing.allocator;
    const io = testing.io;

    // no changes
    {
        const test_file = "test_no_change_polling.txt";

        try Util.createTestFile(allocator, io, test_file, "content");
        std.Io.Dir.cwd().deleteFile(io, test_file) catch {};

        var watcher = try Watcher.init(allocator, io, .polling);
        defer watcher.deinit();

        try watcher.addPath(test_file);

        const has_changes = try watcher.checkForChanges();
        try testing.expect(!has_changes);
    }

    // modified
    {
        const test_file = "test_modified_polling.txt";

        try Util.createTestFile(allocator, io, test_file, "initial");
        defer std.Io.Dir.cwd().deleteFile(io, test_file) catch {};

        var watcher = try Watcher.init(allocator, io, .polling);
        defer watcher.deinit();

        try watcher.addPath(test_file);

        try Util.modifyTestFile(test_file, "modified content", io);

        const has_changes = try watcher.checkForChanges();
        try testing.expect(has_changes);

        const has_more_changes = try watcher.checkForChanges();
        try testing.expect(!has_more_changes);
    }

    //deleted
    {
        const test_file = "test_deleted_polling.txt";

        try Util.createTestFile(allocator, io, test_file, "content");

        var watcher = try Watcher.init(allocator, io, .polling);
        defer watcher.deinit();

        try watcher.addPath(test_file);

        std.Io.Dir.cwd().deleteFile(io, test_file) catch {};

        const has_changes = try watcher.checkForChanges();
        try testing.expect(has_changes);
        try testing.expect(watcher.files.items[0].mtime == 0);
    }

    //created after watch
    {
        const test_file = "test_created_later_polling.txt";
        defer std.Io.Dir.cwd().deleteFile(io, test_file) catch {};

        var watcher = try Watcher.init(allocator, io, .polling);
        defer watcher.deinit();

        try watcher.addPath(test_file);
        try testing.expect(watcher.files.items[0].mtime == 0);

        try Util.createTestFile(allocator, io, test_file, "new content");

        const has_changes = try watcher.checkForChanges();
        try testing.expect(has_changes);
        try testing.expect(watcher.files.items[0].mtime > 0);
    }

    // multiple files with mixed changes
    {
        const file1 = "test_multi1_polling.txt";
        const file2 = "test_multi2_polling.txt";
        const file3 = "test_multi3_polling.txt";

        try Util.createTestFile(allocator, io, file1, "file1");
        try Util.createTestFile(allocator, io, file2, "file2");
        try Util.createTestFile(allocator, io, file3, "file3");

        defer {
            std.Io.Dir.cwd().deleteFile(io, file1) catch {};
            std.Io.Dir.cwd().deleteFile(io, file2) catch {};
            std.Io.Dir.cwd().deleteFile(io, file3) catch {};
        }

        var watcher = try Watcher.init(allocator, io, .polling);
        defer watcher.deinit();

        try watcher.addPath(file1);
        try watcher.addPath(file2);
        try watcher.addPath(file3);

        try Util.modifyTestFile(file2, "file2 modified", io);

        const has_changes = try watcher.checkForChanges();
        try testing.expect(has_changes);
    }
}

test "kqueue" {
    if (!KQUEUE) return error.SkipZigTest;

    const allocator = testing.allocator;
    const io = testing.io;
    const test_file = "test_watch_kqueue.txt";

    const environ = std.testing.environ;
    var environ_map = try std.process.Environ.createMap(environ, allocator);
    defer environ_map.deinit();

    try Util.createTestFile(allocator, io, test_file, "initial");
    defer std.Io.Dir.cwd().deleteFile(io, test_file) catch {};

    var watcher = try Watcher.init(allocator, io, .kqueue);
    defer watcher.deinit();

    watcher.poll_interval_ms = 100;
    watcher.debounce_delay_ms = 50;

    try watcher.addPath(test_file);

    var queue = SyncQueue{
        .mutex = std.Io.Mutex.init,
        .should_sync = false,
        .io = io,
    };

    var active = true;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_file = try std.Io.Dir.cwd().createFile(io, "test_out_kqueue.txt", .{});
    defer stdout_file.close(io);

    var stderr_buf: [1024]u8 = undefined;
    var stderr_file = try std.Io.Dir.cwd().createFile(io, "test_err_kqueue.txt", .{});
    defer stderr_file.close(io);

    defer {
        std.Io.Dir.cwd().deleteFile(io, "test_out_kqueue.txt") catch {};
        std.Io.Dir.cwd().deleteFile(io, "test_err_kqueue.txt") catch {};
    }

    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const stdout_interface: *std.Io.Writer = &stdout_writer.interface;

    var stderr_writer = stderr_file.writer(io, &stderr_buf);
    const stderr_interface: *std.Io.Writer = &stderr_writer.interface;

    var core = Core{
        .allocator = allocator,
        .io = io,
        .environ_map = &environ_map,
        .stdout = stdout_interface,
        .stderr = stderr_interface,
        .logs = false,
    };

    const WatchContext = struct {
        watcher: *Watcher,
        core: *Core,
        active: *bool,
        queue: *SyncQueue,
    };

    var context = WatchContext{
        .watcher = &watcher,
        .core = &core,
        .active = &active,
        .queue = &queue,
    };

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: *WatchContext) !void {
            try ctx.watcher.watchPoll(ctx.core, ctx.active, ctx.queue);
        }
    }.run, .{&context});

    core.io.sleep(.fromMilliseconds(100), .boot) catch {};

    try Util.modifyTestFile(test_file, "modified", io);

    core.io.sleep(.fromMilliseconds(3000), .boot) catch {};

    active = false;
    thread.join();

    queue.mutex.lockUncancelable(io);
    defer queue.mutex.unlock(io);
    try testing.expect(queue.should_sync);
}

test "epoll" {
    if (!EPOLL) return error.SkipZigTest;

    const allocator = testing.allocator;
    const io = testing.io;
    const test_file = "test_watch_epoll.txt";
    const environ = std.testing.environ;
    var environ_map = try std.process.Environ.createMap(environ, allocator);
    defer environ_map.deinit();

    try Util.createTestFile(allocator, io, test_file, "initial");
    defer std.Io.Dir.cwd().deleteFile(io, test_file) catch {};

    var watcher = try Watcher.init(allocator, io, .epoll);
    defer watcher.deinit();

    watcher.poll_interval_ms = 100;
    watcher.debounce_delay_ms = 50;

    try watcher.addPath(test_file);

    var queue = SyncQueue{
        .mutex = .init,
        .should_sync = false,
        .io = io,
    };

    var active = true;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_file = try std.Io.Dir.cwd().createFile(io, "test_out_epoll.txt", .{});
    defer stdout_file.close(io);

    var stderr_buf: [1024]u8 = undefined;
    var stderr_file = try std.Io.Dir.cwd().createFile(io, "test_err_epoll.txt", .{});
    defer stderr_file.close(io);

    defer {
        std.Io.Dir.cwd().deleteFile(io, "test_out_epoll.txt") catch {};
        std.Io.Dir.cwd().deleteFile(io, "test_err_epoll.txt") catch {};
    }

    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const stdout_interface: *std.Io.Writer = &stdout_writer.interface;

    var stderr_writer = stderr_file.writer(io, &stderr_buf);
    const stderr_interface: *std.Io.Writer = &stderr_writer.interface;

    var core = Core{
        .allocator = allocator,
        .io = io,
        .environ_map = &environ_map,
        .stdout = stdout_interface,
        .stderr = stderr_interface,
        .logs = false,
    };

    const WatchContext = struct {
        watcher: *Watcher,
        core: *Core,
        active: *bool,
        queue: *SyncQueue,
    };

    var context = WatchContext{
        .watcher = &watcher,
        .core = &core,
        .active = &active,
        .queue = &queue,
    };

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: *WatchContext) !void {
            try ctx.watcher.watchPoll(ctx.core, ctx.active, ctx.queue);
        }
    }.run, .{&context});

    core.io.sleep(.fromMilliseconds(100), .boot) catch {};

    try Util.modifyTestFile(test_file, "modified", core.io);

    core.io.sleep(.fromMilliseconds(3000), .boot) catch {};

    active = false;
    thread.join();

    queue.mutex.lockUncancelable(core.io);
    defer queue.mutex.unlock(core.io);
    try testing.expect(queue.should_sync);
}

test "polling" {
    const allocator = testing.allocator;
    const io = testing.io;
    const test_file = "test_watch_polling.txt";

    const environ = std.testing.environ;
    var environ_map = try std.process.Environ.createMap(environ, allocator);
    defer environ_map.deinit();

    try Util.createTestFile(allocator, io, test_file, "initial");
    defer std.Io.Dir.cwd().deleteFile(io, test_file) catch {};

    var watcher = try Watcher.init(allocator, io, .polling);
    defer watcher.deinit();

    watcher.poll_interval_ms = 100;
    watcher.debounce_delay_ms = 50;

    try watcher.addPath(test_file);

    var queue = SyncQueue{
        .mutex = .init,
        .should_sync = false,
        .io = io,
    };

    var active = true;

    var stdout_buf: [1024]u8 = undefined;
    var stdout_file = try std.Io.Dir.cwd().createFile(io, "test_out_polling.txt", .{});
    defer stdout_file.close(io);

    var stderr_buf: [1024]u8 = undefined;
    var stderr_file = try std.Io.Dir.cwd().createFile(io, "test_err_polling.txt", .{});
    defer stderr_file.close(io);

    defer {
        std.Io.Dir.cwd().deleteFile(io, "test_out_polling.txt") catch {};
        std.Io.Dir.cwd().deleteFile(io, "test_err_polling.txt") catch {};
    }

    var stdout_writer = stdout_file.writer(io, &stdout_buf);
    const stdout_interface: *std.Io.Writer = &stdout_writer.interface;

    var stderr_writer = stderr_file.writer(io, &stderr_buf);
    const stderr_interface: *std.Io.Writer = &stderr_writer.interface;

    var core = Core{
        .allocator = allocator,
        .io = io,
        .environ_map = &environ_map,
        .stdout = stdout_interface,
        .stderr = stderr_interface,
        .logs = false,
    };

    const WatchContext = struct {
        watcher: *Watcher,
        core: *Core,
        active: *bool,
        queue: *SyncQueue,
    };

    var context = WatchContext{
        .watcher = &watcher,
        .core = &core,
        .active = &active,
        .queue = &queue,
    };

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(ctx: *WatchContext) !void {
            try ctx.watcher.watchPoll(ctx.core, ctx.active, ctx.queue);
        }
    }.run, .{&context});

    core.io.sleep(.fromMilliseconds(100), .boot) catch {};

    try Util.modifyTestFile(test_file, "modified", io);

    core.io.sleep(.fromMilliseconds(3000), .boot) catch {};

    active = false;
    thread.join();

    queue.mutex.lockUncancelable(io);
    defer queue.mutex.unlock(io);
    try testing.expect(queue.should_sync);
}

const Watcher = @This();
const std = @import("std");
const testing = std.testing;
const SyncQueue = @import("daemon.zig").SyncQueue;
const Config = @import("../config.zig");
const Dotfile = @import("../dotfile.zig");
const Core = @import("../core.zig");
const Util = @import("../util.zig");
const builtin = @import("builtin");
