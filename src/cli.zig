pub const CommandT = cova.Command.Custom(.{
    .global_help_prefix = assets.help_prefix,
    .help_header_fmt = assets.help_message,
    .help_category_order = &.{
        .Prefix, .Header, .Aliases, .Examples, .Commands, .Options, .Values,
    },
    .examples_header_fmt = assets.examples_header,
    .global_usage_fn = struct {
        fn usage(self: anytype, writer: anytype, _: ?std.mem.Allocator) !void {
            const CmdT = @TypeOf(self.*);
            const OptT = CmdT.OptionT;
            const indent_fmt = CmdT.indent_fmt;
            var no_args = true;
            var pre_sep: []const u8 = "";

            try writer.print("{s}{s}USAGE:\n", .{ assets.help_prefix, "\n" });
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
        .custom_types = &.{},
    },
});

const ValueT = CommandT.ValueT;

pub const setup_cmd: CommandT = .{
    .name = "dfs",
    .description = "Dotfiles manager",
    .examples = &.{
        "dfs",
    },
    .sub_cmds_mandatory = true,
    .sub_cmds = &.{
        .{
            .name = "version",
            .description = "Show the 'dfs' version.",
        },
        .{
            .name = "init",
            .description = "Initialize the configuration.",
        },
        .{
            .name = "sync",
            .description = "Run synchronization.",
            .opts = &.{
                .{
                    .name = "dry",
                    .description = "Preview changes without writing any files.",
                    .long_name = "dry",
                },
            },
        },
    },
    .opts = &.{
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
            .name = "destination",
            .description = "Override the destination directory.",
            .short_name = 'd',
            .long_name = "destination",
            .val = ValueT.ofType([]const u8, .{
                .name = "string",
                .alias_child_type = "path",
            }),
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

const main = @import("main.zig");
const std = @import("std");

const cova = @import("cova");
const assets = @import("assets.zig");
