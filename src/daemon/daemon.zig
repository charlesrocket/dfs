pub const SyncQueue = struct {
    mutex: Thread.Mutex = .{},
    cond: Thread.Condition = .{},
    stopping: bool = false,
    should_sync: bool = false,
    config_call: bool = false,
    syncing: bool = false,
    paused: bool = false,
    sync_state_changed: bool = false,
    sync_time: ?[]const u8 = null,
    sync_time_updated: bool = false,

    fn updateSyncTime(self: *SyncQueue, allocator: std.mem.Allocator) !void {
        if (self.sync_time) |old_val| allocator.free(old_val);
        var buf: [16]u8 = undefined;
        var time_str: time.tm = undefined;
        var current_time = time.time(null);
        const local_time = time.localtime_r(&current_time, &time_str);
        const format = "%b %d %H:%M:%S";
        const len = time.strftime(&buf, buf.len, format, local_time);
        self.sync_time = try allocator.dupe(
            u8,
            if (len == 0) "unknown" else buf[0..len],
        );
    }
};

const Context = struct {
    queue: *SyncQueue,
    icon: *Icon,
    item_id: ?i32 = null,
};

pub fn start(
    core: *Core,
    config: *Config,
) !void {
    const tray_enabled = config.tray.enabled;
    var active = true;
    var queue = SyncQueue{};
    defer if (queue.sync_time) |v| core.allocator.free(v);

    // initial sync
    try core.scan();
    try core.sync();
    try queue.updateSyncTime(core.allocator);
    queue.sync_time_updated = true;
    core.stdout.print(
        "Initialization completed\n",
        .{},
    ) catch {};

    var watcher = try Watcher.init(core.allocator, config.watcher);
    defer watcher.deinit();

    try watcher.addPaths(core.files.items);

    const watcher_thread = try Thread.spawn(
        .{},
        Watcher.watch,
        .{ &watcher, core, &active, &queue },
    );

    watcher_thread.detach();

    if (build_options.dbus and tray_enabled) {
        const tray_thread = try Thread.spawn(
            .{},
            spawnTray,
            .{ core, config, &queue },
        );

        tray_thread.detach();
    }

    Thread.sleep(500 * std.time.ns_per_ms);

    while (active) {
        queue.mutex.lock();

        while (!queue.should_sync and !queue.config_call and !queue.stopping) {
            queue.cond.wait(&queue.mutex);
        }

        if (queue.stopping) {
            active = false;
            queue.mutex.unlock();
        } else if (queue.should_sync) {
            queue.should_sync = false;
            queue.syncing = true;
            queue.sync_state_changed = true;
            queue.mutex.unlock();

            core.stdout.print(
                "{s}{s}Syncing{s}\n",
                .{ Cli.bold, Cli.yellow, Cli.reset },
            ) catch {};

            try watcher.recheckMissingFiles();
            // re-scan to catch new files
            try core.scan();

            core.sync() catch {
                queue.mutex.lock();
                queue.syncing = false;
                queue.sync_state_changed = true;
                queue.mutex.unlock();
                continue; // do not crash
            };

            core.stdout.print(
                "{s}{s}Sync completed{s}\n",
                .{ Cli.bold, Cli.green, Cli.reset },
            ) catch {};

            try core.stdout.flush();

            queue.mutex.lock();
            try queue.updateSyncTime(core.allocator);
            queue.syncing = false;
            queue.sync_state_changed = true;
            queue.sync_time_updated = true;
            queue.mutex.unlock();
        } else if (queue.config_call) {
            queue.config_call = false;
            queue.mutex.unlock();
            try openConfig(core.allocator, core.config_path);
        } else queue.mutex.unlock();
    }

    if (core.logs) Util.log(.INFO, "Stopping the daemon", .{});

    Thread.sleep(1 * std.time.ns_per_s);
}

fn spawnTray(
    core: *Core,
    config: *Config,
    queue: *SyncQueue,
) !void {
    var icon = try Icon.create(
        core.allocator,
        "org.hellbyte.dfs",
        switch (config.tray.icon) {
            .bright => "dfs-bright",
            .dark => "dfs-dark",
        },
        "DFS",
    );

    defer icon.destroy();

    var sfd = [_]std.posix.pollfd{.{
        .fd = try icon.fd(),
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    var menu = try Menu.create(core.allocator);

    const sync_item = try menu.addItem("Sync", onSync, queue);
    _ = try menu.addSeparator();

    var pause_ctx = Context{ .queue = queue, .icon = &icon };
    const pause_item = try menu.addItem(
        "Pause",
        onPause,
        &pause_ctx,
    );

    pause_ctx.item_id = pause_item;

    _ = try menu.addSeparator();
    const config_item = try menu.addItem("Configuration", onConfig, queue);
    const quit_item = try menu.addItem("Quit", onQuit, queue);

    try menu.setItemIcon(sync_item, "emblem-synchronizing");
    try menu.setItemIcon(pause_item, "media-playback-pause");
    try menu.setItemIcon(config_item, "preferences-system");
    try menu.setItemIcon(quit_item, "application-exit");

    icon.setMenu(&menu);

    const registered: bool = icon.register() catch {
        try core.stderr.print("{s}{s}Warning:{s} D-Bus failure!\n", .{
            Cli.blue,
            Cli.bold,
            Cli.reset,
        });

        try core.stderr.flush();
    };

    if (!registered) {
        try core.stderr.print(
            "{s}{s}Warning:{s} no tray watcher detected!\n",
            .{
                Cli.blue,
                Cli.bold,
                Cli.reset,
            },
        );

        try core.stderr.flush();
    }

    while (!queue.stopping) {
        queue.mutex.lock();

        if (queue.sync_time_updated) {
            queue.sync_time_updated = false;

            if (queue.sync_time) |sync_time|
                try icon.setTooltip("Last sync", sync_time);
        }

        if (queue.sync_state_changed) {
            queue.sync_state_changed = false;
            icon.setMenuItemEnabled(sync_item, !queue.syncing);
        }

        queue.mutex.unlock();
        _ = try std.posix.poll(&sfd, -1);
        icon.processEvents();
    }
}

fn onSync(menu_id: i32, queue_data: ?*anyopaque) void {
    _ = menu_id;
    if (queue_data) |ptr| {
        const queue = @as(*SyncQueue, @ptrCast(@alignCast(ptr)));
        queue.mutex.lock();
        queue.*.should_sync = true;
        queue.cond.signal();
        queue.mutex.unlock();
    }
}

fn onConfig(menu_id: i32, queue_data: ?*anyopaque) void {
    _ = menu_id;

    if (queue_data) |ptr| {
        const queue = @as(*SyncQueue, @ptrCast(@alignCast(ptr)));
        queue.mutex.lock();
        queue.*.config_call = true;
        queue.mutex.unlock();
    }
}

fn onPause(menu_id: i32, queue_data: ?*anyopaque) void {
    _ = menu_id;

    if (queue_data) |ptr| {
        const ctx = @as(*Context, @ptrCast(@alignCast(ptr)));
        ctx.queue.mutex.lock();
        ctx.queue.paused = !ctx.queue.paused;
        ctx.queue.mutex.unlock();

        ctx.icon.setMenuItemLabel(ctx.item_id.?, if (ctx.queue.paused)
            "Resume"
        else
            "Pause") catch return;

        ctx.icon.menu.?.setItemIcon(ctx.item_id.?, if (ctx.queue.paused)
            "media-playback-start"
        else
            "media-playback-pause") catch return;
    }
}

fn onQuit(menu_id: i32, user_data: ?*anyopaque) void {
    _ = menu_id;
    if (user_data) |ptr| {
        const queue = @as(*SyncQueue, @ptrCast(@alignCast(ptr)));
        queue.mutex.lock();
        queue.stopping = true;
        queue.cond.signal();
        queue.mutex.unlock();
    }
}

fn openConfig(allocator: std.mem.Allocator, path: []const u8) !void {
    const xdg_command = [_][]const u8{
        "xdg-open",
        path,
    };

    var proc = std.process.Child.init(&xdg_command, allocator);
    try proc.spawn();
    _ = try proc.wait();
}

const std = @import("std");
const time = @cImport(@cInclude("time.h"));
const builtin = @import("builtin");
const build_options = @import("build_options");
const stray = @import("stray");
const Core = @import("../core.zig");
const Config = @import("../config.zig");
const Cli = @import("../cli.zig");
const Util = @import("../util.zig");
const Watcher = @import("watcher.zig");
const Icon = stray.Icon;
const Menu = stray.Menu;
const Thread = std.Thread;
