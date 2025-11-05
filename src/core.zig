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

allocator: std.mem.Allocator,
stdout: *std.Io.Writer,
stderr: *std.Io.Writer,
direction: Cli.Direction,
src_dir: std.fs.Dir,
source: []const u8,
target: []const u8,
config_path: []const u8,
ignore_items: [][]const u8,
progress: ?std.Progress.Node,
files: std.array_list.Aligned(Dotfile, null),
counter: Util.Counter,
logs: bool,
dry: bool,
verbose: bool,
json: bool,

pub fn new(
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    err: *std.Io.Writer,
) Core {
    return .{
        .allocator = allocator,
        .stdout = out,
        .stderr = err,
        .direction = Cli.Direction.dual,
        .src_dir = std.fs.cwd(),
        .source = undefined,
        .target = undefined,
        .config_path = undefined,
        .ignore_items = undefined,
        .progress = null,
        .files = std.array_list.Aligned(Dotfile, null).empty,
        .counter = Util.Counter.new(false),
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
    self: *Core,
) !void {
    if (self.files.items.len > 0) {
        // make sure previous files are removed
        for (self.files.items) |file| {
            self.allocator.free(file.src);
            self.allocator.free(file.dest);
        }

        self.files.clearAndFree(self.allocator);
    }

    // get target files from the source directory
    var walker = try self.src_dir.walk(self.allocator);
    defer walker.deinit();

    const scan_node = if (self.progress != null) self.progress.?.start(
        "Scanning",
        self.files.items.len,
    ) else null;

    defer if (self.progress != null) scan_node.?.end();

    if (self.logs) Util.log(INFO, "Scanning the source", .{});

    walk: while (try walker.next()) |entry| {
        if (Util.isIgnored(entry.basename, self.ignore_items)) {
            if (self.logs)
                Util.log(INFO, "Ignoring: {s}", .{entry.basename});

            if (entry.kind == .directory) {
                // remove from stack, with prejudice
                var item = walker.stack.pop().?;
                // don't let this be the root directory
                item.iter.dir.close();
            }

            continue :walk;
        }

        if (self.progress != null) scan_node.?.completeOne();

        switch (entry.kind) {
            .file => {
                const src_path = try std.fs.path.join(
                    self.allocator,
                    &.{ self.source, entry.path },
                );

                const target_path = try std.fs.path.join(
                    self.allocator,
                    &.{ self.target, entry.path },
                );

                const file = Dotfile.new(src_path, target_path);

                try self.files.append(self.allocator, file);
            },
            else => continue :walk,
        }
    }
}

pub fn sync(
    self: *Core,
) !void {
    if (!self.json and (self.verbose or self.dry))
        _ = try self.stdout.write("\n");

    const sync_node = if (self.progress != null) self.progress.?.start(
        "Syncing",
        self.files.items.len,
    ) else null;

    defer if (self.progress != null) sync_node.?.end();

    if (self.logs) Util.log(
        INFO,
        "Syncing ({s}/{s})",
        .{ @tagName(self.direction), switch (self.dry) {
            true => "dry",
            false => "live",
        } },
    );

    for (self.files.items) |file| {
        file.processFile(
            self.allocator,
            &self.counter,
            self,
        ) catch |err| {
            if (self.logs) Util.log(ERR, "{}: {s}", .{ err, file.src });
            if (!self.json) {
                try self.stderr.print("{s}{s}ERROR | {}:{s} {s}\n", .{
                    Cli.bold,
                    Cli.red,
                    err,
                    Cli.reset,
                    file.src,
                });

                try self.stderr.flush();
            }
        };

        try self.stdout.flush();
        if (self.progress != null) sync_node.?.completeOne();
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
