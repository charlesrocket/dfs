pub const SyncQueue = struct {
    mutex: std.Thread.Mutex = .{},
    should_sync: bool = false,
};

pub fn start(
    core: *Core,
    config: *Config,
) !void {
    var active = true;
    var queue = SyncQueue{ .should_sync = false };

    // initial scan to get the file list
    try core.scan();
    // initial sync
    try core.sync();

    var watcher = try Watcher.init(core.allocator, config.watcher);
    defer watcher.deinit();

    try watcher.addPaths(core.files.items);

    const watcher_thread = try std.Thread.spawn(
        .{},
        Watcher.watch,
        .{ &watcher, core, &active, &queue },
    );
    watcher_thread.detach();

    if (build_options.dbus) {
        const tray_thread = try std.Thread.spawn(
            .{},
            spawnTray,
            .{ core, &active, &queue },
        );

        tray_thread.detach();
    }

    while (active) {
        queue.mutex.lock();
        if (queue.should_sync) {
            queue.should_sync = false;
            queue.mutex.unlock();

            core.stdout.print(
                "{s}{s}Syncing{s}\n",
                .{ Cli.bold, Cli.yellow, Cli.reset },
            ) catch {};

            // re-scan to catch new files
            try core.scan();

            core.sync() catch {
                continue; // do not crash
            };

            core.stdout.print(
                "{s}{s}Sync completed{s}\n",
                .{ Cli.bold, Cli.green, Cli.reset },
            ) catch {};

            try core.stdout.flush();
        } else queue.mutex.unlock();

        Thread.sleep(500 * std.time.ns_per_ms);
    }

    if (core.logs) Util.log(.INFO, "Stopping the daemon", .{});

    // TODO
    std.Thread.sleep(500 * std.time.ns_per_ms);
}

fn spawnTray(
    core: *Core,
    active: *bool,
    queue: *SyncQueue,
) !void {
    const stray = @import("stray");
    const TrayIcon = stray.TrayIcon;
    const TrayMenu = stray.TrayMenu;

    var icon = try TrayIcon.create(
        core.allocator,
        "org.hellbyte.dfs",
        "starred",
        "DFS",
    );

    defer icon.destroy();

    var menu = try TrayMenu.create(core.allocator);
    defer menu.destroy();

    _ = try menu.addItem("Sync", onSync, queue);
    _ = try menu.addSeparator();
    _ = try menu.addItem("Quit", onQuit, active);

    icon.setMenu(&menu);

    icon.register() catch {
        try core.stderr.print("Failed to register with D-Bus!\n", .{});
        try core.stderr.flush();
    };

    while (active.*) {
        icon.processEvents();
        std.Thread.sleep(500 * std.time.ns_per_ms);
    }
}

fn onSync(menu_id: i32, queue_data: ?*anyopaque) void {
    _ = menu_id;
    if (queue_data) |ptr| {
        const queue = @as(*SyncQueue, @ptrCast(@alignCast(ptr)));
        queue.mutex.lock();
        queue.*.should_sync = true;
        queue.mutex.unlock();
    }
}

fn onQuit(menu_id: i32, user_data: ?*anyopaque) void {
    _ = menu_id;

    if (user_data) |ptr| {
        const bool_ptr = @as(*bool, @ptrCast(@alignCast(ptr)));
        bool_ptr.* = false;
    }
}

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Core = @import("../core.zig");
const Config = @import("../config.zig");
const Cli = @import("../cli.zig");
const Util = @import("../util.zig");
const Watcher = @import("watcher.zig");
const Thread = std.Thread;
