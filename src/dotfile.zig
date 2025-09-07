dest: []const u8,
src: []const u8,
synced: ?u64,

pub fn new(src: []const u8, dest: []const u8) @This() {
    return .{
        .dest = dest,
        .src = src,
        .synced = null,
    };
}
