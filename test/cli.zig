const Proc = struct {
    term: std.process.Child.Term,
    out: []u8,
    err: []u8,
};

fn runner(args: []const []const u8) !Proc {
    var proc = std.process.Child.init(args, allocator);

    proc.stdout_behavior = .Pipe;
    proc.stderr_behavior = .Pipe;

    var stdout: std.ArrayListAlignedUnmanaged(u8, 1) = .empty;
    var stderr: std.ArrayListAlignedUnmanaged(u8, 1) = .empty;
    defer {
        stdout.deinit(allocator);
        stderr.deinit(allocator);
    }

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
    const argv = [3][]const u8{
        exe_path,
        "-c=test/conf.zon",
        "sync",
    };

    const proc = try runner(&argv);

    const expected_conf =
        \\____________ _____
        \\|  _  \  ___/  ___|
        \\| | | | |_  \ `--.
        \\| | | |  _|  `--. \
        \\| |/ /| |   /\__/ /
        \\|___/ \_|   \____/
        \\
        \\SYNC STARTED
        \\PROCESSED FILES: 3
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

    try std.testing.expectEqualStrings(expected_conf, out);
    try std.testing.expectEqual(proc.term.Exited, 0);
}

test "sync-dry" {
    const argv = [4][]const u8{
        exe_path,
        "-c=test/conf.zon",
        "sync",
        "--dry",
    };

    const proc = try runner(&argv);

    const expected_conf =
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
        \\FILE | test/dest/testfile1
        \\DATA | render:
        \\
        \\# TEST
        \\Foo
        \\val="Bar"
        \\
        \\--- --- ---
        \\
        \\ERROR | test/dest/testfile-invalid
        \\FILE | test/root/test.png >>> test/dest/test.png
        \\PROCESSED FILES: 3
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

    try std.testing.expectEqualStrings(expected_conf, out);
    try std.testing.expectEqual(proc.term.Exited, 0);
}

test "sync-back" {
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

    std.time.sleep(1000000000);

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
        \\    .source = "/tmp/src/dotfiles",
        \\    .destination = "/tmp/test",
        \\    .ignore_list = .{},
        \\}
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
