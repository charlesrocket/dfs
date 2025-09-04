const Token = union(enum) {
    text: []const u8,
    tag: []const u8,
};

fn tokenize(template: []const u8, allocator: std.mem.Allocator) ![]Token {
    var tokens = std.ArrayList(Token).init(allocator);
    errdefer tokens.deinit();

    var i: usize = 0;
    while (i < template.len) {
        const start_tag = std.mem.indexOfPos(u8, template, i, "{>");
        if (start_tag == null) {
            try tokens.append(.{ .text = template[i..] });
            break;
        }

        const tag_start = start_tag.?;

        // push preceding text if any
        if (tag_start > i) {
            try tokens.append(.{ .text = template[i..tag_start] });
        }

        const end_tag = std.mem.indexOfPos(
            u8,
            template,
            tag_start + 2,
            "<}",
        ) orelse
            return error.InvalidTemplate;

        const raw_tag = template[tag_start + 2 .. end_tag];
        try tokens.append(.{ .tag = trimTag(raw_tag) });

        i = end_tag + 2;
    }

    return try tokens.toOwnedSlice();
}

fn interpret(tokens: []Token, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    var w = out.writer();

    var i: usize = 0;
    while (i < tokens.len) {
        switch (tokens[i]) {
            .text => |t| {
                try w.print("{s}", .{t});
                i += 1;
            },
            .tag => |tag| {
                if (std.mem.startsWith(u8, tag, "if ")) {
                    i = try evalIfGroup(tokens, i, &w);
                } else {
                    // outside of an if-group tags are not allowed
                    return error.InvalidTemplate;
                }
            },
        }
    }
    return out.toOwnedSlice();
}

fn evalIfBlock(
    tokens: []Token,
    start: usize,
    branch_taken: *bool,
    w: anytype,
) !usize {
    var i = start;

    while (i < tokens.len) {
        switch (tokens[i]) {
            .text => |body| {
                if (branch_taken.*) {
                    // trim trailing newlines if needed
                    try w.print("{s}", .{trimTrailingNewlines(body)});
                }

                i += 1;
            },
            .tag => |tag| {
                if (std.mem.startsWith(u8, tag, "if ")) {
                    const cond = evalCondition(tag[3..]);
                    if (cond and !branch_taken.*) branch_taken.* = true;
                    i += 1;
                } else if (std.mem.startsWith(u8, tag, "elif ")) {
                    const cond = evalCondition(tag[5..]);
                    if (cond and !branch_taken.*) branch_taken.* = true;
                    i += 1;
                } else if (std.mem.eql(u8, tag, "else")) {
                    if (!branch_taken.*) branch_taken.* = true;
                    i += 1;
                } else if (std.mem.eql(u8, tag, "end")) {
                    return i + 1; // exit block
                } else {
                    return error.InvalidTemplate;
                }
            },
        }
    }

    return error.MissingEnd;
}

fn evalIfGroup(tokens: []Token, start: usize, w: anytype) !usize {
    if (start >= tokens.len) return error.InvalidTemplate;

    var i: usize = start;
    var branch_taken: bool = false;

    while (i < tokens.len) {
        // ensure current token is a tag
        const cur_tag = switch (tokens[i]) {
            .tag => |t| t,
            else => return error.InvalidTemplate,
        };

        var active: bool = false;

        // decide whether this branch is active
        if (std.mem.startsWith(u8, cur_tag, "if ")) {
            active = evalCondition(cur_tag[3..]) and !branch_taken;
        } else if (std.mem.startsWith(u8, cur_tag, "elif ")) {
            active = evalCondition(cur_tag[5..]) and !branch_taken;
        } else if (std.mem.eql(u8, cur_tag, "else")) {
            active = !branch_taken;
        } else if (std.mem.eql(u8, cur_tag, "end")) {
            // consume the 'end' tag and return index after it
            return i + 1;
        } else {
            return error.InvalidTemplate;
        }

        // check if there is a following text token (the body for this control)
        var had_body: bool = false;
        var body: []const u8 = &[_]u8{}; //empty

        if (i + 1 < tokens.len) {
            switch (tokens[i + 1]) {
                .text => |t| {
                    had_body = true;
                    body = t;
                    // trim exactly one leading newline after the control tag
                    if (body.len > 0 and (body[0] == '\n' or body[0] == '\r')) {
                        body = body[1..];
                    }
                },
                else => {},
            }
        }

        if (active) {
            branch_taken = true;
            const trimmed = trimTrailingNewlines(body);
            try w.print("{s}", .{trimmed});
        }

        // compute increment and ensure we don't step past tokens.len
        const inc: usize = if (had_body) 2 else 1;
        // check that i + inc does not overflow and that it is <= tokens.len
        if (inc > tokens.len - i) {
            // past end of the token stream
            return error.InvalidTemplate;
        }
        i += inc;

        // next token is `end`, consume it and return
        if (i < tokens.len) {
            switch (tokens[i]) {
                .tag => |t2| {
                    if (std.mem.eql(u8, t2, "end")) {
                        // i < tokens.len here
                        return i + 1;
                    }
                    // or continue loop to handle next elif/else
                },
                else => {
                    // according to our grammar, after a control+body we
                    // expect the next token to be another control tag or end
                    // (text tokens are invalid here)
                    return error.InvalidTemplate;
                },
            }
        } else {
            // reached end of tokens without an `end` tag
            return error.InvalidTemplate;
        }
    }

    // missing end
    return error.invalidTemplate;
}

fn evalCondition(cond: []const u8) bool {
    // split on any whitespace (handles multiple spaces/tabs)
    var parts: [3][]const u8 = undefined; // 3 parts: lhs, op, rhs
    var i: usize = 0;

    var iter = std.mem.splitAny(u8, cond, " \t");
    while (true) {
        const part = iter.next();

        if (part == null) break;
        if (i >= 3) return false;

        parts[i] = part.?;
        i += 1;
    }

    if (i != 3) return false;

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
    const tokens = try tokenize(template, allocator);
    defer allocator.free(tokens);

    return try interpret(tokens, allocator);
}

pub fn reverseTemplate(
    allocator: std.mem.Allocator,
    rendered: []const u8,
    template: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    var tpl_i: usize = 0; // template index
    var rnd_i: usize = 0; // rendered index

    const tpl_len = template.len;
    const rnd_len = rendered.len;

    var branch_taken = false;

    while (tpl_i < tpl_len) {
        if (std.mem.startsWith(u8, template[tpl_i..], "{>")) {
            const start = tpl_i + 2;
            const rel_end = std.mem.indexOf(u8, template[start..], "<}") orelse
                return error.InvalidTemplate;

            const tag_slice = template[start .. start + rel_end];
            const tag_trim = trimTag(tag_slice);

            tpl_i = start + rel_end + 2;

            if (std.mem.startsWith(u8, tag_trim, "if ")) branch_taken = false;

            try out.appendSlice("{>");
            try out.appendSlice(tag_slice);
            try out.appendSlice("<}");

            const body_start = tpl_i;
            var depth: usize = 0;
            var body_end = tpl_i;

            while (body_end < tpl_len) {
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

            var active = false;
            if (std.mem.startsWith(u8, tag_trim, "if ")) {
                active = evalCondition(tag_trim[3..]) and !branch_taken;
            } else if (std.mem.startsWith(u8, tag_trim, "elif ")) {
                active = evalCondition(tag_trim[5..]) and !branch_taken;
            } else if (std.mem.eql(u8, tag_trim, "else")) {
                active = !branch_taken;
            }

            if (active) {
                branch_taken = true;

                // find anchor literal after this block
                var scan = body_end;
                var depth2: usize = 0;
                var anchor_start = tpl_len;
                while (scan < tpl_len) {
                    if (std.mem.startsWith(u8, template[scan..], "{>")) {
                        const s2 = scan + 2;
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
                                anchor_start = s2 + e2 + 2;
                                break;
                            }
                            depth2 -= 1;
                        }

                        scan = s2 + e2 + 2;
                    } else scan += 1;
                }

                const next_tag_off = std.mem.indexOf(
                    u8,
                    template[anchor_start..],
                    "{>",
                );

                const anchor_end = if (next_tag_off) |off|
                    anchor_start + off
                else
                    tpl_len;

                const anchor_lit = template[anchor_start..anchor_end];
                var user_end = rnd_len;

                if (anchor_lit.len > 0) {
                    if (std.mem.indexOf(u8, rendered[rnd_i..], anchor_lit)) |pos| {
                        user_end = rnd_i + pos;
                    }
                }

                const user_chunk = rendered[rnd_i..user_end];

                // preserve leading/trailing template whitespace
                var lead: usize = 0;
                while (lead < body.len and
                    (body[lead] == '\n' or
                        body[lead] == '\r'))
                    lead += 1;

                var trail: usize = 0;
                while (trail < body.len - lead and
                    (body[body.len - 1 - trail] == '\n' or
                        body[body.len - 1 - trail] == '\r'))
                    trail += 1;

                if (lead > 0) try out.appendSlice(body[0..lead]);
                try out.appendSlice(user_chunk);
                if (trail > 0) try out.appendSlice(body[body.len - trail ..]);

                rnd_i = user_end;
            } else {
                try out.appendSlice(body); // inactive branch verbatim
            }

            tpl_i = body_end;
        } else {
            const next_tag_off = std.mem.indexOf(u8, template[tpl_i..], "{>");
            const literal_end = if (next_tag_off) |off| tpl_i + off else tpl_len;
            const literal_len = literal_end - tpl_i;
            const render_end = if (rnd_i + literal_len <= rnd_len)
                rnd_i + literal_len
            else
                rnd_len;

            try out.appendSlice(rendered[rnd_i..render_end]);

            rnd_i = render_end;
            tpl_i = literal_end;
        }
    }

    if (rnd_i < rnd_len) try out.appendSlice(rendered[rnd_i..]);

    const result = try out.toOwnedSlice();

    // normalize trailing CR/LF
    var tmpl_trail: usize = 0;
    var jj: usize = tpl_len;
    while (jj > 0 and (template[jj - 1] == '\n' or
        template[jj - 1] == '\r')) : (jj -= 1) tmpl_trail += 1;

    var res_trail: usize = 0;
    var kk: usize = result.len;
    while (kk > 0 and (result[kk - 1] == '\n' or
        result[kk - 1] == '\r')) : (kk -= 1) res_trail += 1;

    if (res_trail == tmpl_trail) return result;

    const core_len = result.len - res_trail;
    const new_len = core_len + tmpl_trail;
    const new_slice = try allocator.alloc(u8, new_len);

    @memcpy(new_slice[0..core_len], result[0..core_len]);

    if (tmpl_trail > 0) @memcpy(
        new_slice[core_len..],
        template[tpl_len - tmpl_trail .. tpl_len],
    );

    allocator.free(result);

    return new_slice;
}

fn getSystem() []const u8 {
    return @tagName(builtin.target.os.tag);
}

fn splitWhitespace(s: []const u8) struct { lead: usize, trail: usize } {
    var lead: usize = 0;
    var trail: usize = 0;

    // count leading whitespace
    while (lead < s.len and (s[lead] == ' ' or s[lead] == '\t')) : (lead += 1) {}

    // count trailing whitespace
    var j = s.len;
    while (j > lead and (s[j - 1] == ' ' or s[j - 1] == '\t')) : (j -= 1) {}

    trail = s.len - j;

    return .{ .lead = lead, .trail = trail };
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
