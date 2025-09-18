//! LIBDFS
//!
//! Dfs is a template engine with reverse translation.

// {> x <}
const TAG_START = "{>";
const TAG_END = "<}";

const Token = union(enum) {
    text: []const u8,
    tag: []const u8,
};

const Tag = struct {
    raw: []const u8,
    trim: []const u8,
    after: usize,
};

const Body = struct {
    slice: []const u8,
    after: usize,
};

const Chunk = struct {
    slice: []const u8,
    end: usize,
};

fn tokenize(allocator: std.mem.Allocator, template: []const u8) ![]Token {
    var tokens = std.ArrayList(Token).init(allocator);
    errdefer tokens.deinit();

    var i: usize = 0;

    while (i < template.len) {
        const start_tag = std.mem.indexOfPos(u8, template, i, TAG_START);

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
            TAG_END,
        ) orelse
            return error.InvalidTemplate;

        const raw_tag = template[tag_start + 2 .. end_tag];
        try tokens.append(.{ .tag = trimTag(raw_tag) });

        i = end_tag + 2;
    }

    return try tokens.toOwnedSlice();
}

fn interpret(allocator: std.mem.Allocator, tokens: []Token) ![]u8 {
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
                if (std.mem.startsWith(u8, tag, "if")) {
                    i = try evalIfGroup(allocator, tokens, i, &w);
                } else {
                    // outside of an if-group tags are not allowed
                    return error.InvalidTemplateGroup;
                }
            },
        }
    }

    return out.toOwnedSlice();
}

fn indexOfTag(s: []const u8, start: usize) ?usize {
    if (std.mem.indexOf(u8, s[start..], TAG_START)) |pos| {
        return start + pos;
    }

    return null;
}

fn countTrail(s: []const u8) usize {
    var i: usize = s.len;
    while (i > 0 and (s[i - 1] == '\n' or s[i - 1] == '\r')) : (i -= 1) {}

    return s.len - i;
}

fn parseTag(template: []const u8, i: usize) !Tag {
    const start = i + 2;
    const rel_end = std.mem.indexOf(u8, template[start..], TAG_END) orelse
        return error.InvalidTemplateEndTag;

    const raw = template[start .. start + rel_end];

    return Tag{
        .raw = raw,
        .trim = trimTag(raw),
        .after = start + rel_end + 2,
    };
}

fn parseBody(template: []const u8, start: usize) !Body {
    const tpl_len = template.len;
    var i = start;
    var depth: usize = 0;

    while (i < tpl_len) {
        if (std.mem.startsWith(u8, template[i..], TAG_START)) {
            const t = try parseTag(template, i);

            if (std.mem.startsWith(u8, t.trim, "if")) {
                depth += 1;
            } else if (std.mem.eql(u8, t.trim, "end")) {
                if (depth == 0) break;
                depth -= 1;
            } else if ((std.mem.startsWith(u8, t.trim, "elif") or
                std.mem.eql(u8, t.trim, "else")) and depth == 0)
            {
                break;
            }

            i = t.after;
        } else i += 1;
    }

    return Body{ .slice = template[start..i], .after = i };
}

fn nextTag(template: []const u8, start: usize) ?usize {
    if (std.mem.indexOf(u8, template[start..], TAG_START)) |pos| {
        return start + pos;
    } else {
        return null;
    }
}

fn findAnchorLiteral(
    template: []const u8,
    body_end: usize,
) ![]const u8 {
    const tpl_len = template.len;
    var scan = body_end;
    var depth: usize = 0;
    var anchor_start: usize = tpl_len;

    while (scan < tpl_len) {
        if (std.mem.startsWith(u8, template[scan..], TAG_START)) {
            const s2 = scan + 2;
            const e2 = std.mem.indexOf(u8, template[s2..], TAG_END) orelse
                return error.InvalidTemplateEndTag;

            const t2 = trimTag(template[s2 .. s2 + e2]);

            if (std.mem.startsWith(u8, t2, "if")) {
                depth += 1;
            } else if (std.mem.eql(u8, t2, "end")) {
                if (depth == 0) {
                    anchor_start = s2 + e2 + 2;
                    break;
                }
                depth -= 1;
            }

            scan = s2 + e2 + 2;
        } else scan += 1;
    }

    if (anchor_start >= tpl_len) return template[tpl_len..tpl_len];
    if (std.mem.indexOf(u8, template[anchor_start..], TAG_START)) |off| {
        return template[anchor_start .. anchor_start + off];
    } else {
        return template[anchor_start..tpl_len];
    }
}

fn extractChangeChunk(
    rendered: []const u8,
    rnd_i: usize,
    anchor_lit: []const u8,
) Chunk {
    var change_end = rendered.len;

    if (anchor_lit.len > 0) {
        if (std.mem.indexOf(u8, rendered[rnd_i..], anchor_lit)) |pos| {
            change_end = rnd_i + pos;
        }
    }

    return Chunk{ .slice = rendered[rnd_i..change_end], .end = change_end };
}

fn copyWithWhitespace(
    out: *std.ArrayList(u8),
    body: []const u8,
    change: []const u8,
) !void {
    var lead: usize = 0;

    while (lead < body.len and (body[lead] == '\n' or
        body[lead] == '\r')) lead += 1;

    var trail: usize = 0;

    while (trail < body.len - lead and (body[body.len - 1 - trail] == '\n' or
        body[body.len - 1 - trail] == '\r')) trail += 1;

    if (lead > 0) try out.appendSlice(body[0..lead]);
    try out.appendSlice(change);
    if (trail > 0) try out.appendSlice(body[body.len - trail ..]);
}

fn normalizeTrailing(
    allocator: std.mem.Allocator,
    result: []u8,
    template: []const u8,
) ![]u8 {
    const tmpl_trail = countTrail(template);
    const res_trail = countTrail(result);

    if (res_trail == tmpl_trail) return result;

    const core_len = result.len - res_trail;
    const new_len = core_len + tmpl_trail;
    const new_slice = try allocator.alloc(u8, new_len);

    @memcpy(new_slice[0..core_len], result[0..core_len]);

    if (tmpl_trail > 0) @memcpy(
        new_slice[core_len..],
        template[template.len - tmpl_trail ..],
    );

    allocator.free(result);

    return new_slice;
}

fn evalIfGroup(
    allocator: std.mem.Allocator,
    tokens: []Token,
    start: usize,
    w: anytype,
) !usize {
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
        if (std.mem.startsWith(u8, cur_tag, "if")) {
            active = evalCondition(allocator, cur_tag[3..]) and !branch_taken;
        } else if (std.mem.startsWith(u8, cur_tag, "elif")) {
            active = evalCondition(allocator, cur_tag[5..]) and !branch_taken;
        } else if (std.mem.eql(u8, cur_tag, "else")) {
            active = !branch_taken;
        } else if (std.mem.eql(u8, cur_tag, "end")) {
            // consume the 'end' tag and return index after it
            return i + 1;
        } else {
            return error.InvalidTemplateTag;
        }

        // check if there is a following text token
        // (the body for this control tag)
        var had_body: bool = false;
        var body: []const u8 = &[_]u8{};

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
        // check that i+inc does not overflow and that it is <= tokens.len
        if (inc > tokens.len - i) {
            // past end of the token stream
            return error.InvalidTemplateTag;
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
                    return error.InvalidTemplateTag;
                },
            }
        } else {
            // reached end of tokens without an `end` tag
            return error.InvalidTemplateEndTag;
        }
    }

    // missing `end` tag
    return error.invalidTemplateEndTag;
}

fn evalCondition(allocator: std.mem.Allocator, cond: []const u8) bool {
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
        const os = getOS();

        if (std.mem.eql(u8, op, "==")) return std.mem.eql(u8, os, rhs);
        if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, os, rhs);
    } else if (std.mem.eql(u8, lhs, "SYSTEM.hostname")) {
        const host = getHostname(allocator) catch "unknown";
        defer allocator.free(host);

        if (std.mem.eql(u8, op, "==")) return std.mem.eql(u8, host, rhs);
        if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, host, rhs);
    } else if (std.mem.eql(u8, lhs, "SYSTEM.arch")) {
        const host = getArch();

        if (std.mem.eql(u8, op, "==")) return std.mem.eql(u8, host, rhs);
        if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, host, rhs);
    }

    return false;
}

pub fn applyTemplate(
    allocator: std.mem.Allocator,
    template: []const u8,
) ![]u8 {
    const tokens = try tokenize(allocator, template);
    defer allocator.free(tokens);

    return try interpret(allocator, tokens);
}

pub fn reverseTemplate(
    allocator: std.mem.Allocator,
    render: []const u8,
    template: []const u8,
) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    const tpl_len = template.len;
    const rnd_len = render.len;

    var tpl_i: usize = 0; // template index
    var rnd_i: usize = 0; // rendered index

    while (tpl_i < tpl_len) {
        if (std.mem.startsWith(u8, template[tpl_i..], TAG_START)) {
            const tag = try parseTag(template, tpl_i);

            // check if this is the start of a conditional group
            if (std.mem.startsWith(u8, tag.trim, "if")) {
                // process the entire if-elif-else-end group
                var group_tpl_i = tpl_i;
                var branch_taken = false;
                var active_branch_processed = false;

                while (group_tpl_i < tpl_len) {
                    const group_tag = try parseTag(template, group_tpl_i);

                    // output the tag
                    try out.appendSlice(TAG_START);
                    try out.appendSlice(group_tag.raw);
                    try out.appendSlice(TAG_END);

                    group_tpl_i = group_tag.after;

                    // check if this is the end tag
                    if (std.mem.eql(u8, group_tag.trim, "end")) {
                        tpl_i = group_tpl_i;
                        break;
                    }

                    // parse the body for this branch
                    const body = try parseBody(template, group_tpl_i);

                    // decide whether this branch is active
                    var active = false;

                    if (std.mem.startsWith(u8, group_tag.trim, "if")) {
                        active = evalCondition(allocator, group_tag.trim[3..]) and
                            !branch_taken;
                    } else if (std.mem.startsWith(u8, group_tag.trim, "elif")) {
                        active = evalCondition(allocator, group_tag.trim[5..]) and
                            !branch_taken;
                    } else if (std.mem.eql(u8, group_tag.trim, "else")) {
                        active = !branch_taken;
                    }

                    if (active and !active_branch_processed) {
                        branch_taken = true;
                        active_branch_processed = true;

                        // extract changed render content for the active branch
                        const anchor_lit = try findAnchorLiteral(
                            template,
                            body.after,
                        );

                        const change_chunk = extractChangeChunk(
                            render,
                            rnd_i,
                            anchor_lit,
                        );

                        try copyWithWhitespace(
                            &out,
                            body.slice,
                            change_chunk.slice,
                        );

                        rnd_i = change_chunk.end;
                    } else {
                        // inactive branch: copy the template body
                        try out.appendSlice(body.slice);
                    }

                    group_tpl_i = body.after;
                }
            } else {
                // no non-if tags outside of the group
                return error.InvalidTemplateTag;
            }
        } else {
            // handle literal text between conditional groups
            const lit_end = nextTag(template, tpl_i) orelse tpl_len;
            const lit_template = template[tpl_i..lit_end];

            // copy corresponding content from rendered output
            var len = lit_template.len;
            if (rnd_i + len > rnd_len) {
                len = rnd_len - rnd_i;
            }

            try out.appendSlice(render[rnd_i .. rnd_i + len]);

            rnd_i += len;
            tpl_i = lit_end;
        }
    }

    // append any remaining rendered content
    if (rnd_i < rnd_len) {
        try out.appendSlice(render[rnd_i..]);
    }

    const result = try out.toOwnedSlice();
    return try normalizeTrailing(allocator, result, template);
}

fn getOS() []const u8 {
    return @tagName(builtin.target.os.tag);
}

fn getArch() []const u8 {
    return @tagName(builtin.cpu.arch);
}

fn getHostname(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host = try std.posix.gethostname(&buf);
    return allocator.dupe(u8, host) catch unreachable;
}

fn splitWhitespace(s: []const u8) struct { lead: usize, trail: usize } {
    var lead: usize = 0;
    var trail: usize = 0;

    // count leading whitespace
    while (lead < s.len and (s[lead] == ' ' or
        s[lead] == '\t')) : (lead += 1)
    {}

    // count trailing whitespace
    var j = s.len;

    while (j > lead and (s[j - 1] == ' ' or
        s[j - 1] == '\t')) : (j -= 1)
    {}

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

test interpret {
    const template_invalid =
        \\FOO
        \\{> else <}
        \\val="HOST1"
        \\{> end <}
        \\
    ;

    const template =
        \\FOO
        \\{> if SYSTEM.hostname == somepc <}
        \\val="HOST2"
        \\{> else <}
        \\val="HOST1"
        \\{> end <}
        \\
    ;

    const tokenized_invalid = try tokenize(std.testing.allocator, template_invalid);
    defer std.testing.allocator.free(tokenized_invalid);

    const interpreted_invalid = interpret(std.testing.allocator, tokenized_invalid);
    try std.testing.expectError(error.InvalidTemplateGroup, interpreted_invalid);

    const tokenized = try tokenize(std.testing.allocator, template);
    defer std.testing.allocator.free(tokenized);

    const interpreted = try interpret(std.testing.allocator, tokenized);
    defer std.testing.allocator.free(interpreted);

    try std.testing.expectEqualStrings("FOO\nval=\"HOST1\"\n", interpreted);
}

test tokenize {
    const template_invalid =
        \\FOO{> xx
    ;

    const failure = tokenize(std.testing.allocator, template_invalid);
    try std.testing.expectError(error.InvalidTemplate, failure);

    const template =
        \\FOO{> if SYSTEM.hostname == somepc <}val="HOST2"{> else <}val="HOST1"{> end <}
    ;

    const tokenized = try tokenize(std.testing.allocator, template);
    defer std.testing.allocator.free(tokenized);

    try std.testing.expectEqualStrings("FOO", tokenized[0].text);
    try std.testing.expectEqualStrings("if SYSTEM.hostname == somepc", tokenized[1].tag);
    try std.testing.expectEqualStrings("val=\"HOST2\"", tokenized[2].text);
    try std.testing.expectEqualStrings("else", tokenized[3].tag);
    try std.testing.expectEqualStrings("val=\"HOST1\"", tokenized[4].text);
    try std.testing.expectEqualStrings("end", tokenized[5].tag);
}

test nextTag {
    const template = "text{>tagA<}more{>tagB<}end";
    try testing.expectEqual(@as(?usize, 4), nextTag(template, 0));
    try testing.expectEqual(@as(?usize, 16), nextTag(template, 10));
    try testing.expectEqual(@as(?usize, null), nextTag(template, 22));
}

test parseTag {
    const template = "prefix{> if SYSTEM.os == openbsd <}suffix";
    const template_whitespace = "{>   elif SYSTEM.arch == x86_64   <}";
    const template_invalid = "prefix{> if SYSTEM.os == openbsd <suffix";
    const tag = try parseTag(template, 6);
    const tag_whitespace = try parseTag(template_whitespace, 0);
    const tag_invalid = parseTag(template_invalid, 6);

    try testing.expectEqualStrings(" if SYSTEM.os == openbsd ", tag.raw);
    try testing.expectEqualStrings("if SYSTEM.os == openbsd", tag.trim);
    try testing.expectEqual(@as(usize, 35), tag.after);
    try testing.expectEqualStrings("   elif SYSTEM.arch == x86_64   ", tag_whitespace.raw);
    try testing.expectEqualStrings("elif SYSTEM.arch == x86_64", tag_whitespace.trim);
    try testing.expectError(error.InvalidTemplateEndTag, tag_invalid);
}

test parseBody {
    const template =
        \\content content content
        \\{> end <}
    ;

    const body = try parseBody(template, 0);

    try testing.expectEqualStrings("content content content\n", body.slice);
    try testing.expectEqual(@as(usize, 24), body.after);

    const template_nested =
        \\outer content
        \\{> if SYSTEM.os == linux <}
        \\inner content
        \\{> end <}
        \\more outer
        \\{> end <}
    ;
    const body_nested = try parseBody(template_nested, 0);

    const expected =
        \\outer content
        \\{> if SYSTEM.os == linux <}
        \\inner content
        \\{> end <}
        \\more outer
        \\
    ;

    try testing.expectEqualStrings(expected, body_nested.slice);

    const template_if =
        \\content for if
        \\{> elif SYSTEM.arch == arm64 <}
        \\content for elif
    ;
    const body_if = try parseBody(template_if, 0);

    try testing.expectEqualStrings("content for if\n", body_if.slice);

    const template_else =
        \\content for if
        \\{> else <}
        \\content for else
    ;
    const body_else = try parseBody(template_else, 0);

    try testing.expectEqualStrings("content for if\n", body_else.slice);
}

test findAnchorLiteral {
    const template =
        \\{> if SYSTEM.os == foo <}
        \\content
        \\{> end <}
        \\anchor text here
        \\{> if SYSTEM.arch == bar <}
    ;

    const anchor = try findAnchorLiteral(template, 10);
    try testing.expectEqualStrings("\nanchor text here\n", anchor);

    const template_nested =
        \\{> if outer == true <}
        \\{> if inner == true <}
        \\inner content
        \\{> end <}
        \\{> end <}
        \\final anchor
    ;

    const anchor_nested = try findAnchorLiteral(template_nested, 14);
    try testing.expectEqualStrings("\nfinal anchor", anchor_nested);

    const template_noanchor =
        \\{> if SYSTEM.os == zoot <}
        \\content
        \\{> end <}
    ;

    const anchor_without = try findAnchorLiteral(template_noanchor, 27);
    try testing.expectEqualStrings("", anchor_without);
}

test extractChangeChunk {
    const rendered = "prefix changed content suffix unchanged";
    const anchor_lit = " suffix unchanged";

    const chunk = extractChangeChunk(rendered, 7, anchor_lit);

    try testing.expectEqualStrings("changed content", chunk.slice);
    try testing.expectEqual(@as(usize, 22), chunk.end);

    const rendered_no_anch = "all content changed";
    const anchor_lit_no_anch = "";

    const chunk_no_anch = extractChangeChunk(rendered_no_anch, 4, anchor_lit_no_anch);

    try testing.expectEqualStrings("content changed", chunk_no_anch.slice);
    try testing.expectEqual(@as(usize, 19), chunk_no_anch.end);

    const rendered_anchor_not_found = "content without the anchor";
    const anchor_lit_not_found = "missing anchor";

    const chunk_anchor_not_found = extractChangeChunk(rendered_anchor_not_found, 8, anchor_lit_not_found);

    try testing.expectEqualStrings("without the anchor", chunk_anchor_not_found.slice);
    try testing.expectEqual(@as(usize, 26), chunk_anchor_not_found.end);
}

test copyWithWhitespace {
    var out = std.ArrayList(u8).init(testing.allocator);
    defer out.deinit();

    const body = "\n\r  original content  \n\r";
    const change = "new content";

    try copyWithWhitespace(&out, body, change);

    try testing.expectEqualStrings("\n\rnew content\n\r", out.items);

    var out_none = std.ArrayList(u8).init(testing.allocator);
    defer out_none.deinit();

    const body_none = "original";
    const change_none = "new";

    try copyWithWhitespace(&out_none, body_none, change_none);

    try testing.expectEqualStrings("new", out_none.items);

    var out_leading = std.ArrayList(u8).init(testing.allocator);
    defer out_leading.deinit();

    const body_leading = "\n\roriginal";
    const change_leading = "new";

    try copyWithWhitespace(&out_leading, body_leading, change_leading);

    try testing.expectEqualStrings("\n\rnew", out_leading.items);
}

test splitWhitespace {
    const result1 = splitWhitespace("  zoot  ");
    try testing.expectEqual(@as(usize, 2), result1.lead);
    try testing.expectEqual(@as(usize, 2), result1.trail);

    const result2 = splitWhitespace("zoot");
    try testing.expectEqual(@as(usize, 0), result2.lead);
    try testing.expectEqual(@as(usize, 0), result2.trail);

    const result3 = splitWhitespace("\t\ttest\t");
    try testing.expectEqual(@as(usize, 2), result3.lead);
    try testing.expectEqual(@as(usize, 1), result3.trail);
}

test indexOfTag {
    const template = "prefix{>tagA<}suffix{>tagB<}";
    try testing.expectEqual(@as(?usize, 6), indexOfTag(template, 0));
    try testing.expectEqual(@as(?usize, 20), indexOfTag(template, 10));
    try testing.expectEqual(@as(?usize, null), indexOfTag(template, 25));
}

test normalizeTrailing {
    const result_add = try testing.allocator.dupe(u8, "content");
    const template_add = "template\n\r";
    const normalized_add = try normalizeTrailing(testing.allocator, result_add, template_add);
    defer testing.allocator.free(normalized_add);

    try testing.expectEqualStrings("content\n\r", normalized_add);

    const result_remove = try testing.allocator.dupe(u8, "content\n\r\n");
    const template_remove = "template";
    const normalized_remove = try normalizeTrailing(testing.allocator, result_remove, template_remove);
    defer testing.allocator.free(normalized_remove);

    try testing.expectEqualStrings("content", normalized_remove);

    const result_none = try testing.allocator.dupe(u8, "content\n");
    const template_none = "template\n";
    const normalized_none = try normalizeTrailing(testing.allocator, result_none, template_none);
    defer testing.allocator.free(normalized_none);

    // same slice
    try testing.expect(normalized_none.ptr == result_none.ptr);
    try testing.expectEqualStrings("content\n", normalized_none);
}

test trimTag {
    try testing.expectEqualStrings("test", trimTag("  test  "));
    try testing.expectEqualStrings("if SYSTEM.os == netbsd", trimTag("\n\r if SYSTEM.os == netbsd \t\n"));
    try testing.expectEqualStrings("", trimTag("   \t\r\n   "));
    try testing.expectEqualStrings("end", trimTag("end"));
}

test trimTrailingNewlines {
    try testing.expectEqualStrings("zoot", trimTrailingNewlines("zoot\n\r\n"));
    try testing.expectEqualStrings("hello\nworld", trimTrailingNewlines("hello\nworld\r\n"));
    try testing.expectEqualStrings("", trimTrailingNewlines("\n\r\n"));
    try testing.expectEqualStrings("test", trimTrailingNewlines("test"));
    try testing.expectEqualStrings("\nhello", trimTrailingNewlines("\nhello\n"));
}

test evalCondition {
    const current_os = @tagName(builtin.target.os.tag);
    const condition = std.fmt.allocPrint(
        testing.allocator,
        "SYSTEM.os == {s}",
        .{current_os},
    ) catch unreachable;

    defer testing.allocator.free(condition);

    try testing.expect(evalCondition(testing.allocator, condition));
}

test evalIfGroup {
    var tokens_invalid_end = [_]Token{
        .{ .tag = "if SYSTEM.os == foo" },
        .{ .text = "content" },
    };

    var out_invalid_end = std.ArrayList(u8).init(testing.allocator);
    defer out_invalid_end.deinit();

    const result_invalid_end = evalIfGroup(testing.allocator, &tokens_invalid_end, 0, out_invalid_end.writer());
    try testing.expectError(error.InvalidTemplateEndTag, result_invalid_end);

    var tokens_invalid_tag = [_]Token{
        .{ .tag = "if SYSTEM.os == foo" },
        .{ .text = "content" },
        .{ .text = "unexpected text" },
    };

    var out_invalid_tag = std.ArrayList(u8).init(testing.allocator);
    defer out_invalid_tag.deinit();

    const result_invalid_tag = evalIfGroup(testing.allocator, &tokens_invalid_tag, 0, out_invalid_tag.writer());
    try testing.expectError(error.InvalidTemplateTag, result_invalid_tag);

    var tokens_invalid_template = [_]Token{
        .{ .tag = "unknown_tag" },
        .{ .tag = "end" },
    };

    var out_invalid_template = std.ArrayList(u8).init(testing.allocator);
    defer out_invalid_template.deinit();

    const result_invalid_template = evalIfGroup(testing.allocator, &tokens_invalid_template, 0, out_invalid_template.writer());
    try testing.expectError(error.InvalidTemplateTag, result_invalid_template);
}

test applyTemplate {
    if (builtin.os.tag != .freebsd or
        builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    var gpa = std.testing.allocator;

    const template =
        \\{> if SYSTEM.os == linux <}
        \\val="Foo"
        \\{> elif SYSTEM.os == freebsd <}
        \\val="Bar"
        \\{> else <}
        \\val="Else"
        \\{> end <}
        \\{> if SYSTEM.arch == x86_64 <}
        \\val="test0"
        \\{> else <}
        \\val="test1"
        \\{> end <}
        \\
        \\{> if SYSTEM.hostname == not_my_machine <}
        \\val="HOST2"
        \\{> else <}
        \\val="HOST1"
        \\{> end <}
        \\
    ;

    const rendered_expected =
        \\val="Bar"
        \\val="test0"
        \\
        \\val="HOST1"
        \\
    ;

    const rendered = try applyTemplate(gpa, template);
    defer gpa.free(rendered);
    try std.testing.expectEqualStrings(rendered_expected, rendered);
}

test reverseTemplate {
    if (builtin.os.tag != .freebsd or
        builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    var gpa = std.testing.allocator;

    const template =
        \\{> if SYSTEM.os == linux <}
        \\val="Foo"
        \\{> elif SYSTEM.os == freebsd <}
        \\val="Bar"
        \\{> else <}
        \\val="Else"
        \\{> end <}
        \\{> if SYSTEM.arch == x86_64 <}
        \\val="test0"
        \\{> else <}
        \\val="test1"
        \\{> end <}
        \\
        \\{> if SYSTEM.hostname == not_my_machine <}
        \\val="HOST2"
        \\{> else <}
        \\val="HOST1"
        \\{> end <}
        \\
    ;

    const rendered_user_edit =
        \\val="Zoot"
        \\val="test0-back"
        \\
        \\val="HOST3"
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
        \\{> if SYSTEM.arch == x86_64 <}
        \\val="test0-back"
        \\{> else <}
        \\val="test1"
        \\{> end <}
        \\
        \\{> if SYSTEM.hostname == not_my_machine <}
        \\val="HOST2"
        \\{> else <}
        \\val="HOST3"
        \\{> end <}
        \\
    ;

    try std.testing.expectEqualStrings(expected_template, reversed);
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

test "blocks (fbsd)" {
    if (builtin.os.tag != .freebsd or
        builtin.cpu.arch != .x86_64) return error.SkipZigTest;

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
        \\{> if SYSTEM.arch == x86_64 <}
        \\val="test0"
        \\{> else <}
        \\val="test1"
        \\{> end <}
        \\
        \\{> if SYSTEM.hostname == not_my_machine <}
        \\val="HOST2"
        \\{> else <}
        \\val="HOST1"
        \\{> end <}
        \\
    ;

    const rendered_user_edit =
        \\BAR
        \\val="Zoot"
        \\val="test0-back"
        \\
        \\val="HOST3"
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
        \\{> if SYSTEM.arch == x86_64 <}
        \\val="test0-back"
        \\{> else <}
        \\val="test1"
        \\{> end <}
        \\
        \\{> if SYSTEM.hostname == not_my_machine <}
        \\val="HOST2"
        \\{> else <}
        \\val="HOST3"
        \\{> end <}
        \\
    ;

    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "blocks (linux)" {
    if (builtin.os.tag != .linux or
        builtin.cpu.arch != .x86_64) return error.SkipZigTest;

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
        \\{> if SYSTEM.arch == x86_64 <}
        \\val="test0"
        \\{> else <}
        \\val="test1"
        \\{> end <}
        \\
        \\{> if SYSTEM.hostname == not_my_machine <}
        \\val="HOST2"
        \\{> else <}
        \\val="HOST1"
        \\{> end <}
        \\
    ;

    const rendered_user_edit =
        \\BAR
        \\val="Zoot"
        \\val="test0-back"
        \\
        \\val="HOST3"
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
        \\{> if SYSTEM.arch == x86_64 <}
        \\val="test0-back"
        \\{> else <}
        \\val="test1"
        \\{> end <}
        \\
        \\{> if SYSTEM.hostname == not_my_machine <}
        \\val="HOST2"
        \\{> else <}
        \\val="HOST3"
        \\{> end <}
        \\
    ;

    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "blocks-mixed (fbsd)" {
    if (builtin.os.tag != .freebsd or
        builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    var gpa = std.testing.allocator;

    const template =
        \\FOO
        \\val="{> if SYSTEM.os == freebsd <}Inline{> else <}Bar{> end <}"
        \\{> if SYSTEM.arch == x86_64 <}
        \\val="test0"
        \\{> else <}
        \\val="test1"
        \\{> end <}
        \\
        \\val="{> if SYSTEM.hostname == not_my_machine <}HOST2{> else <}HOST1{> end <}"
        \\
    ;

    const render = try applyTemplate(gpa, template);
    defer gpa.free(render);

    const expected =
        \\FOO
        \\val="Inline"
        \\val="test0"
        \\
        \\val="HOST1"
        \\
    ;

    try std.testing.expectEqualStrings(render, expected);
}

test "blocks-mixed (linux)" {
    if (builtin.os.tag != .linux or
        builtin.cpu.arch != .x86_64) return error.SkipZigTest;

    var gpa = std.testing.allocator;

    const template =
        \\FOO
        \\val="{> if SYSTEM.os == linux <}Inline{> else <}Bar{> end <}"
        \\{> if SYSTEM.arch == x86_64 <}
        \\val="test0"
        \\{> else <}
        \\val="test1"
        \\{> end <}
        \\
        \\val="{> if SYSTEM.hostname == not_my_machine <}HOST2{> else <}HOST1{> end <}"
        \\
    ;

    const render = try applyTemplate(gpa, template);
    defer gpa.free(render);

    const expected =
        \\FOO
        \\val="Inline"
        \\val="test0"
        \\
        \\val="HOST1"
        \\
    ;

    try std.testing.expectEqualStrings(render, expected);
}

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
