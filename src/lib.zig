//! LIBDFS
//!
//! Dfs is a template engine with reverse translation.

// {> x <}
const TAG_START = "{>";
const TAG_END = "<}";

const TagInfo = struct {
    content: []const u8, // trimmed tag content
    raw: []const u8, // raw tag with whitespaces
    start: usize, // position in the original template
    end: usize, // position after the tag in the original template
};

const Tag = struct {
    raw: []const u8,
    trim: []const u8,
    after: usize,
};

const Token = union(enum) {
    text: []const u8,
    tag: TagInfo,
};

const Body = struct {
    slice: []const u8,
    after: usize,
};

const Chunk = struct {
    slice: []const u8,
    end: usize,
};

const Branch = struct {
    active: bool,
    condition: ?[]const u8,
};

pub const TemplateError = error{
    IndexOutOfBounds,
    InvalidTag,
    InvalidCondition,
    InvalidToken,
    MissingCondition,
    MissingEndTag,
    MissingDelimiter,
    MismatchedEnd,
    OrphanedElseElif,
    EmptyTag,
};

const SYSTEM = enum {
    desktop,
    os,
    hostname,
    arch,

    fn fromString(s: []const u8) ?SYSTEM {
        inline for (@typeInfo(SYSTEM).@"enum".fields) |field| {
            const name = "SYSTEM." ++ field.name;
            if (std.mem.eql(u8, s, name)) {
                return @enumFromInt(field.value);
            }
        }

        return null;
    }

    fn getValue(self: SYSTEM, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .os => getOS(),
            .desktop => getDesktop(allocator),
            .hostname => getHostname(allocator),
            .arch => getArch(),
        };
    }

    fn shouldFree(self: SYSTEM) bool {
        return switch (self) {
            .hostname => true,
            .desktop => true,
            else => false,
        };
    }
};

const ParsedCondition = struct {
    lhs: []const u8,
    op: []const u8,
    rhs: []const u8,

    fn isValidOp(self: ParsedCondition) bool {
        return std.mem.eql(u8, self.op, "==") or std.mem.eql(u8, self.op, "!=");
    }

    fn compare(self: ParsedCondition, actual: []const u8) !bool {
        if (self.lhs.len == 0) {
            return TemplateError.InvalidCondition;
        }

        const matches = std.mem.eql(u8, actual, self.rhs);

        if (std.mem.eql(u8, self.op, "==")) return matches;
        if (std.mem.eql(u8, self.op, "!=")) return !matches;

        return TemplateError.InvalidCondition;
    }
};

fn parseCondition(cond: []const u8) !ParsedCondition {
    // try to find '==' operator
    if (std.mem.indexOf(u8, cond, "==")) |pos| {
        const lhs = std.mem.trim(u8, cond[0..pos], " \t");
        const rhs = std.mem.trim(u8, cond[pos + 2 ..], " \t");

        if (lhs.len == 0 or rhs.len == 0) return TemplateError.InvalidCondition;

        return ParsedCondition{
            .lhs = lhs,
            .op = "==",
            .rhs = rhs,
        };
    }

    // try to find '!=' operator
    if (std.mem.indexOf(u8, cond, "!=")) |pos| {
        const lhs = std.mem.trim(u8, cond[0..pos], " \t");
        const rhs = std.mem.trim(u8, cond[pos + 2 ..], " \t");

        if (lhs.len == 0 or rhs.len == 0) return TemplateError.InvalidCondition;

        return ParsedCondition{
            .lhs = lhs,
            .op = "!=",
            .rhs = rhs,
        };
    }

    return TemplateError.InvalidCondition;
}

fn isValidCondition(condition: []const u8) bool {
    const parsed = parseCondition(condition) catch return false;

    // check if LHS is valid system variable
    if (SYSTEM.fromString(parsed.lhs) == null) return false;

    // check if operator is valid
    if (!parsed.isValidOp()) return false;

    // check if RHS is not empty
    return parsed.rhs.len > 0;
}

fn evalCondition(allocator: std.mem.Allocator, cond: []const u8) !bool {
    const parsed = try parseCondition(cond);

    if (!parsed.isValidOp()) return false;

    const var_type = SYSTEM.fromString(parsed.lhs) orelse return false;
    const actual_value = var_type.getValue(allocator) catch return false;

    const should_free = var_type.shouldFree();
    defer if (should_free) allocator.free(actual_value);

    return try parsed.compare(actual_value);
}

/// Contains the error type with a message and the coordinates.
pub const ValidationInfo = struct {
    err: TemplateError,
    line: usize,
    column: usize,
    message: []const u8,
};

pub const ValidationResult = union(enum) {
    ok: void,
    err: ValidationInfo,

    pub fn isError(self: ValidationResult) bool {
        return switch (self) {
            .ok => false,
            .err => true,
        };
    }
};

fn tokenize(allocator: std.mem.Allocator, template: []const u8) ![]Token {
    var tokens = std.array_list.Managed(Token).init(allocator);
    errdefer tokens.deinit();

    var i: usize = 0;

    while (i < template.len) {
        const start_tag = std.mem.indexOfPos(u8, template, i, TAG_START);

        if (start_tag == null) {
            if (i < template.len) {
                try tokens.append(.{ .text = template[i..] });
            }
            break;
        }

        const tag_start = start_tag.?;

        // push preceding text if any
        if (tag_start > i) {
            try tokens.append(.{ .text = template[i..tag_start] });
        }

        const tag = try parseTag(template, tag_start);
        try tokens.append(.{ .tag = .{
            .content = tag.trim,
            .raw = tag.raw,
            .start = tag_start,
            .end = tag.after,
        } });

        i = tag.after;
    }

    return try tokens.toOwnedSlice();
}

fn interpret(allocator: std.mem.Allocator, tokens: []Token) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    var w = out.writer();
    var i: usize = 0;

    while (i < tokens.len) {
        switch (tokens[i]) {
            .text => |t| {
                try w.print("{s}", .{t});
                i += 1;
            },
            .tag => |tag_info| {
                if (std.mem.startsWith(u8, tag_info.content, "if")) {
                    i = try evalIfGroup(allocator, tokens, i, &w);
                } else {
                    // outside of an if-group tags are not allowed
                    return TemplateError.MissingCondition;
                }
            },
        }
    }

    return out.toOwnedSlice();
}

fn parseTag(template: []const u8, i: usize) !Tag {
    // i should point to the { of TAG_START
    if (!std.mem.startsWith(u8, template[i..], TAG_START)) {
        return TemplateError.InvalidTag;
    }

    const start = i + TAG_START.len;
    const rel_end = std.mem.indexOf(u8, template[start..], TAG_END) orelse
        return TemplateError.MissingDelimiter;

    const raw = template[start .. start + rel_end];

    return Tag{
        .raw = raw,
        .trim = trimTag(raw),
        .after = start + rel_end + TAG_END.len,
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

fn findAnchorLiteralFromTokens(
    tokens: []Token,
    start_idx: usize,
    template: []const u8,
) ![]const u8 {
    var depth: usize = 0;
    var i = start_idx;

    // skip past the body token to start searching from next tag
    if (i < tokens.len and tokens[i] == .text) {
        i += 1;
    }

    // find the matching 'end' tag
    while (i < tokens.len) {
        switch (tokens[i]) {
            .tag => |tag_info| {
                if (std.mem.startsWith(u8, tag_info.content, "if")) {
                    depth += 1;
                } else if (std.mem.eql(u8, tag_info.content, "end")) {
                    if (depth == 0) {
                        // found the matching end, look for next text token
                        if (i + 1 < tokens.len and tokens[i + 1] == .text) {
                            return tokens[i + 1].text;
                        }

                        // no text after the end tag—this is fine
                        return template[template.len..template.len];
                    }
                    depth -= 1;
                }
            },
            else => {},
        }
        i += 1;
    }

    // reached end without finding the matching 'end' tag
    return TemplateError.MissingEndTag;
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
    out: *std.array_list.Managed(u8),
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
    const tmpl_trimmed = trimTrailingNewlines(template);
    const res_trimmed = trimTrailingNewlines(result);
    const tmpl_trail = template.len - tmpl_trimmed.len;
    const res_trail = result.len - res_trimmed.len;

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

fn evalBranch(
    allocator: std.mem.Allocator,
    tag_content: []const u8,
    branch_taken: bool,
) !Branch {
    if (std.mem.eql(u8, tag_content, "end")) {
        return .{ .active = false, .condition = null };
    }

    if (std.mem.eql(u8, tag_content, "else")) {
        return .{ .active = !branch_taken, .condition = null };
    }

    const condition = cnd: {
        if (std.mem.startsWith(u8, tag_content, "if "))
            break :cnd tag_content[3..];
        if (std.mem.startsWith(u8, tag_content, "elif "))
            break :cnd tag_content[5..];
        return TemplateError.InvalidTag;
    };

    const active = try evalCondition(allocator, condition) and !branch_taken;
    return .{ .active = active, .condition = condition };
}

fn evalIfGroup(
    allocator: std.mem.Allocator,
    tokens: []Token,
    start: usize,
    w: anytype,
) !usize {
    if (start >= tokens.len) return TemplateError.IndexOutOfBounds;

    var i = start;
    var branch_taken = false;

    while (i < tokens.len) : (i += 0) {
        // tag check
        const tag_info = switch (tokens[i]) {
            .tag => |t| t,
            else => return TemplateError.InvalidToken,
        };

        if (std.mem.eql(u8, tag_info.content, "end")) {
            return i + 1;
        }

        const branch = try evalBranch(
            allocator,
            tag_info.content,
            branch_taken,
        );

        var body: []const u8 = &[_]u8{};
        var has_body = false;

        if (i + 1 < tokens.len and tokens[i + 1] == .text) {
            body = tokens[i + 1].text;

            // trim exactly one leading newline after the control tag
            if (body.len > 0 and (body[0] == '\n' or body[0] == '\r')) {
                body = body[1..];
            }

            has_body = true;
        }

        if (branch.active) {
            branch_taken = true;
            const trimmed = trimTrailingNewlines(body);
            try w.print("{s}", .{trimmed});
        }

        i += if (has_body) 2 else 1;

        if (i < tokens.len and tokens[i] != .tag) {
            return TemplateError.InvalidTag;
        }
    }

    return TemplateError.MissingEndTag;
}

/// Applies the provided template and returns the result.
/// The caller owns the returned memory.
pub fn applyTemplate(
    allocator: std.mem.Allocator,
    template: []const u8,
) ![]const u8 {
    const tokens = try tokenize(allocator, template);
    defer allocator.free(tokens);

    return try interpret(allocator, tokens);
}

/// Translates the rendered file back to the template and returns the result.
/// The caller owns the returned memory.
pub fn reverseTemplate(
    allocator: std.mem.Allocator,
    render: []const u8,
    template: []const u8,
) ![]const u8 {
    const tokens = try tokenize(allocator, template);
    defer allocator.free(tokens);

    return try reverseFromTokens(allocator, render, template, tokens);
}

fn reverseFromTokens(
    allocator: std.mem.Allocator,
    render: []const u8,
    template: []const u8,
    tokens: []Token,
) ![]u8 {
    // first, check if template has any conditionals
    const has_conditionals = hasAnyConditionals(tokens);

    if (!has_conditionals) {
        // no structure to preserve, just return render as the new template.
        // this is the correct behavior: if user edits a pure literal template
        // the new template is the edited version
        const result = try allocator.dupe(u8, render);
        return try normalizeTrailing(allocator, result, template);
    }

    // template has a structure, preserving it
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    var rnd_i: usize = 0;
    var tok_i: usize = 0;

    while (tok_i < tokens.len) {
        switch (tokens[tok_i]) {
            .text => |lit| {
                // check if we're out of render content
                if (rnd_i >= render.len) {
                    // render is exhausted—skip remaining literals
                    tok_i += 1;
                    continue;
                }

                // try to intelligently consume from render
                try consumeLiteral(
                    &out,
                    render,
                    &rnd_i,
                    lit,
                    tokens,
                    tok_i,
                    allocator,
                );

                tok_i += 1;
            },
            .tag => |tag_info| {
                if (std.mem.startsWith(u8, tag_info.content, "if")) {
                    tok_i = try reverseIfGroup(
                        allocator,
                        &out,
                        render,
                        &rnd_i,
                        template,
                        tokens,
                        tok_i,
                    );
                } else {
                    return TemplateError.InvalidTag;
                }
            },
        }
    }

    // append any remaining rendered content
    if (rnd_i < render.len) {
        try out.appendSlice(render[rnd_i..]);
    }

    const result = try out.toOwnedSlice();
    return try normalizeTrailing(allocator, result, template);
}

fn hasAnyConditionals(tokens: []Token) bool {
    for (tokens) |token| {
        if (token == .tag) return true;
    }

    return false;
}

// consume literal content from render
fn consumeLiteral(
    out: *std.array_list.Managed(u8),
    render: []const u8,
    rnd_i: *usize,
    lit: []const u8,
    tokens: []Token,
    tok_i: usize,
    allocator: std.mem.Allocator,
) !void {
    const len = lit.len;
    const available = render.len - rnd_i.*;

    // strategy: Look ahead to see if next token is a conditional
    const next_is_conditional = (tok_i + 1 < tokens.len and
        tokens[tok_i + 1] == .tag);

    if (next_is_conditional) {
        // next is a conditional—try to find where it starts in render
        // by rendering it and searching for that output

        // get what the next conditional would output
        if (findConditionalOutputInRender(
            render,
            rnd_i.*,
            tokens,
            tok_i + 1,
            allocator,
        )) |anchor_pos| {
            // found where the conditional content starts
            // everything before it is the literal content
            try out.appendSlice(render[rnd_i.*..anchor_pos]);
            rnd_i.* = anchor_pos;
            return;
        } else |_| {
            // could not find an anchor
            // fall through to simple approach
        }
    }

    // simple approach: consume based on the expected length
    if (len <= available) {
        try out.appendSlice(render[rnd_i.* .. rnd_i.* + len]);
        rnd_i.* += len;
    } else {
        // not enough content—consume what is left
        try out.appendSlice(render[rnd_i.*..]);
        rnd_i.* = render.len;
    }
}

// try to find where a conditional's output appears in the render
fn findConditionalOutputInRender(
    render: []const u8,
    start_pos: usize,
    tokens: []Token,
    cond_idx: usize,
    allocator: std.mem.Allocator,
) !usize {
    // try to find where a conditional's output appears in the render

    if (cond_idx >= tokens.len or tokens[cond_idx] != .tag) {
        return error.NoConditional;
    }

    // we need to evaluate just this conditional group to get its output
    // then search for that output in the render starting from 'start_pos'

    // extract the conditional group tokens
    const group_end = try findConditionalGroupEnd(tokens, cond_idx);
    const group_tokens = tokens[cond_idx .. group_end + 1];

    // interpret just this group
    const expected_output = interpret(allocator, group_tokens) catch {
        return error.InterpretFailed;
    };

    defer allocator.free(expected_output);

    // search for this output in render
    const trimmed_output = trimTrailingNewlines(expected_output);
    if (trimmed_output.len == 0) {
        return error.EmptyOutput;
    }

    // search in the remaining render content
    if (std.mem.indexOf(u8, render[start_pos..], trimmed_output)) |offset| {
        return start_pos + offset;
    }

    return error.AnchorNotFound;
}

fn findConditionalGroupEnd(tokens: []Token, start: usize) !usize {
    if (tokens[start] != .tag) return TemplateError.InvalidTag;

    var depth: usize = 1;
    var i = start + 1;

    while (i < tokens.len) : (i += 1) {
        if (tokens[i] == .tag) {
            const content = tokens[i].tag.content;
            if (std.mem.startsWith(u8, content, "if")) {
                depth += 1;
            } else if (std.mem.eql(u8, content, "end")) {
                depth -= 1;
                if (depth == 0) return i;
            }
        }
    }

    return TemplateError.MissingEndTag;
}

fn reverseIfGroup(
    allocator: std.mem.Allocator,
    out: *std.array_list.Managed(u8),
    render: []const u8,
    rnd_i: *usize,
    template: []const u8,
    tokens: []Token,
    start: usize,
) !usize {
    var tok_i = start;
    var branch_taken = false;
    var active_branch_processed = false;

    while (tok_i < tokens.len) : (tok_i += 0) {
        const tag_info = switch (tokens[tok_i]) {
            .tag => |t| t,
            else => return TemplateError.InvalidToken,
        };

        // output the tag
        try out.appendSlice(TAG_START);
        try out.appendSlice(tag_info.raw);
        try out.appendSlice(TAG_END);

        tok_i += 1;

        // check if this is the end tag
        if (std.mem.eql(u8, tag_info.content, "end")) {
            return tok_i;
        }

        // get body (next token if it's text)
        var body: []const u8 = &[_]u8{};
        var has_body = false;

        if (tok_i < tokens.len and tokens[tok_i] == .text) {
            body = tokens[tok_i].text;
            has_body = true;
        }

        const branch = try evalBranch(
            allocator,
            tag_info.content,
            branch_taken,
        );

        if (branch.active and !active_branch_processed) {
            branch_taken = true;
            active_branch_processed = true;

            // find the anchor literal (look ahead in tokens)
            const anchor_lit = try findAnchorLiteralFromTokens(
                tokens,
                tok_i,
                template,
            );

            const change_chunk = extractChangeChunk(
                render,
                rnd_i.*,
                anchor_lit,
            );

            try copyWithWhitespace(out, body, change_chunk.slice);
            rnd_i.* = change_chunk.end;
        } else {
            // inactive branch: copy the template body as-is
            try out.appendSlice(body);
        }

        if (has_body) {
            tok_i += 1;
        }
    }

    return TemplateError.MissingEndTag;
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
    return try allocator.dupe(u8, host);
}

fn getDesktop(allocator: std.mem.Allocator) ![]const u8 {
    const xdg_session_desktop = std.process.getEnvVarOwned(
        allocator,
        "XDG_SESSION_DESKTOzzzP",
    ) catch {
        const desktop_session = std.process.getEnvVarOwned(
            allocator,
            "DESKTOP_SESSION",
            // the library always frees the output
        ) catch return std.ascii.allocLowerString(allocator, "UNKNOWN");

        defer allocator.free(desktop_session);
        return std.ascii.allocLowerString(allocator, desktop_session);
    };

    defer allocator.free(xdg_session_desktop);
    return std.ascii.allocLowerString(allocator, xdg_session_desktop);
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

/// Validates the provided template.
pub fn validate(template: []const u8) ValidationResult {
    var i: usize = 0;
    var line: usize = 1;
    var column: usize = 1;
    var if_depth: usize = 0;
    var has_if_in_group: bool = false;

    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], TAG_START)) {
            const tag_line = line;
            const tag_column = column;
            const tag = parseTag(template, i) catch |err| {
                return ValidationResult{
                    .err = .{
                        .err = err,
                        .line = tag_line,
                        .column = tag_column,
                        .message = switch (err) {
                            TemplateError.MissingDelimiter => "Unclosed tag",
                            else => "Invalid tag",
                        },
                    },
                };
            };

            if (tag.raw.len == 0) {
                return ValidationResult{
                    .err = .{
                        .err = TemplateError.EmptyTag,
                        .line = tag_line,
                        .column = tag_column,
                        .message = "Empty tag",
                    },
                };
            }

            if (tag.trim.len == 0) {
                return ValidationResult{
                    .err = .{
                        .err = TemplateError.EmptyTag,
                        .line = tag_line,
                        .column = tag_column,
                        .message = "Empty tag after trimming whitespace",
                    },
                };
            }

            // validate tag content
            if (std.mem.startsWith(u8, tag.trim, "if")) {
                if (tag.trim.len < 4 or tag.trim[2] != ' ') {
                    return ValidationResult{
                        .err = .{
                            .err = TemplateError.InvalidCondition,
                            .line = tag_line,
                            .column = tag_column,
                            .message = "Invalid 'if' condition format",
                        },
                    };
                }

                const condition = tag.trim[3..];

                if (!isValidCondition(condition)) {
                    return ValidationResult{
                        .err = .{
                            .err = TemplateError.InvalidCondition,
                            .line = tag_line,
                            .column = tag_column,
                            .message = "Invalid conditional syntax",
                        },
                    };
                }

                if_depth += 1;
                has_if_in_group = true;
            } else if (std.mem.startsWith(u8, tag.trim, "elif")) {
                if (if_depth == 0 or !has_if_in_group) {
                    return ValidationResult{
                        .err = .{
                            .err = TemplateError.OrphanedElseElif,
                            .line = tag_line,
                            .column = tag_column,
                            .message = "Orphaned 'elif' without matching 'if'",
                        },
                    };
                }

                if (tag.trim.len < 6 or tag.trim[4] != ' ') {
                    return ValidationResult{
                        .err = .{
                            .err = TemplateError.InvalidCondition,
                            .line = tag_line,
                            .column = tag_column,
                            .message = "Invalid 'elif' condition format",
                        },
                    };
                }

                const condition = tag.trim[5..];

                if (!isValidCondition(condition)) {
                    return ValidationResult{
                        .err = .{
                            .err = TemplateError.InvalidCondition,
                            .line = tag_line,
                            .column = tag_column,
                            .message = "Invalid 'elif' condition syntax",
                        },
                    };
                }
            } else if (std.mem.eql(u8, tag.trim, "else")) {
                if (if_depth == 0 or !has_if_in_group) {
                    return ValidationResult{
                        .err = .{
                            .err = TemplateError.OrphanedElseElif,
                            .line = tag_line,
                            .column = tag_column,
                            .message = "Orphaned 'else' without matching 'if'",
                        },
                    };
                }
            } else if (std.mem.eql(u8, tag.trim, "end")) {
                if (if_depth == 0) {
                    return ValidationResult{
                        .err = .{
                            .err = TemplateError.MismatchedEnd,
                            .line = tag_line,
                            .column = tag_column,
                            .message = "Mismatched 'end' tag without matching 'if'",
                        },
                    };
                }

                if_depth -= 1;

                if (if_depth == 0) {
                    has_if_in_group = false;
                }
            } else {
                return ValidationResult{
                    .err = .{
                        .err = TemplateError.InvalidTag,
                        .line = tag_line,
                        .column = tag_column,
                        .message = "Unknown or invalid tag",
                    },
                };
            }

            // update position tracking using tag.after
            column += (tag.after - i);
            i = tag.after;
        } else {
            if (template[i] == '\n') {
                line += 1;
                column = 1;
            } else {
                column += 1;
            }

            i += 1;
        }
    }

    // check for unclosed `if` blocks
    if (if_depth > 0) {
        return ValidationResult{
            .err = .{
                .err = TemplateError.MismatchedEnd,
                .line = line,
                .column = column,
                .message = "Unclosed 'if' block(s) at the end of a template",
            },
        };
    }

    return ValidationResult{ .ok = {} };
}

test parseCondition {
    {
        const parsed = ParsedCondition{
            .lhs = "SYSTEM.os",
            .op = "==",
            .rhs = "freebsd",
        };

        try testing.expect(try parsed.compare("freebsd"));
        try testing.expect(!try parsed.compare("linux"));
        try testing.expect(!try parsed.compare("macos"));
    }

    {
        const parsed = ParsedCondition{
            .lhs = "SYSTEM.os",
            .op = "!=",
            .rhs = "openbsd",
        };

        try testing.expect(try parsed.compare("linux"));
        try testing.expect(try parsed.compare("macos"));
        try testing.expect(!try parsed.compare("openbsd"));
    }

    {
        const parsed = ParsedCondition{
            .lhs = "SYSTEM.os",
            .op = ">=",
            .rhs = "linux",
        };

        try testing.expectError(TemplateError.InvalidCondition, parsed.compare("linux"));
        try testing.expectError(TemplateError.InvalidCondition, parsed.compare("windows"));
    }

    {
        const parsed = ParsedCondition{
            .lhs = "",
            .op = "==",
            .rhs = "linux",
        };

        try testing.expectError(TemplateError.InvalidCondition, parsed.compare("linux"));
    }
}

test validate {
    {
        const template_unclosed = "FOO{> xx";
        const result_unclosed = validate(template_unclosed);
        try testing.expect(result_unclosed.isError());
        try testing.expectEqual(TemplateError.MissingDelimiter, result_unclosed.err.err);
        try testing.expectEqual(@as(usize, 1), result_unclosed.err.line);
        try testing.expectEqual(@as(usize, 4), result_unclosed.err.column);
    }

    {
        const template_empty = "FOO{><}BAR";
        const result_empty = validate(template_empty);
        try testing.expect(result_empty.isError());
        try testing.expectEqual(TemplateError.EmptyTag, result_empty.err.err);
    }

    {
        const template_whitespace_only = "FOO{>   \t\n  <}BAR";
        const result_whitespace_only = validate(template_whitespace_only);
        try testing.expect(result_whitespace_only.isError());
        try testing.expectEqual(TemplateError.EmptyTag, result_whitespace_only.err.err);
    }

    {
        const template_orphaned_else =
            \\FOO
            \\{> else <}
            \\val="HOST1"
            \\{> end <}
        ;

        const result_orphaned_else = validate(template_orphaned_else);
        try testing.expect(result_orphaned_else.isError());
        try testing.expectEqual(TemplateError.OrphanedElseElif, result_orphaned_else.err.err);
        try testing.expectEqual(@as(usize, 2), result_orphaned_else.err.line);
    }

    {
        const template_orphaned_elif =
            \\FOO
            \\{> elif SYSTEM.os == freebsd <}
            \\val="HOST1"
            \\{> end <}
        ;

        const result_orphaned_elif = validate(template_orphaned_elif);
        try testing.expect(result_orphaned_elif.isError());
        try testing.expectEqual(TemplateError.OrphanedElseElif, result_orphaned_elif.err.err);
    }

    {
        const template_mismatched = "{> end <}";
        const result_mismatched = validate(template_mismatched);
        try testing.expect(result_mismatched.isError());
        try testing.expectEqual(TemplateError.MismatchedEnd, result_mismatched.err.err);
    }

    {
        const template_unclosed_if =
            \\FOO
            \\{> if SYSTEM.os == openbsd <}
            \\val="test"
        ;

        const result_unclosed_if = validate(template_unclosed_if);
        try testing.expect(result_unclosed_if.isError());
        try testing.expectEqual(TemplateError.MismatchedEnd, result_unclosed_if.err.err);
    }

    {
        const template_bad_if_format = "{> ifSYSTEM.os == linux <}content{> end <}";
        const result_bad_if_format = validate(template_bad_if_format);
        try testing.expect(result_bad_if_format.isError());
        try testing.expectEqual(TemplateError.InvalidCondition, result_bad_if_format.err.err);
    }

    {
        const template_bad_elif_format =
            \\{> if SYSTEM.os == foo <}
            \\content1
            \\{> elifSYSTEM.os == bar <}
            \\content2
            \\{> end <}
        ;

        const result_bad_elif_format = validate(template_bad_elif_format);
        try testing.expect(result_bad_elif_format.isError());
        try testing.expectEqual(TemplateError.InvalidCondition, result_bad_elif_format.err.err);
    }

    {
        const template_bad_elif_cond =
            \\{> if SYSTEM.os == linux <}
            \\content1
            \\{> elif SYSTEM.os >= windows <}
            \\content2
            \\{> end <}
        ;

        const result = validate(template_bad_elif_cond);
        try testing.expect(result.isError());
        try testing.expectEqual(TemplateError.InvalidCondition, result.err.err);
        try testing.expectEqualStrings("Invalid 'elif' condition syntax", result.err.message);
    }

    {
        const template_bad_condition_parts = "{> if SYSTEM.os <}content{> end <}";
        const result_bad_condition_parts = validate(template_bad_condition_parts);
        try testing.expect(result_bad_condition_parts.isError());
        try testing.expectEqual(TemplateError.InvalidCondition, result_bad_condition_parts.err.err);
    }

    {
        const template_bad_lhs = "{> if INVALID.var == value <}content{> end <}";
        const result_bad_lhs = validate(template_bad_lhs);
        try testing.expect(result_bad_lhs.isError());
        try testing.expectEqual(TemplateError.InvalidCondition, result_bad_lhs.err.err);
    }

    {
        const template_bad_operator = "{> if SYSTEM.os >= linux <}content{> end <}";
        const result_bad_operator = validate(template_bad_operator);
        try testing.expect(result_bad_operator.isError());
        try testing.expectEqual(TemplateError.InvalidCondition, result_bad_operator.err.err);
    }

    {
        const template_unknown_tag = "{> unknown_tag <}";
        const result_unknown_tag = validate(template_unknown_tag);
        try testing.expect(result_unknown_tag.isError());
        try testing.expectEqual(TemplateError.InvalidTag, result_unknown_tag.err.err);
    }

    {
        const template_valid_simple =
            \\FOO
            \\{> if SYSTEM.hostname == baal <}
            \\val="HOST2"
            \\{> else <}
            \\val="HOST1"
            \\{> end <}
        ;

        const result_valid_simple = validate(template_valid_simple);
        try testing.expect(!result_valid_simple.isError());
    }

    {
        const template_valid_chain =
            \\{> if SYSTEM.os == netbsd <}
            \\netbsd_content
            \\{> elif SYSTEM.os == windows <}
            \\windows_content
            \\{> elif SYSTEM.os == freebsd <}
            \\freebsd_content
            \\{> else <}
            \\other_content
            \\{> end <}
        ;

        const result_valid_chain = validate(template_valid_chain);
        try testing.expect(!result_valid_chain.isError());
    }

    {
        const template_valid_nested =
            \\{> if SYSTEM.os == freebsd <}
            \\{> if SYSTEM.arch == x86_64 <}
            \\freebsd_x64
            \\{> else <}
            \\freebsd_other
            \\{> end <}
            \\{> end <}
        ;

        const result_valid_nested = validate(template_valid_nested);
        try testing.expect(!result_valid_nested.isError());
    }

    {
        const template_valid_multiple =
            \\{> if SYSTEM.os == freebsd <}
            \\first_block
            \\{> end <}
            \\some text
            \\{> if SYSTEM.arch == arm64 <}
            \\second_block
            \\{> end <}
        ;

        const result_valid_multiple = validate(template_valid_multiple);
        try testing.expect(!result_valid_multiple.isError());
    }

    {
        const template_valid_all_vars =
            \\{> if SYSTEM.os == openbsd <}os_content{> end <}
            \\{> if SYSTEM.hostname == host <}host_content{> end <}
            \\{> if SYSTEM.arch == x86_64 <}arch_content{> end <}
        ;

        const result_valid_all_vars = validate(template_valid_all_vars);
        try testing.expect(!result_valid_all_vars.isError());
    }

    {
        const template_valid_operators =
            \\{> if SYSTEM.os == linux <}equal{> end <}
            \\{> if SYSTEM.os != windows <}not_equal{> end <}
        ;

        const result_valid_operators = validate(template_valid_operators);
        try testing.expect(!result_valid_operators.isError());
    }

    {
        const template_multiline =
            \\line 1
            \\line 2
            \\line 3 {> invalid_tag <}
            \\line 4
        ;

        const result_multiline = validate(template_multiline);
        try testing.expect(result_multiline.isError());
        try testing.expectEqual(TemplateError.InvalidTag, result_multiline.err.err);
        try testing.expectEqual(@as(usize, 3), result_multiline.err.line);
        try testing.expectEqual(@as(usize, 8), result_multiline.err.column);
    }

    {
        const template_line_tracking =
            \\first line
            \\second line
            \\third line
            \\{> else <}
            \\fifth line
        ;

        const result_line_tracking = validate(template_line_tracking);
        try testing.expect(result_line_tracking.isError());
        try testing.expectEqual(TemplateError.OrphanedElseElif, result_line_tracking.err.err);
        try testing.expectEqual(@as(usize, 4), result_line_tracking.err.line);
    }
}

test interpret {
    {
        const template_invalid =
            \\FOO
            \\{> else <}
            \\val="HOST1"
            \\{> end <}
            \\
        ;

        const tokenized_invalid = try tokenize(std.testing.allocator, template_invalid);
        defer std.testing.allocator.free(tokenized_invalid);

        const interpreted_invalid = interpret(std.testing.allocator, tokenized_invalid);
        try std.testing.expectError(TemplateError.MissingCondition, interpreted_invalid);
    }

    {
        const template =
            \\FOO
            \\{> if SYSTEM.hostname == baal <}
            \\val="HOST2"
            \\{> else <}
            \\val="HOST1"
            \\{> end <}
            \\
        ;

        const tokenized = try tokenize(std.testing.allocator, template);
        defer std.testing.allocator.free(tokenized);

        const interpreted = try interpret(std.testing.allocator, tokenized);
        defer std.testing.allocator.free(interpreted);

        try std.testing.expectEqualStrings("FOO\nval=\"HOST1\"\n", interpreted);
    }
}

test tokenize {
    const template_invalid =
        \\FOO{> xx
    ;

    const failure = tokenize(std.testing.allocator, template_invalid);
    try std.testing.expectError(TemplateError.MissingDelimiter, failure);

    const template =
        \\FOO{> if SYSTEM.hostname == gibson <}val="HOST2"{> else <}val="HOST1"{> end <}
    ;

    const tokenized = try tokenize(std.testing.allocator, template);
    defer std.testing.allocator.free(tokenized);

    try std.testing.expectEqualStrings("FOO", tokenized[0].text);
    try std.testing.expectEqualStrings("if SYSTEM.hostname == gibson", tokenized[1].tag.content);
    try std.testing.expectEqualStrings("val=\"HOST2\"", tokenized[2].text);
    try std.testing.expectEqualStrings("else", tokenized[3].tag.content);
    try std.testing.expectEqualStrings("val=\"HOST1\"", tokenized[4].text);
    try std.testing.expectEqualStrings("end", tokenized[5].tag.content);
}

test parseTag {
    const template = "prefix{> if SYSTEM.os == openbsd <}suffix";
    const template_whitespace = "{>   elif SYSTEM.arch == x86_64   <}";
    const template_missing_delim = "prefix{> if SYSTEM.os == openbsd <suffix";
    const template_invalid_tag = "prefix> if SYSTEM.os == openbsd <suffix";
    const tag = try parseTag(template, 6);
    const tag_whitespace = try parseTag(template_whitespace, 0);
    const tag_missing_delim = parseTag(template_missing_delim, 6);
    const tag_invalid = parseTag(template_invalid_tag, 6);

    try testing.expectEqualStrings(" if SYSTEM.os == openbsd ", tag.raw);
    try testing.expectEqualStrings("if SYSTEM.os == openbsd", tag.trim);
    try testing.expectEqual(@as(usize, 35), tag.after);
    try testing.expectEqualStrings("   elif SYSTEM.arch == x86_64   ", tag_whitespace.raw);
    try testing.expectEqualStrings("elif SYSTEM.arch == x86_64", tag_whitespace.trim);
    try testing.expectError(TemplateError.MissingDelimiter, tag_missing_delim);
    try testing.expectError(TemplateError.InvalidTag, tag_invalid);
}

test parseBody {
    {
        const template =
            \\content content content
            \\{> end <}
        ;

        const body = try parseBody(template, 0);

        try testing.expectEqualStrings("content content content\n", body.slice);
        try testing.expectEqual(@as(usize, 24), body.after);
    }

    {
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
    }

    {
        const template_if =
            \\content for if
            \\{> elif SYSTEM.arch == arm64 <}
            \\content for elif
        ;

        const body_if = try parseBody(template_if, 0);
        try testing.expectEqualStrings("content for if\n", body_if.slice);
    }

    {
        const template_else =
            \\content for if
            \\{> else <}
            \\content for else
        ;
        const body_else = try parseBody(template_else, 0);
        try testing.expectEqualStrings("content for if\n", body_else.slice);
    }
}

test findAnchorLiteralFromTokens {
    const allocator = testing.allocator;
    {
        const template =
            \\{> if SYSTEM.os == foo <}
            \\content
            \\{> end <}
            \\anchor text here
            \\{> if SYSTEM.arch == bar <}
        ;

        const tokens = try tokenize(allocator, template);
        defer allocator.free(tokens);

        const anchor = try findAnchorLiteralFromTokens(tokens, 1, template);
        try testing.expectEqualStrings("\nanchor text here\n", anchor);
    }

    {
        const template_nested =
            \\{> if outer == true <}
            \\{> if inner == true <}
            \\inner content
            \\{> end <}
            \\{> end <}
            \\final anchor
        ;

        const tokens_nested = try tokenize(allocator, template_nested);
        defer allocator.free(tokens_nested);

        const anchor_nested = try findAnchorLiteralFromTokens(tokens_nested, 1, template_nested);
        try testing.expectEqualStrings("\nfinal anchor", anchor_nested);
    }

    {
        const template_noanchor =
            \\{> if SYSTEM.os == zoot <}
            \\content
            \\{> end <}
        ;

        const tokens_noanchor = try tokenize(allocator, template_noanchor);
        defer allocator.free(tokens_noanchor);

        const anchor_without = try findAnchorLiteralFromTokens(tokens_noanchor, 1, template_noanchor);
        try testing.expectEqualStrings("", anchor_without);
    }

    {
        const template_missing_tag =
            \\{> if SYSTEM.os == foo <}
            \\content without end tag
        ;

        const tokens = try tokenize(allocator, template_missing_tag);
        defer allocator.free(tokens);

        const result = findAnchorLiteralFromTokens(tokens, 1, template_missing_tag);
        try testing.expectError(TemplateError.MissingEndTag, result);
    }
}

test extractChangeChunk {
    {
        const rendered = "prefix changed content suffix unchanged";
        const anchor_lit = " suffix unchanged";
        const chunk = extractChangeChunk(rendered, 7, anchor_lit);

        try testing.expectEqualStrings("changed content", chunk.slice);
        try testing.expectEqual(@as(usize, 22), chunk.end);
    }

    {
        const rendered_no_anch = "all content changed";
        const anchor_lit_no_anch = "";
        const chunk_no_anch = extractChangeChunk(rendered_no_anch, 4, anchor_lit_no_anch);

        try testing.expectEqualStrings("content changed", chunk_no_anch.slice);
        try testing.expectEqual(@as(usize, 19), chunk_no_anch.end);
    }

    {
        const rendered_anchor_not_found = "content without the anchor";
        const anchor_lit_not_found = "missing anchor";
        const chunk_anchor_not_found = extractChangeChunk(rendered_anchor_not_found, 8, anchor_lit_not_found);

        try testing.expectEqualStrings("without the anchor", chunk_anchor_not_found.slice);
        try testing.expectEqual(@as(usize, 26), chunk_anchor_not_found.end);
    }
}

test copyWithWhitespace {
    {
        var out = std.array_list.Managed(u8).init(testing.allocator);
        defer out.deinit();

        const body = "\n\r  original content  \n\r";
        const change = "new content";

        try copyWithWhitespace(&out, body, change);
        try testing.expectEqualStrings("\n\rnew content\n\r", out.items);
    }

    {
        var out_none = std.array_list.Managed(u8).init(testing.allocator);
        defer out_none.deinit();

        const body_none = "original";
        const change_none = "new";

        try copyWithWhitespace(&out_none, body_none, change_none);
        try testing.expectEqualStrings("new", out_none.items);
    }

    {
        var out_leading = std.array_list.Managed(u8).init(testing.allocator);
        defer out_leading.deinit();

        const body_leading = "\n\roriginal";
        const change_leading = "new";

        try copyWithWhitespace(&out_leading, body_leading, change_leading);
        try testing.expectEqualStrings("\n\rnew", out_leading.items);
    }
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
    {
        const current_os = @tagName(builtin.target.os.tag);
        const condition = std.fmt.allocPrint(
            testing.allocator,
            "SYSTEM.os == {s}",
            .{current_os},
        ) catch unreachable;

        defer testing.allocator.free(condition);

        try testing.expect(try evalCondition(testing.allocator, condition));
    }

    {
        const current_os = @tagName(builtin.target.os.tag);
        const condition = std.fmt.allocPrint(
            testing.allocator,
            "SYSTEM.os=={s}",
            .{current_os},
        ) catch unreachable;

        defer testing.allocator.free(condition);

        try testing.expect(try evalCondition(testing.allocator, condition));
    }

    {
        const current_os = @tagName(builtin.target.os.tag);
        const condition = std.fmt.allocPrint(
            testing.allocator,
            "SYSTEM.os    ==    {s}",
            .{current_os},
        ) catch unreachable;

        defer testing.allocator.free(condition);

        try testing.expect(try evalCondition(testing.allocator, condition));
    }

    {
        const current_os = @tagName(builtin.target.os.tag);
        const condition = std.fmt.allocPrint(
            testing.allocator,
            "SYSTEM.os ?= {s}",
            .{current_os},
        ) catch unreachable;

        defer testing.allocator.free(condition);

        const result = evalCondition(testing.allocator, condition);
        try testing.expectError(TemplateError.InvalidCondition, result);
    }
}

test reverseIfGroup {
    const allocator = testing.allocator;

    const template =
        \\{> if SYSTEM.os == doom <}
        \\content
    ;

    const tokens = try tokenize(allocator, template);
    defer allocator.free(tokens);

    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    const rendered = "content";
    var rnd_i: usize = 0;

    const result = reverseIfGroup(
        allocator,
        &out,
        rendered,
        &rnd_i,
        template,
        tokens,
        0,
    );

    try testing.expectError(TemplateError.MissingEndTag, result);
}

test evalIfGroup {
    const allocator = testing.allocator;

    {
        const tokens_oob = &[_]Token{};
        var out = std.array_list.Managed(u8).init(allocator);
        defer out.deinit();

        const result = evalIfGroup(allocator, tokens_oob, 0, out.writer());
        try testing.expectError(TemplateError.IndexOutOfBounds, result);
    }

    {
        var tokens_unexpected = [_]Token{
            .{ .text = "unexpected text" },
            .{ .tag = .{ .content = "end", .raw = " end ", .start = 0, .end = 10 } },
        };

        var out = std.array_list.Managed(u8).init(testing.allocator);
        defer out.deinit();

        const result = evalIfGroup(allocator, &tokens_unexpected, 0, out.writer());
        try testing.expectError(TemplateError.InvalidToken, result);
    }

    {
        var tokens_invalid_tag = [_]Token{
            .{ .tag = .{ .content = "if SYSTEM.os == foo", .raw = " if SYSTEM.os == foo ", .start = 0, .end = 10 } },
            .{ .text = "content" },
            .{ .text = "unexpected text" },
        };

        var out_invalid_tag = std.array_list.Managed(u8).init(testing.allocator);
        defer out_invalid_tag.deinit();

        const result_invalid_tag = evalIfGroup(allocator, &tokens_invalid_tag, 0, out_invalid_tag.writer());
        try testing.expectError(TemplateError.InvalidTag, result_invalid_tag);
    }

    {
        var tokens_invalid_template = [_]Token{
            .{ .tag = .{ .content = "unknown_tag", .raw = " unknown_tag ", .start = 0, .end = 10 } },
            .{ .tag = .{ .content = "end", .raw = " end ", .start = 20, .end = 30 } },
        };

        var out_invalid_template = std.array_list.Managed(u8).init(testing.allocator);
        defer out_invalid_template.deinit();

        const result_invalid_template = evalIfGroup(allocator, &tokens_invalid_template, 0, out_invalid_template.writer());
        try testing.expectError(TemplateError.InvalidTag, result_invalid_template);
    }

    {
        var tokens_missing_end = [_]Token{
            .{ .tag = .{ .content = "if SYSTEM.os == foo", .raw = " if SYSTEM.os == foo ", .start = 0, .end = 10 } },
            .{ .text = "body" },
        };

        var out = std.array_list.Managed(u8).init(allocator);
        defer out.deinit();

        const result = evalIfGroup(allocator, &tokens_missing_end, 0, out.writer());
        try testing.expectError(TemplateError.MissingEndTag, result);
    }

    {
        var tokens_end_only = [_]Token{
            .{ .tag = .{ .content = "end", .raw = " end ", .start = 0, .end = 5 } },
        };

        var out = std.array_list.Managed(u8).init(allocator);
        defer out.deinit();

        const result = try evalIfGroup(allocator, &tokens_end_only, 0, out.writer());
        try testing.expect(result == 1);
    }
}

test applyTemplate {
    var allocator = std.testing.allocator;
    const os = @tagName(builtin.target.os.tag);
    const arch = @tagName(builtin.cpu.arch);
    const host = try getHostname(allocator);

    defer allocator.free(host);

    const template = std.fmt.allocPrint(
        testing.allocator,
        \\{{> if SYSTEM.os == foo <}}
        \\val="Foo"
        \\{{> elif SYSTEM.os == {s} <}}
        \\val="Bar"
        \\{{> else <}}
        \\val="Else"
        \\{{> end <}}
        \\{{> if SYSTEM.arch == {s} <}}
        \\val="test0"
        \\{{> else <}}
        \\val="test1"
        \\{{> end <}}
        \\
        \\{{> if SYSTEM.hostname == {s} <}}
        \\val="HOST1"
        \\{{> else <}}
        \\val="HOST2"
        \\{{> end <}}
        \\val="{{> if SYSTEM.desktop == Z00t <}}13{{> else <}}23{{> end <}}"
        \\
    ,
        .{ os, arch, host },
    ) catch unreachable;

    defer allocator.free(template);

    const rendered_expected =
        \\val="Bar"
        \\val="test0"
        \\
        \\val="HOST1"
        \\val="23"
        \\
    ;

    const rendered = try applyTemplate(allocator, template);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(rendered_expected, rendered);
}

test reverseTemplate {
    const os = @tagName(builtin.target.os.tag);
    const arch = @tagName(builtin.cpu.arch);

    var allocator = std.testing.allocator;

    const template = std.fmt.allocPrint(
        testing.allocator,
        \\{{> if SYSTEM.os == lifoox <}}
        \\val="Foo"
        \\{{> elif SYSTEM.os == {s} <}}
        \\val="Bar"
        \\{{> else <}}
        \\val="Else"
        \\{{> end <}}
        \\{{> if SYSTEM.arch == {s} <}}
        \\val="test0"
        \\{{> else <}}
        \\val="test1"
        \\{{> end <}}
        \\
        \\{{> if SYSTEM.hostname == not_my_machine <}}
        \\val="HOST2"
        \\{{> else <}}
        \\val="HOST1"
        \\{{> end <}}
        \\
    ,
        .{ os, arch },
    ) catch unreachable;

    defer testing.allocator.free(template);

    const rendered_user_edit =
        \\val="Zoot"
        \\val="test0-back"
        \\
        \\val="HOST3"
        \\
    ;

    const reversed = try reverseTemplate(allocator, rendered_user_edit, template);
    defer allocator.free(reversed);

    const expected_template = std.fmt.allocPrint(
        testing.allocator,
        \\{{> if SYSTEM.os == lifoox <}}
        \\val="Foo"
        \\{{> elif SYSTEM.os == {s} <}}
        \\val="Zoot"
        \\{{> else <}}
        \\val="Else"
        \\{{> end <}}
        \\{{> if SYSTEM.arch == {s} <}}
        \\val="test0-back"
        \\{{> else <}}
        \\val="test1"
        \\{{> end <}}
        \\
        \\{{> if SYSTEM.hostname == not_my_machine <}}
        \\val="HOST2"
        \\{{> else <}}
        \\val="HOST3"
        \\{{> end <}}
        \\
    ,
        .{ os, arch },
    ) catch unreachable;

    defer testing.allocator.free(expected_template);

    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "forward" {
    const os = @tagName(builtin.target.os.tag);
    var allocator = std.testing.allocator;

    const template = std.fmt.allocPrint(
        testing.allocator,
        \\{{> if SYSTEM.os == foo <}}
        \\val="Foo"
        \\{{> elif SYSTEM.os == {s} <}}
        \\val="Bar"
        \\{{> else <}}
        \\val="Else"
        \\{{> end <}}
        \\
    ,
        .{os},
    ) catch unreachable;

    defer testing.allocator.free(template);

    const rendered_expected =
        \\val="Bar"
        \\
    ;

    const rendered = try applyTemplate(allocator, template);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(rendered_expected, rendered);
}

test "forward-inline" {
    const os = @tagName(builtin.target.os.tag);
    var allocator = std.testing.allocator;

    const template = std.fmt.allocPrint(
        testing.allocator,
        \\{{> if SYSTEM.os == foo <}}val="Foo"{{> elif SYSTEM.os == {s} <}}val="Bar"{{> else <}}val="Else"{{> end <}}
        \\
    ,
        .{os},
    ) catch unreachable;

    defer testing.allocator.free(template);

    const rendered_expected =
        \\val="Bar"
        \\
    ;

    const rendered = try applyTemplate(allocator, template);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings(rendered_expected, rendered);
}

test "back-template" {
    const os = @tagName(builtin.target.os.tag);
    var allocator = std.testing.allocator;

    const template = std.fmt.allocPrint(
        testing.allocator,
        \\{{> if SYSTEM.os == foo <}}
        \\val="Foo"
        \\{{> elif SYSTEM.os == {s} <}}
        \\val="Bar"
        \\{{> else <}}
        \\val="Else"
        \\{{> end <}}
        \\
    ,
        .{os},
    ) catch unreachable;

    defer testing.allocator.free(template);

    const rendered_user_edit =
        \\val="Zoot"
        \\
    ;

    const reversed = try reverseTemplate(allocator, rendered_user_edit, template);
    defer allocator.free(reversed);

    const expected_template = std.fmt.allocPrint(
        testing.allocator,
        \\{{> if SYSTEM.os == foo <}}
        \\val="Foo"
        \\{{> elif SYSTEM.os == {s} <}}
        \\val="Zoot"
        \\{{> else <}}
        \\val="Else"
        \\{{> end <}}
        \\
    ,
        .{os},
    ) catch unreachable;

    defer testing.allocator.free(expected_template);

    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "back-no_template" {
    const os = @tagName(builtin.target.os.tag);
    var allocator = std.testing.allocator;

    const template = std.fmt.allocPrint(
        testing.allocator,
        \\FOO
        \\{{> if SYSTEM.os == {s} <}}
        \\val="Foo"
        \\{{> elif SYSTEM.os == foo <}}
        \\val="Bar"
        \\{{> else <}}
        \\val="Else"
        \\{{> end <}}
        \\
    ,
        .{os},
    ) catch unreachable;

    defer testing.allocator.free(template);

    const rendered_user_edit =
        \\BAR
        \\val="Zoot"
        \\
    ;

    const reversed = try reverseTemplate(allocator, rendered_user_edit, template);
    defer allocator.free(reversed);

    const expected_template = std.fmt.allocPrint(
        testing.allocator,
        \\BAR
        \\{{> if SYSTEM.os == {s} <}}
        \\val="Zoot"
        \\{{> elif SYSTEM.os == foo <}}
        \\val="Bar"
        \\{{> else <}}
        \\val="Else"
        \\{{> end <}}
        \\
    ,
        .{os},
    ) catch unreachable;

    defer testing.allocator.free(expected_template);

    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "mixed" {
    const os = @tagName(builtin.target.os.tag);
    var allocator = std.testing.allocator;

    const template = std.fmt.allocPrint(
        testing.allocator,
        \\FOO
        \\{{> if SYSTEM.os == foo <}}
        \\val="Foo"
        \\{{> elif SYSTEM.os == {s} <}}
        \\val="Bar"
        \\{{> else <}}
        \\val="Else"
        \\{{> end <}}
        \\
    ,
        .{os},
    ) catch unreachable;

    defer testing.allocator.free(template);

    const rendered_user_edit =
        \\BAR
        \\val="Zoot"
        \\
    ;

    const reversed = try reverseTemplate(allocator, rendered_user_edit, template);
    defer allocator.free(reversed);

    const expected_template = std.fmt.allocPrint(
        testing.allocator,
        \\BAR
        \\{{> if SYSTEM.os == foo <}}
        \\val="Foo"
        \\{{> elif SYSTEM.os == {s} <}}
        \\val="Zoot"
        \\{{> else <}}
        \\val="Else"
        \\{{> end <}}
        \\
    ,
        .{os},
    ) catch unreachable;

    defer testing.allocator.free(expected_template);

    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "mixed-inlie" {
    const os = @tagName(builtin.target.os.tag);
    var allocator = std.testing.allocator;

    const template = std.fmt.allocPrint(
        testing.allocator,
        \\FOO
        \\{{> if SYSTEM.os == foo <}}val="Foo"{{> elif SYSTEM.os == {s} <}}val="Bar"{{> else <}}val="Else"{{> end <}}
        \\
    ,
        .{os},
    ) catch unreachable;

    defer testing.allocator.free(template);

    const rendered_user_edit =
        \\BAR
        \\val="Zoot"
        \\
    ;

    const reversed = try reverseTemplate(allocator, rendered_user_edit, template);
    defer allocator.free(reversed);

    const expected_template = std.fmt.allocPrint(
        testing.allocator,
        \\BAR
        \\{{> if SYSTEM.os == foo <}}val="Foo"{{> elif SYSTEM.os == {s} <}}val="Zoot"{{> else <}}val="Else"{{> end <}}
        \\
    ,
        .{os},
    ) catch unreachable;

    defer testing.allocator.free(expected_template);

    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "mixed-else" {
    var allocator = std.testing.allocator;

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

    const reversed = try reverseTemplate(allocator, rendered_user_edit, template);
    defer allocator.free(reversed);

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

test "blocks" {
    const os = @tagName(builtin.target.os.tag);
    const arch = @tagName(builtin.cpu.arch);
    var allocator = std.testing.allocator;

    const template = std.fmt.allocPrint(
        testing.allocator,
        \\FOO
        \\{{> if SYSTEM.os == foo <}}
        \\val="Foo"
        \\{{> elif SYSTEM.os == {s} <}}
        \\val="Bar"
        \\{{> else <}}
        \\val="Else"
        \\{{> end <}}
        \\{{> if SYSTEM.arch == {s} <}}
        \\val="test0"
        \\{{> else <}}
        \\val="test1"
        \\{{> end <}}
        \\
        \\{{> if SYSTEM.hostname == not_my_machine <}}
        \\val="HOST2"
        \\{{> else <}}
        \\val="HOST1"
        \\{{> end <}}
        \\
    ,
        .{ os, arch },
    ) catch unreachable;

    defer testing.allocator.free(template);

    const rendered_user_edit =
        \\BAR
        \\val="Zoot"
        \\val="test0-back"
        \\
        \\val="HOST3"
        \\
    ;

    const reversed = try reverseTemplate(allocator, rendered_user_edit, template);
    defer allocator.free(reversed);

    const expected_template = std.fmt.allocPrint(
        testing.allocator,
        \\BAR
        \\{{> if SYSTEM.os == foo <}}
        \\val="Foo"
        \\{{> elif SYSTEM.os == {s} <}}
        \\val="Zoot"
        \\{{> else <}}
        \\val="Else"
        \\{{> end <}}
        \\{{> if SYSTEM.arch == {s} <}}
        \\val="test0-back"
        \\{{> else <}}
        \\val="test1"
        \\{{> end <}}
        \\
        \\{{> if SYSTEM.hostname == not_my_machine <}}
        \\val="HOST2"
        \\{{> else <}}
        \\val="HOST3"
        \\{{> end <}}
        \\
    ,
        .{ os, arch },
    ) catch unreachable;

    defer testing.allocator.free(expected_template);

    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "blocks-mixed" {
    const os = @tagName(builtin.target.os.tag);
    const arch = @tagName(builtin.cpu.arch);
    var allocator = std.testing.allocator;

    const template = std.fmt.allocPrint(
        testing.allocator,
        \\FOO
        \\val="{{> if SYSTEM.os == {s} <}}Inline{{> else <}}Bar{{> end <}}"
        \\{{> if SYSTEM.arch == {s} <}}
        \\val="test0"
        \\{{> else <}}
        \\val="test1"
        \\{{> end <}}
        \\
        \\val="{{> if SYSTEM.hostname == not_my_machine <}}HOST2{{> else <}}HOST1{{> end <}}"
        \\
    ,
        .{ os, arch },
    ) catch unreachable;

    defer testing.allocator.free(template);

    const render = try applyTemplate(allocator, template);
    defer allocator.free(render);

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
