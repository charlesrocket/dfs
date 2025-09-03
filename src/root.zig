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

                // trim exactly one leading newline after any control tag
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

            // reset branch_taken at the start of each if-block
            if (std.mem.startsWith(u8, tag_trim, "if ")) {
                branch_taken = false;
            }

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
                        return error.InvalidTemplate;

                    const inner_tag = trimTag(template[s .. s + e]);

                    if (std.mem.startsWith(u8, inner_tag, "if ")) {
                        depth += 1;
                    } else if (std.mem.eql(u8, inner_tag, "end")) {
                        if (depth == 0) break;
                        depth -= 1;
                    } else if ((std.mem.startsWith(u8, inner_tag, "elif ") or
                        std.mem.eql(u8, inner_tag, "else")) and depth == 0)
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

                // find the end of this entire if...end block
                // to locate the anchor literal after it
                var scan2 = body_end;
                var depth2: usize = 0;
                var after_end: usize = template.len;

                while (scan2 < template.len) {
                    if (std.mem.startsWith(u8, template[scan2..], "{>")) {
                        const s2 = scan2 + 2;
                        const e2 = std.mem.indexOf(
                            u8,
                            template[s2..],
                            "<}",
                        ) orelse
                            return error.InvalidTemplate;

                        const t2 = trimTag(template[s2 .. s2 + e2]);

                        if (std.mem.startsWith(u8, t2, "if ")) {
                            depth2 += 1;
                        } else if (std.mem.eql(u8, t2, "end")) {
                            if (depth2 == 0) {
                                // right after "<}" of end
                                after_end = s2 + e2 + 2;
                                break;
                            }
                            depth2 -= 1;
                        }

                        scan2 = s2 + e2 + 2;
                    } else {
                        scan2 += 1;
                    }
                }

                const anchor_start = after_end;
                const next_tag_off = std.mem.indexOf(
                    u8,
                    template[anchor_start..],
                    "{>",
                );

                const anchor_end = if (next_tag_off) |off|
                    anchor_start + off
                else
                    template.len;

                const anchor_lit = template[anchor_start..anchor_end];

                // find user chunk in rendered by
                // searching for the anchor literal (if any)
                var user_end = rendered.len;
                if (anchor_lit.len > 0) {
                    if (std.mem.indexOf(u8, rendered[r..], anchor_lit)) |pos| {
                        user_end = r + pos;
                    }
                }
                var user_chunk = rendered[r..user_end];

                // the forward pass trimmed trailing newlines from bodies
                // so trim them here from user content
                var user_trim_end = user_chunk.len;
                while (user_trim_end > 0 and
                    (user_chunk[user_trim_end - 1] == '\n' or
                        user_chunk[user_trim_end - 1] == '\r'))
                {
                    user_trim_end -= 1;
                }

                // preserve template's leading/trailing newlines around the body
                var lead: usize = 0;
                while (lead < body.len and
                    (body[lead] == '\n' or
                        body[lead] == '\r'))
                    lead += 1;

                var trail: usize = 0;
                while (trail < body.len - lead and
                    (body[body.len - 1 - trail] == '\n' or
                        body[body.len - 1 - trail] == '\r'))
                {
                    trail += 1;
                }

                // original leading newlines
                try out.appendSlice(body[0..lead]);
                // user content (no trailing NLs)
                try out.appendSlice(user_chunk[0..user_trim_end]);
                // original trailing newlines
                if (trail > 0)
                    try out.appendSlice(body[body.len - trail .. body.len]);

                // advance rendered cursor to the consumed user chunk
                r = user_end;
            } else {
                // non-active branch: keep template body verbatim
                try out.appendSlice(body);
            }

            i = body_end;
        } else {
            // literal text outside template tags
            // copy corresponding rendered bytes (if present)
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

    // normalize final trailing CR/LF sequence to
    // exactly match template's trailing CR/LF sequence
    var result = try out.toOwnedSlice();

    var tmpl_trail: usize = 0;
    var jj: usize = template.len;
    while (jj > 0 and
        (template[jj - 1] == '\n' or
            template[jj - 1] == '\r')) : (jj -= 1)
    {
        tmpl_trail += 1;
    }

    var res_trail: usize = 0;
    var kk: usize = result.len;
    while (kk > 0 and
        (result[kk - 1] == '\n' or
            result[kk - 1] == '\r')) : (kk -= 1)
    {
        res_trail += 1;
    }

    if (res_trail == tmpl_trail) {
        return result;
    }

    const core_len = result.len - res_trail;
    const new_len = core_len + tmpl_trail;
    const new_slice = try allocator.alloc(u8, new_len);
    @memcpy(new_slice[0..core_len], result[0..core_len]);

    if (tmpl_trail > 0) {
        @memcpy(
            new_slice[core_len..new_len],
            template[template.len - tmpl_trail .. template.len],
        );
    }

    allocator.free(result);

    return new_slice;
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

test "forward-inline (fbsd)" {
    if (builtin.os.tag != .freebsd) return error.SkipZigTest;
    var gpa = std.testing.allocator;

    const template =
        \\{> if SYSTEM.os == linux <}val="Foo"{> elif SYSTEM.os == freebsd <}val="Bar"{> else <}val="Else"{> end <}
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

test "forward (linux)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
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
        \\val="Foo"
        \\
    ;

    const rendered = try applyTemplate(gpa, template);
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings(rendered_expected, rendered);
}

test "forward-inline (linux)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var gpa = std.testing.allocator;

    const template =
        \\{> if SYSTEM.os == linux <}val="Foo"{> elif SYSTEM.os == freebsd <}val="Bar"{> else <}val="Else"{> end <}
        \\
    ;

    const rendered_expected =
        \\val="Foo"
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

test "back-template (linux)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
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
        \\val="Zoot"
        \\{> elif SYSTEM.os == freebsd <}
        \\val="Bar"
        \\{> else <}
        \\val="Else"
        \\{> end <}
        \\
    ;
    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "back-no_template (linux)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
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
        \\val="Bar"
        \\{> elif SYSTEM.os == freebsd <}
        \\val="Bar"
        \\{> else <}
        \\val="Else"
        \\{> end <}
        \\
    ;
    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "mixed (fbsd)" {
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
        \\val="Zoot"
        \\
    ;

    const reversed = try reverseTemplate(gpa, rendered_user_edit, template);
    defer gpa.free(reversed);

    const expected_template =
        \\BAR
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

test "mixed (linux)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
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
        \\val="Zoot"
        \\
    ;

    const reversed = try reverseTemplate(gpa, rendered_user_edit, template);
    defer gpa.free(reversed);

    const expected_template =
        \\BAR
        \\{> if SYSTEM.os == linux <}
        \\val="Zoot"
        \\{> elif SYSTEM.os == freebsd <}
        \\val="Bar"
        \\{> else <}
        \\val="Else"
        \\{> end <}
        \\
    ;
    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "mixed-inlie (fbsd)" {
    if (builtin.os.tag != .freebsd) return error.SkipZigTest;
    var gpa = std.testing.allocator;

    const template =
        \\FOO
        \\{> if SYSTEM.os == linux <}val="Foo"{> elif SYSTEM.os == freebsd <}val="Bar"{> else <}val="Else"{> end <}
        \\
    ;

    const rendered_user_edit =
        \\BAR
        \\val="Zoot"
        \\
    ;

    const reversed = try reverseTemplate(gpa, rendered_user_edit, template);
    defer gpa.free(reversed);

    const expected_template =
        \\BAR
        \\{> if SYSTEM.os == linux <}val="Foo"{> elif SYSTEM.os == freebsd <}val="Zoot"{> else <}val="Else"{> end <}
        \\
    ;
    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "mixed-inlie (linux)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var gpa = std.testing.allocator;

    const template =
        \\FOO
        \\{> if SYSTEM.os == linux <}val="Foo"{> elif SYSTEM.os == freebsd <}val="Bar"{> else <}val="Else"{> end <}
        \\
    ;

    const rendered_user_edit =
        \\BAR
        \\val="Zoot"
        \\
    ;

    const reversed = try reverseTemplate(gpa, rendered_user_edit, template);
    defer gpa.free(reversed);

    const expected_template =
        \\BAR
        \\{> if SYSTEM.os == linux <}val="Zoot"{> elif SYSTEM.os == freebsd <}val="Bar"{> else <}val="Else"{> end <}
        \\
    ;
    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "mixed-else" {
    var gpa = std.testing.allocator;

    const template =
        \\FOO
        \\{> if SYSTEM.os == openbsd <}
        \\val="Foo"
        \\{> elif SYSTEM.os == netbsd <}
        \\val="Bar"
        \\{> else <}
        \\val="Else"
        \\{> end <}
        \\
    ;

    const rendered_user_edit =
        \\BAR
        \\val="Zoot"
        \\
    ;

    const reversed = try reverseTemplate(gpa, rendered_user_edit, template);
    defer gpa.free(reversed);

    const expected_template =
        \\BAR
        \\{> if SYSTEM.os == openbsd <}
        \\val="Foo"
        \\{> elif SYSTEM.os == netbsd <}
        \\val="Bar"
        \\{> else <}
        \\val="Zoot"
        \\{> end <}
        \\
    ;
    try std.testing.expectEqualStrings(expected_template, reversed);
}

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
