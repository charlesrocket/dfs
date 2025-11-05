pub const SyncQueue = struct {
    mutex: std.Thread.Mutex = .{},
    should_sync: bool,
    config_call: bool,
};

pub fn start(
    core: *Core,
    config: *Config,
) !void {
    var active = true;
    var queue = SyncQueue{
        .should_sync = false,
        .config_call = false,
    };

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
        } else if (queue.config_call) {
            queue.config_call = false;
            queue.mutex.unlock();
            try openConfig(core.allocator, core.config_path);
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
    var icon = try TrayIcon.create(
        core.allocator,
        "org.hellbyte.dfs",
        "dfs-bright",
        "DFS",
    );

    defer icon.destroy();

    var menu = try TrayMenu.create(core.allocator);
    defer menu.destroy();

    _ = try menu.addItem("Sync", onSync, queue);
    _ = try menu.addSeparator();
    _ = try menu.addItem("Configuration", onConfig, queue);
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

fn onConfig(menu_id: i32, queue_data: ?*anyopaque) void {
    _ = menu_id;

    if (queue_data) |ptr| {
        const queue = @as(*SyncQueue, @ptrCast(@alignCast(ptr)));
        queue.mutex.lock();
        queue.*.config_call = true;
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
const builtin = @import("builtin");
const build_options = @import("build_options");
const stray = @import("stray");
const Core = @import("../core.zig");
const Config = @import("../config.zig");
const Cli = @import("../cli.zig");
const Util = @import("../util.zig");
const Watcher = @import("watcher.zig");
const TrayIcon = stray.TrayIcon;
const TrayMenu = stray.TrayMenu;
const Thread = std.Thread;
