pub const SyncQueue = struct {
    mutex: Thread.Mutex = .{},
    should_sync: bool = true,
    config_call: bool = false,
    syncing: bool = false,
    sync_state_changed: bool = false,
};

pub fn start(
    core: *Core,
    config: *Config,
) !void {
    const tray_enabled = config.tray.enabled;
    var active = true;
    var queue = SyncQueue{};

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
            .{ core, config, &active, &queue },
        );

        tray_thread.detach();
    }

    while (active) {
        queue.mutex.lock();

        if (queue.should_sync) {
            queue.should_sync = false;
            queue.syncing = true;
            queue.sync_state_changed = true;
            queue.mutex.unlock();

            core.stdout.print(
                "{s}{s}Syncing{s}\n",
                .{ Cli.bold, Cli.yellow, Cli.reset },
            ) catch {};

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
            queue.syncing = false;
            queue.sync_state_changed = true;
            queue.mutex.unlock();
        } else if (queue.config_call) {
            queue.config_call = false;
            queue.mutex.unlock();
            try openConfig(core.allocator, core.config_path);
        } else queue.mutex.unlock();

        Thread.sleep(1 * std.time.ns_per_s);
    }

    if (core.logs) Util.log(.INFO, "Stopping the daemon", .{});

    // TODO
    Thread.sleep(1 * std.time.ns_per_s);
}

fn spawnTray(
    core: *Core,
    config: *Config,
    active: *bool,
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

    var menu = try Menu.create(core.allocator);

    const sync_item = try menu.addItem("Sync", onSync, queue);
    _ = try menu.addSeparator();
    _ = try menu.addItem("Configuration", onConfig, queue);
    _ = try menu.addItem("Quit", onQuit, active);

    icon.setMenu(&menu);

    icon.register() catch {
        try core.stderr.print("Failed to register with D-Bus!\n", .{});
        try core.stderr.flush();
    };

    while (active.*) {
        queue.mutex.lock();

        if (queue.sync_state_changed) {
            queue.sync_state_changed = false;
            icon.setMenuItemEnabled(sync_item, !queue.syncing);
            queue.mutex.unlock();
        } else queue.mutex.unlock();

        icon.processEvents();
        Thread.sleep(500 * std.time.ns_per_ms);
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
const Icon = stray.Icon;
const Menu = stray.Menu;
const Thread = std.Thread;
