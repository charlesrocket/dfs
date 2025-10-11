pub const CommandT = Cli.CommandT;
pub const setup_cmd = Cli.setup_cmd;

const VERSION = build_options.version;

pub const IGNORE_LIST = [_][]const u8{
    "CHANGELOG.md",
    "README.md",
    "LICENSE",
    "codecov.yml",
    "codecov.yaml",
    ".gitignore",
    ".gitmodules",
    ".github",
    ".git",
    ".DS_Store",
};

pub const MAC_SPECIFIC = [_][]const u8{
    ".yabairc",
};

fn init(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    config_path: []const u8,
) !void {
    try stdout.print("{s}{s}{s}\nInitializing configuration...\n", .{
        assets.help_prefix,
        Cli.bold,
        Cli.reset,
    });

    try stdout.flush();

    const repo_usr = try Cli.getUserInput(
        allocator,
        stdout,
        Cli.UserInput.Url,
    );

    const src_usr = try Cli.getUserInput(
        allocator,
        stdout,
        Cli.UserInput.Source,
    );

    const dest_usr = try Cli.getUserInput(
        allocator,
        stdout,
        Cli.UserInput.Destination,
    );

    defer {
        repo_usr.deinit();
        src_usr.deinit();
        dest_usr.deinit();
    }

    const repo = repo_usr.items;
    const src = src_usr.items;
    const dest = dest_usr.items;

    var config = try Config.Configuration.new(allocator, repo, src, dest);
    const command = [_][]const u8{
        "git",
        "clone",
        "--recurse-submodules",
        repo,
        try Config.pathFormat(allocator, src),
    };

    var proc = std.process.Child.init(&command, allocator);

    try proc.spawn();
    _ = try proc.wait();

    try config.write(allocator, config_path);
    _ = try stdout.write("COMPLETED\n");

    try stdout.flush();
    std.process.exit(0);
}

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

    var custom_config_path: ?[]const u8 = null;
    var usage_help_called = false;
    var dry_run = false;
    var json = false;
    var args_iter = try cova.ArgIteratorGeneric.init(allocator);
    defer args_iter.deinit();

    cova.parseArgs(
        &args_iter,
        CommandT,
        main_cmd,
        stdout,
        .{ .err_reaction = .Usage },
    ) catch |err|
        switch (err) {
            error.UsageHelpCalled => {
                usage_help_called = true;
            },
            else => return err,
        };

    const opts = try main_cmd.getOpts(.{});

    if (usage_help_called) {
        try stdout.flush();
        std.process.exit(0);
    }

    if (main_cmd.checkFlag("version")) {
        try stdout.print(
            "{s}{s}{s}",
            .{ "dfs version ", VERSION, "\n" },
        );

        try stdout.flush();
        std.process.exit(0);
    }

    if (main_cmd.checkFlag("json")) {
        json = true;
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
        try stdout.print("{s}\nErasing application data...\n", .{
            assets.help_prefix,
        });

        const data = try Config.getXdgDir(allocator, Config.XdgDir.Data);
        defer allocator.free(data);

        try std.fs.cwd().deleteTree(data);
        try stdout.print("COMPLETED\n", .{});
    }

    if (main_cmd.checkSubCmd("init")) {
        try init(allocator, stdout, config_path);
        try stdout.flush();
        std.process.exit(0);
    } else if (main_cmd.matchSubCmd("bootstrap")) |bootstrap_cmd| {
        const bootstrap_opts = try bootstrap_cmd.getOpts(.{});
        const url = try bootstrap_opts.get("url").?.val.getAs([]const u8);

        try stdout.print("{s}\nFetching external config...\n", .{
            assets.help_prefix,
        });

        try stdout.flush();
        try Util.bootstrap(allocator, url);
        try stdout.print("{s}DONE{s}\n", .{
            Cli.bold,
            Cli.reset,
        });

        try stdout.flush();
        std.process.exit(0);
    }

    const config_file = std.fs.cwd().openFile(config_path, .{}) catch |err|
        switch (err) {
            error.FileNotFound => {
                try stderr.print("{s}Config not found!{s}\nRun `dfs init`.", .{
                    Cli.red,
                    Cli.reset,
                });

                try stderr.flush();
                std.process.exit(1);
            },
            else => return err,
        };

    defer config_file.close();

    const config_size: usize = @intCast((try config_file.stat()).size);
    const config_content_t = try config_file.readToEndAlloc(
        allocator,
        config_size,
    );

    defer allocator.free(config_content_t);

    var config_content = std.array_list.Managed(u8).init(allocator);
    defer config_content.deinit();

    for (config_content_t) |c| {
        try config_content.append(c);
    }

    try config_content.append(0);

    const config_data =
        config_content.items[0 .. config_content.items.len - 1 :0];

    var config = std.zon.parse.fromSlice(
        Config.Configuration,
        allocator,
        config_data,
        null,
        .{},
    ) catch {
        const example_config = try Config.Configuration.new(
            allocator,
            "https://gibson.com/git/dotfiles",
            "$HOME/src/dotfiles",
            "/tmp/test",
        );

        defer std.zon.parse.free(allocator, example_config);

        try stderr.print("{s}{s}INVALID CONFIG{s}: {s}\n\n", .{
            Cli.red,
            Cli.bold,
            Cli.reset,
            config_path,
        });

        _ = try stderr.write("Example:\n\n");
        _ = try std.zon.stringify.serialize(
            example_config,
            .{},
            stderr,
        );

        try Config.migrateConfig(allocator, config_path);

        _ = try stderr.print(
            "\n\n{s}Config file updated!{s}\nExiting...\n",
            .{ Cli.yellow, Cli.reset },
        );

        try stderr.flush();
        std.process.exit(1);
    };

    defer std.zon.parse.free(allocator, config);

    if (opts.get("destination")) |dest| {
        config.destination = try dest.val.getAs([]const u8);
    }

    if (opts.get("source")) |src| {
        config.source = try src.val.getAs([]const u8);
    }

    const source_with_slash = try Config.pathFormat(
        allocator,
        config.source,
    );

    const dest_with_slash = try Config.pathFormat(
        allocator,
        config.destination,
    );

    defer {
        if (!std.mem.eql(u8, source_with_slash, config.source))
            allocator.free(source_with_slash);

        if (!std.mem.eql(u8, dest_with_slash, config.destination))
            allocator.free(dest_with_slash);
    }

    const sync_cmd = main_cmd.checkSubCmd("sync");
    const validate_cmd = main_cmd.checkSubCmd("validate");

    var ignore_list = std.array_list.Managed([]const u8).init(allocator);
    defer ignore_list.deinit();

    for (IGNORE_LIST) |item| {
        try ignore_list.append(item);
    }

    for (config.ignore_list) |item| {
        try ignore_list.append(item);
    }

    var verbose = false;

    if (!json) {
        if (sync_cmd) {
            try stdout.print("{s}\n{s}{s}SYNC STARTED{s}\n", .{
                assets.logo,
                Cli.magenta,
                Cli.bold,
                Cli.reset,
            });
        }

        if (validate_cmd) {
            try stdout.print("{s}\n{s}{s}VALIDATION STARTED{s}\n", .{
                assets.help_prefix,
                Cli.magenta,
                Cli.bold,
                Cli.reset,
            });
        }
    }

    if (main_cmd.matchSubCmd("sync")) |cmd| {
        if (cmd.checkFlag("verbose")) verbose = true;
        if ((try cmd.getOpts(.{})).get("dry")) |dry_opt| {
            dry_run = dry_opt.val.isSet();

            if (!json and dry_run) {
                try stdout.print("{s}{s}DRY RUN{s}\n\n", .{
                    Cli.italic,
                    Cli.blink,
                    Cli.reset,
                });
            }
        }
    }

    var counter = Util.Counter.new(dry_run);
    var files = std.ArrayListUnmanaged(Dotfile).empty;

    defer {
        for (files.items) |file| {
            file.deinit(allocator);
        }

        files.deinit(allocator);
    }

    var src_dir = try std.fs.cwd().openDir(
        source_with_slash,
        .{ .iterate = true },
    );

    defer src_dir.close();

    // progress
    const no_progress = (json or verbose or dry_run) and
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

        walk: while (try walker.next()) |entry| {
            if (Util.isIgnored(entry.basename, ignore_items)) {
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

                    const dest_path = try std.fs.path.join(
                        allocator,
                        &.{ dest_with_slash, entry.path },
                    );

                    const file = Dotfile.new(src_path, dest_path);

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

        for (files.items) |file| {
            _ = file.validate(
                allocator,
                &counter,
                json,
            );

            try stderr.flush();
            try stdout.flush();
            validate_node.completeOne();
        }
    }

    if (sync_cmd and !validate_cmd) {
        const sync_opts = try main_cmd.getSubCmd("sync").?.getOpts(.{});
        const sync_node = main_node.start(
            "Syncing",
            files.items.len,
        );

        defer sync_node.end();

        const direction_opt = sync_opts.get("direction").?;
        const direction = try direction_opt.val.getAs(Cli.Direction);

        for (files.items) |file| {
            try file.processFile(
                allocator,
                stdout,
                direction,
                &counter,
                dry_run,
                verbose,
                json,
            );

            try stdout.flush();
            sync_node.completeOne();
        }
    }

    main_node.end();

    if (json) {
        try counter.json(stdout);
        _ = try stdout.write("\n");
    } else {
        if (sync_cmd) {
            try stdout.print("TOTAL: {s}{d}{s}\n", .{
                Cli.underline,
                counter.total,
                Cli.reset,
            });

            try stdout.print("UPDATED: {s}{d}{s}\n", .{
                Cli.underline,
                counter.updated,
                Cli.reset,
            });

            try stdout.print("TEMPLATES: {s}{d}{s}\n", .{
                Cli.underline,
                counter.template,
                Cli.reset,
            });

            try stdout.print("RENDERS: {s}{d}{s}\n", .{
                Cli.underline,
                counter.render,
                Cli.reset,
            });

            try stdout.print("BINARIES: {s}{d}{s}\n", .{
                Cli.underline,
                counter.binary,
                Cli.reset,
            });

            try stdout.print("ERRORS: {s}{d}{s}\n", .{
                Cli.underline,
                counter.errors,
                Cli.reset,
            });
        }
    }

    if (!json and (sync_cmd or validate_cmd)) {
        try stdout.print("{s}{s}DONE{s}\n", .{
            Cli.bold,
            Cli.green,
            Cli.reset,
        });
    }

    try stdout.flush();
}

test {
    _ = Dotfile;
}

const std = @import("std");
const build_options = @import("build_options");

const cova = @import("cova");
const Config = @import("config.zig");
const Dotfile = @import("dotfile.zig");
const Util = @import("util.zig");
const Cli = @import("cli.zig");
const assets = @import("assets.zig");
