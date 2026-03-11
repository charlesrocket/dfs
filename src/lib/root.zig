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

    // check if RHS is not empty
    return parsed.rhs.len > 0;
}

fn evalCondition(allocator: std.mem.Allocator, cond: []const u8) !bool {
    const parsed = try parseCondition(cond);

    const var_type = SYSTEM.fromString(parsed.lhs) orelse return false;
    const actual_value = var_type.getValue(allocator) catch return false;
    const should_free = var_type.shouldFree();

    defer if (should_free) allocator.free(actual_value);

    return try parsed.compare(actual_value);
}

fn tokenize(allocator: std.mem.Allocator, template: []const u8) ![]Token {
    var tokens = std.ArrayList(Token).empty;
    errdefer tokens.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        const start_tag = std.mem.indexOfPos(u8, template, i, TAG_START);
        if (start_tag == null) {
            if (i < template.len) try tokens.append(allocator, .{ .text = template[i..] });
            break;
        }

        const tag_start = start_tag.?;

        // push preceding text if any
        if (tag_start > i) try tokens.append(
            allocator,
            .{ .text = template[i..tag_start] },
        );

        const tag = try parseTag(template, tag_start);

        try tokens.append(allocator, .{ .tag = .{
            .content = tag.trim,
            .raw = tag.raw,
            .start = tag_start,
            .end = tag.after,
        } });

        i = tag.after;
    }

    return try tokens.toOwnedSlice(allocator);
}

fn interpret(allocator: std.mem.Allocator, tokens: []Token) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var w = out.writer(allocator);
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

    return try out.toOwnedSlice(allocator);
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

fn isActiveBranch(
    allocator: std.mem.Allocator,
    tag_content: []const u8,
    branch_taken: bool,
) !bool {
    if (std.mem.eql(u8, tag_content, "endif"))
        return false;

    if (std.mem.eql(u8, tag_content, "else"))
        return !branch_taken;

    if (std.mem.startsWith(u8, tag_content, "if "))
        return try evalCondition(allocator, tag_content[3..]);

    if (std.mem.startsWith(u8, tag_content, "elif "))
        return !branch_taken and try evalCondition(allocator, tag_content[5..]);

    return TemplateError.InvalidTag;
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

    while (i < tokens.len) {
        const tag_info = switch (tokens[i]) {
            .tag => |t| t,
            else => return TemplateError.InvalidToken,
        };

        if (std.mem.eql(u8, tag_info.content, "endif")) return i + 1;

        const active = try isActiveBranch(allocator, tag_info.content, branch_taken);

        var body: []const u8 = &[_]u8{};
        var has_body = false;

        if (i + 1 < tokens.len and tokens[i + 1] == .text) {
            body = tokens[i + 1].text;
            has_body = true;
        }

        if (active) {
            branch_taken = true;
            // preserve body
            try w.print("{s}", .{body});
        }

        i += if (has_body) 2 else 1;

        // after advancing, the next token (if any) must be a tag
        if (i < tokens.len) {
            switch (tokens[i]) {
                .tag => {}, // expected, continue
                .text => return TemplateError.InvalidTag, // malformed
            }
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

fn generateSegments(
    allocator: std.mem.Allocator,
    template: []const u8,
) !std.ArrayList([]const u8) {
    var segments = std.ArrayList([]const u8).empty;
    errdefer segments.deinit(allocator);

    var start: usize = 0;
    var i: usize = 0;
    var depth: usize = 0;

    while (i < template.len) {
        if (std.mem.startsWith(u8, template[i..], TAG_START)) {
            const tag = parseTag(template, i) catch {
                i += 1;
                continue;
            };

            const tag_content = tag.trim;

            if (std.mem.startsWith(u8, tag_content, "if ")) {
                depth += 1;

                if (depth == 1) {
                    if (start < i) {
                        try segments.append(allocator, template[start..i]);
                    }

                    start = i;
                }
            } else if (std.mem.eql(u8, tag_content, "endif")) {
                if (depth == 0) {
                    return TemplateError.MismatchedEnd;
                } else {
                    depth -= 1;

                    if (depth == 0) {
                        try segments.append(allocator, template[start..tag.after]);
                        start = tag.after;
                    }
                }
            }

            i = tag.after;
        } else {
            i += 1;
        }
    }

    if (start < template.len) {
        try segments.append(allocator, template[start..]);
    }

    return segments;
}

/// Translates the rendered file back to the template and returns the result.
/// The caller owns the returned memory.
pub fn reverseTemplate(
    allocator: std.mem.Allocator,
    render: []const u8,
    template: []const u8,
) ![]const u8 {
    var segments = try generateSegments(allocator, template);
    defer segments.deinit(allocator);

    const original_render = try applyTemplate(allocator, template);
    defer allocator.free(original_render);

    var render_map = std.ArrayList(struct {
        segment: []const u8,
        rendered: []const u8,
    }).empty;

    defer {
        for (render_map.items) |item| {
            allocator.free(item.rendered);
        }

        render_map.deinit(allocator);
    }

    for (segments.items) |segment| {
        const rendered = try applyTemplate(allocator, segment);

        try render_map.append(allocator, .{
            .segment = segment,
            .rendered = rendered,
        });
    }

    const diff = try Myers.diff(allocator, original_render, render);
    defer allocator.free(diff);

    // build position mappings (do not map deleted positions)
    var pos_map = std.AutoHashMap(usize, usize).init(allocator);
    defer pos_map.deinit();

    var insertions = std.ArrayList(struct {
        orig_pos: usize,
        new_index: usize,
        count: usize,
    }).empty;

    defer insertions.deinit(allocator);

    const old_cp_to_byte = try buildCpToByteMap(allocator, original_render);
    defer allocator.free(old_cp_to_byte);

    const new_cp_to_byte = try buildCpToByteMap(allocator, render);
    defer allocator.free(new_cp_to_byte);

    var old_pos: usize = 0;
    var new_pos: usize = 0;

    for (diff) |op| {
        switch (op) {
            .equal => |eq| {
                var i: usize = 0;
                while (i < eq.count) : (i += 1) {
                    const old_byte_start = old_cp_to_byte[old_pos + i];
                    const old_byte_end = old_cp_to_byte[old_pos + i + 1];
                    const new_byte_start = new_cp_to_byte[new_pos + i];

                    for (0..(old_byte_end - old_byte_start)) |b| {
                        try pos_map.put(old_byte_start + b, new_byte_start + b);
                    }
                }

                old_pos += eq.count;
                new_pos += eq.count;
            },
            .delete => |del| {
                // deleted positions don't exist in the new render
                old_pos += del.count;
            },
            .insert => |ins| {
                const orig_byte = if (old_pos < old_cp_to_byte.len - 1)
                    old_cp_to_byte[old_pos]
                else
                    original_render.len;

                const new_byte_start = new_cp_to_byte[ins.new_index];
                const new_byte_end = new_cp_to_byte[ins.new_index + ins.count];

                try insertions.append(allocator, .{
                    .orig_pos = orig_byte,
                    .new_index = new_byte_start,
                    .count = new_byte_end - new_byte_start,
                });

                new_pos += ins.count;
            },
        }
    }

    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    // track which original positions had deletions
    var deleted_positions = std.AutoHashMap(usize, void).init(allocator);
    defer deleted_positions.deinit();

    var check_old_pos: usize = 0;
    for (diff) |op| {
        switch (op) {
            .equal => |eq| check_old_pos += eq.count,
            .delete => |del| {
                var k: usize = 0;
                while (k < del.count) : (k += 1) {
                    const byte_start = old_cp_to_byte[check_old_pos + k];
                    const byte_end = old_cp_to_byte[check_old_pos + k + 1];

                    for (byte_start..byte_end) |b| {
                        try deleted_positions.put(b, {});
                    }
                }

                check_old_pos += del.count;
            },
            .insert => {},
        }
    }

    var original_pos: usize = 0;

    for (render_map.items) |map| {
        const seg_orig_start = original_pos;
        const seg_orig_end = original_pos + map.rendered.len;

        // collect edited positions that map from this segment
        var reverse_map = std.AutoHashMap(usize, void).init(allocator);
        defer reverse_map.deinit();

        var i: usize = seg_orig_start;
        while (i < seg_orig_end) : (i += 1) {
            if (pos_map.get(i)) |mapped_pos| {
                try reverse_map.put(mapped_pos, {});
            }
        }

        // add insertions that replace deleted content in this segment
        for (insertions.items) |ins| {
            const strictly_inside = ins.orig_pos > seg_orig_start and ins.orig_pos < seg_orig_end;
            const at_end_boundary = ins.orig_pos == seg_orig_end;

            // whether a deletion is adjacent to this insertion point
            const has_adjacent_deletion =
                deleted_positions.contains(ins.orig_pos) or
                (ins.orig_pos > 0 and deleted_positions.contains(ins.orig_pos - 1));

            // adjacent deletion is within this segment's bounds
            const deletion_in_seg =
                has_adjacent_deletion and
                (ins.orig_pos >= seg_orig_start and
                    (ins.orig_pos == 0 or ins.orig_pos - 1 >= seg_orig_start));

            // at start boundary: only claim if the triggering deletion is within this segment
            // (disambiguates: the deletion is within this segment, so the replacement belongs here)
            const at_start_boundary = ins.orig_pos == seg_orig_start and deletion_in_seg;
            if (!strictly_inside and !at_end_boundary and !at_start_boundary) continue;

            // for insertions without adjacent deletion (pure additions), only include
            // if they are inlined (both neighboring chars in original_render are non-whitespace)
            // (this captures value extensions like `test0` -> `test0-back`
            // but excludes between-line additions)
            if (!has_adjacent_deletion and strictly_inside) {
                const prev_is_ws = ins.orig_pos == 0 or blk: {
                    const c = original_render[ins.orig_pos - 1];
                    break :blk c == ' ' or c == '\t' or c == '\n' or c == '\r';
                };

                const next_is_ws = ins.orig_pos >= original_render.len or blk: {
                    const c = original_render[ins.orig_pos];
                    break :blk c == ' ' or c == '\t' or c == '\n' or c == '\r';
                };

                if (prev_is_ws or next_is_ws) {
                    continue;
                }
            }

            var j: usize = 0;
            while (j < ins.count) : (j += 1) {
                try reverse_map.put(ins.new_index + j, {});
            }
        }

        // extract the content from reverse_map (only positions that are mapped)
        const edited_content = if (reverse_map.count() > 0) blk: {
            var min_pos: usize = std.math.maxInt(usize);
            var max_pos: usize = 0;
            var iter = reverse_map.keyIterator();
            while (iter.next()) |pos| {
                min_pos = @min(min_pos, pos.*);
                max_pos = @max(max_pos, pos.*);
            }

            // extract only characters that are in reverse_map
            var chars = std.ArrayList(u8).empty;
            defer chars.deinit(allocator);
            var pos: usize = min_pos;
            while (pos <= max_pos) : (pos += 1) {
                if (reverse_map.contains(pos)) {
                    try chars.append(allocator, render[pos]);
                }
            }

            break :blk try chars.toOwnedSlice(allocator);
        } else "";

        defer allocator.free(edited_content);

        // update template
        const is_whitespace_only = for (map.rendered) |c| {
            if (c != '\n' and c != '\r' and c != ' ' and c != '\t') break false;
        } else true;

        if (std.mem.eql(u8, map.rendered, edited_content)) {
            try result.appendSlice(allocator, map.segment);
        } else if (std.mem.indexOf(u8, map.segment, TAG_START) == null and is_whitespace_only) {
            // whitespace-only plain-text separators between conditional
            // blocks are structural template text
            try result.appendSlice(allocator, map.segment);
        } else if (std.mem.indexOf(u8, map.segment, TAG_START) == null) {
            try result.appendSlice(allocator, edited_content);
        } else {
            const updated = try reverseTranslateConditional(
                allocator,
                map.segment,
                edited_content,
            );

            defer allocator.free(updated);
            try result.appendSlice(allocator, updated);
        }

        original_pos = seg_orig_end;
    }

    return result.toOwnedSlice(allocator);
}

fn reverseTranslateConditional(
    allocator: std.mem.Allocator,
    segment: []const u8,
    new_rendered: []const u8,
) ![]const u8 {
    const tokens = try tokenize(allocator, segment);
    defer allocator.free(tokens);

    var active_content_start: ?usize = null;
    var active_content_end: ?usize = null;

    var i: usize = 0;
    var branch_taken = false;

    while (i < tokens.len) {
        if (tokens[i] != .tag) {
            i += 1;
            continue;
        }

        const tag = tokens[i].tag;

        if (std.mem.eql(u8, tag.content, "endif")) break;

        // evaluate the branch header
        const active = try isActiveBranch(allocator, tag.content, branch_taken);

        // locate the body: from this tag's end to the next tag's start
        const content_start = tag.end;
        var content_end = segment.len;
        var j = i + 1;

        while (j < tokens.len) {
            if (tokens[j] == .tag) {
                content_end = tokens[j].tag.start;
                break;
            }

            j += 1;
        }

        if (active) {
            branch_taken = true;
            active_content_start = content_start;
            active_content_end = content_end;
            break;
        }

        // inactive: skip to the next tag
        i = j;
    }

    if (active_content_start) |start| {
        const end = active_content_end.?;
        const original_body = segment[start..end];

        var result = std.ArrayList(u8).empty;
        errdefer result.deinit(allocator);

        try result.appendSlice(allocator, segment[0..start]);

        // re-inject leading newline(s) if the body had them but `new_rendered` does not
        var lead: usize = 0;
        while (lead < original_body.len and original_body[lead] == '\n') : (lead += 1) {}

        if (lead > 0 and (new_rendered.len == 0 or new_rendered[0] != '\n')) {
            try result.appendSlice(allocator, original_body[0..lead]);
        }

        try result.appendSlice(allocator, new_rendered);

        // re-inject trailing newline(s)
        var trail: usize = original_body.len;
        while (trail > 0 and original_body[trail - 1] == '\n') : (trail -= 1) {}

        const trailing_nl = original_body[trail..];

        if (trailing_nl.len > 0 and
            (new_rendered.len == 0 or new_rendered[new_rendered.len - 1] != '\n'))
        {
            try result.appendSlice(allocator, trailing_nl);
        }

        try result.appendSlice(allocator, segment[end..]);

        return result.toOwnedSlice(allocator);
    }

    return try allocator.dupe(u8, segment);
}

fn buildCpToByteMap(allocator: std.mem.Allocator, str: []const u8) ![]usize {
    var map = std.ArrayList(usize).empty;
    errdefer map.deinit(allocator);

    const is_ascii = for (str) |c| {
        if (!std.ascii.isAscii(c)) break false;
    } else true;

    if (is_ascii) {
        for (0..str.len + 1) |i| try map.append(allocator, i);
        return map.toOwnedSlice(allocator);
    }

    var i: usize = 0;

    while (i < str.len) {
        try map.append(allocator, i);
        const cp_len = std.unicode.utf8ByteSequenceLength(str[i]) catch 1;
        i += cp_len;
    }

    try map.append(allocator, str.len);
    return map.toOwnedSlice(allocator);
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
                if (if_depth > 0) {
                    return ValidationResult{
                        .err = .{
                            .err = TemplateError.InvalidTag,
                            .line = tag_line,
                            .column = tag_column,
                            .message = "Nested 'if' blocks are not allowed",
                        },
                    };
                }

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
        const template_invalid_nested =
            \\{> if SYSTEM.os == freebsd <}
            \\{> if SYSTEM.arch == x86_64 <}
            \\freebsd_x64
            \\{> else <}
            \\freebsd_other
            \\{> endif <}
            \\{> endif <}
        ;

        const result_nested = validate(template_invalid_nested);
        try testing.expect(result_nested.isError());
        try testing.expectEqual(TemplateError.InvalidTag, result_nested.err.err);
        try testing.expectEqualStrings("Nested 'if' blocks are not allowed", result_nested.err.message);
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

test trimTag {
    try testing.expectEqualStrings("test", trimTag("  test  "));
    try testing.expectEqualStrings("if SYSTEM.os == netbsd", trimTag("\n\r if SYSTEM.os == netbsd \t\n"));
    try testing.expectEqualStrings("", trimTag("   \t\r\n   "));
    try testing.expectEqualStrings("endif", trimTag("endif"));
}

test generateSegments {
    const allocator = std.testing.allocator;

    {
        const invalid =
            \\test text
            \\{> endif <}
            \\test text
        ;

        const segments_invalid = generateSegments(allocator, invalid);
        try std.testing.expectError(TemplateError.MismatchedEnd, segments_invalid);
    }

    {
        const invalid =
            \\{> if SYSTEM.os == linux <}
            \\linux-content
            \\{> endif <}
            \\{> endif <}
        ;

        const segments_invalid = generateSegments(allocator, invalid);
        try std.testing.expectError(TemplateError.MismatchedEnd, segments_invalid);
    }

    {
        const valid =
            \\{> if SYSTEM.os == freebsd <}
            \\fbsd-content
            \\{> endif <}
            \\foo
            \\
            \\{> if SYSTEM.os == openbsd <}
            \\obsd-content
            \\{> endif <}
        ;

        const s1 =
            \\{> if SYSTEM.os == freebsd <}
            \\fbsd-content
            \\{> endif <}
        ;

        const s2 =
            \\
            \\foo
            \\
            \\
        ;

        const s3 =
            \\{> if SYSTEM.os == openbsd <}
            \\obsd-content
            \\{> endif <}
        ;

        var segments_valid = try generateSegments(allocator, valid);
        defer segments_valid.deinit(allocator);

        try std.testing.expect(segments_valid.items.len == 3);
        try std.testing.expectEqualStrings(s1, segments_valid.items[0]);
        try std.testing.expectEqualStrings(s2, segments_valid.items[1]);
        try std.testing.expectEqualStrings(s3, segments_valid.items[2]);
    }
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
        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);

        const result = evalIfGroup(allocator, tokens_oob, 0, out.writer(allocator));
        try testing.expectError(TemplateError.IndexOutOfBounds, result);
    }

    {
        var tokens_unexpected = [_]Token{
            .{ .text = "unexpected text" },
            .{ .tag = .{ .content = "endif", .raw = " endif ", .start = 0, .end = 10 } },
        };

        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);

        const result = evalIfGroup(allocator, &tokens_unexpected, 0, out.writer(allocator));
        try testing.expectError(TemplateError.InvalidToken, result);
    }

    {
        var tokens_invalid_tag = [_]Token{
            .{ .tag = .{ .content = "if SYSTEM.os == foo", .raw = " if SYSTEM.os == foo ", .start = 0, .end = 10 } },
            .{ .text = "content" },
            .{ .text = "unexpected text" },
        };

        var out_invalid_tag = std.ArrayList(u8).empty;
        defer out_invalid_tag.deinit(allocator);

        const result_invalid_tag = evalIfGroup(allocator, &tokens_invalid_tag, 0, out_invalid_tag.writer(allocator));
        try testing.expectError(TemplateError.InvalidTag, result_invalid_tag);
    }

    {
        var tokens_invalid_template = [_]Token{
            .{ .tag = .{ .content = "unknown_tag", .raw = " unknown_tag ", .start = 0, .end = 10 } },
            .{ .tag = .{ .content = "endif", .raw = " endif ", .start = 20, .end = 30 } },
        };

        var out_invalid_template = std.ArrayList(u8).empty;
        defer out_invalid_template.deinit(allocator);

        const result_invalid_template = evalIfGroup(allocator, &tokens_invalid_template, 0, out_invalid_template.writer(allocator));
        try testing.expectError(TemplateError.InvalidTag, result_invalid_template);
    }

    {
        var tokens_missing_end = [_]Token{
            .{ .tag = .{ .content = "if SYSTEM.os == foo", .raw = " if SYSTEM.os == foo ", .start = 0, .end = 10 } },
            .{ .text = "body" },
        };

        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);

        const result = evalIfGroup(allocator, &tokens_missing_end, 0, out.writer(allocator));
        try testing.expectError(TemplateError.MissingEndTag, result);
    }

    {
        var tokens_end_only = [_]Token{
            .{ .tag = .{ .content = "endif", .raw = " endif ", .start = 0, .end = 5 } },
        };

        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);

        const result = try evalIfGroup(allocator, &tokens_end_only, 0, out.writer(allocator));
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
        \\# test_val2="{{> if SYSTEM.os == zoot <}}zero{{> else <}}testA{{> endif <}}"
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
        \\# test_val2="testB"
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
        \\# test_val2="{{> if SYSTEM.os == zoot <}}zero{{> else <}}testB{{> endif <}}"
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

test "mixed-inline" {
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
        \\{> if SYSTEM.os == foo1 <}
        \\val="Foo"
        \\{> elif SYSTEM.os == foo2 <}
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
        \\{> if SYSTEM.os == foo1 <}
        \\val="Foo"
        \\{> elif SYSTEM.os == foo2 <}
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

test "unicode" {
    var allocator = std.testing.allocator;

    const template =
        \\🫠
        \\
    ;

    const rendered_user_edit =
        \\😈
        \\
    ;

    const reversed = try reverseTemplate(allocator, rendered_user_edit, template);
    defer allocator.free(reversed);

    const expected_template =
        \\😈
        \\
    ;

    try std.testing.expectEqualStrings(expected_template, reversed);
}

test "unicode-template" {
    var allocator = std.testing.allocator;

    const template =
        \\😀
        \\{> if SYSTEM.os == foo1 <}
        \\val="😁"
        \\{> elif SYSTEM.os == foo2 <}
        \\val="😜"
        \\{> else <}
        \\val="😑"
        \\{> endif <}
        \\
    ;

    const rendered_user_edit =
        \\😃
        \\val="😊"
        \\
    ;

    const reversed = try reverseTemplate(allocator, rendered_user_edit, template);
    defer allocator.free(reversed);

    const expected_template =
        \\😃
        \\{> if SYSTEM.os == foo1 <}
        \\val="😁"
        \\{> elif SYSTEM.os == foo2 <}
        \\val="😜"
        \\{> else <}
        \\val="😊"
        \\{> endif <}
        \\
    ;

    try std.testing.expectEqualStrings(expected_template, reversed);
}

const std = @import("std");
const builtin = @import("builtin");
pub const Myers = @import("myers.zig");
const testing = std.testing;
