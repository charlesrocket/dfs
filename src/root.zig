fn evalCondition(cond: []const u8) bool {
    // split on any whitespace (handles multiple spaces/tabs)
    var parts: [3][]const u8 = undefined; // 3 parts: lhs, op, rhs
    var idx: usize = 0;

    var iter = std.mem.splitAny(u8, cond, " \t");
    while (true) {
        const part = iter.next();

        if (part == null) break;
        if (idx >= 3) return false;

        parts[idx] = part.?;
        idx += 1;
    }

    if (idx != 3) return false;

    const lhs = parts[0];
    const op = parts[1];
    const rhs = trimTag(parts[2]);

    if (std.mem.eql(u8, lhs, "SYSTEM.os")) {
        const sys = getSystem();

        if (std.mem.eql(u8, op, "==")) return std.mem.eql(u8, sys, rhs);
        if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, sys, rhs);
    }

    return false;
}

pub fn applyTemplate(
    allocator: std.mem.Allocator,
    template: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    var i: usize = 0;

    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], "{>")) {
            const start = i + 2;
            const rel_end = std.mem.indexOf(u8, template[start..], "<}") orelse
                return error.InvalidTemplate;

            var tag_trim = trimTag(template[start .. start + rel_end]);
            i = start + rel_end + 2;

            if (!std.mem.startsWith(u8, tag_trim, "if "))
                return error.InvalidTemplate;

            var branch_taken = false;
            var scan = i;

            while (true) {
                const next_open_opt = std.mem.indexOf(
                    u8,
                    template[scan..],
                    "{>",
                );
                const next_open = if (next_open_opt) |v|
                    scan + v
                else
                    template.len;

                var body = template[i..next_open];

                // trim leading newline after tag
                if (body.len > 0 and (body[0] == '\n' or body[0] == '\r')) {
                    body = body[1..];
                }

                // determine if branch is active
                var active: bool = false;
                if (std.mem.startsWith(u8, tag_trim, "if ")) {
                    active = evalCondition(tag_trim[3..]) and !branch_taken;
                } else if (std.mem.startsWith(u8, tag_trim, "elif ")) {
                    active = evalCondition(tag_trim[5..]) and !branch_taken;
                } else if (std.mem.eql(u8, tag_trim, "else")) {
                    active = !branch_taken;
                }

                if (active) {
                    branch_taken = true;
                    const body_trimmed = trimTrailingNewlines(body);
                    try out.appendSlice(body_trimmed);
                }

                if (next_open == template.len) break;

                const s = next_open + 2;
                const e = std.mem.indexOf(u8, template[s..], "<}") orelse
                    return error.InvalidTemplate;

                const next_tag = trimTag(template[s .. s + e]);

                if (std.mem.eql(u8, next_tag, "end")) {
                    i = s + e + 2;
                    break;
                }

                tag_trim = next_tag;
                i = s + e + 2;
                scan = i;
            }
        } else {
            const next_tag_opt = std.mem.indexOf(u8, template[i..], "{>");
            if (next_tag_opt) |off| {
                try out.appendSlice(template[i .. i + off]);
                i += off;
            } else {
                try out.appendSlice(template[i..]);
                break;
            }
        }
    }

    return out.toOwnedSlice();
}

pub fn reverseTemplate(
    allocator: std.mem.Allocator,
    rendered: []const u8,
    template: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    var i: usize = 0; // template index
    var r: usize = 0; // rendered index
    var branch_taken = false;

    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], "{>")) {
            // parse tag
            const start = i + 2;
            const rel_end = std.mem.indexOf(u8, template[start..], "<}") orelse
                return error.InvalidTemplate;

            const tag_slice = template[start .. start + rel_end];
            const tag_trim = trimTag(tag_slice);

            i = start + rel_end + 2;

            // copy tag literally
            try out.appendSlice("{>");
            try out.appendSlice(tag_slice);
            try out.appendSlice("<}");

            // find branch body boundaries
            const body_start = i;
            var depth: usize = 0;
            var body_end: usize = i;

            while (body_end < template.len) {
                if (std.mem.startsWith(u8, template[body_end..], "{>")) {
                    const s = body_end + 2;
                    const e = std.mem.indexOf(u8, template[s..], "<}") orelse
                        template.len;

                    const inner_tag = trimTag(template[s .. s + e]);

                    if (std.mem.startsWith(u8, inner_tag, "if ")) depth += 1;
                    if (std.mem.eql(u8, inner_tag, "end")) {
                        if (depth == 0) break;
                        depth -= 1;
                    }

                    if ((std.mem.startsWith(u8, inner_tag, "elif ") or
                        std.mem.eql(u8, inner_tag, "else")) and
                        depth == 0)
                    {
                        break;
                    }

                    body_end = s + e + 2;
                } else {
                    body_end += 1;
                }
            }

            const body = template[body_start..body_end];

            // check if branch is active
            var active: bool = false;
            if (std.mem.startsWith(u8, tag_trim, "if ")) {
                active = evalCondition(tag_trim[3..]) and !branch_taken;
            } else if (std.mem.startsWith(u8, tag_trim, "elif ")) {
                active = evalCondition(tag_trim[5..]) and !branch_taken;
            } else if (std.mem.eql(u8, tag_trim, "else")) {
                active = !branch_taken;
            }

            if (active) {
                branch_taken = true;

                // preserve leading newline(s) after the tag from template
                var body_offset: usize = 0;
                while (body_offset < body.len and (body[body_offset] == '\n' or
                    body[body_offset] == '\r'))
                {
                    try out.append(body[body_offset]);
                    body_offset += 1;
                }

                // append remaining user-edited rendered
                // content corresponding to this branch
                const remaining_len = rendered.len - r;
                try out.appendSlice(rendered[r .. r + remaining_len]);

                r += remaining_len;
            } else {
                // keep template body
                try out.appendSlice(body);
            }

            i = body_end;
        } else {
            // literal text outside template tags
            const next_tag_opt = std.mem.indexOf(u8, template[i..], "{>");
            const literal_end = if (next_tag_opt) |off|
                i + off
            else
                template.len;

            const literal_len = literal_end - i;

            if (r + literal_len <= rendered.len) {
                try out.appendSlice(rendered[r .. r + literal_len]);
                r += literal_len;
            } else {
                try out.appendSlice(rendered[r..]);
                r = rendered.len;
            }

            i = literal_end;
        }
    }

    // append any remaining rendered content
    if (r < rendered.len) {
        try out.appendSlice(rendered[r..]);
    }

    return out.toOwnedSlice();
}

fn getSystem() []const u8 {
    return @tagName(builtin.target.os.tag);
}

fn trimTag(tag: []const u8) []const u8 {
    return std.mem.trim(u8, tag, " \t\r\n");
}

fn trimTrailingNewlines(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0) : (end -= 1) {
        const c = s[end - 1];
        if (c != '\n' and c != '\r') break;
    }

    return s[0..end];
}

test "forward (fbsd)" {
    if (builtin.os.tag != .freebsd) return error.SkipZigTest;
    var gpa = std.testing.allocator;

    const template =
        \\{> if SYSTEM.os == linux <}
        \\val="Foo"
        \\{> elif SYSTEM.os == freebsd <}
        \\val="Bar"
        \\{> else <}
        \\val="Else"
        \\{> end <}
        \\
    ;

    const rendered_expected =
        \\val="Bar"
        \\
    ;

    const rendered = try applyTemplate(gpa, template);
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings(rendered_expected, rendered);
}

test "back-template (fbsd)" {
    if (builtin.os.tag != .freebsd) return error.SkipZigTest;
    var gpa = std.testing.allocator;

    const template =
        \\{> if SYSTEM.os == linux <}
        \\val="Foo"
        \\{> elif SYSTEM.os == freebsd <}
        \\val="Bar"
        \\{> else <}
        \\val="Else"
        \\{> end <}
        \\
    ;

    const rendered_user_edit =
        \\val="Zoot"
        \\
    ;

    const reversed = try reverseTemplate(gpa, rendered_user_edit, template);
    defer gpa.free(reversed);

    const expected_template =
        \\{> if SYSTEM.os == linux <}
        \\val="Foo"
        \\{> elif SYSTEM.os == freebsd <}
        \\val="Zoot"
        \\{> else <}
        \\val="Else"
        \\{> end <}
        \\
    ;
    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "back-no_template (fbsd)" {
    if (builtin.os.tag != .freebsd) return error.SkipZigTest;
    var gpa = std.testing.allocator;

    const template =
        \\FOO
        \\{> if SYSTEM.os == linux <}
        \\val="Foo"
        \\{> elif SYSTEM.os == freebsd <}
        \\val="Bar"
        \\{> else <}
        \\val="Else"
        \\{> end <}
        \\
    ;

    const rendered_user_edit =
        \\BAR
        \\val="Bar"
        \\
    ;

    const reversed = try reverseTemplate(gpa, rendered_user_edit, template);
    defer gpa.free(reversed);

    const expected_template =
        \\BAR
        \\{> if SYSTEM.os == linux <}
        \\val="Foo"
        \\{> elif SYSTEM.os == freebsd <}
        \\val="Bar"
        \\{> else <}
        \\val="Else"
        \\{> end <}
        \\
    ;
    try std.testing.expectEqualStrings(expected_template, reversed);
}

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
