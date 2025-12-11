//! LIBDFS
//!
//! This is a template engine with reverse translation capability.
//! Translations are mapped via the Myers difference algorithm.

// {> x <}
pub const TAG_START = "{>";
pub const TAG_END = "<}";

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

pub const SYSTEM = enum {
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
        if (self.lhs.len == 0) return TemplateError.InvalidCondition;

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

        return .{
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

        return .{
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

fn tokenize(allocator: std.mem.Allocator, template: []const u8) ![]Token {
    var tokens = std.array_list.Managed(Token).init(allocator);
    errdefer tokens.deinit();

    var i: usize = 0;
    while (i < template.len) {
        const start_tag = std.mem.indexOfPos(u8, template, i, TAG_START);
        if (start_tag == null) {
            if (i < template.len) try tokens.append(.{ .text = template[i..] });
            break;
        }

        const tag_start = start_tag.?;

        // push preceding text if any
        if (tag_start > i) try tokens.append(
            .{ .text = template[i..tag_start] },
        );

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
    return try out.toOwnedSlice();
}

fn parseTag(template: []const u8, i: usize) !Tag {
    // i should point to the { of TAG_START
    if (!std.mem.startsWith(u8, template[i..], TAG_START))
        return TemplateError.InvalidTag;

    const start = i + TAG_START.len;
    const rel_end = std.mem.indexOf(u8, template[start..], TAG_END) orelse
        return TemplateError.MissingDelimiter;

    const raw = template[start .. start + rel_end];

    return .{
        .raw = raw,
        .trim = trimTag(raw),
        .after = start + rel_end + TAG_END.len,
    };
}

fn evalBranch(
    allocator: std.mem.Allocator,
    tag_content: []const u8,
    branch_taken: bool,
) !Branch {
    if (std.mem.eql(u8, tag_content, "endif"))
        return .{ .active = false, .condition = null };

    if (std.mem.eql(u8, tag_content, "else"))
        return .{ .active = !branch_taken, .condition = null };

    const condition = if (std.mem.startsWith(u8, tag_content, "if "))
        tag_content[3..]
    else if (std.mem.startsWith(u8, tag_content, "elif "))
        tag_content[5..]
    else
        return TemplateError.InvalidTag;

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

        if (std.mem.eql(u8, tag_info.content, "endif")) return i + 1;

        const branch = try evalBranch(
            allocator,
            tag_info.content,
            branch_taken,
        );

        var body: []const u8 = &[_]u8{};
        var has_body = false;

        if (i + 1 < tokens.len and tokens[i + 1] == .text) {
            body = tokens[i + 1].text;
            has_body = true;
        }

        if (branch.active) {
            branch_taken = true;
            // preserve body
            try w.print("{s}", .{body});
        }

        i += if (has_body) 2 else 1;

        if (i < tokens.len and tokens[i] != .tag)
            return TemplateError.InvalidTag;
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

    if (!hasAnyConditionals(tokens)) {
        const result = try allocator.dupe(u8, render);
        return try normalizeTrailing(allocator, result, template);
    }

    // get the original render from the template
    const original_render = try applyTemplate(allocator, template);
    defer allocator.free(original_render);

    // diff the original render against the edited render
    const edits = try Myers.diff(allocator, original_render, render);
    defer allocator.free(edits);

    // build replacement maps
    var replacements = try allocator.alloc(u8, original_render.len);
    defer allocator.free(replacements);
    var replacement_valid = try allocator.alloc(bool, original_render.len);
    defer allocator.free(replacement_valid);
    @memset(replacement_valid, false);

    var insertions = std.AutoHashMap(usize, []const u8).init(allocator);
    defer insertions.deinit();

    // build deletion tracking and process all edits
    var had_deletion = try allocator.alloc(bool, original_render.len);
    defer allocator.free(had_deletion);
    @memset(had_deletion, false);

    var old_pos_tracker: usize = 0;

    for (edits) |edit| {
        switch (edit) {
            .equal => |e| {
                if (e.old_index != old_pos_tracker) {
                    old_pos_tracker = e.old_index;
                }

                for (0..e.count) |i| {
                    const old_pos = e.old_index + i;
                    const new_pos = e.new_index + i;
                    replacements[old_pos] = render[new_pos];
                    replacement_valid[old_pos] = true;
                }

                old_pos_tracker = e.old_index + e.count;
            },
            .delete => |d| {
                if (d.old_index != old_pos_tracker) {
                    old_pos_tracker = d.old_index;
                }

                for (0..d.count) |i| {
                    const pos = d.old_index + i;
                    replacement_valid[pos] = false;
                    if (pos < had_deletion.len) {
                        had_deletion[pos] = true;
                    }
                }

                // mark the position after deletion too
                // (where insertion goes)
                const after_pos = d.old_index + d.count;

                if (after_pos < had_deletion.len) {
                    had_deletion[after_pos] = true;
                }

                old_pos_tracker = after_pos;
            },
            .insert => |ins| {
                const insert_text =
                    render[ins.new_index .. ins.new_index + ins.count];

                try insertions.put(old_pos_tracker, insert_text);
            },
        }
    }

    var ctx = ReverseContext{
        .allocator = allocator,
        .replacements = replacements,
        .replacement_valid = replacement_valid,
        .insertions = &insertions,
        .had_deletion = had_deletion,
        .old_pos = 0,
    };

    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    try reverseTokens(tokens, &ctx, &out);

    const result = try out.toOwnedSlice();
    return try normalizeTrailing(allocator, result, template);
}

const ReverseContext = struct {
    allocator: std.mem.Allocator,
    replacements: []u8,
    replacement_valid: []bool,
    had_deletion: []bool,
    insertions: *std.AutoHashMap(usize, []const u8),
    old_pos: usize,
};

fn reverseTokens(
    tokens: []Token,
    ctx: *ReverseContext,
    out: *std.array_list.Managed(u8),
) !void {
    var i: usize = 0;
    while (i < tokens.len) {
        switch (tokens[i]) {
            .text => |text| {
                try applyReplacements(text, ctx, out);
                i += 1;
            },
            .tag => |tag_info| {
                if (std.mem.startsWith(u8, tag_info.content, "if")) {
                    i = try reverseIfBlock(tokens, i, ctx, out);
                } else {
                    return TemplateError.InvalidTag;
                }
            },
        }
    }
}

fn applyReplacements(
    text: []const u8,
    ctx: *ReverseContext,
    out: *std.array_list.Managed(u8),
) !void {
    const start_pos = ctx.old_pos;
    const end_pos = start_pos + text.len;

    // determine the actual end of the rendered content for this block
    const render_end = @min(end_pos, ctx.replacement_valid.len);

    // if the template text starts with a newline, always output it
    // (newlines after tags are structural and should always be preserved)
    var i: usize = 0;
    if (text.len > 0 and text[0] == '\n') {
        // check for an insertion at position 0 (always allowed)
        if (start_pos < render_end) {
            if (ctx.insertions.get(start_pos)) |insert_text| {
                try out.appendSlice(insert_text);
            }
        }

        try out.append('\n');
        i = 1;
    }

    // for each remaining byte position
    while (i < text.len) : (i += 1) {
        const old_pos = start_pos + i;

        // check if we're beyond the rendered content for this block
        if (old_pos >= render_end) {
            // output the remaining template raw
            try out.appendSlice(text[i..]);
            break;
        }

        // check for an insertion at this position
        const is_valid = ctx.replacement_valid[old_pos];
        const prev_pos = if (old_pos > start_pos) old_pos - 1 else old_pos;
        const prev_valid = if (prev_pos < ctx.replacement_valid.len and
            ctx.replacement_valid[prev_pos])
            (ctx.replacements[prev_pos] != '\n')
        else
            false;

        // check if we got past a newline in the template
        const after_template_newline = (i > 0 and text[i - 1] == '\n');

        // apply an insertion if valid conditions
        // are met, but not after a newline
        if (!after_template_newline and
            (is_valid or prev_valid or
                (old_pos < ctx.had_deletion.len and ctx.had_deletion[old_pos])))
        {
            if (ctx.insertions.get(old_pos)) |insert_text| {
                try out.appendSlice(insert_text);
                _ = ctx.insertions.remove(old_pos);
            }
        }

        // output the character if is a valid one (not deleted)
        if (is_valid) {
            try out.append(ctx.replacements[old_pos]);
        } else if (text[i] == '\n') {
            // TODO
            try out.append('\n');
        }
    }

    ctx.old_pos = end_pos;
}

fn reverseIfBlock(
    tokens: []Token,
    start: usize,
    ctx: *ReverseContext,
    out: *std.array_list.Managed(u8),
) !usize {
    var i = start;
    var branch_taken = false;

    while (i < tokens.len) {
        const tag_info = switch (tokens[i]) {
            .tag => |t| t,
            else => return TemplateError.InvalidToken,
        };

        try out.appendSlice(TAG_START);
        try out.appendSlice(tag_info.raw);
        try out.appendSlice(TAG_END);

        if (std.mem.eql(u8, tag_info.content, "endif")) {
            return i + 1;
        }

        i += 1;

        var body: []const u8 = &[_]u8{};
        var has_body = false;

        if (i < tokens.len and tokens[i] == .text) {
            body = tokens[i].text;
            has_body = true;
        }

        const branch = try evalBranch(
            ctx.allocator,
            tag_info.content,
            branch_taken,
        );

        if (branch.active) {
            branch_taken = true;
            // this branch was rendered—apply replacements
            try applyReplacements(body, ctx, out);
        } else {
            // this branch was not rendered—keep the original
            // and do not advance old_pos
            try out.appendSlice(body);
        }

        if (has_body) i += 1;
    }

    return TemplateError.MissingEndTag;
}

fn hasAnyConditionals(tokens: []Token) bool {
    for (tokens) |token| {
        if (token == .tag) return true;
    }
    return false;
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
        "XDG_SESSION_DESKTOP",
    ) catch {
        const desktop_session = std.process.getEnvVarOwned(
            allocator,
            "DESKTOP_SESSION",
        ) catch {
            const current_desktop = std.process.getEnvVarOwned(
                allocator,
                "XDG_CURRENT_DESKTOP",
            ) catch
                return std.ascii.allocLowerString(allocator, "UNKNOWN");
            defer allocator.free(current_desktop);
            return std.ascii.allocLowerString(allocator, current_desktop);
        };

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
            } else if (std.mem.eql(u8, tag.trim, "endif")) {
                if (if_depth == 0) {
                    return ValidationResult{
                        .err = .{
                            .err = TemplateError.MismatchedEnd,
                            .line = tag_line,
                            .column = tag_column,
                            .message = "Mismatched 'endif' tag without a matching 'if'",
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
            \\{> endif <}
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
            \\{> endif <}
        ;

        const result_orphaned_elif = validate(template_orphaned_elif);
        try testing.expect(result_orphaned_elif.isError());
        try testing.expectEqual(TemplateError.OrphanedElseElif, result_orphaned_elif.err.err);
    }

    {
        const template_mismatched = "{> endif <}";
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
        const template_bad_if_format = "{> ifSYSTEM.os == linux <}content{> endif <}";
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
            \\{> endif <}
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
            \\{> endif <}
        ;

        const result = validate(template_bad_elif_cond);
        try testing.expect(result.isError());
        try testing.expectEqual(TemplateError.InvalidCondition, result.err.err);
        try testing.expectEqualStrings("Invalid 'elif' condition syntax", result.err.message);
    }

    {
        const template_bad_condition_parts = "{> if SYSTEM.os <}content{> endif <}";
        const result_bad_condition_parts = validate(template_bad_condition_parts);
        try testing.expect(result_bad_condition_parts.isError());
        try testing.expectEqual(TemplateError.InvalidCondition, result_bad_condition_parts.err.err);
    }

    {
        const template_bad_lhs = "{> if INVALID.var == value <}content{> endif <}";
        const result_bad_lhs = validate(template_bad_lhs);
        try testing.expect(result_bad_lhs.isError());
        try testing.expectEqual(TemplateError.InvalidCondition, result_bad_lhs.err.err);
    }

    {
        const template_bad_operator = "{> if SYSTEM.os >= linux <}content{> endif <}";
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
            \\{> endif <}
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
            \\{> endif <}
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
            \\{> endif <}
            \\{> endif <}
        ;

        const result_valid_nested = validate(template_valid_nested);
        try testing.expect(!result_valid_nested.isError());
    }

    {
        const template_valid_multiple =
            \\{> if SYSTEM.os == freebsd <}
            \\first_block
            \\{> endif <}
            \\some text
            \\{> if SYSTEM.arch == arm64 <}
            \\second_block
            \\{> endif <}
        ;

        const result_valid_multiple = validate(template_valid_multiple);
        try testing.expect(!result_valid_multiple.isError());
    }

    {
        const template_valid_all_vars =
            \\{> if SYSTEM.os == openbsd <}os_content{> endif <}
            \\{> if SYSTEM.hostname == host <}host_content{> endif <}
            \\{> if SYSTEM.arch == x86_64 <}arch_content{> endif <}
        ;

        const result_valid_all_vars = validate(template_valid_all_vars);
        try testing.expect(!result_valid_all_vars.isError());
    }

    {
        const template_valid_operators =
            \\{> if SYSTEM.os == linux <}equal{> endif <}
            \\{> if SYSTEM.os != windows <}not_equal{> endif <}
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
            \\{> endif <}
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
            \\{> endif <}
            \\
        ;

        const tokenized = try tokenize(std.testing.allocator, template);
        defer std.testing.allocator.free(tokenized);

        const interpreted = try interpret(std.testing.allocator, tokenized);
        defer std.testing.allocator.free(interpreted);

        try std.testing.expectEqualStrings("FOO\n\nval=\"HOST1\"\n\n", interpreted);
    }
}

test tokenize {
    const template_invalid =
        \\FOO{> xx
    ;

    const failure = tokenize(std.testing.allocator, template_invalid);
    try std.testing.expectError(TemplateError.MissingDelimiter, failure);

    const template =
        \\FOO{> if SYSTEM.hostname == gibson <}val="HOST2"{> else <}val="HOST1"{> endif <}
    ;

    const tokenized = try tokenize(std.testing.allocator, template);
    defer std.testing.allocator.free(tokenized);

    try std.testing.expectEqualStrings("FOO", tokenized[0].text);
    try std.testing.expectEqualStrings("if SYSTEM.hostname == gibson", tokenized[1].tag.content);
    try std.testing.expectEqualStrings("val=\"HOST2\"", tokenized[2].text);
    try std.testing.expectEqualStrings("else", tokenized[3].tag.content);
    try std.testing.expectEqualStrings("val=\"HOST1\"", tokenized[4].text);
    try std.testing.expectEqualStrings("endif", tokenized[5].tag.content);
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
    try testing.expectEqualStrings("endif", trimTag("endif"));
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
            .{ .tag = .{ .content = "endif", .raw = " endif ", .start = 0, .end = 10 } },
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
            .{ .tag = .{ .content = "endif", .raw = " endif ", .start = 20, .end = 30 } },
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
            .{ .tag = .{ .content = "endif", .raw = " endif ", .start = 0, .end = 5 } },
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
        \\{{> endif <}}
        \\{{> if SYSTEM.arch == {s} <}}
        \\val="test0"
        \\{{> else <}}
        \\val="test1"
        \\{{> endif <}}
        \\
        \\{{> if SYSTEM.hostname == {s} <}}
        \\val="HOST1"
        \\{{> else <}}
        \\val="HOST2"
        \\{{> endif <}}
        \\val="{{> if SYSTEM.desktop == Z00t <}}13{{> else <}}23{{> endif <}}"
        \\
    ,
        .{ os, arch, host },
    ) catch unreachable;

    defer allocator.free(template);

    const rendered_expected =
        \\
        \\val="Bar"
        \\
        \\
        \\val="test0"
        \\
        \\
        \\
        \\val="HOST1"
        \\
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
        \\{{> endif <}}
        \\{{> if SYSTEM.arch == {s} <}}
        \\val="test0"
        \\{{> else <}}
        \\val="test1"
        \\{{> endif <}}
        \\
        \\{{> if SYSTEM.hostname == not_my_machine <}}
        \\val="HOST2"
        \\{{> else <}}
        \\val="HOST1"
        \\{{> endif <}}
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
        \\{{> endif <}}
        \\{{> if SYSTEM.arch == {s} <}}
        \\val="test0-back"
        \\{{> else <}}
        \\val="test1"
        \\{{> endif <}}
        \\
        \\{{> if SYSTEM.hostname == not_my_machine <}}
        \\val="HOST2"
        \\{{> else <}}
        \\val="HOST3"
        \\{{> endif <}}
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
        \\{{> endif <}}
        \\
    ,
        .{os},
    ) catch unreachable;

    defer testing.allocator.free(template);

    const rendered_expected =
        \\
        \\val="Bar"
        \\
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
        \\{{> if SYSTEM.os == foo <}}val="Foo"{{> elif SYSTEM.os == {s} <}}val="Bar"{{> else <}}val="Else"{{> endif <}}
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
        \\{{> endif <}}
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
        \\{{> endif <}}
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
        \\{{> endif <}}
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
        \\{{> endif <}}
        \\
    ,
        .{os},
    ) catch unreachable;

    defer testing.allocator.free(expected_template);

    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "complex" {
    const os = @tagName(builtin.target.os.tag);
    const arch = @tagName(builtin.cpu.arch);
    var allocator = std.testing.allocator;

    const template = std.fmt.allocPrint(
        testing.allocator,
        \\FOO
        \\# {{> if SYSTEM.os == foo <}}
        \\val="Foo"
        \\# {{> elif SYSTEM.os == {s} <}}
        \\val="Bar"
        \\# {{> else <}}
        \\val="Else"
        \\# {{> endif <}}
        \\ Test
        \\# {{> if SYSTEM.arch == {s} <}}
        \\test_val=23
        \\# {{> elif SYSTEM.arch == foo <}}
        \\test_val=0
        \\# {{> else <}}
        \\test_val=13
        \\# {{> endif <}}
        \\
    ,
        .{ os, arch },
    ) catch unreachable;

    defer testing.allocator.free(template);

    const rendered_user_edit =
        \\BAR
        \\# 
        \\val="Zoot"
        \\# 
        \\# 
        \\# 
        \\ Test
        \\# 
        \\test_val=66
        \\# 
        \\# 
        \\# 
        \\
    ;

    const reversed = try reverseTemplate(allocator, rendered_user_edit, template);
    defer allocator.free(reversed);

    const expected_template = std.fmt.allocPrint(
        testing.allocator,
        \\BAR
        \\# {{> if SYSTEM.os == foo <}}
        \\val="Foo"
        \\# {{> elif SYSTEM.os == {s} <}}
        \\val="Zoot"
        \\# {{> else <}}
        \\val="Else"
        \\# {{> endif <}}
        \\ Test
        \\# {{> if SYSTEM.arch == {s} <}}
        \\test_val=66
        \\# {{> elif SYSTEM.arch == foo <}}
        \\test_val=0
        \\# {{> else <}}
        \\test_val=13
        \\# {{> endif <}}
        \\
    ,
        .{ os, arch },
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
        \\#{{> if SYSTEM.os == foo <}}
        \\val="Foo"
        \\# {{> elif SYSTEM.os == {s} <}}
        \\val="Bar"
        \\;;{{> else <}}
        \\val="Else"
        \\//{{> endif <}}
        \\
    ,
        .{os},
    ) catch unreachable;

    defer testing.allocator.free(template);

    const rendered_user_edit =
        \\BAR
        \\#
        \\val="Zoot"
        \\# 
        \\;;
        \\//
        \\
    ;

    const reversed = try reverseTemplate(allocator, rendered_user_edit, template);
    defer allocator.free(reversed);

    const expected_template = std.fmt.allocPrint(
        testing.allocator,
        \\BAR
        \\#{{> if SYSTEM.os == foo <}}
        \\val="Foo"
        \\# {{> elif SYSTEM.os == {s} <}}
        \\val="Zoot"
        \\;;{{> else <}}
        \\val="Else"
        \\//{{> endif <}}
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
        \\{{> if SYSTEM.os == foo <}}val="Foo"{{> elif SYSTEM.os == {s} <}}val="Bar"{{> else <}}val="Else"{{> endif <}}
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
        \\{{> if SYSTEM.os == foo <}}val="Foo"{{> elif SYSTEM.os == {s} <}}val="Zoot"{{> else <}}val="Else"{{> endif <}}
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
        \\{> endif <}
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
        \\{> endif <}
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
        \\{{> endif <}}
        \\{{> if SYSTEM.arch == {s} <}}
        \\val="test0"
        \\{{> else <}}
        \\val="test1"
        \\{{> endif <}}
        \\
        \\{{> if SYSTEM.hostname == not_my_machine <}}
        \\val="HOST2"
        \\{{> else <}}
        \\val="HOST1"
        \\{{> endif <}}
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
        \\{{> endif <}}
        \\{{> if SYSTEM.arch == {s} <}}
        \\val="test0-back"
        \\{{> else <}}
        \\val="test1"
        \\{{> endif <}}
        \\
        \\{{> if SYSTEM.hostname == not_my_machine <}}
        \\val="HOST2"
        \\{{> else <}}
        \\val="HOST3"
        \\{{> endif <}}
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
        \\val="{{> if SYSTEM.os == {s} <}}Inline{{> else <}}Bar{{> endif <}}"
        \\{{> if SYSTEM.arch == {s} <}}
        \\val="test0"
        \\{{> else <}}
        \\val="test1"
        \\{{> endif <}}
        \\
        \\val="{{> if SYSTEM.hostname == not_my_machine <}}HOST2{{> else <}}HOST1{{> endif <}}"
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
        \\
        \\val="test0"
        \\
        \\
        \\val="HOST1"
        \\
    ;

    try std.testing.expectEqualStrings(render, expected);
}

const std = @import("std");
const builtin = @import("builtin");
pub const Myers = @import("myers.zig");
const testing = std.testing;
