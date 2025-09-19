pub const CommandT = cli.CommandT;
pub const setup_cmd = cli.setup_cmd;

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
    stdout: @TypeOf(std.io.getStdOut().writer()),
    custom_config: ?[]const u8,
) !void {
    try stdout.print("{s}{s}{s}\nInitializing configuration...\n", .{
        assets.help_prefix,
        cli.bold,
        cli.reset,
    });

    var repo_usr = try cli.getUserInput(allocator, cli.UserInput.Url);
    var src_usr = try cli.getUserInput(allocator, cli.UserInput.Source);
    var dest_usr = try cli.getUserInput(allocator, cli.UserInput.Destination);

    const repo = try repo_usr.toOwnedSlice();
    const src = try src_usr.toOwnedSlice();
    const dest = try dest_usr.toOwnedSlice();

    var config = try Config.Configuration.new(allocator, src, dest);
    const command = [_][]const u8{
        "git",
        "clone",
        "--recurse-submodules",
        repo,
        src,
    };

    var proc = std.process.Child.init(&command, allocator);

    try proc.spawn();
    _ = try proc.wait();

    try config.write(allocator, custom_config);
    _ = try stdout.write("COMPLETED\n");

    std.process.exit(0);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

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

    if (main_cmd.checkFlag("version")) {
        try stdout.print(
            "{s}{s}{s}",
            .{ "dfs version ", VERSION, "\n" },
        );

        std.process.exit(0);
    }

    if (main_cmd.checkFlag("json")) {
        json = true;
    }

    if (opts.get("config")) |dest| {
        custom_config_path = try dest.val.getAs([]const u8);
    }

    if (main_cmd.checkSubCmd("init")) {
        try init(allocator, stdout, custom_config_path);
    } else if (main_cmd.matchSubCmd("bootstrap")) |bootstrap_cmd| {
        const bootstrap_opts = try bootstrap_cmd.getOpts(.{});
        const url = try bootstrap_opts.get("url").?.val.getAs([]const u8);

        try stdout.print("{s}\nFetching external config...\n", .{
            assets.help_prefix,
        });

        try Util.bootstrap(allocator, url);
        try stdout.print("{s}DONE{s}\n", .{
            cli.bold,
            cli.reset,
        });

        std.process.exit(0);
    }

    const conf_home = try Config.getXdgDir(allocator, Config.XdgDir.Config);
    defer allocator.free(conf_home);

    const config_default = try std.fmt.allocPrint(
        allocator,
        "{s}/dfs.zon",
        .{conf_home},
    );

    defer allocator.free(config_default);

    const config_path = if (custom_config_path == null)
        config_default
    else
        custom_config_path.?;

    const config_file = std.fs.cwd().openFile(config_path, .{}) catch |err|
        switch (err) {
            error.FileNotFound => {
                std.debug.print("{s}Config not found!{s}\nRun `dfs init`.", .{
                    cli.red,
                    cli.reset,
                });

                std.process.exit(1);
            },
            else => return err,
        };

    defer config_file.close();

    const config_content_t = try config_file.readToEndAlloc(
        allocator,
        1024,
    );

    defer allocator.free(config_content_t);

    var config_content = std.ArrayList(u8).init(allocator);
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
            "/tmp/src/dotfiles",
            "/tmp/test",
        );

        defer std.zon.parse.free(allocator, example_config);

        try stderr.print("{s}INVALID CONFIG{s}: {s}\n\n", .{
            cli.red,
            cli.reset,
            config_path,
        });

        _ = try stderr.write("Example:\n\n");
        _ = try std.zon.stringify.serialize(
            example_config,
            .{},
            stderr,
        );

        _ = try stderr.write("\n");
        std.process.exit(1);
    };

    defer std.zon.parse.free(allocator, config);

    if (opts.get("destination")) |dest| {
        config.destination = try dest.val.getAs([]const u8);
    }

    if (opts.get("source")) |src| {
        config.source = try src.val.getAs([]const u8);
    }

    const source_with_slash = try Util.ensureTrailingSlash(
        allocator,
        config.source,
    );

    const dest_with_slash = try Util.ensureTrailingSlash(
        allocator,
        config.destination,
    );

    defer {
        if (!std.mem.eql(u8, source_with_slash, config.source))
            allocator.free(source_with_slash);

        if (!std.mem.eql(u8, dest_with_slash, config.destination))
            allocator.free(dest_with_slash);
    }

    if (main_cmd.matchSubCmd("sync")) |sync_cmd| {
        var ignore_list = std.ArrayList([]const u8).init(allocator);
        defer ignore_list.deinit();

        for (IGNORE_LIST) |item| {
            try ignore_list.append(item);
        }

        for (config.ignore_list) |item| {
            try ignore_list.append(item);
        }

        var verbose = false;

        if (!json) {
            try stdout.print("{s}\n{s}{s}SYNC STARTED{s}\n", .{
                assets.logo,
                cli.magenta,
                cli.bold,
                cli.reset,
            });
        }

        if (sync_cmd.checkFlag("verbose")) verbose = true;

        if ((try sync_cmd.getOpts(.{})).get("dry")) |dry_opt| {
            dry_run = dry_opt.val.isSet();

            if (!json and dry_run) {
                try stdout.print("{s}{s}DRY RUN{s}\n\n", .{
                    cli.italic,
                    cli.blink,
                    cli.reset,
                });
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
            config.source,
            .{ .iterate = true },
        );

        defer src_dir.close();

        // get target files from the source directory
        var walker = try src_dir.walk(allocator);
        defer walker.deinit();

        const ignore_items = ignore_list.items;

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

        for (files.items) |file| {
            try file.processFile(
                allocator,
                stdout,
                &counter,
                dry_run,
                verbose,
                json,
            );
        }

        if (json) {
            try counter.json(stdout);
            _ = try stdout.write("\n");
        } else {
            try stdout.print("PROCESSED FILES: {s}{d}{s}\n", .{
                cli.underline,
                counter.total,
                cli.reset,
            });

            try stdout.print("ERRORS: {s}{d}{s}\n", .{
                cli.underline,
                counter.errors,
                cli.reset,
            });

            try stdout.print("{s}{s}DONE{s}\n", .{
                cli.bold,
                cli.green,
                cli.reset,
            });
        }
    }
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
const cli = @import("cli.zig");
const assets = @import("assets.zig");
