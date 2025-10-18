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

const Core = @This();
const std = @import("std");
const assets = @import("assets.zig");
const Config = @import("config.zig");
const Cli = @import("cli.zig");
const Util = @import("util.zig");
