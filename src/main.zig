const Dotfile = struct {
    dest: []const u8,
    src: []const u8,
    modified: ?u64,

    fn new(src: []const u8, dest: []const u8) Dotfile {
        return .{
            .dest = dest,
            .src = src,
            .modified = null,
        };
    }
};

// TODO use regex
const ignore_list = [_][]const u8{
    "LICENSE",
    "codecov.yml",
    "codecov.yaml",
    ".gitignore",
    ".gitmodules",
    ".github",
    ".git",
};

fn isIgnored(value: []const u8) bool {
    for (ignore_list) |el| {
        if (std.mem.eql(u8, el, value)) {
            return true;
        }
    }

    return false;
}

fn walkSrc(
    arr: *std.ArrayListUnmanaged(Dotfile),
    allocator: std.mem.Allocator,
    path: []const u8,
    dest: []const u8,
) !void {
    try walkDir(arr, allocator, path, path, dest);
}

fn walkDir(
    arr: *std.ArrayListUnmanaged(Dotfile),
    allocator: std.mem.Allocator,
    base_path: []const u8,
    current_path: []const u8,
    dest: []const u8,
) !void {
    var dir = try std.fs.cwd().openDir(current_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (isIgnored(entry.name)) continue;

        const entry_path = try std.fs.path.join(allocator, &.{ current_path, entry.name });
        defer allocator.free(entry_path);

        const rel_path = try std.fs.path.relative(allocator, base_path, entry_path);
        defer allocator.free(rel_path);

        const dest_path = try std.fs.path.join(allocator, &.{ dest, rel_path });
        defer allocator.free(dest_path);

        switch (entry.kind) {
            .file => {
                const file = Dotfile.new(entry_path, dest_path);
                try arr.append(allocator, file);
            },
            .directory => {
                try walkDir(arr, allocator, base_path, entry_path, dest);
            },
            else => {
                continue;
            },
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const dotfiles = "/home/charlie/src/dotfiles/";
    const allocator = gpa.allocator();
    const destination = "/home/charlie/test/"; //try std.process.getEnvVarOwned(allocator, "HOME");
    //defer allocator.free(destination);

    var files = std.ArrayListUnmanaged(Dotfile).empty;
    defer files.deinit(allocator);

    //const source = "/home/charlie/lab/dotfiles/";
    //const file = ".config/shell-choker.zon";
    //const file_dest = concatString(allocator, source, file);
    //const file_source = concatString(allocator, destination, file);
    //const path_index = std.mem.lastIndexOf(u8, file, "/").?;
    //const dirstr = file[0..path_index];
    //const filename = file[path_index + 1 ..];

    try walkSrc(&files, allocator, dotfiles, destination);
}

const std = @import("std");
const lib = @import("libdfs");
const posix = std.posix;
