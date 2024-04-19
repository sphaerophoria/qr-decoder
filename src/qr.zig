const std = @import("std");
const img = @import("img.zig");
const vis = @import("visualizer.zig");
const types_2d = @import("types_2d.zig");
const Rect = types_2d.Rect;
const Image = img.Image;

const Allocator = std.mem.Allocator;

const FinderCandidate1D = struct {
    center: f32,
    length: f32,
};

const DetectFinderAlgoState = union(enum) {
    detect_vert_candidates,
    detect_horiz_candidates: struct {
        vert_candidates: std.ArrayList(Rect),
    },
    detect_combined_candidates: struct {
        vert_candidates: std.ArrayList(Rect),
        horiz_candidates: std.ArrayList(Rect),
    },
    rois: struct {
        candidates: std.ArrayList(std.ArrayList(Rect)),
    },
    finished: std.ArrayList(Rect),
};

/// Helper state machine for detecting QR finder segments. This may seem a
/// little odd, but we want to extract the internal state at different stages
/// of the algorithm. "Why don't you just split out functions?" you might ask,
/// well when we want to use this in normal usage vs debugging, we'd have to
/// duplicate the stitching of functions to a point where I didn't want to.
/// This is arguably worse, arguably better. Deal with it
pub const DetectFinderAlgo = struct {
    // All internal state is managed by the arena to avoid worrying about
    // deiniting intermediate output
    arena: std.heap.ArenaAllocator,
    output_alloc: Allocator,
    image: *img.Image,
    state: DetectFinderAlgoState,

    pub const Output = union(enum) {
        vert_candidates: []const Rect,
        horiz_candidates: []const Rect,
        combined_candidates: []const std.ArrayList(Rect),
        rois: []const Rect,
    };

    pub fn init(alloc: Allocator, image: *img.Image) DetectFinderAlgo {
        return .{
            .arena = std.heap.ArenaAllocator.init(alloc),
            .output_alloc = alloc,
            .image = image,
            .state = .detect_vert_candidates,
        };
    }

    pub fn deinit(self: *DetectFinderAlgo) void {
        self.arena.deinit();
    }

    fn detectVertCandidates(self: *DetectFinderAlgo) !?Output {
        var vertical_candidates = std.ArrayList(Rect).init(self.arena.allocator());

        for (0..self.image.width) |x| {
            var candidates = try finderCandidates(self.arena.allocator(), self.image.col(x));
            defer candidates.deinit();

            for (candidates.items) |candidate| {
                var cx = @as(f32, @floatFromInt(x)) + 0.5;
                try vertical_candidates.append(Rect.initCenterSize(cx, candidate.center, 0.0, candidate.length));
            }
        }

        self.state = .{ .detect_horiz_candidates = .{
            .vert_candidates = vertical_candidates,
        } };

        return .{
            .vert_candidates = vertical_candidates.items,
        };
    }

    fn detectHorizCandidates(self: *DetectFinderAlgo) !?Output {
        var horizontal_candidates = std.ArrayList(Rect).init(self.arena.allocator());

        for (0..self.image.height) |y| {
            var candidates = try finderCandidates(self.arena.allocator(), self.image.row(y));
            defer candidates.deinit();

            for (candidates.items) |candidate| {
                var cy = @as(f32, @floatFromInt(y)) + 0.5;
                try horizontal_candidates.append(Rect.initCenterSize(candidate.center, cy, candidate.length, 0));
            }
        }

        const vertical_candidates = self.state.detect_horiz_candidates.vert_candidates;

        self.state = .{ .detect_combined_candidates = .{
            .vert_candidates = vertical_candidates,
            .horiz_candidates = horizontal_candidates,
        } };

        return .{
            .horiz_candidates = horizontal_candidates.items,
        };
    }

    fn detectCombinedCandidates(self: *DetectFinderAlgo) !?Output {
        var buckets = std.ArrayList(std.ArrayList(Rect)).init(self.arena.allocator());
        var vert_candidates = self.state.detect_combined_candidates.vert_candidates;
        var horiz_candidates = self.state.detect_combined_candidates.horiz_candidates;

        for (vert_candidates.items) |vert_candidate| {
            for (horiz_candidates.items) |horiz_candidate| {
                if (rectCentersEql(&vert_candidate, &horiz_candidate, 1.0)) {
                    var cx = (vert_candidate.cx() + horiz_candidate.cx()) / 2.0;
                    var cy = (vert_candidate.cy() + horiz_candidate.cy()) / 2.0;
                    var width = horiz_candidate.width();
                    var height = vert_candidate.height();

                    var combined = Rect.initCenterSize(cx, cy, width, height);

                    try addRectToBucket(&buckets, combined);
                }
            }
        }

        self.state = .{ .rois = .{
            .candidates = buckets,
        } };

        return .{
            .combined_candidates = buckets.items,
        };
    }

    pub fn detectRois(self: *DetectFinderAlgo) !?Output {
        var buckets = self.state.rois.candidates;

        var ret = std.ArrayList(Rect).init(self.output_alloc);
        errdefer ret.deinit();

        for (buckets.items) |bucket| {
            var cx: f32 = 0;
            var cy: f32 = 0;
            var width: f32 = 0;
            var height: f32 = 0;

            for (bucket.items) |rect| {
                cx += rect.cx();
                cy += rect.cy();
                width += rect.width();
                height += rect.height();
            }

            try ret.append(Rect.initCenterSize(
                cx / @as(f32, @floatFromInt(bucket.items.len)),
                cy / @as(f32, @floatFromInt(bucket.items.len)),
                width / @as(f32, @floatFromInt(bucket.items.len)),
                height / @as(f32, @floatFromInt(bucket.items.len)),
            ));
        }

        self.state = .{
            .finished = ret,
        };

        return .{
            .rois = ret.items,
        };
    }

    pub fn step(self: *DetectFinderAlgo) !?Output {
        switch (self.state) {
            .detect_vert_candidates => {
                return self.detectVertCandidates();
            },
            .detect_horiz_candidates => {
                return self.detectHorizCandidates();
            },
            .detect_combined_candidates => {
                return self.detectCombinedCandidates();
            },
            .rois => {
                return self.detectRois();
            },
            .finished => {
                return null;
            },
        }
    }
};

fn addRectToBucket(buckets: *std.ArrayList(std.ArrayList(Rect)), rect: Rect) !void {
    for (buckets.items) |*bucket| {
        for (bucket.items) |bucket_rect| {
            if (rectCentersEql(&bucket_rect, &rect, 10.0)) {
                try bucket.append(rect);
                return;
            }
        }
    }

    try buckets.append(std.ArrayList(Rect).init(buckets.allocator));
    try buckets.items[buckets.items.len - 1].append(rect);
}

fn isAlmostSame(a: usize, b: usize) bool {
    const a_f: f32 = @floatFromInt(a);
    const b_f: f32 = @floatFromInt(b);

    return @fabs(a_f / b_f - 1.0) < 0.2;
}

/// Find potential pixel positions for the center of the qr finder pattern in 1 dimension.
pub fn finderCandidates(alloc: Allocator, it: anytype) !std.ArrayList(FinderCandidate1D) {
    var is_light_it = img.isLightIter(it);
    var rle = try runLengthEncode(alloc, &is_light_it);
    defer rle.deinit();

    var ret = std.ArrayList(FinderCandidate1D).init(alloc);
    errdefer ret.deinit();

    if (rle.items.len < 5) {
        return ret;
    }

    const end = rle.items.len - 5;
    for (0..end) |i| {
        const ref = rle.items[i].length;
        // FIXME: Allow for any amount of error
        if (!isAlmostSame(rle.items[i + 1].length, ref)) {
            continue;
        }

        if (!isAlmostSame(rle.items[i + 2].length, ref * 3)) {
            continue;
        }

        if (!isAlmostSame(rle.items[i + 3].length, ref)) {
            continue;
        }

        if (!isAlmostSame(rle.items[i + 4].length, ref)) {
            continue;
        }

        const center_block_length: f32 = @floatFromInt(rle.items[i + 2].length);
        const center_block_start: f32 = @floatFromInt(rle.items[i + 2].start);
        var center = center_block_start + center_block_length / 2;

        const first = rle.items[i];
        const last = rle.items[i + 4];
        const length: f32 = @floatFromInt(last.start + last.length - first.start);

        try ret.append(.{
            .center = center,
            .length = length,
        });
    }

    return ret;
}

fn rectCentersEql(a: *const Rect, b: *const Rect, tolerance: f32) bool {
    return std.math.approxEqAbs(f32, a.cx(), b.cx(), tolerance) and std.math.approxEqAbs(f32, a.cy(), b.cy(), tolerance);
}

pub fn findFinderPatterns(alloc: Allocator, image: *img.Image) !std.ArrayList(Rect) {
    var algo = DetectFinderAlgo.init(alloc, image);
    // NOTE: finished state is not deinitialized
    defer algo.deinit();

    while (try algo.step()) |_| {}
    return algo.state.finished;
}

const finder_num_elements: usize = 7;
// Vertical offset for horizontal pattern, horizontal offset for vertical pattern
// Aligns with last row of finder
const timer_pattern_offset: usize = finder_num_elements - 1;
// Horizontal position for horizontal pattern, element directly after finder
// pattern
const timer_pattern_start: usize = finder_num_elements;

pub const HorizTimingIter = struct {
    qr_code: *const QrCode,
    x_pos: usize,

    const Self = @This();

    fn init(qr_code: *const QrCode) HorizTimingIter {
        return .{
            .qr_code = qr_code,
            .x_pos = timer_pattern_start,
        };
    }

    pub fn next(self: *Self) ?Rect {
        if (self.x_pos >= self.qr_code.grid_width - timer_pattern_start) {
            return null;
        }

        const rect = self.qr_code.idxToRoi(self.x_pos, timer_pattern_offset);
        self.x_pos += 1;

        return rect;
    }
};

pub const VertTimingIter = struct {
    qr_code: *const QrCode,
    y_pos: usize,

    const Self = @This();

    fn init(qr_code: *const QrCode) VertTimingIter {
        return .{
            .qr_code = qr_code,
            .y_pos = timer_pattern_start,
        };
    }

    pub fn next(self: *Self) ?Rect {
        if (self.y_pos >= self.qr_code.grid_height - timer_pattern_start) {
            return null;
        }

        const rect = self.qr_code.idxToRoi(timer_pattern_offset, self.y_pos);
        self.y_pos += 1;

        return rect;
    }
};
pub const DataIter = struct {
    qr_code: *const QrCode,
    x_pos: i32,
    y_pos: i32,
    moving_vertically: bool,
    movement_direction: i2,

    const Self = @This();

    pub fn init(qr_code: *const QrCode) Self {
        return .{
            .qr_code = qr_code,
            // Initial position is off the bottom edge, because next()
            // unconditionally does a movement. Set it up so that the first zig
            // zag starts us in the bottom right corner
            .x_pos = @intCast(qr_code.grid_width - 2),
            .y_pos = @intCast(qr_code.grid_height),
            .moving_vertically = true,
            .movement_direction = -1,
        };
    }

    pub fn next(self: *Self) ?Rect {
        // Qr code data iteration is not super trivial. We follow a zig zag
        // pattern along a 2 block wide column. Starting in the bottom right,
        // and moving up.
        //
        // If we hit a finder pattern, or the edge of the QR code, we have to
        // turn around
        //
        // If we hit an alignment pattern or a timing pattern we have to skip
        // over it, preserving the zig zag motion. Note that if the alignment
        // pattern does not align with the 2 block column, we have to consume
        // the blocks that it does not cover. AFAICT, just continuing the zig
        // zag while we are in the "skippable" sections preserves the correct
        // behavior

        while (true) {
            const last_move_vertical = self.doZigZag();
            self.doTurnAround(last_move_vertical) catch {
                return null;
            };

            if (!shouldSkip(self.x_pos, self.y_pos)) {
                break;
            }
        }

        return self.qr_code.idxToRoi(@intCast(self.x_pos), @intCast(self.y_pos));
    }

    fn doZigZag(self: *Self) bool {
        if (self.moving_vertically) {
            self.x_pos += 1;
            self.y_pos += self.movement_direction;
        } else {
            self.x_pos -= 1;
        }

        self.moving_vertically = !self.moving_vertically;
        return !self.moving_vertically;
    }

    fn doTurnAround(self: *Self, last_move_vertical: bool) !void {
        if (!self.shouldTurnAround(self.x_pos, self.y_pos)) {
            return;
        }

        if (!last_move_vertical) {
            std.log.err("Do not know how to handle horizontal out of bounds", .{});
            return error.Unimplemented;
        }

        self.x_pos -= 2;
        self.y_pos -= self.movement_direction;
        self.movement_direction *= -1;
        self.moving_vertically = false;
    }

    fn shouldSkip(x: i32, y: i32) bool {
        return x == timer_pattern_offset or y == timer_pattern_offset;
    }

    fn shouldTurnAround(self: *const Self, x: i32, y: i32) bool {
        const x_left_of_left_finder = x < finder_num_elements + 2;
        const y_above_top_finder = y < finder_num_elements + 2;

        const in_tl_finder = x_left_of_left_finder and y_above_top_finder;
        if (in_tl_finder) {
            return true;
        }

        const y_below_bottom_finder = y >= self.qr_code.grid_height - finder_num_elements - 1;
        const in_bl_finder = x_left_of_left_finder and y_below_bottom_finder;
        if (in_bl_finder) {
            return true;
        }

        const x_right_of_right_finder = x > self.qr_code.grid_width - finder_num_elements - 1;
        const in_tr_finder = x_right_of_right_finder and y_above_top_finder;
        if (in_tr_finder) {
            return true;
        }

        const out_of_bounds = x >= self.qr_code.grid_width or x < 0 or y >= self.qr_code.grid_height or y < 0;
        if (out_of_bounds) {
            return true;
        }

        return false;
    }
};

pub const QrCode = struct {
    roi: Rect,
    elem_width: f32,
    elem_height: f32,
    grid_width: usize,
    grid_height: usize,

    pub fn init(alloc: Allocator, image: *Image) !QrCode {
        var finders = try findFinderPatterns(alloc, image);
        defer finders.deinit();

        if (finders.items.len != 3) {
            return error.InvalidData;
        }

        var qr_rect = Rect{
            .top = std.math.floatMax(f32),
            .bottom = 0,
            .left = std.math.floatMax(f32),
            .right = 0,
        };

        var elem_width: f32 = 0;
        var elem_height: f32 = 0;

        for (finders.items) |rect| {
            elem_width += rect.width() / finder_num_elements;
            elem_height += rect.height() / finder_num_elements;
            qr_rect.top = @min(qr_rect.top, rect.top);
            qr_rect.bottom = @max(qr_rect.bottom, rect.bottom);
            qr_rect.left = @min(qr_rect.left, rect.left);
            qr_rect.right = @max(qr_rect.right, rect.right);
        }

        elem_width /= @floatFromInt(finders.items.len);
        elem_height /= @floatFromInt(finders.items.len);

        return .{
            .roi = qr_rect,
            .elem_width = elem_width,
            .elem_height = elem_height,
            .grid_width = @intFromFloat(@round(qr_rect.width() / elem_width)),
            .grid_height = @intFromFloat(@round(qr_rect.height() / elem_height)),
        };
    }

    pub fn idxToRoi(self: *const QrCode, x: usize, y: usize) Rect {
        const left = (@as(f32, @floatFromInt(x)) * self.elem_width) + self.roi.left;
        const right = left + self.elem_width;
        const top = (@as(f32, @floatFromInt(y)) * self.elem_height) + self.roi.top;
        const bottom = top + self.elem_height;

        return .{
            .left = left,
            .right = right,
            .top = top,
            .bottom = bottom,
        };
    }

    pub fn horizTimings(self: *const QrCode) HorizTimingIter {
        return HorizTimingIter.init(self);
    }

    pub fn vertTimings(self: *const QrCode) VertTimingIter {
        return VertTimingIter.init(self);
    }

    pub fn data(self: *const QrCode) DataIter {
        return DataIter.init(self);
    }
};

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
