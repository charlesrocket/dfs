pub const Replacement = struct {
    key: []const u8,
    value: []const u8,
};

pub fn reverseTemplate(
    allocator: std.mem.Allocator,
    rendered: []const u8,
    replacements: []const Replacement,
) ![]u8 {
    var stream = std.ArrayList(u8).init(allocator);
    defer stream.deinit();

    var i: usize = 0;
    while (i < rendered.len) {
        var matched = false;
        for (replacements) |rep| {
            if (std.mem.startsWith(u8, rendered[i..], rep.value)) {
                try stream.appendSlice("{>");
                try stream.appendSlice(rep.key);
                try stream.appendSlice("<}");
                i += rep.value.len;
                matched = true;

                break;
            }
        }

        if (!matched) {
            try stream.append(rendered[i]);
            i += 1;
        }
    }

    return stream.toOwnedSlice();
}

pub fn applyTemplate(
    allocator: std.mem.Allocator,
    template: []const u8,
    replacements: []const Replacement,
) ![]u8 {
    var stream = std.ArrayList(u8).init(allocator);
    defer stream.deinit();

    var i: usize = 0;
    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], "{>")) {
            const start = i + 2;
            const end = std.mem.indexOf(u8, template[start..], "<}") orelse {
                return error.InvalidTemplate;
            };

            const key = template[start .. start + end];
            i = start + end + 2;

            var replaced = false;
            for (replacements) |rep| {
                if (std.mem.eql(u8, rep.key, key)) {
                    try stream.appendSlice(rep.value);
                    replaced = true;
                    break;
                }
            }

            if (!replaced) {
                try stream.appendSlice("{{");
                try stream.appendSlice(key);
                try stream.appendSlice("}}");
            }
        } else {
            try stream.append(template[i]);
            i += 1;
        }
    }

    return stream.toOwnedSlice();
}

const std = @import("std");
const testing = std.testing;
