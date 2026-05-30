pub const UserInput = enum {
    Url,
    Source,
    Destination,
};

pub const Direction = enum {
    forward,
    back,
    dual,
};

// ANSI codes
pub const reset = "\x1b[0m";
pub const reverse = "\x1b[7m";
pub const bold = "\x1b[1m";
pub const underline = "\x1b[4m";
pub const italic = "\x1b[3m";
pub const blink = "\x1b[5m";
pub const red = "\x1b[31m";
pub const green = "\x1b[32m";
pub const blue = "\x1b[34m";
pub const yellow = "\x1b[33m";
pub const magenta = "\x1b[35m";

pub const CommandT = cova.Command.Custom(.{
    .global_help_prefix = assets.help_prefix,
    .help_header_fmt = assets.help_message,
    .examples_header_fmt = assets.examples_header,
    .help_category_order = &.{
        .prefix,
        .header,
        .aliases,
        .examples,
        .commands,
        .options,
        .values,
    },
    .global_usage_fn = struct {
        fn usage(self: anytype, writer: anytype, _: ?std.mem.Allocator) !void {
            const CmdT = @TypeOf(self.*);
            const OptT = CmdT.OptionT;
            const indent_fmt = CmdT.indent_fmt;
            var no_args = true;
            var pre_sep: []const u8 = "";

            if (self.opts) |opts| {
                no_args = false;
                try writer.print("{s}{s} [", .{
                    indent_fmt,
                    self.name,
                });

                for (opts) |opt| {
                    try writer.print("{s} {s}{s} <{s}>", .{
                        pre_sep,
                        OptT.long_prefix orelse opt.short_prefix,
                        opt.long_name orelse &.{opt.short_name orelse 0},
                        opt.val.childTypeName(),
                    });

                    pre_sep = "\n  " ++ indent_fmt ++ indent_fmt;
                }

                try writer.print(" ]\n\n", .{});
            }

            if (self.sub_cmds) |cmds| {
                no_args = false;
                try writer.print("{s}{s} [", .{
                    indent_fmt,
                    self.name,
                });

                pre_sep = "";

                for (cmds) |cmd| {
                    try writer.print("{s} {s} ", .{
                        pre_sep,
                        cmd.name,
                    });
                    pre_sep = "|";
                }

                try writer.print("]\n\n", .{});
            }

            if (no_args) try writer.print("{s}{s}{s}", .{
                indent_fmt,
                indent_fmt,
                self.name,
            });
        }
    }.usage,
    .opt_config = .{
        .usage_fmt = assets.opt_usage,
        .name_sep_fmt = ", ",
    },
    .val_config = .{
        .custom_types = &.{
            Direction,
        },
    },
});

const ValueT = CommandT.ValueT;

pub const setup_cmd: CommandT = .{
    .name = "dfs",
    .description =
    \\A configuration (dotfiles) manager with a template engine and
    \\    a true 2-way synchronization. The deployed layout recreates the
    \\    source completely (except assets in the ignore list). So it is
    \\    recommended to structure the source repository as a $HOME mirror.
    \\
    \\    TEMPLATE SYNTAX:
    \\
    \\
    ++ Syntax.getSyntax(CommandT.indent_fmt),
    .examples = &.{
        "dfs init -h",
    },
    .sub_cmds_mandatory = true,
    .sub_cmds = &.{
        .{
            .name = "version",
            .description = "Show the 'dfs' version.",
        },
        .{
            .name = "init",
            .description = "Initialize the configuration (requires git).",
            .sub_cmds_mandatory = false,
            .sub_cmds = &.{
                .{
                    .name = "bootstrap",
                    .description = "Download and deploy an external config file.",
                    .examples = &.{
                        "dfs init bootstrap https://example.com/git/dotfiles/.config/dfs/config.zon",
                    },
                    .vals = &.{
                        ValueT.ofType([]const u8, .{
                            .name = "config",
                            .alias_child_type = "URL",
                        }),
                    },
                },
            },
        },
        .{
            .name = "sync",
            .description = "Run synchronization.",
            .sub_cmds_mandatory = false,
            .opts = &.{
                .{
                    .name = "dry",
                    .description = "Preview changes without writing any files.",
                    .long_name = "dry",
                },
                .{
                    .name = "direction",
                    .description = "Set the direction of the synchronization " ++ genVals(Direction, 2) ++ ".",
                    .short_name = 'd',
                    .long_name = "direction",
                    .val = ValueT.ofType(Direction, .{
                        .name = "direction_val",
                        .default_val = Direction.dual,
                        .alias_child_type = "string",
                    }),
                },
                .{
                    .name = "verbose",
                    .description = "Verbose mode.",
                    .long_name = "verbose",
                },
            },
        },
        .{
            .name = "validate",
            .description = "Run template validation.",
        },
        .{
            .name = "daemon",
            .description = "Start the daemon.",
        },
        .{
            .name = "purge",
            .description = "Delete application data (meta, backups, logs).",
        },
    },
    .opts = &.{
        .{
            .name = "config",
            .description = "Configuration path.",
            .short_name = 'c',
            .long_name = "config",
            .val = ValueT.ofType([]const u8, .{
                .name = "string",
                .alias_child_type = "path",
            }),
        },
        .{
            .name = "source",
            .description = "Override the source directory.",
            .short_name = 's',
            .long_name = "source",
            .val = ValueT.ofType([]const u8, .{
                .name = "string",
                .alias_child_type = "path",
            }),
        },
        .{
            .name = "target",
            .description = "Override the target directory.",
            .short_name = 't',
            .long_name = "target",
            .alias_long_names = &.{"destination"},
            .val = ValueT.ofType([]const u8, .{
                .name = "string",
                .alias_child_type = "path",
            }),
        },
        .{
            .name = "notifications",
            .description = "Show desktop notifications.",
            .short_name = 'n',
            .long_name = "notifications",
        },
        .{
            .name = "json",
            .description = "Output JSON status string.",
            .long_name = "json",
        },
    },
};

fn genVals(T: type, default: ?usize) []const u8 {
    return blk: {
        var str: []const u8 = "(";
        const vals = std.meta.fieldNames(T);

        for (vals, 0..) |val, i| {
            str = if (default != null and default == i) dflt: {
                break :dflt str ++ "*" ++ val;
            } else str ++ val;

            if (i < vals.len - 1) {
                str = str ++ ", ";
            }
        }

        str = str ++ ")";
        break :blk str;
    };
}

pub fn getUserInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    input: UserInput,
) !std.ArrayList(u8) {
    var stdin_buffer: [2048]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    var buf: [2048]u8 = undefined;
    var list = std.ArrayList(u8).empty;

    try stdout.print("Enter {s}: ", .{
        switch (input) {
            .Url => "repository URL",
            .Source => "repository destination",
            .Destination => "destination",
        },
    });

    try stdout.flush();

    var writer = std.Io.Writer.fixed(&buf);
    const len = try stdin.streamDelimiter(&writer, '\n');

    try list.appendSlice(allocator, buf[0..len]);
    return list;
}

pub fn sendNotification(
    io: std.Io,
    summary: []const u8,
    body: []const u8,
    urgency: []const u8,
) void {
    const args = [7][]const u8{
        "notify-send",
        summary,
        body,
        "-u",
        urgency,
        "-a",
        "dfs",
    };

    var proc = std.process.spawn(io, .{ .argv = &args }) catch return;
    _ = proc.wait(io) catch {};
}

const main = @import("main.zig");
const Syntax = @import("syntax.zig");
const std = @import("std");
const cova = @import("cova");
const assets = @import("assets.zig");
