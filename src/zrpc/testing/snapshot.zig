const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const SourceLocation = std.builtin.SourceLocation;

const update_all: bool = false;

fn equal_excluding_ignored(got: []const u8, snapshot: []const u8) bool {
    assert(!std.mem.startsWith(u8, snapshot, "<snap:ignore>"));
    assert(!std.mem.endsWith(u8, snapshot, "<snap:ignore>"));

    var got_idx: usize = 0;
    var snap_idx: usize = 0;
    var iteration: u32 = 0;

    while (iteration < 10) : (iteration += 1) {
        const ignore_marker_idx = std.mem.indexOf(u8, snapshot[snap_idx..], "<snap:ignore>");

        const snap_part = if (ignore_marker_idx) |idx|
            snapshot[snap_idx .. snap_idx + idx]
        else
            snapshot[snap_idx..];

        if (got_idx + snap_part.len > got.len) return false;
        if (!std.mem.eql(u8, got[got_idx .. got_idx + snap_part.len], snap_part)) {
            return false;
        }

        got_idx += snap_part.len;
        if (ignore_marker_idx == null) {
            return got_idx == got.len;
        }
        snap_idx += snap_part.len + "<snap:ignore>".len;

        const next_snap_marker_idx = std.mem.indexOf(u8, snapshot[snap_idx..], "<snap:ignore>");
        const next_snap_part = if (next_snap_marker_idx) |idx|
            snapshot[snap_idx .. snap_idx + idx]
        else
            snapshot[snap_idx..];

        assert(next_snap_part.len > 0);

        const next_got_match_idx = std.mem.indexOf(u8, got[got_idx..], next_snap_part);
        if (next_got_match_idx == null) return false;

        const ignored_in_got = got[got_idx .. got_idx + next_got_match_idx.?];
        if (ignored_in_got.len == 0) return false;
        if (std.mem.indexOfScalar(u8, ignored_in_got, '\n') != null) return false;
        got_idx += next_got_match_idx.?;
    } else @panic("more than 10 ignores");

    return got_idx == got.len and snap_idx == snapshot.len;
}

pub const Snap = struct {
    comptime {
        assert(builtin.is_test);
    }

    location: SourceLocation,
    text: []const u8,
    update_this: bool = false,

    pub fn snap(location: SourceLocation, text: []const u8) Snap {
        return Snap{ .location = location, .text = text };
    }

    pub fn update(snapshot: *const Snap) Snap {
        return Snap{
            .location = snapshot.location,
            .text = snapshot.text,
            .update_this = true,
        };
    }

    fn should_update(snapshot: *const Snap) bool {
        return snapshot.update_this or update_all or
            std.process.hasEnvVarConstant("SNAP_UPDATE");
    }

    pub fn diff_fmt(snapshot: *const Snap, comptime fmt: []const u8, fmt_args: anytype) !void {
        const got = try std.fmt.allocPrint(std.testing.allocator, fmt, fmt_args);
        defer std.testing.allocator.free(got);

        try snapshot.diff(got);
    }

    pub fn diff_json(
        snapshot: *const Snap,
        value: anytype,
        options: std.json.StringifyOptions,
    ) !void {
        var got = std.ArrayList(u8).init(std.testing.allocator);
        defer got.deinit();

        try std.json.stringify(value, options, got.writer());
        try snapshot.diff(got.items);
    }

    pub fn diff(snapshot: *const Snap, got: []const u8) !void {
        if (equal_excluding_ignored(got, snapshot.text)) return;

        std.debug.print(
            \\Snapshot differs.
            \\Want:
            \\----
            \\{s}
            \\----
            \\Got:
            \\----
            \\{s}
            \\----
            \\
        ,
            .{
                snapshot.text,
                got,
            },
        );

        if (!snapshot.should_update()) {
            std.debug.print(
                "Rerun with SNAP_UPDATE=1 environmental variable to update the snapshot.\n",
                .{},
            );
            return error.SnapDiff;
        }

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const allocator = arena.allocator();

        const file_text =
            try std.fs.cwd().readFileAlloc(allocator, snapshot.location.file, 1024 * 1024);
        var file_text_updated = try std.ArrayList(u8).initCapacity(allocator, file_text.len);

        const line_zero_based = snapshot.location.line - 1;
        const range = snap_range(file_text, line_zero_based);

        const snapshot_prefix = file_text[0..range.start];
        const snapshot_text = file_text[range.start..range.end];
        const snapshot_suffix = file_text[range.end..];

        const indent = get_indent(snapshot_text);

        try file_text_updated.appendSlice(snapshot_prefix);
        {
            var lines = std.mem.splitScalar(u8, got, '\n');
            while (lines.next()) |line| {
                try file_text_updated.writer().print("{s}\\\\{s}\n", .{ indent, line });
            }
        }
        try file_text_updated.appendSlice(snapshot_suffix);

        try std.fs.cwd().writeFile(.{
            .sub_path = snapshot.location.file,
            .data = file_text_updated.items,
        });

        std.debug.print("Updated {s}\n", .{snapshot.location.file});
        return error.SnapUpdated;
    }
};

fn equal_excluding_ignored_case(got: []const u8, snapshot: []const u8, ok: bool) !void {
    try std.testing.expectEqual(equal_excluding_ignored(got, snapshot), ok);
}

const Range = struct { start: usize, end: usize };

fn snap_range(text: []const u8, src_line: u32) Range {
    var offset: usize = 0;
    var line_number: u32 = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    const snap_start = while (lines.next()) |line| : (line_number += 1) {
        if (line_number == src_line) {
            assert(std.mem.indexOf(u8, line, "@src()") != null);
        }
        if (line_number == src_line + 1) {
            assert(is_multiline_string(line));
            break offset;
        }
        offset += line.len + 1;
    } else unreachable;

    lines = std.mem.splitScalar(u8, text[snap_start..], '\n');
    const snap_end = while (lines.next()) |line| {
        if (!is_multiline_string(line)) {
            break offset;
        }
        offset += line.len + 1;
    } else unreachable;

    return Range{ .start = snap_start, .end = snap_end };
}

fn is_multiline_string(line: []const u8) bool {
    for (line, 0..) |c, i| {
        switch (c) {
            ' ' => {},
            '\\' => return (i + 1 < line.len and line[i + 1] == '\\'),
            else => return false,
        }
    }
    return false;
}

fn get_indent(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c != ' ') return line[0..i];
    }
    return line;
}

test equal_excluding_ignored {
    try equal_excluding_ignored_case("ABA", "ABA", true);
    try equal_excluding_ignored_case("ABBA", "A<snap:ignore>A", true);
    try equal_excluding_ignored_case("ABBACABA", "AB<snap:ignore>CA<snap:ignore>A", true);

    try equal_excluding_ignored_case("ABA", "ACA", false);
    try equal_excluding_ignored_case("ABBA", "A<snap:ignore>C", false);
    try equal_excluding_ignored_case("ABBACABA", "AB<snap:ignore>DA<snap:ignore>BA", false);
    try equal_excluding_ignored_case("ABBACABA", "AB<snap:ignore>BA<snap:ignore>DA", false);
    try equal_excluding_ignored_case("ABA", "AB<snap:ignore>A", false);
    try equal_excluding_ignored_case("A\nB\nA", "A<snap:ignore>A", false);
}
