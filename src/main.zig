pub const CommandT = cli.CommandT;
pub const setup_cmd = cli.setup_cmd;

const VERSION = build_options.version;

const Dotfile = struct {
    dest: []const u8,
    src: []const u8,
    synced: ?u64,

    fn new(src: []const u8, dest: []const u8) Dotfile {
        return .{
            .dest = dest,
            .src = src,
            .synced = null,
        };
    }
};

const Config = struct {
    source: []const u8,
    destination: []const u8,

    fn new(
        allocator: std.mem.Allocator,
        source: []const u8,
        destination: ?[]const u8,
    ) !Config {
        const path = if (destination == null)
            try std.process.getEnvVarOwned(allocator, "HOME")
        else
            destination.?;

        return .{
            .source = source,
            .destination = path,
        };
    }

    fn write(self: *Config, allocator: std.mem.Allocator) !void {
        const path = try configPath(allocator);
        const config = try std.fmt.allocPrint(
            allocator,
            "{s}/dfs.zon",
            .{path},
        );

        try createDirRecursively(allocator, path);

        const f = try std.fs.createFileAbsolute(
            config,
            .{ .read = false, .truncate = true },
        );

        defer f.close();

        var writer = f.writer();
        try writer.print(
            ".{{\n" ++
                "    .source= \"{s}\",\n" ++
                "    .destination = \"{s}\",\n" ++
                "}}\n",
            .{
                self.source,
                self.destination,
            },
        );
    }
};

const Meta = struct {
    src: []const u8,
    dest: []const u8,
    synced: i64,
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

const UserInput = enum {
    Url,
    Source,
    Destination,
};

fn getUserInput(allocator: std.mem.Allocator, input: UserInput) !std.ArrayList(u8) {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var buf: [2048]u8 = undefined;
    var list = std.ArrayList(u8).init(allocator);

    try stdout.print("Enter {s}: ", .{switch (input) {
        .Url => "repository URL",
        .Source => "repository destination",
        .Destination => "configuration destination",
    }});

    if (try stdin.readUntilDelimiterOrEof(buf[0..], '\n')) |user_input| {
        for (user_input) |c| {
            try list.append(c);
        }

        return list;
    } else {
        return error.Foo;
    }
}

fn init(allocator: std.mem.Allocator) !void {
    var repo_usr = try getUserInput(allocator, UserInput.Url);
    var src_usr = try getUserInput(allocator, UserInput.Source);
    var dest_usr = try getUserInput(allocator, UserInput.Destination);

    const repo = try repo_usr.toOwnedSlice();
    const src = try src_usr.toOwnedSlice();
    const dest = try dest_usr.toOwnedSlice();

    var config = try Config.new(allocator, src, dest);
    const command = [_][]const u8{
        "git",
        "clone",
        repo,
        src,
    };

    var proc = std.process.Child.init(&command, allocator);

    try proc.spawn();
    _ = try proc.wait();
    try config.write(allocator);
    std.posix.exit(0);
}

fn isIgnored(value: []const u8) bool {
    for (ignore_list) |el| {
        if (std.mem.eql(u8, el, value)) {
            return true;
        }
    }

    return false;
}

fn isText(data: []const u8) bool {
    if (std.unicode.utf8ValidateSlice(data)) {
        return true;
    }

    // ASCII heuristic
    var non_text_count: usize = 0;
    for (data) |c| {
        // common text whitespace
        if (c == '\n' or c == '\r' or c == '\t') continue;
        // printable range
        if (c >= 0x20 and c <= 0x7E) continue;

        non_text_count += 1;
    }

    // treat as binary if the threshold is reached
    return (non_text_count * 100 / data.len) < 10;
}

fn configPath(allocator: std.mem.Allocator) ![]const u8 {
    var path = std.ArrayList(u8).init(allocator);

    // TODO handle missing env var
    const xdg_conf = try std.process.getEnvVarOwned(
        allocator,
        "XDG_CONFIG_HOME",
    );

    const config_home = try std.fmt.allocPrint(
        allocator,
        "{s}",
        .{xdg_conf},
    );

    try path.appendSlice(config_home);
    return path.toOwnedSlice();
}

fn createDirRecursively(allocator: std.mem.Allocator, path: []const u8) !void {
    var parts = try std.fs.path.componentIterator(path);
    var buffer = std.ArrayList(u8).init(allocator);
    //defer buffer.deinit();

    const sep = std.fs.path.sep;

    if (std.fs.path.isAbsolute(path)) {
        try buffer.append(sep);
    }

    while (parts.next()) |component| {
        const part = component.name;
        if (part.len == 0) continue;

        if (buffer.items.len > 1 or (buffer.items.len == 1 and buffer.items[0] != sep)) {
            try buffer.append(sep);
        }

        try buffer.appendSlice(part);
        const dir_path = buffer.items;

        std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

fn recordLastSync(file: Dotfile) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const sync_path = try std.fmt.bufPrint(&buf, "{s}.sync.zon", .{file.dest});
    const f = try std.fs.createFileAbsolute(sync_path, .{ .read = false, .truncate = true });
    defer f.close();

    const record = Meta{
        .src = file.src,
        .dest = file.dest,
        .synced = std.time.timestamp(),
    };

    var writer = f.writer();
    try writer.print(
        ".{{\n" ++
            "    .src = \"{s}\",\n" ++
            "    .dest = \"{s}\",\n" ++
            "    .synced = {d},\n" ++
            "}}\n",
        .{
            record.src,
            record.dest,
            record.synced,
        },
    );
}

fn lastMod(file: []const u8) ?u64 {
    const path = std.fs.path.dirname(file);
    const dir = std.fs.cwd().openDir(path.?, .{}) catch return null;
    const stat = dir.statFile(file) catch return null;

    // compress the integer
    const result = @divFloor(
        @as(u64, @intCast(stat.mtime)),
        1000000000,
    );

    return result;
}

fn processFile(allocator: std.mem.Allocator, file: Dotfile, dry_run: bool) !void {
    const template_file = try std.fs.cwd().openFile(file.src, .{});
    defer template_file.close();

    // TODO adjust buffer limit
    const template_content = try template_file.readToEndAlloc(allocator, 2048 * 2048);
    const is_text = isText(template_content);

    if (!is_text) {
        if (dry_run) {
            std.debug.print("FILE: copy binary {s} -> {s}\n", .{ file.src, file.dest });
        } else {
            // ensure destination directory exists
            const dir_path = std.fs.path.dirname(file.dest) orelse return error.InvalidPath;
            try createDirRecursively(allocator, dir_path);

            const dest_file = try std.fs.createFileAbsolute(file.dest, .{
                .read = false,
                .truncate = true,
            });
            defer dest_file.close();

            try dest_file.writeAll(template_content);
            try recordLastSync(file);
        }

        return;
    }

    var last_sync: usize = 0;
    var meta_present = true;
    const meta_file_path = try std.fmt.allocPrint(
        allocator,
        "{s}.sync.zon",
        .{file.dest},
    );

    defer allocator.free(meta_file_path);

    const dir_path = std.fs.path.dirname(file.dest) orelse return error.InvalidPath;

    try createDirRecursively(allocator, dir_path);

    const meta_file = std.fs.cwd().openFile(meta_file_path, .{}) catch |err| switch (err) {
        error.FileNotFound => blk: {
            meta_present = false;
            _ = try std.fs.createFileAbsolute(
                meta_file_path,
                .{ .read = false, .truncate = true },
            );

            break :blk std.fs.cwd().openFile(meta_file_path, .{}) catch unreachable;
        },

        else => return err,
    };

    defer meta_file.close();

    if (meta_present) {
        const meta_content_t = try meta_file.readToEndAlloc(allocator, 1024);
        var meta_content = std.ArrayList(u8).init(allocator);
        defer meta_content.deinit();

        for (meta_content_t) |c| {
            try meta_content.append(c);
        }

        // null-terminated
        try meta_content.append(0);

        const input = meta_content.items[0 .. meta_content.items.len - 1 :0];
        const meta = try std.zon.parse.fromSlice(
            Meta,
            allocator,
            input,
            null,
            .{},
        );

        last_sync = @intCast(meta.synced);
    }

    const last_modified = lastMod(file.dest) orelse 0;

    if (last_sync < last_modified) {
        const rendered_file = try std.fs.cwd().openFile(file.dest, .{});
        defer rendered_file.close();

        const rendered_content = try rendered_file.readToEndAlloc(allocator, 1024);
        defer allocator.free(rendered_content);

        const new_template = try lib.reverseTemplate(allocator, rendered_content, template_content);

        if (!dry_run) {
            const updated_template = try std.fs.createFileAbsolute(file.src, .{
                .read = false,
                .truncate = true,
            });

            defer updated_template.close();
            try updated_template.writeAll(new_template);
        } else {
            std.debug.print("FILE: updated: {s}\n", .{file.src});
            std.debug.print("FILE: new template data:\n{s}\n", .{new_template});
        }
    }

    const result = try lib.applyTemplate(allocator, template_content);

    if (!dry_run) {
        const output_file = try std.fs.createFileAbsolute(file.dest, .{
            .read = false,
            .truncate = true,
        });

        try output_file.writeAll(result);
        defer output_file.close();

        try recordLastSync(file);
    } else {
        std.debug.print("FILE: updated: {s}\n", .{file.dest});

        if (is_text)
            std.debug.print("FILE: new render data:\n{s}\n", .{result})
        else
            std.debug.print("FILE: new render data: binary\n", .{});
    }
}

fn walk(
    arr: *std.ArrayListUnmanaged(Dotfile),
    allocator: std.mem.Allocator,
    config: Config,
) !void {
    // with base path reference
    try walkDir(
        arr,
        allocator,
        config.source,
        config.source,
        config.destination,
    );
}

fn walkDir(
    arr: *std.ArrayListUnmanaged(Dotfile),
    allocator: std.mem.Allocator,
    base_path: []const u8,
    current_path: []const u8,
    dest: []const u8,
) !void {
    var dir = try std.fs.cwd().openDir(current_path, .{});
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |node| {
        if (isIgnored(node.name)) continue;

        const node_path = try std.fs.path.join(allocator, &.{ current_path, node.name });
        //defer allocator.free(node_path);

        const rel_path = try std.fs.path.relative(allocator, base_path, node_path);
        //defer allocator.free(rel_path);

        const dest_path = try std.fs.path.join(allocator, &.{ dest, rel_path });
        //defer allocator.free(dest_path);

        switch (node.kind) {
            .file => {
                // grab file strings
                const src_copy = try allocator.dupe(u8, node_path);
                const dest_copy = try allocator.dupe(u8, dest_path);
                const file = Dotfile.new(src_copy, dest_copy);
                try arr.append(allocator, file);
            },
            .directory => {
                try walkDir(arr, allocator, base_path, node_path, dest);
            },
            else => {
                continue;
            },
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer _ = arena.deinit();

    const allocator = arena.allocator();
    const stdout = std.io.getStdOut().writer();

    const main_cmd = try setup_cmd.init(allocator, .{});
    defer main_cmd.deinit();

    var usage_help_called = false;
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

        std.posix.exit(0);
    }

    if (main_cmd.checkSubCmd("init")) {
        try init(allocator);
    }

    const conf_home = try configPath(allocator);
    const config_path = try std.fmt.allocPrint(
        allocator,
        "{s}/dfs.zon",
        .{conf_home},
    );

    const config_file = std.fs.cwd().openFile(config_path, .{}) catch |err|
        switch (err) {
            error.FileNotFound => {
                std.debug.print("Config not found!\nRun `dfs init`.", .{});
                std.posix.exit(1);
            },
            else => return err,
        };

    defer config_file.close();

    const config_content_t = try config_file.readToEndAlloc(allocator, 1024);
    var config_content = std.ArrayList(u8).init(allocator);
    defer config_content.deinit();

    for (config_content_t) |c| {
        try config_content.append(c);
    }

    try config_content.append(0);

    const config_data = config_content.items[0 .. config_content.items.len - 1 :0];
    var config = try std.zon.parse.fromSlice(
        Config,
        allocator,
        config_data,
        null,
        .{},
    );

    if (opts.get("destination")) |dest| {
        config.destination = try dest.val.getAs([]const u8);
    }

    if (opts.get("source")) |src| {
        config.source = try src.val.getAs([]const u8);
    }

    if (main_cmd.matchSubCmd("sync")) |sync_cmd| {
        // TODO add colors to the (dry-run) output
        var dry_run = false;
        if ((try sync_cmd.getOpts(.{})).get("dry")) |dry_opt| {
            if (dry_opt.val.isSet()) {
                std.debug.print("DRY RUN\n", .{});
                dry_run = true;
            }
        }

        var files = std.ArrayListUnmanaged(Dotfile).empty;
        //defer files.deinit(allocator);

        try walk(&files, allocator, config);

        const owned_files = try files.toOwnedSlice(allocator);

        for (owned_files) |file| {
            try processFile(allocator, file, dry_run);
        }
    }
}

const std = @import("std");
const lib = @import("libdfs");
const posix = std.posix;
const build_options = @import("build_options");

const cova = @import("cova");
const cli = @import("cli.zig");
