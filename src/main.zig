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

    var core = Core.new(stdout, stderr);
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

    const config_home = try Config.getXdgDir(allocator, Config.XdgDir.Config);
    defer allocator.free(config_home);

    const config_default = try std.fmt.allocPrint(
        allocator,
        "{s}/dfs.zon",
        .{config_home},
    );

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

    core.logs = config.logging;

    if (core.logs) try Util.setLogger(allocator);

    if (opts.get("target")) |target| {
        config.target = try target.val.getAs([]const u8);
    }

    if (opts.get("source")) |src| {
        config.source = try src.val.getAs([]const u8);
    }

    if (opts.get("notifications")) |src| {
        config.notifications = try src.val.getAs(bool);
    }

    const source_with_slash = try Config.pathFormat(
        allocator,
        config.source,
    );

    const target_with_slash = try Config.pathFormat(
        allocator,
        config.target,
    );

    defer {
        if (!std.mem.eql(u8, source_with_slash, config.source))
            allocator.free(source_with_slash);

        if (!std.mem.eql(u8, target_with_slash, config.target))
            allocator.free(target_with_slash);
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

    var counter = Util.Counter.new(core.dry);
    var files = std.ArrayListUnmanaged(Dotfile).empty;

    defer {
        for (files.items) |file| {
            file.deinit(allocator);
        }

        files.deinit(allocator);
    }

    try core.stdout.print("\nSource is {s}{s}{s}\n", .{
        Cli.underline,
        source_with_slash,
        Cli.reset,
    });

    try core.stdout.flush();

    var src_dir = std.fs.cwd().openDir(
        source_with_slash,
        .{ .iterate = true },
    ) catch |err| {
        switch (err) {
            error.FileNotFound => {
                if (core.logs) Util.log(
                    ERR,
                    "Source not found: {s}",
                    .{source_with_slash},
                );

                try core.stderr.flush();
                return err;
            },
            else => return err,
        }
    };

    defer src_dir.close();

    try core.stdout.print("Target is {s}{s}{s}\n", .{
        Cli.underline,
        target_with_slash,
        Cli.reset,
    });

    try core.stdout.flush();
    // progress
    const no_progress = (core.json or core.verbose or core.dry) and
        (!sync_cmd or !validate_cmd);

    const main_node = std.Progress.start(
        .{
            .disable_printing = no_progress,
            .initial_delay_ns = 80,
        },
    );

    // get target files from the source directory
    var walker = try src_dir.walk(allocator);
    defer walker.deinit();

    const ignore_items = ignore_list.items;

    if (sync_cmd or validate_cmd) {
        const scan_node = main_node.start(
            "Scanning",
            files.items.len,
        );

        defer scan_node.end();

        if (core.logs) Util.log(INFO, "Scanning the source", .{});

        walk: while (try walker.next()) |entry| {
            if (Util.isIgnored(entry.basename, ignore_items)) {
                if (core.logs)
                    Util.log(INFO, "Ignoring: {s}", .{entry.basename});

                if (entry.kind == .directory) {
                    // remove from stack, with prejudice
                    var item = walker.stack.pop().?;
                    // don't let this be the root directory
                    item.iter.dir.close();
                }

                continue :walk;
            }

            scan_node.completeOne();

            switch (entry.kind) {
                .file => {
                    const src_path = try std.fs.path.join(
                        allocator,
                        &.{ source_with_slash, entry.path },
                    );

                    const target_path = try std.fs.path.join(
                        allocator,
                        &.{ target_with_slash, entry.path },
                    );

                    const file = Dotfile.new(src_path, target_path);

                    try files.append(allocator, file);
                },
                else => continue :walk,
            }
        }
    }

    if (validate_cmd and !sync_cmd) {
        const validate_node = main_node.start(
            "Validating templates",
            files.items.len,
        );

        defer validate_node.end();

        if (core.logs) Util.log(INFO, "Validating", .{});

        for (files.items) |file| {
            _ = file.validate(
                allocator,
                &counter,
                core.json,
            );

            try core.stderr.flush();
            try core.stdout.flush();
            validate_node.completeOne();
        }
    }

    if (sync_cmd and !validate_cmd) {
        if (!core.json and (core.verbose or core.dry))
            _ = try core.stdout.write("\n");

        const sync_opts = try main_cmd.getSubCmd("sync").?.getOpts(.{});
        const sync_node = main_node.start(
            "Syncing",
            files.items.len,
        );

        defer sync_node.end();

        if (sync_opts.get("direction")) |opt|
            core.direction = try opt.val.getAs(Cli.Direction);

        if (core.logs) Util.log(
            INFO,
            "Syncing ({s}/{s})",
            .{ @tagName(core.direction), switch (core.dry) {
                true => "dry",
                false => "live",
            } },
        );

        for (files.items) |file| {
            file.processFile(
                allocator,
                &counter,
                &core,
            ) catch |err| {
                if (core.logs) Util.log(ERR, "{}: {s}", .{ err, file.src });
                if (!core.json) {
                    try core.stderr.print("{s}{s}ERROR | {}:{s} {s}\n", .{
                        Cli.bold,
                        Cli.red,
                        err,
                        Cli.reset,
                        file.src,
                    });

                    try core.stderr.flush();
                }
            };

            try core.stdout.flush();
            sync_node.completeOne();
        }
    }

    main_node.end();

    if (core.json) {
        try counter.json(core.stdout);
        _ = try core.stdout.write("\n");
    } else {
        if (sync_cmd) {
            try core.stdout.print("\n{s}{s}SUMMARY{s}\n", .{
                Cli.bold,
                Cli.reverse,
                Cli.reset,
            });

            try core.stdout.print("TOTAL: {s}{d}{s}\n", .{
                Cli.underline,
                counter.total,
                Cli.reset,
            });

            try core.stdout.print("UPDATED: {s}{d}{s}\n", .{
                Cli.underline,
                counter.updated,
                Cli.reset,
            });

            try core.stdout.print("TEMPLATES: {s}{d}{s}\n", .{
                Cli.underline,
                counter.template,
                Cli.reset,
            });

            try core.stdout.print("RENDERS: {s}{d}{s}\n", .{
                Cli.underline,
                counter.render,
                Cli.reset,
            });

            try core.stdout.print("BINARIES: {s}{d}{s}\n", .{
                Cli.underline,
                counter.binary,
                Cli.reset,
            });

            try core.stdout.print("ERRORS: {s}{d}{s}\n", .{
                Cli.underline,
                counter.errors,
                Cli.reset,
            });

            if (config.notifications) {
                const stats = try std.fmt.allocPrint(
                    allocator,
                    "Summary: total {d}, updated {d}, templates {d}, renders {d}, binaries {d}, errors {d}",
                    .{
                        counter.total,
                        counter.updated,
                        counter.template,
                        counter.render,
                        counter.binary,
                        counter.errors,
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

    if (core.logs) Util.log(
        INFO,
        "Finished: total {d}, updated {d}, templates {d}, renders {d}, binaries {d}, errors {d}",
        .{
            counter.total,
            counter.updated,
            counter.template,
            counter.render,
            counter.binary,
            counter.errors,
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
    _ = Config;
    _ = Dotfile;
    _ = Util;
}

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const cova = @import("cova");
const Core = @import("core.zig");
const Config = @import("config.zig");
const Cli = @import("cli.zig");
const Dotfile = @import("dotfile.zig");
const Util = @import("util.zig");
const assets = @import("assets.zig");

const INFO = Util.Level.INFO;
const ERR = Util.Level.ERROR;
const WARN = Util.Level.WARNING;
