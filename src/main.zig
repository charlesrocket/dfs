const VERSION = build_options.version;
pub const CommandT = Cli.CommandT;
pub const setup_cmd = Cli.setup_cmd;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;

    const main_cmd = try setup_cmd.init(allocator, .{});
    defer main_cmd.deinit();

    var core = Core.new(allocator, stdout, stderr);
    var custom_config_path: ?[]const u8 = null;
    var usage_help_called = false;
    var args_iter = try cova.ArgIteratorGeneric.init(allocator);
    defer args_iter.deinit();

    cova.parseArgs(
        &args_iter,
        CommandT,
        main_cmd,
        core.stdout,
        .{ .err_reaction = .Usage },
    ) catch |err|
        switch (err) {
            error.UsageHelpCalled => {
                usage_help_called = true;
            },
            else => return err,
        };

    const sync_cmd = main_cmd.checkSubCmd("sync");
    const validate_cmd = main_cmd.checkSubCmd("validate");
    const daemon_cmd = main_cmd.checkSubCmd("daemon");
    const opts = try main_cmd.getOpts(.{});

    if (usage_help_called) {
        try core.stdout.flush();
        return;
    }

    if (main_cmd.checkFlag("version")) {
        try core.stdout.print(
            "{s}{s}{s}",
            .{ "dfs version ", VERSION, "\n" },
        );

        try core.stdout.flush();
        return;
    }

    if (main_cmd.checkFlag("json")) {
        core.json = true;
    }

    if (opts.get("config")) |dest| {
        custom_config_path = try dest.val.getAs([]const u8);
    }

    const config_default = try Config.defaultConfigPath(allocator);
    defer allocator.free(config_default);

    const config_path = if (custom_config_path == null)
        config_default
    else
        custom_config_path.?;

    if (main_cmd.checkSubCmd("purge")) {
        try core.stdout.print("{s}\nErasing application data\n", .{
            assets.help_prefix,
        });

        const data = try Config.getXdgDir(allocator, Config.XdgDir.Data);
        defer allocator.free(data);

        const state = try Config.getXdgDir(allocator, Config.XdgDir.State);
        defer allocator.free(state);

        try std.fs.cwd().deleteTree(data);
        try std.fs.cwd().deleteTree(state);
        try core.stdout.print("COMPLETED\n", .{});
        try core.stdout.flush();

        return;
    }

    if (main_cmd.matchSubCmd("init")) |init_cmd| {
        if (init_cmd.matchSubCmd("bootstrap")) |bootstrap_cmd| {
            const bootstrap_vals = try bootstrap_cmd.getVals(.{});
            const url = try bootstrap_vals.get("config").?.getAs([]const u8);

            try core.stdout.print("{s}\nFetching external config\n", .{
                assets.help_prefix,
            });

            try core.stdout.flush();
            try Config.bootstrap(allocator, url, &core);
            try core.stdout.print("{s}DONE{s}\n", .{
                Cli.bold,
                Cli.reset,
            });

            try core.stdout.flush();
            return;
        }

        try core.init(allocator, config_path);
        try core.stdout.flush();
        return;
    }

    // no more early exits
    if (!core.json) {
        try core.stdout.print("{s}\n", .{
            assets.logo,
        });

        try core.stdout.flush();
    }

    var config = try Config.open(allocator, config_path, &core);
    defer std.zon.parse.free(allocator, config);

    core.config_path = config_path;
    core.logs = config.logging;

    if (core.logs) try Util.setLogger(allocator);

    if (opts.get("target")) |target| {
        config.target = try target.val.getAs([]const u8);
    }

    if (opts.get("source")) |src| {
        config.source = try src.val.getAs([]const u8);
    }

    if (opts.get("notifications")) |notif| {
        config.notifications = try notif.val.getAs(bool);
    }

    core.source = try Config.pathFormat(
        allocator,
        config.source,
    );

    core.target = try Config.pathFormat(
        allocator,
        config.target,
    );

    defer {
        if (!std.mem.eql(u8, core.source, config.source))
            allocator.free(core.source);

        if (!std.mem.eql(u8, core.target, config.target))
            allocator.free(core.target);
    }

    var ignore_list = std.array_list.Managed([]const u8).init(allocator);
    defer ignore_list.deinit();

    for (Core.IGNORE_LIST) |item| {
        try ignore_list.append(item);
    }

    for (config.ignore_list) |item| {
        try ignore_list.append(item);
    }

    if (!core.json) {
        if (sync_cmd) {
            try core.stdout.print("{s}{s}SYNC STARTED{s}\n", .{
                Cli.magenta,
                Cli.bold,
                Cli.reset,
            });
        }

        if (validate_cmd) {
            try core.stdout.print("{s}{s}VALIDATION STARTED{s}\n", .{
                Cli.magenta,
                Cli.bold,
                Cli.reset,
            });
        }

        if (daemon_cmd) {
            try core.stdout.print("{s}{s}DAEMON STARTED{s}\n", .{
                Cli.magenta,
                Cli.bold,
                Cli.reset,
            });
        }
    }

    if (main_cmd.matchSubCmd("sync")) |cmd| {
        if (cmd.checkFlag("verbose")) core.verbose = true;
        if ((try cmd.getOpts(.{})).get("dry")) |dry_opt| {
            core.dry = dry_opt.val.isSet();

            if (!core.json and core.dry) {
                try core.stdout.print("{s}{s}DRY RUN{s}\n", .{
                    Cli.italic,
                    Cli.blink,
                    Cli.reset,
                });
            }
        }
    }

    defer {
        for (core.files.items) |file| {
            file.deinit(allocator);
        }

        core.files.deinit(allocator);
    }

    try core.stdout.print("\nSource is {s}{s}{s}\n", .{
        Cli.underline,
        core.source,
        Cli.reset,
    });

    try core.stdout.flush();

    core.src_dir = std.fs.cwd().openDir(
        core.source,
        .{ .iterate = true },
    ) catch |err| {
        switch (err) {
            error.FileNotFound => {
                if (core.logs) Util.log(
                    ERR,
                    "Source not found: {s}",
                    .{core.source},
                );

                try core.stderr.flush();
                return err;
            },
            else => return err,
        }
    };

    defer core.src_dir.close();

    try core.stdout.print("Target is {s}{s}{s}\n", .{
        Cli.underline,
        core.target,
        Cli.reset,
    });

    try core.stdout.flush();
    // progress
    const no_progress = (core.json or core.verbose or core.dry) and
        (!sync_cmd or !validate_cmd) or daemon_cmd;

    var main_node = if (no_progress) null else std.Progress.start(
        .{
            .disable_printing = no_progress,
            .initial_delay_ns = 80,
        },
    );

    if (!no_progress) core.progress = main_node.?;

    core.ignore_items = ignore_list.items;

    if (sync_cmd or validate_cmd) {
        try core.scan();
    }

    if (daemon_cmd) try Daemon.start(&core, &config);
    if (validate_cmd and !sync_cmd and !daemon_cmd) {
        const validate_node = main_node.?.start(
            "Validating templates",
            core.files.items.len,
        );

        defer validate_node.end();

        if (core.logs) Util.log(INFO, "Validating", .{});

        for (core.files.items) |file| {
            _ = file.validate(
                allocator,
                &core.counter,
                core.json,
            );

            try core.stderr.flush();
            try core.stdout.flush();
            validate_node.completeOne();
        }
    }

    if (sync_cmd and !validate_cmd and !daemon_cmd) {
        const sync_opts = try main_cmd.getSubCmd("sync").?.getOpts(.{});

        if (sync_opts.get("direction")) |opt|
            core.direction = try opt.val.getAs(Cli.Direction);

        try core.sync();
    }

    if (!no_progress) core.progress.?.end();

    if (core.json) {
        try core.counter.json(core.stdout);
        _ = try core.stdout.write("\n");
    } else {
        if (sync_cmd) {
            _ = try core.stdout.write("\n");

            try core.stdout.print("TOTAL: {s}{d}{s}\n", .{
                Cli.underline,
                core.counter.total,
                Cli.reset,
            });

            try core.stdout.print("UPDATED: {s}{d}{s}\n", .{
                Cli.underline,
                core.counter.updated,
                Cli.reset,
            });

            try core.stdout.print("TEMPLATES: {s}{d}{s}\n", .{
                Cli.underline,
                core.counter.template,
                Cli.reset,
            });

            try core.stdout.print("RENDERS: {s}{d}{s}\n", .{
                Cli.underline,
                core.counter.render,
                Cli.reset,
            });

            try core.stdout.print("BINARIES: {s}{d}{s}\n", .{
                Cli.underline,
                core.counter.binary,
                Cli.reset,
            });

            try core.stdout.print("ERRORS: {s}{d}{s}\n", .{
                Cli.underline,
                core.counter.errors,
                Cli.reset,
            });

            if (config.notifications) {
                const stats = try std.fmt.allocPrint(
                    allocator,
                    "Summary: total {d}, updated {d}, templates {d}, renders {d}, binaries {d}, errors {d}",
                    .{
                        core.counter.total,
                        core.counter.updated,
                        core.counter.template,
                        core.counter.render,
                        core.counter.binary,
                        core.counter.errors,
                    },
                );

                defer allocator.free(stats);
                Cli.sendNotification(
                    allocator,
                    "DFS Sync completed",
                    stats,
                    "normal",
                );
            }
        }
    }

    if (core.logs and (!daemon_cmd and !validate_cmd)) Util.log(
        INFO,
        "Finished: total {d}, updated {d}, templates {d}, renders {d}, binaries {d}, errors {d}",
        .{
            core.counter.total,
            core.counter.updated,
            core.counter.template,
            core.counter.render,
            core.counter.binary,
            core.counter.errors,
        },
    );

    if (!core.json and (sync_cmd or validate_cmd)) {
        try core.stdout.print("{s}{s}DONE{s}\n", .{
            Cli.bold,
            Cli.green,
            Cli.reset,
        });
    }

    try core.stdout.flush();
}

test {
    _ = Core;
    _ = Config;
    _ = Daemon;
    _ = Dotfile;
    _ = Syntax;
    _ = Util;
    _ = Watcher;
}

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const cova = @import("cova");
const Core = @import("core.zig");
const Config = @import("config.zig");
const Cli = @import("cli.zig");
const Daemon = @import("daemon/daemon.zig");
const Dotfile = @import("dotfile.zig");
const Syntax = @import("syntax.zig");
const Util = @import("util.zig");
const Watcher = @import("daemon/watcher.zig");
const assets = @import("assets.zig");

const INFO = Util.Level.INFO;
const ERR = Util.Level.ERROR;
const WARN = Util.Level.WARNING;
