const std = @import("std");
const img = @import("img.zig");
const vis = @import("visualizer.zig");

const Allocator = std.mem.Allocator;

/// Find potential pixel positions for the center of the qr finder pattern in 1 dimension.
pub fn finderCandidates(alloc: Allocator, rle: []const RleItem) !std.ArrayList(usize) {
    var ret = std.ArrayList(usize).init(alloc);
    if (rle.len < 5) {
        return ret;
    }

    const end = rle.len - 5;
    for (0..end) |i| {
        const ref = rle[i].length;
        // FIXME: Allow for any amount of error
        if (rle[i + 1].length != ref) {
            continue;
        }

        if (rle[i + 2].length / ref != 3) {
            continue;
        }

        if (rle[i + 3].length != ref) {
            continue;
        }

        if (rle[i + 4].length != ref) {
            continue;
        }

        try ret.append(rle[i + 2].start + rle[i + 2].length / 2);
    }

    return ret;
}

/// Look for the center of QR code finder patterns and draw them with the visualizer
pub fn findFinderPatterns(alloc: Allocator, image: *img.Image, visualizer: anytype) !void {
    const Point = struct {
        x: usize,
        y: usize,
    };

    var vertical_candidates = std.ArrayList(Point).init(alloc);
    defer vertical_candidates.deinit();

    for (0..image.width) |x| {
        var it = img.isLightIter(image.col(x));
        var rle = try runLengthEncode(alloc, &it);
        defer rle.deinit();

        var candidates = try finderCandidates(alloc, rle.items);
        defer candidates.deinit();

        for (candidates.items) |candidate| {
            try vertical_candidates.append(.{
                .x = x,
                .y = candidate,
            });
            try visualizer.drawCircle(@floatFromInt(x), @floatFromInt(candidate), 1, "blue");
        }
    }

    var horizontal_candidates = std.ArrayList(Point).init(alloc);
    defer horizontal_candidates.deinit();

    for (0..image.height) |y| {
        var it = img.isLightIter(image.row(y));

        var rle = try runLengthEncode(alloc, &it);
        defer rle.deinit();

        var candidates = try finderCandidates(alloc, rle.items);
        defer candidates.deinit();

        for (candidates.items) |candidate| {
            try horizontal_candidates.append(.{
                .x = candidate,
                .y = y,
            });
            try visualizer.drawCircle(@floatFromInt(candidate), @floatFromInt(y), 1, "red");
        }
    }

    for (vertical_candidates.items) |vert_candidate| {
        for (horizontal_candidates.items) |horiz_candidate| {
            if (std.meta.eql(vert_candidate, horiz_candidate)) {
                try visualizer.drawCircle(@floatFromInt(horiz_candidate.x), @floatFromInt(horiz_candidate.y), 4, "green");
            }
        }
    }
}

const RleItem = struct {
    start: usize,
    length: usize,
};

/// Given an iterator it who has a fn next() ?T, return an array of segments
/// that contained the same value.
///
/// E.g. if your iterator returns 110001110 we the return would be [3, 6, 3]
fn runLengthEncode(alloc: Allocator, it: anytype) !std.ArrayList(RleItem) {
    var ret = std.ArrayList(RleItem).init(alloc);
    errdefer ret.deinit();

    var prev = it.next() orelse {
        return ret;
    };

    var count: u64 = 1;
    var pos: usize = 1;
    while (it.next()) |val| {
        defer pos += 1;
        if (val == prev) {
            count += 1;
        } else {
            try ret.append(.{
                .start = pos - count,
                .length = count,
            });
            prev = val;
            count = 1;
        }
    }

    try ret.append(.{
        .start = pos - count,
        .length = count,
    });
    return ret;
}

test "run length encode sanity" {
    var alloc = std.testing.allocator;
    const BufIter = struct {
        buf: []const u8,
        i: usize,

        const Self = @This();

        pub fn next(self: *Self) ?u8 {
            if (self.i >= self.buf.len) {
                return null;
            }

            var ret = self.buf[self.i];
            self.i += 1;
            return ret;
        }
    };
    var buf = [_]u8{ 0, 0, 0, 1, 1, 0, 1 };
    var it = BufIter{
        .buf = &buf,
        .i = 0,
    };
    var rle = try runLengthEncode(alloc, &it);
    defer rle.deinit();

    try std.testing.expectEqualSlices(RleItem, &[_]RleItem{
        .{
            .start = 0,
            .length = 3,
        },
        .{
            .start = 3,
            .length = 2,
        },
        .{
            .start = 5,
            .length = 1,
        },
        .{
            .start = 6,
            .length = 1,
        },
    }, rle.items);
}
