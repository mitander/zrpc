const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const SourceLocation = std.builtin.SourceLocation;

const update_all: bool = false;

fn FmtBytesDetailed(comptime T: type) type {
    if (T != []const u8) @compileError("Requires []const u8");
    return struct {
        bytes: []const u8,

        pub fn format(
            self: FmtBytesDetailed([]const u8),
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            for (self.bytes, 0..) |byte, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("0x{x:0>2}", .{byte});
            }
        }
    };
}

pub fn fmt_bytes_detailed(bytes: []const u8) FmtBytesDetailed([]const u8) {
    return .{ .bytes = bytes };
}

fn equal_excluding_ignored(got: []const u8, snapshot: []const u8) bool {
    const ignore_tag = "<snap:ignore>";
    var got_idx: usize = 0;
    var snap_idx: usize = 0;

    while (snap_idx < snapshot.len) {
        if (std.mem.startsWith(u8, snapshot[snap_idx..], ignore_tag)) {
            snap_idx += ignore_tag.len;
            const next_match_idx = std.mem.indexOf(u8, snapshot[snap_idx..], ignore_tag) orelse snapshot.len - snap_idx;
            const next_match_str = snapshot[snap_idx .. snap_idx + next_match_idx];

            const got_match_idx = std.mem.indexOf(u8, got[got_idx..], next_match_str);
            if (got_match_idx == null) {
                return false;
            }
            got_idx += got_match_idx.? + next_match_str.len;
            snap_idx += next_match_str.len;
        } else {
            if (got_idx >= got.len or got[got_idx] != snapshot[snap_idx]) {
                return false;
            }
            got_idx += 1;
            snap_idx += 1;
        }
    }

    return got_idx == got.len;
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
        if (std.mem.eql(u8, got, snapshot.text)) {
            return;
        }

        if (equal_excluding_ignored(got, snapshot.text)) {
            return;
        }

        std.debug.print("\n-- Comparing Snapshot --\n", .{});
        std.debug.print("Location: {s}:{d}\n", .{ snapshot.location.file, snapshot.location.line });

        const got_fmt_str = std.fmt.allocPrint(std.testing.allocator, "{}", .{fmt_bytes_detailed(got)}) catch "<alloc error>";
        defer std.testing.allocator.free(got_fmt_str);
        const want_fmt_str = std.fmt.allocPrint(std.testing.allocator, "{}", .{fmt_bytes_detailed(snapshot.text)}) catch "<alloc error>";
        defer std.testing.allocator.free(want_fmt_str);

        std.debug.print("Got (len={d}): >|{s}|<\n", .{ got.len, got_fmt_str });
        std.debug.print("Want(len={d}): >|{s}|<\n", .{ snapshot.text.len, want_fmt_str });
        std.debug.print("-- End Comparison --\n", .{});

        std.debug.print(
            \\Snapshot differs.
            \\Want (Inline):
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
                want_fmt_str,
                got_fmt_str,
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

        const snap_filename = try std.fmt.allocPrint(allocator, "snapshots/snap_{s}_{d}.snap", .{
            std.fs.path.stem(snapshot.location.file),
            snapshot.location.line,
        });
        defer allocator.free(snap_filename);

        std.fs.cwd().makeDir("snapshots") catch |err| {
            if (err != error.PathAlreadyExists) {
                std.log.err("Failed to create snapshots directory: {any}", .{err});
                return err;
            }
        };

        try std.fs.cwd().writeFile(.{
            .sub_path = snap_filename,
            .data = got,
        });

        std.debug.print("Updated {s}\n", .{snap_filename});
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
    try equal_excluding_ignored_case("ABA", "AB<snap:ignore>A", true);
    try equal_excluding_ignored_case("ABC", "A<snap:ignore>D", false);
}
