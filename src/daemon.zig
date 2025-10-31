pub fn start(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    var active = true;

    var icon = try TrayIcon.create(
        allocator,
        "org.hellbyte.dfs",
        "starred",
        "DFS",
    );

    defer icon.destroy();

    var menu = try TrayMenu.create(allocator);
    defer menu.destroy();

    _ = try menu.addItem("Sync", onSync, null);
    _ = try menu.addSeparator();
    _ = try menu.addItem("Quit", onQuit, &active);

    icon.setMenu(&menu);

    icon.register() catch {
        try stderr.print("Failed to register with D-Bus!\n", .{});
        try stderr.flush();
    };

    while (active) {
        icon.processEvents();
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    if (!active) _ = try stdout.write("\nShutting down DFS daemon!\n");
}

fn onSync(menu_id: i32, user_data: ?*anyopaque) void {
    _ = menu_id;
    _ = user_data;
}

fn onQuit(menu_id: i32, user_data: ?*anyopaque) void {
    _ = menu_id;

    if (user_data) |ptr| {
        const bool_ptr = @as(*bool, @ptrCast(@alignCast(ptr)));
        bool_ptr.* = false;
    }
}

const std = @import("std");
const stray = @import("stray");
const TrayIcon = stray.TrayIcon;
const TrayMenu = stray.TrayMenu;
