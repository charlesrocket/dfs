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

stdout: *std.Io.Writer,
stderr: *std.Io.Writer,
direction: Cli.Direction,
logs: bool,
dry: bool,
verbose: bool,
json: bool,

pub fn new(out: *std.Io.Writer, err: *std.Io.Writer) Core {
    return .{
        .stdout = out,
        .stderr = err,
        .direction = Cli.Direction.dual,
        .logs = false,
        .dry = false,
        .verbose = false,
        .json = false,
    };
}

pub fn init(
    self: *Core,
    allocator: std.mem.Allocator,
    config_path: []const u8,
) !void {
    try self.stdout.print("{s}{s}{s}\nInitializing configuration...\n", .{
        assets.help_prefix,
        Cli.bold,
        Cli.reset,
    });

    try self.stdout.flush();

    const repo_usr = try Cli.getUserInput(
        allocator,
        self.stdout,
        Cli.UserInput.Url,
    );

    const src_usr = try Cli.getUserInput(
        allocator,
        self.stdout,
        Cli.UserInput.Source,
    );

    const dest_usr = try Cli.getUserInput(
        allocator,
        self.stdout,
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

    var config = try Config.new(allocator, repo, src, dest);

    try Util.cloneRepo(allocator, repo, src, self);
    try config.write(allocator, config_path);
    _ = try self.stdout.write("COMPLETED\n");
    try self.stdout.flush();
}

pub fn scan(
    allocator: std.mem.Allocator,
    progress: ?*std.Progress.Node,
    src_dir: *std.fs.Dir,
    source: []const u8,
    target: []const u8,
    files: *std.array_list.Aligned(Dotfile, null),
    ignore_items: [][]const u8,
    core: *Core,
) !void {
    // get target files from the source directory
    var walker = try src_dir.walk(allocator);
    defer walker.deinit();

    const scan_node = if (progress != null) progress.?.start(
        "Scanning",
        files.items.len,
    ) else null;

    defer if (progress != null) scan_node.?.end();

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

        if (progress != null) scan_node.?.completeOne();

        switch (entry.kind) {
            .file => {
                const src_path = try std.fs.path.join(
                    allocator,
                    &.{ source, entry.path },
                );

                const target_path = try std.fs.path.join(
                    allocator,
                    &.{ target, entry.path },
                );

                const file = Dotfile.new(src_path, target_path);

                try files.append(allocator, file);
            },
            else => continue :walk,
        }
    }
}

pub fn sync(
    allocator: std.mem.Allocator,
    progress: ?*std.Progress.Node,
    files: *std.array_list.Aligned(Dotfile, null),
    counter: *Util.Counter,
    core: *Core,
) !void {
    if (!core.json and (core.verbose or core.dry))
        _ = try core.stdout.write("\n");

    const sync_node = if (progress != null) progress.?.start(
        "Syncing",
        files.items.len,
    ) else null;

    defer if (progress != null) sync_node.?.end();

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
            counter,
            core,
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
        if (progress != null) sync_node.?.completeOne();
    }
}

const Core = @This();
const std = @import("std");
const assets = @import("assets.zig");
const Config = @import("config.zig");
const Dotfile = @import("dotfile.zig");
const Cli = @import("cli.zig");
const Util = @import("util.zig");

const INFO = Util.Level.INFO;
const ERR = Util.Level.ERROR;
