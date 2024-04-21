const std = @import("std");
const img = @import("img.zig");
const vis = @import("visualizer.zig");
const types_2d = @import("types_2d.zig");
const Rect = types_2d.Rect;
const Image = img.Image;

const Allocator = std.mem.Allocator;

const qr = @This();

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
// Vertical position for horizontal pattern, 2 elements after finder pattern, 1
// index after the length
const format_pattern_offset: usize = finder_num_elements + 1;
const alignment_pattern_size: usize = 5;

pub fn mask_pattern_0(x: usize, y: usize) bool {
    _ = y;
    return x % 3 == 0;
}

pub fn mask_pattern_2(x: usize, y: usize) bool {
    return (x + y) % 2 == 0;
}

pub fn mask_pattern_5(x: usize, y: usize) bool {
    return (((x * y) % 3) + x + y) % 2 == 0;
}

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

pub const HorizFormatIter = struct {
    qr_code: *const QrCode,
    x_pos: usize,

    const Self = @This();

    fn init(qr_code: *const QrCode) HorizFormatIter {
        return .{
            .qr_code = qr_code,
            .x_pos = 0,
        };
    }

    pub fn next(self: *Self) ?Rect {
        while (true) {
            if (self.x_pos >= self.qr_code.grid_width) {
                return null;
            }

            const prev_x = self.x_pos;

            self.x_pos += 1;
            const second_half_start = self.qr_code.grid_width - finder_num_elements - 1;

            if (self.x_pos >= finder_num_elements + 1 and self.x_pos < second_half_start) {
                self.x_pos = second_half_start;
            }

            if (prev_x == timer_pattern_offset) {
                continue;
            }

            return self.qr_code.idxToRoi(prev_x, format_pattern_offset);
        }
    }
};

pub const VertFormatIter = struct {
    qr_code: *const QrCode,
    y_pos: usize,

    const Self = @This();

    fn init(qr_code: *const QrCode) VertFormatIter {
        return .{
            .qr_code = qr_code,
            .y_pos = qr_code.grid_height,
        };
    }

    pub fn next(self: *Self) ?Rect {
        while (true) {
            if (self.y_pos == 0) {
                return null;
            }
            self.y_pos -= 1;

            const first_half_end = self.qr_code.grid_height - finder_num_elements - 1;

            if (self.y_pos == first_half_end) {
                self.y_pos = finder_num_elements + 1;
            }

            if (self.y_pos == timer_pattern_offset) {
                continue;
            }

            return self.qr_code.idxToRoi(format_pattern_offset, self.y_pos);
        }
    }
};

pub const MaskFn = *const fn (usize, usize) bool;

pub const DataBitIter = struct {
    qr_code: *const QrCode,
    x_pos: i32,
    y_pos: i32,
    moving_vertically: bool,
    movement_direction: i2,
    mask_fn: MaskFn,
    image: *img.Image,

    const Self = @This();

    pub const Output = struct {
        x: usize,
        y: usize,
        val: bool,
        roi: Rect,
    };

    pub fn init(qr_code: *const QrCode, mask_fn: MaskFn, image: *img.Image) Self {
        return .{
            .qr_code = qr_code,
            // Initial position is off the bottom edge, because next()
            // unconditionally does a movement. Set it up so that the first zig
            // zag starts us in the bottom right corner
            .x_pos = @intCast(qr_code.grid_width - 2),
            .y_pos = @intCast(qr_code.grid_height),
            .mask_fn = mask_fn,
            .image = image,
            .moving_vertically = true,
            .movement_direction = -1,
        };
    }

    pub fn next(self: *Self) ?Output {
        if (self.updatePosition()) {
            return null;
        }

        const roi = self.qr_code.idxToRoi(@intCast(self.x_pos), @intCast(self.y_pos));
        const x: usize = @intCast(self.x_pos);
        const y: usize = @intCast(self.y_pos);
        const is_dark = !img.isLightRoi(&roi, self.image);
        const val = is_dark != self.mask_fn(x, y);

        return .{
            .x = @intCast(self.x_pos),
            .y = @intCast(self.y_pos),
            .val = val,
            .roi = roi,
        };
    }

    /// Update our current position, return true if finished iterating
    fn updatePosition(self: *Self) bool {
        // Qr code data iteration is not super trivial. We follow a zig zag
        // pattern along a 2 block wide column. Starting in the bottom right,
        // and moving up.
        //
        // If we hit a finder pattern, or the edge of the QR code, we have to
        // turn around
        //
        // If we hit an alignment pattern or a timing pattern we have to skip
        // over it. In some cases we preserve the zig zag pattern, but in
        // others we have to just continue in a straight line. Note that if the
        // alignment pattern does not align with the 2 block column, we have to
        // consume the blocks that it does not cover.
        //
        // Do one move following the typical zig zag pattern, and if that puts
        // us in a bad spot, continue moving until we're out

        var last_move_vertical = self.doZigZag();
        while (true) {
            const next_action = self.checkNextAction();
            switch (next_action) {
                .continue_straight => {
                    self.doContinue(last_move_vertical);
                },
                .continue_zig_zag => {
                    last_move_vertical = self.doZigZag();
                },
                .turn_around => {
                    self.doTurnAround();
                    last_move_vertical = false;
                },
                .finish => {
                    return true;
                },
                .yield => {
                    return false;
                },
            }
        }
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

    fn doContinue(self: *Self, last_move_vertical: bool) void {
        if (last_move_vertical) {
            self.y_pos += self.movement_direction;
        } else {
            self.x_pos -= 1;
        }
    }

    fn doTurnAround(self: *Self) void {
        self.x_pos -= 2;
        self.y_pos -= self.movement_direction;
        self.movement_direction *= -1;
        self.moving_vertically = false;
    }

    const NextAction = enum {
        continue_zig_zag,
        continue_straight,
        turn_around,
        finish,
        yield,
    };

    const NextActionHelper = struct {
        x: i32,
        y: i32,
        grid_width: usize,
        grid_height: usize,
        x_right_of_right_finder: bool,
        y_above_top_finder: bool,
        x_left_of_left_finder: bool,
        y_below_bottom_finder: bool,
        alignment_patterns: []const GridPoint,

        const Helper = @This();

        fn init(parent: *const Self) Helper {
            const x_right_of_right_finder = parent.x_pos > parent.qr_code.grid_width - finder_num_elements - 1;
            const y_below_bottom_finder = parent.y_pos >= parent.qr_code.grid_height - finder_num_elements - 1;
            const y_above_top_finder = parent.y_pos <= format_pattern_offset;
            const x_left_of_left_finder = parent.x_pos <= format_pattern_offset;
            return .{
                .x = parent.x_pos,
                .y = parent.y_pos,
                .grid_width = parent.qr_code.grid_width,
                .grid_height = parent.qr_code.grid_height,
                .x_right_of_right_finder = x_right_of_right_finder,
                .y_above_top_finder = y_above_top_finder,
                .x_left_of_left_finder = x_left_of_left_finder,
                .y_below_bottom_finder = y_below_bottom_finder,
                .alignment_patterns = parent.qr_code.alignment_positions.items,
            };
        }

        fn finished(self: *const Helper) bool {
            return self.x < 0;
        }

        fn outOfBoundsY(self: *const Helper) bool {
            return self.y >= self.grid_height or self.y < 0;
        }

        fn inTrFinder(self: *const Helper) bool {
            return self.x_right_of_right_finder and self.y_above_top_finder;
        }

        fn inTlFinder(self: *const Helper) bool {
            return self.x_left_of_left_finder and self.y_above_top_finder;
        }

        fn inBrFinder(self: *const Helper) bool {
            return self.x_left_of_left_finder and self.y_below_bottom_finder;
        }

        fn inTimerPattern(self: *const Helper) bool {
            return self.x == timer_pattern_offset or self.y == timer_pattern_offset;
        }

        fn inAlignmentPattern(self: *const Helper) bool {
            for (self.alignment_patterns) |tl| {
                const x_in_alignment = self.x >= tl.x and self.x < tl.x + alignment_pattern_size;
                const y_in_alignment = self.y >= tl.y and self.y < tl.y + alignment_pattern_size;
                if (x_in_alignment and y_in_alignment) {
                    return true;
                }
            }

            return false;
        }
    };

    fn checkNextAction(self: *Self) NextAction {
        // There's a lot of conditions here, name them and put them somewhere else
        const helper = NextActionHelper.init(self);

        if (helper.finished()) {
            return .finish;
        }

        // If we are out of bounds on the top or bottom edge, nothing to think
        // about, just turn around
        if (helper.outOfBoundsY()) {
            return .turn_around;
        }

        // If we are in the top right finder, we must have got there from
        // below. We start iterating from the bottom right
        if (helper.inTrFinder()) {
            return .turn_around;
        }

        // If we are in one of the left finders, we have two options. If we
        // were moving towards the finder we hit, we have to turn around,
        // however if we're moving away (because we entered from the outside
        // edge during a turn around),  we can just keep zig zagging until we
        // escape
        if (helper.inTlFinder()) {
            if (self.movement_direction == -1) {
                return .turn_around;
            } else {
                return .continue_zig_zag;
            }
        }

        if (helper.inBrFinder()) {
            if (self.movement_direction == 1) {
                return .turn_around;
            } else {
                return .continue_zig_zag;
            }
        }

        // If we hit the timing rows, we have to continue moving in the same
        // direction. Note that we do not do the normal zig zag pattern in this
        // case. If we did, we would read 4 bits vertically on the left edge of
        // the vertical timing pattern instead of skipping the timing column
        // completely
        if (helper.inTimerPattern()) {
            return .continue_straight;
        }

        if (helper.inAlignmentPattern()) {
            return .continue_zig_zag;
        }

        return .yield;
    }
};

pub fn BitCollector(comptime ValType: type, comptime ShiftType: type) type {
    return struct {
        val: ValType = 0,
        idx: ShiftType = std.math.maxInt(ShiftType),

        const Self = @This();
        fn push(self: *Self, in: bool) ?ValType {
            if (in) {
                self.val |= @as(ValType, 1) << self.idx;
            }

            if (self.idx == 0) {
                self.idx = std.math.maxInt(ShiftType);
                const ret = self.val;
                self.val = 0;
                return ret;
            } else {
                self.idx -= 1;
            }

            return null;
        }
    };
}

test "bit collector" {
    var c = BitCollector(u4, u2){};
    try std.testing.expectEqual(@as(?u4, null), c.push(true));
    try std.testing.expectEqual(@as(?u4, null), c.push(false));
    try std.testing.expectEqual(@as(?u4, null), c.push(true));
    try std.testing.expectEqual(@as(?u4, 0b1011), c.push(true));
}

fn collectBits(collector: anytype, it: *DataBitIter) !@TypeOf(collector.val) {
    while (true) {
        var item = it.next() orelse {
            std.log.err("data stream ended early\n", .{});
            return error.InvalidData;
        };

        if (collector.push(item.val)) |output| {
            return output;
        }
    }
}

pub const DataIter = struct {
    bit_iter: DataBitIter,
    encoding: u4,
    length: u8,
    num_bytes_read: usize,
    collector: BitCollector(u8, u3),

    fn init(bit_iter_in: DataBitIter) !DataIter {
        var bit_iter = bit_iter_in;

        var encoding_collector = BitCollector(u4, u2){};
        var encoding = try collectBits(&encoding_collector, &bit_iter);

        var u8_collector = BitCollector(u8, u3){};
        var length: u8 = try collectBits(&u8_collector, &bit_iter);

        return .{
            .bit_iter = bit_iter,
            .encoding = encoding,
            .num_bytes_read = 0,
            .length = length,
            .collector = BitCollector(u8, u3){},
        };
    }

    pub fn next(self: *DataIter) ?u8 {
        while (true) {
            if (self.length == self.num_bytes_read) {
                return null;
            }

            const ret = collectBits(&self.collector, &self.bit_iter) catch {
                return null;
            };
            self.num_bytes_read += 1;
            return ret;
        }
    }
};

const ImageTimingXPixelIter = struct {
    image: *img.Image,
    timing_row_center_px: usize,
    timing_x_pos: usize,
    timing_iter_end: usize,

    fn init(image: *img.Image, qr_rect: *const Rect, estimated_elem_width: f32, estimated_elem_height: f32, finder_width: f32) ImageTimingXPixelIter {
        const timing_row_center_f = qr_rect.top + finder_num_elements * estimated_elem_height - estimated_elem_height / 2.0;
        const timing_row_center_px: usize = @intFromFloat(@round(timing_row_center_f));
        var timing_x_pos: usize = @intFromFloat(@round(qr_rect.left + finder_num_elements * estimated_elem_width - estimated_elem_width / 2.0));
        const timing_iter_end: usize = @intFromFloat(@round(qr_rect.right - finder_width + estimated_elem_width / 2.0));

        return .{
            .image = image,
            .timing_row_center_px = timing_row_center_px,
            .timing_x_pos = timing_x_pos,
            .timing_iter_end = timing_iter_end,
        };
    }

    fn next(self: *ImageTimingXPixelIter) ?u8 {
        if (self.timing_x_pos > self.timing_iter_end) {
            return null;
        }

        const ret = self.image.get(self.timing_x_pos, self.timing_row_center_px);
        self.timing_x_pos += 1;
        return ret;
    }
};

const ImageTimingYPixelIter = struct {
    image: *img.Image,
    timing_col_center_px: usize,
    timing_y_pos: usize,
    timing_iter_end: usize,

    fn init(image: *img.Image, qr_rect: *const Rect, estimated_elem_width: f32, estimated_elem_height: f32, finder_height: f32) ImageTimingYPixelIter {
        const timing_col_center_f = qr_rect.left + finder_num_elements * estimated_elem_width - estimated_elem_width / 2.0;
        const timing_col_center_px: usize = @intFromFloat(@round(timing_col_center_f));
        var timing_y_pos: usize = @intFromFloat(@round(qr_rect.top + finder_num_elements * estimated_elem_height - estimated_elem_height / 2.0));
        const timing_iter_end: usize = @intFromFloat(@round(qr_rect.bottom - finder_height + estimated_elem_height / 2.0));

        return .{
            .image = image,
            .timing_col_center_px = timing_col_center_px,
            .timing_y_pos = timing_y_pos,
            .timing_iter_end = timing_iter_end,
        };
    }

    fn next(self: *ImageTimingYPixelIter) ?u8 {
        if (self.timing_y_pos > self.timing_iter_end) {
            return null;
        }

        const ret = self.image.get(self.timing_col_center_px, self.timing_y_pos);
        self.timing_y_pos += 1;
        return ret;
    }
};

fn findElemSize(it: anytype, total_size: f32) f32 {
    var last_is_light = img.isLightPixel(it.next().?);
    var num_elems = finder_num_elements * 2 - 1;

    while (it.next()) |val| {
        var is_light = img.isLightPixel(val);
        if (is_light != last_is_light) {
            num_elems += 1;
        }
        last_is_light = is_light;
    }

    return total_size / @as(f32, @floatFromInt(num_elems));
}

fn idxToRoi(roi: *const Rect, elem_width: f32, elem_height: f32, x: usize, y: usize) Rect {
    const left = (@as(f32, @floatFromInt(x)) * elem_width) + roi.left;
    const right = left + elem_width;
    const top = (@as(f32, @floatFromInt(y)) * elem_height) + roi.top;
    const bottom = top + elem_height;

    return .{
        .left = left,
        .right = right,
        .top = top,
        .bottom = bottom,
    };
}

pub const GridPoint = struct {
    x: usize,
    y: usize,
};

pub const AlignmentFinder = struct {
    // Top left
    x_pos: usize,
    y_pos: usize,

    qr_roi: Rect,
    elem_width: f32,
    elem_height: f32,
    grid_width: usize,
    grid_height: usize,
    image: *Image,

    const Output = struct {
        tl: GridPoint,
        roi: Rect,
    };

    pub fn init(
        qr_roi: Rect,
        elem_width: f32,
        elem_height: f32,
        grid_width: usize,
        grid_height: usize,
        image: *Image,
    ) AlignmentFinder {
        return .{
            .qr_roi = qr_roi,
            .elem_width = elem_width,
            .elem_height = elem_height,
            .grid_width = grid_width,
            .grid_height = grid_height,
            .image = image,
            .x_pos = 0,
            .y_pos = 0,
        };
    }

    fn isAlignmentElement(self: *AlignmentFinder) bool {
        for (0..alignment_pattern_size) |y_offs| {
            for (0..alignment_pattern_size) |x_offs| {
                const is_light = img.isLightRoi(&idxToRoi(
                    &self.qr_roi,
                    self.elem_width,
                    self.elem_height,
                    self.x_pos + x_offs,
                    self.y_pos + y_offs,
                ), self.image);

                const should_be_light = ((y_offs == 1 or y_offs == 3) and x_offs > 0 and x_offs < 4) or
                    ((x_offs == 1 or x_offs == 3) and y_offs > 0 and y_offs < 4);

                if (is_light != should_be_light) {
                    return false;
                }
            }
        }

        return true;
    }

    pub fn next(self: *AlignmentFinder) ?Output {
        while (true) {
            if (self.y_pos >= self.grid_height - 3) {
                return null;
            }

            defer {
                self.x_pos += 1;
                if (self.x_pos >= self.grid_width - 3) {
                    self.x_pos = 0;
                    self.y_pos += 1;
                }
            }

            if (self.isAlignmentElement()) {
                var roi = idxToRoi(&self.qr_roi, self.elem_width, self.elem_height, self.x_pos, self.y_pos);
                roi.bottom += self.elem_height * 4;
                roi.right += self.elem_width * 4;

                return .{
                    .tl = .{
                        .x = self.x_pos,
                        .y = self.y_pos,
                    },
                    .roi = roi,
                };
            }
        }
    }
};

pub const QrCode = struct {
    roi: Rect,
    elem_width: f32,
    elem_height: f32,
    grid_width: usize,
    grid_height: usize,
    alignment_positions: std.ArrayList(GridPoint),

    pub fn init(alloc: Allocator, image: *Image) !QrCode {
        var finders = try findFinderPatterns(alloc, image);
        defer finders.deinit();

        if (finders.items.len != 3) {
            std.log.err("found {d} finder patterns, expected 3", .{finders.items.len});
            return error.InvalidData;
        }

        var qr_rect = Rect{
            .top = std.math.floatMax(f32),
            .bottom = 0,
            .left = std.math.floatMax(f32),
            .right = 0,
        };

        var finder_width: f32 = 0;
        var finder_height: f32 = 0;

        for (finders.items) |rect| {
            finder_width += rect.width();
            finder_height += rect.height();
            qr_rect.top = @min(qr_rect.top, rect.top);
            qr_rect.bottom = @max(qr_rect.bottom, rect.bottom);
            qr_rect.left = @min(qr_rect.left, rect.left);
            qr_rect.right = @max(qr_rect.right, rect.right);
        }

        finder_width /= @floatFromInt(finders.items.len);
        finder_height /= @floatFromInt(finders.items.len);

        const estimated_elem_height = finder_height / finder_num_elements;
        const estimated_elem_width = finder_width / finder_num_elements;

        var x_timing_iter = ImageTimingXPixelIter.init(image, &qr_rect, estimated_elem_width, estimated_elem_height, finder_width);
        const elem_width = findElemSize(&x_timing_iter, qr_rect.width());

        var y_timing_iter = ImageTimingYPixelIter.init(image, &qr_rect, estimated_elem_width, estimated_elem_height, finder_height);
        const elem_height = findElemSize(&y_timing_iter, qr_rect.height());

        const grid_width: usize = @intFromFloat(@round(qr_rect.width() / elem_width));
        const grid_height: usize = @intFromFloat(@round(qr_rect.height() / elem_height));

        var alignment_finder = AlignmentFinder.init(
            qr_rect,
            elem_width,
            elem_height,
            grid_width,
            grid_height,
            image,
        );

        var alignment_positions = std.ArrayList(GridPoint).init(alloc);
        errdefer alignment_positions.deinit();

        while (alignment_finder.next()) |item| {
            try alignment_positions.append(item.tl);
        }

        return .{
            .roi = qr_rect,
            .elem_width = elem_width,
            .elem_height = elem_height,
            .grid_width = grid_width,
            .grid_height = grid_height,
            .alignment_positions = alignment_positions,
        };
    }

    pub fn deinit(self: *QrCode) void {
        self.alignment_positions.deinit();
    }

    pub fn idxToRoi(self: *const QrCode, x: usize, y: usize) Rect {
        return qr.idxToRoi(&self.roi, self.elem_width, self.elem_height, x, y);
    }

    pub fn horizTimings(self: *const QrCode) HorizTimingIter {
        return HorizTimingIter.init(self);
    }

    pub fn vertTimings(self: *const QrCode) VertTimingIter {
        return VertTimingIter.init(self);
    }

    pub fn horizFormat(self: *const QrCode) HorizFormatIter {
        return HorizFormatIter.init(self);
    }

    pub fn vertFormat(self: *const QrCode) VertFormatIter {
        return VertFormatIter.init(self);
    }

    pub fn bitIter(self: *const QrCode, image: *img.Image) !DataBitIter {
        var format_it = self.horizFormat();
        for (0..2) |_| {
            _ = format_it.next();
        }

        var mask_val: u3 = 0;
        for (0..3) |i| {
            const roi = format_it.next() orelse {
                std.log.err("Format iterator ended before we finished parsing the mask type", .{});
                return error.InvalidData;
            };

            if (img.isLightRoi(&roi, image)) {
                mask_val |= @as(@TypeOf(mask_val), 1) << @intCast(3 - i);
            }
        }

        var mask_fn = switch (mask_val) {
            0 => &mask_pattern_0,
            2 => &mask_pattern_2,
            5 => &mask_pattern_5,
            else => {
                std.log.err("Unimplemented mask function", .{});
                return error.Unimplemented;
            },
        };

        return DataBitIter.init(self, mask_fn, image);
    }

    pub fn data(self: *QrCode, image: *img.Image) !DataIter {
        return DataIter.init(try self.bitIter(image));
    }
};

test "hello world" {
    var alloc = std.testing.allocator;
    var image = try img.Image.fromArray(@embedFile("res/hello_world.gif"));
    var qr_code = try QrCode.init(alloc, &image);
    defer qr_code.deinit();

    var it = try qr_code.data(&image);
    try std.testing.expectEqual(it.encoding, 4);

    var output = std.ArrayList(u8).init(alloc);
    defer output.deinit();

    while (it.next()) |v| {
        try output.append(v);
    }

    try std.testing.expectEqualStrings("hello world", output.items);
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
