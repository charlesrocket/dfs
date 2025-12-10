//! Myers' diff algorithm.

const String = union(enum) {
    bytes: []const u8,
    codepoints: []const u21,

    fn len(self: String) usize {
        return switch (self) {
            .codepoints => |cp| cp.len,
            .bytes => |b| b.len,
        };
    }

    fn get(self: String, index: usize) usize {
        return switch (self) {
            .codepoints => |cp| cp[index],
            .bytes => |b| b[index],
        };
    }

    fn deinit(self: String, allocator: std.mem.Allocator) void {
        switch (self) {
            .codepoints => |cp| allocator.free(cp),
            .bytes => {},
        }
    }
};

pub const Edit = union(enum) {
    equal: struct { old_index: usize, new_index: usize, count: usize },
    insert: struct { new_index: usize, count: usize },
    delete: struct { old_index: usize, count: usize },
};

fn needsCodepoints(str: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(str)) return false;

    for (str) |b| {
        if (b > 127) return true; // non-ASCII character found
    }

    return false;
}

fn utf8ToCodepoints(allocator: std.mem.Allocator, utf8: []const u8) ![]u21 {
    var codepoints = std.array_list.Managed(u21).init(allocator);
    defer codepoints.deinit();

    var iter = std.unicode.Utf8Iterator{ .bytes = utf8, .i = 0 };

    while (iter.nextCodepoint()) |codepoint| {
        try codepoints.append(codepoint);
    }

    return try codepoints.toOwnedSlice();
}

pub fn diff(
    allocator: std.mem.Allocator,
    old_str: []const u8,
    new_str: []const u8,
) ![]Edit {
    const old = if (needsCodepoints(old_str))
        String{ .codepoints = try utf8ToCodepoints(allocator, old_str) }
    else
        String{ .bytes = old_str };

    const new = if (needsCodepoints(new_str))
        String{ .codepoints = try utf8ToCodepoints(allocator, new_str) }
    else
        String{ .bytes = new_str };

    defer {
        old.deinit(allocator);
        new.deinit(allocator);
    }

    const old_len = old.len();
    const new_len = new.len();

    const max_d = old_len + new_len;

    // handle empty strings
    if (old_len == 0 and new_len == 0) {
        return try allocator.alloc(Edit, 0);
    }

    var v = try allocator.alloc(isize, 2 * max_d + 1);
    defer allocator.free(v);
    @memset(v, 0);

    var trace = std.array_list.Managed([]isize).init(allocator);
    defer {
        for (trace.items) |item| allocator.free(item);
        trace.deinit();
    }

    const offset = @as(isize, @intCast(max_d));
    v[@intCast(offset + 1)] = 0;

    for (0..max_d + 1) |d| {
        const d_signed: isize = @intCast(d);
        var k: isize = -d_signed;

        while (k <= d_signed) : (k += 2) {
            const k_idx: usize = @intCast(k + offset);
            var x: isize = 0;

            if (k == -d_signed or
                (k != d_signed and v[k_idx - 1] < v[k_idx + 1]))
            {
                x = v[k_idx + 1];
            } else {
                x = v[k_idx - 1] + 1;
            }

            var y = x - k;

            while (x < @as(isize, @intCast(old_len)) and
                y < @as(isize, @intCast(new_len)) and
                old.get(@intCast(x)) == new.get(@intCast(y)))
            {
                x += 1;
                y += 1;
            }

            v[k_idx] = x;

            if (x >= @as(isize, @intCast(old_len)) and
                y >= @as(isize, @intCast(new_len)))
            {
                // save the final trace before returning
                const v_copy = try allocator.alloc(isize, v.len);
                @memcpy(v_copy, v);
                try trace.append(v_copy);

                return try backtrack(
                    allocator,
                    old,
                    new,
                    &trace,
                    d,
                );
            }
        }

        const v_copy = try allocator.alloc(isize, v.len);
        @memcpy(v_copy, v);
        try trace.append(v_copy);
    }

    // return an empty slice if there is no solution
    return try allocator.alloc(Edit, 0);
}

fn backtrack(
    allocator: std.mem.Allocator,
    old: String,
    new: String,
    trace: *std.array_list.Managed([]isize),
    d: usize,
) ![]Edit {
    var edits = std.array_list.Managed(Edit).init(allocator);
    defer edits.deinit();

    var x: isize = @intCast(old.len());
    var y: isize = @intCast(new.len());
    const offset = (trace.items[0].len - 1) / 2;

    var depth: isize = @intCast(d);
    while (depth > 0) : (depth -= 1) {
        const v = trace.items[@intCast(depth)];
        const k = x - y;
        const k_idx: usize = @intCast(k + @as(isize, @intCast(offset)));

        // determine which diagonal the previous path came from
        const prev_k = if (k == -depth or
            (k != depth and v[k_idx - 1] < v[k_idx + 1]))
            k + 1
        else
            k - 1;

        const prev_k_idx: usize = @intCast(prev_k + @as(
            isize,
            @intCast(offset),
        ));

        const prev_x = v[prev_k_idx];
        const prev_y = prev_x - prev_k;

        // follow backwards
        while (x > prev_x and y > prev_y) {
            x -= 1;
            y -= 1;

            try edits.append(.{ .equal = .{
                .old_index = @intCast(x),
                .new_index = @intCast(y),
                .count = 1,
            } });
        }

        // now at end of (D-1)-path, record the insert or delete
        if (x == prev_x) {
            // came from above (insert)
            y -= 1;

            try edits.append(
                .{ .insert = .{ .new_index = @intCast(y), .count = 1 } },
            );
        } else {
            // came from left (delete)
            x -= 1;

            try edits.append(
                .{ .delete = .{ .old_index = @intCast(x), .count = 1 } },
            );
        }

        x = prev_x;
        y = prev_y;
    }

    // at depth 0, handle any remaining diagonal from (0,0) to (x,y)
    while (x > 0 and y > 0) {
        x -= 1;
        y -= 1;

        try edits.append(.{ .equal = .{
            .old_index = @intCast(x),
            .new_index = @intCast(y),
            .count = 1,
        } });
    }

    // reverse the edits since we built them backwards
    const edits_slice = try edits.toOwnedSlice();
    std.mem.reverse(Edit, edits_slice);

    return try compactEdits(allocator, edits_slice);
}

fn compactEdits(allocator: std.mem.Allocator, edits: []Edit) ![]Edit {
    // free edits at the end, even if we return early or error
    errdefer allocator.free(edits);
    defer allocator.free(edits);

    if (edits.len == 0) return try allocator.alloc(Edit, 0);

    var result = std.array_list.Managed(Edit).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;

    while (i < edits.len) {
        const edit = edits[i];
        switch (edit) {
            .equal => |e| {
                var count = e.count;
                const first_idx = e.old_index;
                const first_new_idx = e.new_index;
                var j = i + 1;

                while (j < edits.len) : (j += 1) {
                    if (edits[j] != .equal) break;
                    const next = edits[j].equal;

                    if (next.old_index != first_idx + count or
                        next.new_index != first_new_idx + count) break;
                    count += next.count;
                }

                try result.append(.{ .equal = .{
                    .old_index = first_idx,
                    .new_index = first_new_idx,
                    .count = count,
                } });
                i = j;
            },
            .insert => |ins| {
                var count: usize = ins.count;
                const first_idx = ins.new_index;
                var j = i + 1;

                while (j < edits.len) : (j += 1) {
                    if (edits[j] != .insert) break;

                    const next = edits[j].insert;

                    if (next.new_index != first_idx + count) break;

                    count += next.count;
                }

                try result.append(.{ .insert = .{
                    .new_index = first_idx,
                    .count = count,
                } });

                i = j;
            },
            .delete => |del| {
                var count: usize = del.count;
                const first_idx = del.old_index;
                var j = i + 1;

                while (j < edits.len) : (j += 1) {
                    if (edits[j] != .delete) break;

                    const next = edits[j].delete;

                    if (next.old_index != first_idx + count) break;

                    count += next.count;
                }

                try result.append(.{ .delete = .{
                    .old_index = first_idx,
                    .count = count,
                } });

                i = j;
            },
        }
    }

    return try result.toOwnedSlice();
}

test diff {
    const allocator = testing.allocator;
    const old = "😆";
    const new = "👿";

    const edits = try Myers.diff(allocator, old, new);
    defer allocator.free(edits);

    try testing.expectEqual(1, edits[0].delete.count);
    try testing.expectEqual(1, edits[1].insert.count);
}

test "empty strings" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "", "");
    defer allocator.free(edits);

    try testing.expectEqual(@as(usize, 0), edits.len);
}

test "empty old string" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "", "abc");
    defer allocator.free(edits);

    try testing.expectEqual(1, edits.len);
    try testing.expect(edits[0] == .insert);
    try testing.expectEqual(0, edits[0].insert.new_index);
    try testing.expectEqual(3, edits[0].insert.count);
}

test "empty new string" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "abc", "");
    defer allocator.free(edits);

    try testing.expectEqual(1, edits.len);
    try testing.expect(edits[0] == .delete);
    try testing.expectEqual(0, edits[0].delete.old_index);
    try testing.expectEqual(3, edits[0].delete.count);
}

test "identical strings" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "abc", "abc");
    defer allocator.free(edits);

    try testing.expectEqual(1, edits.len);
    try testing.expect(edits[0] == .equal);
    try testing.expectEqual(0, edits[0].equal.old_index);
    try testing.expectEqual(0, edits[0].equal.new_index);
    try testing.expectEqual(3, edits[0].equal.count);
}

test "insertion at the middle" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "ac", "abc");
    defer allocator.free(edits);

    try testing.expectEqual(3, edits.len);

    // 'a' equal
    try testing.expect(edits[0] == .equal);
    try testing.expectEqual(0, edits[0].equal.old_index);
    try testing.expectEqual(0, edits[0].equal.new_index);
    try testing.expectEqual(1, edits[0].equal.count);

    // 'b' insert
    try testing.expect(edits[1] == .insert);
    try testing.expectEqual(1, edits[1].insert.new_index);
    try testing.expectEqual(1, edits[1].insert.count);

    // 'c' equal
    try testing.expect(edits[2] == .equal);
    try testing.expectEqual(1, edits[2].equal.old_index);
    try testing.expectEqual(2, edits[2].equal.new_index);
    try testing.expectEqual(1, edits[2].equal.count);
}

test "deletion from the middle" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "abc", "ac");
    defer allocator.free(edits);

    try testing.expectEqual(3, edits.len);

    // 'a' equal
    try testing.expect(edits[0] == .equal);
    try testing.expectEqual(0, edits[0].equal.old_index);
    try testing.expectEqual(0, edits[0].equal.new_index);
    try testing.expectEqual(1, edits[0].equal.count);

    // 'b' delete
    try testing.expect(edits[1] == .delete);
    try testing.expectEqual(1, edits[1].delete.old_index);
    try testing.expectEqual(1, edits[1].delete.count);

    // 'c' equal
    try testing.expect(edits[2] == .equal);
    try testing.expectEqual(2, edits[2].equal.old_index);
    try testing.expectEqual(1, edits[2].equal.new_index);
    try testing.expectEqual(1, edits[2].equal.count);
}

test "insertion at the beginning" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "bc", "abc");
    defer allocator.free(edits);

    try testing.expectEqual(2, edits.len);

    // insert 'a'
    try testing.expect(edits[0] == .insert);
    try testing.expectEqual(0, edits[0].insert.new_index);
    try testing.expectEqual(1, edits[0].insert.count);

    // 'bc' equal
    try testing.expect(edits[1] == .equal);
    try testing.expectEqual(0, edits[1].equal.old_index);
    try testing.expectEqual(1, edits[1].equal.new_index);
    try testing.expectEqual(2, edits[1].equal.count);
}

test "deletion at the beginning" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "abc", "bc");
    defer allocator.free(edits);

    try testing.expectEqual(2, edits.len);

    // delete 'a'
    try testing.expect(edits[0] == .delete);
    try testing.expectEqual(0, edits[0].delete.old_index);
    try testing.expectEqual(1, edits[0].delete.count);

    // 'bc' equal
    try testing.expect(edits[1] == .equal);
    try testing.expectEqual(1, edits[1].equal.old_index);
    try testing.expectEqual(0, edits[1].equal.new_index);
    try testing.expectEqual(2, edits[1].equal.count);
}

test "insertion at the end" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "ab", "abc");
    defer allocator.free(edits);

    try testing.expectEqual(2, edits.len);

    // 'ab' equal
    try testing.expect(edits[0] == .equal);
    try testing.expectEqual(0, edits[0].equal.old_index);
    try testing.expectEqual(0, edits[0].equal.new_index);
    try testing.expectEqual(2, edits[0].equal.count);

    // insert 'c'
    try testing.expect(edits[1] == .insert);
    try testing.expectEqual(2, edits[1].insert.new_index);
    try testing.expectEqual(1, edits[1].insert.count);
}

test "deletion at the end" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "abc", "ab");
    defer allocator.free(edits);

    try testing.expectEqual(2, edits.len);

    // 'ab' equal
    try testing.expect(edits[0] == .equal);
    try testing.expectEqual(0, edits[0].equal.old_index);
    try testing.expectEqual(0, edits[0].equal.new_index);
    try testing.expectEqual(2, edits[0].equal.count);

    // delete 'c'
    try testing.expect(edits[1] == .delete);
    try testing.expectEqual(2, edits[1].delete.old_index);
    try testing.expectEqual(1, edits[1].delete.count);
}

test "multiple insertions and deletions" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "abcdef", "aXbYcZdef");
    defer allocator.free(edits);

    // should compact consecutive operations
    // 'a' equal, 'X' insert, 'b' equal, 'Y' insert,
    // 'c' equal, 'Z' insert, 'def' equal
    var equal_count: usize = 0;
    var insert_count: usize = 0;

    for (edits) |edit| {
        switch (edit) {
            .equal => equal_count += 1,
            .insert => insert_count += 1,
            .delete => {},
        }
    }

    try testing.expect(equal_count >= 4);
    try testing.expect(insert_count >= 3);
}

test "identical characters" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "x", "x");
    defer allocator.free(edits);

    try testing.expectEqual(1, edits.len);
    try testing.expect(edits[0] == .equal);
    try testing.expectEqual(1, edits[0].equal.count);
}

test "non-indentical characters" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "a", "b");
    defer allocator.free(edits);

    try testing.expectEqual(2, edits.len);
    try testing.expect(edits[0] == .delete);
    try testing.expect(edits[1] == .insert);
}

test "different strings" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "abc", "xyz");
    defer allocator.free(edits);

    try testing.expectEqual(2, edits.len);

    // delete 'abc'
    try testing.expect(edits[0] == .delete);
    try testing.expectEqual(0, edits[0].delete.old_index);
    try testing.expectEqual(3, edits[0].delete.count);

    // insert 'xyz'
    try testing.expect(edits[1] == .insert);
    try testing.expectEqual(0, edits[1].insert.new_index);
    try testing.expectEqual(3, edits[1].insert.count);
}

test "no common characters" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "aaa", "bbb");
    defer allocator.free(edits);

    try testing.expectEqual(2, edits.len);
    try testing.expect(edits[0] == .delete);
    try testing.expectEqual(3, edits[0].delete.count);
    try testing.expect(edits[1] == .insert);
    try testing.expectEqual(3, edits[1].insert.count);
}

test "common characters" {
    const allocator = testing.allocator;
    const edits = try Myers.diff(allocator, "aaaa", "aaa");
    defer allocator.free(edits);

    // should have an equal section and a delete
    var has_equal = false;
    var has_delete = false;

    for (edits) |edit| {
        switch (edit) {
            .equal => has_equal = true,
            .delete => has_delete = true,
            .insert => {},
        }
    }

    try testing.expect(has_equal);
    try testing.expect(has_delete);
}

test "strings with mixed operations" {
    const allocator = testing.allocator;

    const old = "ABCABBA";
    const new = "CBABAC";

    const edits = try Myers.diff(allocator, "ABCABBA", "CBABAC");
    defer allocator.free(edits);

    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    for (edits) |edit| {
        switch (edit) {
            .equal => |e| {
                for (0..e.count) |i| {
                    try result.append(old[e.old_index + i]);
                }
            },
            .insert => |ins| {
                for (0..ins.count) |i| {
                    try result.append(new[ins.new_index + i]);
                }
            },
            .delete => {},
        }
    }

    try testing.expectEqualStrings(new, result.items);
}

test "reconstruction correctness" {
    const allocator = testing.allocator;

    const old = "The quick brown fox";
    const new = "The slow brown dog";

    const edits = try Myers.diff(allocator, old, new);
    defer allocator.free(edits);

    var result = std.array_list.Managed(u8).init(allocator);
    defer result.deinit();

    for (edits) |edit| {
        switch (edit) {
            .equal => |e| {
                for (0..e.count) |i| {
                    try result.append(old[e.old_index + i]);
                }
            },
            .insert => |ins| {
                for (0..ins.count) |i| {
                    try result.append(new[ins.new_index + i]);
                }
            },
            .delete => {},
        }
    }

    try testing.expectEqualStrings(new, result.items);
}

const Myers = @This();
const std = @import("std");
const testing = std.testing;
