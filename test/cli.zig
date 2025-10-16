const Proc = struct {
    term: std.process.Child.Term,
    out: []u8,
    err: []u8,
};

fn runner(args: []const []const u8) !Proc {
    var proc = std.process.Child.init(args, allocator);

    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;

    var stdout: std.ArrayListUnmanaged(u8) = .empty;
    var stderr: std.ArrayListUnmanaged(u8) = .empty;

    try proc.spawn();
    try proc.collectOutput(allocator, &stdout, &stderr, 13312);

    const term = try proc.wait();
    const out = try stdout.toOwnedSlice(allocator);
    const err = try stderr.toOwnedSlice(allocator);

    return Proc{ .term = term, .out = out, .err = err };
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
    try std.fs.cwd().deleteTree("test/dest");

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
        \\Destination is test/dest/
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

    try std.fs.cwd().deleteTree("test/dest");

    try std.testing.expectEqualStrings(expected, out);
    try std.testing.expectEqual(proc.term.Exited, 0);
}

test "sync-dry" {
    try std.fs.cwd().deleteTree("test/dest-dry");
    try std.fs.cwd().deleteTree("test/root-dry");

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
        \\{> end <}
        \\
    ;

    try std.fs.cwd().makeDir("test/root-dry");

    const orig = try std.fs.cwd().createFile(
        "test/root-dry/testfile1",
        .{ .read = true },
    );

    try orig.writeAll(template);
    orig.close();

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
        \\Destination is test/dest-dry/
        \\
        \\FILE | test/dest-dry/testfile1
        \\DATA | render:
        \\
        \\# TEST
        \\Foo
        \\val="Dry"
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
        std.fs.cwd().deleteTree("test/dest-dry") catch unreachable;
        std.fs.cwd().deleteTree("test/root-dry") catch unreachable;
    }

    try std.testing.expectEqualStrings(expected, out);
    try std.testing.expectEqual(proc.term.Exited, 0);
}

test "sync-back" {
    defer std.fs.cwd().deleteTree("test/dest-back") catch unreachable;
    defer std.fs.cwd().deleteTree("test/root-back") catch unreachable;

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
        \\{> end <}
        \\
    ;

    try std.fs.cwd().makeDir("test/root-back");

    const orig = try std.fs.cwd().createFile(
        "test/root-back/testfile1",
        .{ .read = true },
    );

    try orig.writeAll(orig_template);
    orig.close();

    const proc1 = try runner(&argv);

    std.Thread.sleep(1000000000);

    const file = try std.fs.cwd().createFile(
        "test/dest-back/testfile1",
        .{ .read = true, .truncate = true },
    );

    try file.writeAll(
        \\# TEST
        \\Foo
        \\val="TEST"
        \\
    );

    file.close();

    const proc2 = try runner(&argv);

    const expected_template =
        \\# TEST
        \\Foo
        \\{> if SYSTEM.os == unsupported <}
        \\val="Zoot"
        \\{> else <}
        \\val="TEST"
        \\{> end <}
        \\
    ;

    const template = try std.fs.cwd().openFile("test/root-back/testfile1", .{});
    const template_content = try template.readToEndAlloc(
        std.testing.allocator,
        1024,
    );

    defer std.testing.allocator.free(template_content);

    defer {
        allocator.free(proc1.out);
        allocator.free(proc1.err);
        allocator.free(proc2.out);
        allocator.free(proc2.err);
    }

    defer std.fs.cwd().deleteTree("test/dest-back") catch unreachable;
    defer std.fs.cwd().deleteTree("test/root-back") catch unreachable;

    try std.testing.expectEqualStrings(expected_template, template_content);
    try std.testing.expectEqual(proc1.term.Exited, 0);
    try std.testing.expectEqual(proc2.term.Exited, 0);
}

test "sync-forward-forced" {
    defer std.fs.cwd().deleteTree("test/dest-forward-forced") catch unreachable;
    defer std.fs.cwd().deleteTree("test/root-forward-forced") catch unreachable;

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
        \\{> end <}
        \\
    ;

    try std.fs.cwd().makeDir("test/root-forward-forced");
    try std.fs.cwd().makeDir("test/dest-forward-forced");

    const root = try std.fs.cwd().createFile(
        "test/root-forward-forced/testfile1",
        .{ .read = true },
    );

    try root.writeAll(root_template);
    root.close();

    const file = try std.fs.cwd().createFile(
        "test/dest-forward-forced/testfile1",
        .{ .read = true, .truncate = true },
    );

    try file.writeAll(
        \\# TEST
        \\Foo
        \\val="TEST"
        \\
    );

    file.close();

    const proc = try runner(&argv);

    const expected_render =
        \\# TEST
        \\Foo
        \\val="Bar"
        \\
    ;

    const render = try std.fs.cwd().openFile("test/dest-forward-forced/testfile1", .{});
    const render_content = try render.readToEndAlloc(
        std.testing.allocator,
        1024,
    );

    defer std.testing.allocator.free(render_content);

    defer {
        allocator.free(proc.out);
        allocator.free(proc.err);
    }

    defer std.fs.cwd().deleteTree("test/dest-forward-forced") catch unreachable;
    defer std.fs.cwd().deleteTree("test/root-forward-forced") catch unreachable;

    try std.testing.expectEqualStrings(expected_render, render_content);
    try std.testing.expectEqual(proc.term.Exited, 0);
}

test "sync-back-forced" {
    defer std.fs.cwd().deleteTree("test/dest-back-forced") catch unreachable;
    defer std.fs.cwd().deleteTree("test/root-back-forced") catch unreachable;

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
        \\{> end <}
        \\
    ;

    try std.fs.cwd().makeDir("test/root-back-forced");
    try std.fs.cwd().makeDir("test/dest-back-forced");

    const orig = try std.fs.cwd().createFile(
        "test/root-back-forced/testfile1",
        .{ .read = true },
    );

    try orig.writeAll(orig_template);
    orig.close();

    const file = try std.fs.cwd().createFile(
        "test/dest-back-forced/testfile1",
        .{ .read = true, .truncate = true },
    );

    try file.writeAll(
        \\# TEST
        \\Foo
        \\val="TEST"
        \\
    );

    file.close();

    const proc = try runner(&argv);

    const expected_template =
        \\# TEST
        \\Foo
        \\{> if SYSTEM.os == unsupported <}
        \\val="Foo"
        \\{> else <}
        \\val="TEST"
        \\{> end <}
        \\
    ;

    const template = try std.fs.cwd().openFile("test/root-back-forced/testfile1", .{});
    const template_content = try template.readToEndAlloc(
        std.testing.allocator,
        1024,
    );

    defer std.testing.allocator.free(template_content);

    defer {
        allocator.free(proc.out);
        allocator.free(proc.err);
    }

    defer std.fs.cwd().deleteTree("test/dest-back-forced") catch unreachable;
    defer std.fs.cwd().deleteTree("test/root-back-forced") catch unreachable;

    try std.testing.expectEqualStrings(expected_template, template_content);
    try std.testing.expectEqual(proc.term.Exited, 0);
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
        \\    .destination = "/tmp/test",
        \\    .logging = false,
        \\    .ignore_list = .{},
        \\}
        \\
        \\Exiting...
        \\
    ;

    const out = try stripAnsi(allocator, proc.out);

    defer {
        allocator.free(out);
        allocator.free(proc.out);
        allocator.free(proc.err);
    }

    try std.testing.expectStringEndsWith(proc.err, expected_err);
    try std.testing.expectEqual(proc.term.Exited, 1);
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
    ;

    const out = try stripAnsi(allocator, proc.out);

    defer {
        allocator.free(out);
        allocator.free(proc.out);
        allocator.free(proc.err);
    }

    try std.testing.expectStringEndsWith(proc.err, expected_err);
    try std.testing.expectEqual(proc.term.Exited, 1);
}

const std = @import("std");
const allocator = std.testing.allocator;

const build_options = @import("build_options");
const exe_path = build_options.exe_path;
