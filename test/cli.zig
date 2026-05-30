const Proc = struct {
    term: std.process.Child.Term,
    out: []u8,
    err: []u8,
};

fn runner(args: []const []const u8) !Proc {
    const io = testing.io;
    var proc = try std.process.spawn(io, .{
        .argv = args,
        .stdout = .pipe,
        .stderr = .pipe,
    });

    var stdout_buf: [13312]u8 = undefined;
    var stderr_buf: [13312]u8 = undefined;

    var stdout_reader = proc.stdout.?.reader(io, &stdout_buf);
    var stderr_reader = proc.stderr.?.reader(io, &stderr_buf);

    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    var stderr: std.ArrayListUnmanaged(u8) = .empty;

    try stdout_reader.interface.appendRemaining(allocator, &stdout, .unlimited);
    try stderr_reader.interface.appendRemaining(allocator, &stderr, .unlimited);

    const term = try proc.wait(io);

    return Proc{
        .term = term,
        .out = try stdout.toOwnedSlice(allocator),
        .err = try stderr.toOwnedSlice(allocator),
    };
}

fn stripAnsi(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = try alloc.alloc(u8, input.len);
    var i: usize = 0;
    var j: usize = 0;

    while (i < input.len) {
        if (input[i] == 0x1B and i + 1 < input.len and input[i + 1] == '[') {
            i += 2;

            while (i < input.len) {
                const c = input[i];
                i += 1;

                if ((c >= 'A' and c <= 'Z') or
                    (c >= 'a' and c <= 'z') or
                    c == '~' or c == '@' or c == '`')
                {
                    break;
                }
            }
        } else if (input[i] == 0x1B and i + 1 < input.len) {
            const next_char = input[i + 1];

            if ((next_char >= 'A' and next_char <= 'Z') or
                (next_char >= 'a' and next_char <= 'z') or
                next_char == '=' or next_char == '>' or next_char == '<')
            {
                i += 2;
            } else {
                output[j] = input[i];
                j += 1;
                i += 1;
            }
        } else {
            output[j] = input[i];
            j += 1;
            i += 1;
        }
    }

    return allocator.realloc(output, j);
}

test "sync" {
    const io = testing.io;

    try std.Io.Dir.cwd().deleteTree(io, "test/dest");

    const argv = [3][]const u8{
        exe_path,
        "-c=test/conf.zon",
        "sync",
    };

    const proc = try runner(&argv);

    const expected =
        \\____________ _____
        \\|  _  \  ___/  ___|
        \\| | | | |_  \ `--.
        \\| | | |  _|  `--. \
        \\| |/ /| |   /\__/ /
        \\|___/ \_|   \____/
        \\
        \\SYNC STARTED
        \\
        \\Source is test/root/
        \\Target is test/dest/
        \\
        \\TOTAL: 3
        \\UPDATED: 2
        \\TEMPLATES: 0
        \\RENDERS: 2
        \\BINARIES: 1
        \\ERRORS: 1
        \\DONE
        \\
    ;

    const out = try stripAnsi(allocator, proc.out);

    defer {
        allocator.free(out);
        allocator.free(proc.out);
        allocator.free(proc.err);
    }

    try std.Io.Dir.cwd().deleteTree(io, "test/dest");

    try std.testing.expectEqualStrings(expected, out);
    try std.testing.expectEqual(proc.term.exited, 0);
}

test "sync-dry" {
    const io = testing.io;

    try std.Io.Dir.cwd().deleteTree(io, "test/dest-dry");
    try std.Io.Dir.cwd().deleteTree(io, "test/root-dry");

    const argv = [4][]const u8{
        exe_path,
        "-c=test/conf-dry.zon",
        "sync",
        "--dry",
    };

    const template =
        \\# TEST
        \\Foo
        \\{> if SYSTEM.os == unsupported <}
        \\val="Zoot"
        \\{> else <}
        \\val="Dry"
        \\{> endif <}
        \\
    ;

    try std.Io.Dir.cwd().createDir(io, "test/root-dry", .default_dir);

    const orig = try std.Io.Dir.cwd().createFile(
        io,
        "test/root-dry/testfile1",
        .{ .read = true },
    );

    try orig.writeStreamingAll(io, template);
    orig.close(io);

    const proc = try runner(&argv);

    const expected =
        \\____________ _____
        \\|  _  \  ___/  ___|
        \\| | | | |_  \ `--.
        \\| | | |  _|  `--. \
        \\| |/ /| |   /\__/ /
        \\|___/ \_|   \____/
        \\
        \\SYNC STARTED
        \\DRY RUN
        \\
        \\Source is test/root-dry/
        \\Target is test/dest-dry/
        \\
        \\FILE | test/dest-dry/testfile1
        \\DATA | render:
        \\
        \\# TEST
        \\Foo
        \\
        \\val="Dry"
        \\
        \\
        \\--- --- ---
        \\
        \\TOTAL: 1
        \\UPDATED: 0
        \\TEMPLATES: 0
        \\RENDERS: 1
        \\BINARIES: 0
        \\ERRORS: 0
        \\DONE
        \\
    ;

    const out = try stripAnsi(allocator, proc.out);

    defer {
        allocator.free(out);
        allocator.free(proc.out);
        allocator.free(proc.err);
        std.Io.Dir.cwd().deleteTree(io, "test/dest-dry") catch {};
        std.Io.Dir.cwd().deleteTree(io, "test/root-dry") catch {};
    }

    try std.testing.expectEqualStrings(expected, out);
    try std.testing.expectEqual(proc.term.exited, 0);
}

test "sync-back" {
    const io = testing.io;
    var cwd = std.Io.Dir.cwd();

    defer cwd.deleteTree(io, "test/dest-back") catch {};
    defer cwd.deleteTree(io, "test/root-back") catch {};

    const argv = [3][]const u8{
        exe_path,
        "-c=test/conf-back.zon",
        "sync",
    };

    const orig_template =
        \\# TEST
        \\Foo
        \\{> if SYSTEM.os == unsupported <}
        \\val="Zoot"
        \\{> else <}
        \\val="Bar"
        \\{> endif <}
        \\
    ;

    cwd.createDir(io, "test/root-back", .default_dir) catch {};

    const orig = try cwd.createFile(
        io,
        "test/root-back/testfile1",
        .{ .read = true },
    );

    try orig.writeStreamingAll(io, orig_template);
    orig.close(io);

    const proc1 = try runner(&argv);

    try io.sleep(.fromSeconds(1), .awake);

    const file = try cwd.createFile(
        io,
        "test/dest-back/testfile1",
        .{ .read = true, .truncate = true },
    );

    try file.writeStreamingAll(io,
        \\# TEST
        \\Foo
        \\val="TEST"
        \\
    );

    file.close(io);

    const proc2 = try runner(&argv);

    const expected_template =
        \\# TEST
        \\Foo
        \\{> if SYSTEM.os == unsupported <}
        \\val="Zoot"
        \\{> else <}
        \\val="TEST"
        \\{> endif <}
        \\
    ;

    const template = try cwd.openFile(io, "test/root-back/testfile1", .{});
    var template_reader = template.reader(io, &.{});
    const template_content = try template_reader.interface.allocRemaining(
        std.testing.allocator,
        .limited(1024),
    );

    defer std.testing.allocator.free(template_content);

    defer {
        allocator.free(proc1.out);
        allocator.free(proc1.err);
        allocator.free(proc2.out);
        allocator.free(proc2.err);
    }

    defer cwd.deleteTree(io, "test/dest-back") catch {};
    defer cwd.deleteTree(io, "test/root-back") catch {};

    try std.testing.expectEqualStrings(expected_template, template_content);
    try std.testing.expectEqual(proc1.term.exited, 0);
    try std.testing.expectEqual(proc2.term.exited, 0);
}

test "sync-forward-forced" {
    const io = testing.io;

    defer std.Io.Dir.cwd().deleteTree(io, "test/dest-forward-forced") catch {};
    defer std.Io.Dir.cwd().deleteTree(io, "test/root-forward-forced") catch {};

    const argv = [4][]const u8{
        exe_path,
        "-c=test/conf-forward-forced.zon",
        "sync",
        "--direction=forward",
    };

    const root_template =
        \\# TEST
        \\Foo
        \\{> if SYSTEM.os == unsupported <}
        \\val="Foo"
        \\{> else <}
        \\val="Bar"
        \\{> endif <}
        \\
    ;

    try std.Io.Dir.cwd().createDir(io, "test/root-forward-forced", .default_dir);
    try std.Io.Dir.cwd().createDir(io, "test/dest-forward-forced", .default_dir);

    const root = try std.Io.Dir.cwd().createFile(
        io,
        "test/root-forward-forced/testfile1",
        .{ .read = true },
    );

    try root.writeStreamingAll(io, root_template);
    root.close(io);

    const file = try std.Io.Dir.cwd().createFile(
        io,
        "test/dest-forward-forced/testfile1",
        .{ .read = true, .truncate = true },
    );

    try file.writeStreamingAll(io,
        \\# TEST
        \\Foo
        \\val="TEST"
        \\
    );

    file.close(io);

    const proc = try runner(&argv);

    const expected_render =
        \\# TEST
        \\Foo
        \\
        \\val="Bar"
        \\
        \\
    ;

    const render = try std.Io.Dir.cwd().openFile(io, "test/dest-forward-forced/testfile1", .{});
    var render_reader = render.reader(io, &.{});
    const render_content = try render_reader.interface.allocRemaining(
        std.testing.allocator,
        .limited(1024),
    );

    defer std.testing.allocator.free(render_content);

    defer {
        allocator.free(proc.out);
        allocator.free(proc.err);
    }

    defer std.Io.Dir.cwd().deleteTree(io, "test/dest-forward-forced") catch {};
    defer std.Io.Dir.cwd().deleteTree(io, "test/root-forward-forced") catch {};

    try std.testing.expectEqualStrings(expected_render, render_content);
    try std.testing.expectEqual(proc.term.exited, 0);
}

test "sync-back-forced" {
    const io = testing.io;
    var cwd = std.Io.Dir.cwd();

    defer cwd.deleteTree(io, "test/dest-back-forced") catch {};
    defer cwd.deleteTree(io, "test/root-back-forced") catch {};

    const argv = [4][]const u8{
        exe_path,
        "-c=test/conf-back-forced.zon",
        "sync",
        "--direction=back",
    };

    const orig_template =
        \\# TEST
        \\Foo
        \\{> if SYSTEM.os == unsupported <}
        \\val="Foo"
        \\{> else <}
        \\val="Bar"
        \\{> endif <}
        \\
    ;

    try cwd.createDir(io, "test/root-back-forced", .default_dir);
    try cwd.createDir(io, "test/dest-back-forced", .default_dir);

    const orig = try cwd.createFile(
        io,
        "test/root-back-forced/testfile1",
        .{ .read = true },
    );

    try orig.writeStreamingAll(io, orig_template);
    orig.close(io);

    const file = try cwd.createFile(
        io,
        "test/dest-back-forced/testfile1",
        .{ .read = true, .truncate = true },
    );

    try file.writeStreamingAll(io,
        \\# TEST
        \\Foo
        \\val="TEST"
        \\
    );

    file.close(io);

    const proc = try runner(&argv);

    const expected_template =
        \\# TEST
        \\Foo
        \\{> if SYSTEM.os == unsupported <}
        \\val="Foo"
        \\{> else <}
        \\val="TEST"
        \\{> endif <}
        \\
    ;

    const template = try cwd.openFile(io, "test/root-back-forced/testfile1", .{});
    var template_reader = template.reader(io, &.{});
    const template_content = try template_reader.interface.allocRemaining(
        std.testing.allocator,
        .limited(1024),
    );

    defer std.testing.allocator.free(template_content);

    defer {
        allocator.free(proc.out);
        allocator.free(proc.err);
    }

    defer cwd.deleteTree(io, "test/dest-back-forced") catch {};
    defer cwd.deleteTree(io, "test/root-back-forced") catch {};

    try std.testing.expectEqualStrings(expected_template, template_content);
    try std.testing.expectEqual(proc.term.exited, 0);
}

test "config bad" {
    const argv = [3][]const u8{
        exe_path,
        "-c=test/conf-bad.zon",
        "sync",
    };

    const proc = try runner(&argv);

    const expected_err =
        \\Example:
        \\
        \\.{
        \\    .repository = "https://gibson.com/git/dotfiles",
        \\    .source = "$HOME/src/dotfiles",
        \\    .target = "/tmp/test",
        \\    .logging = false,
        \\    .notifications = false,
        \\    .watcher = .auto,
        \\    .ignore_list = .{},
        \\    .tray = .{ .enabled = true, .icon = .bright },
        \\}
        \\
    ;

    const out = try stripAnsi(allocator, proc.out);

    defer {
        allocator.free(out);
        allocator.free(proc.out);
        allocator.free(proc.err);
    }

    try std.testing.expect(std.mem.indexOf(u8, proc.err, expected_err) != null);
    try std.testing.expectEqual(proc.term.exited, 1);
}

test "config not found" {
    const argv = [3][]const u8{
        exe_path,
        "-c=test/foo.zon",
        "sync",
    };

    const proc = try runner(&argv);

    const expected_err =
        \\Run `dfs init`.
        \\
    ;

    const out = try stripAnsi(allocator, proc.out);

    defer {
        allocator.free(out);
        allocator.free(proc.out);
        allocator.free(proc.err);
    }

    try std.testing.expectStringEndsWith(proc.err, expected_err);
    try std.testing.expectEqual(proc.term.exited, 1);
}

const std = @import("std");
const allocator = std.testing.allocator;
const testing = std.testing;

const build_options = @import("build_options");
const exe_path = build_options.exe_path;
