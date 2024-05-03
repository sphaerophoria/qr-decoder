const std = @import("std");
const libqr = @import("libqr");
const bmp_writer = @import("bmp_writer.zig");
const Rect = libqr.types_2d.Rect(f32);
const Point = libqr.types_2d.Point;

fn findRectCorners(rect: Rect) [4]Point {
    std.debug.print("cx: {d}\n", .{rect.cx()});
    const br_x_dist_from_c = rect.right - rect.cx();
    const br_y_dist_from_c = rect.bottom - rect.cy();

    // NOTE: Since it is a rectangle the center is equidistant from
    // all corners
    const corner_dist = std.math.sqrt(br_x_dist_from_c * br_x_dist_from_c + br_y_dist_from_c * br_y_dist_from_c);
    std.debug.print("corner_dist: {d}\n", .{corner_dist});

    const pi_f32: f32 = std.math.pi;
    const existing_rot = std.math.atan2(br_y_dist_from_c, br_x_dist_from_c);
    const rect_rot_rad = rect.rotation_deg * pi_f32 / 180;
    const br_rotation_rad = rect_rot_rad + existing_rot;

    const br = Point{
        .x = rect.cx() + corner_dist * @cos(br_rotation_rad),
        .y = rect.cy() + corner_dist * @sin(br_rotation_rad),
    };

    //
    //  /
    const tr_rotation_rad = rect_rot_rad - existing_rot;

    const bl_rotation_rad = std.math.pi + tr_rotation_rad;
    const tl_rotation_rad = std.math.pi + br_rotation_rad;

    const tr = Point{
        .x = rect.cx() + corner_dist * @cos(tr_rotation_rad),
        .y = rect.cy() + corner_dist * @sin(tr_rotation_rad),
    };

    const tl = Point{
        .x = rect.cx() + corner_dist * @cos(tl_rotation_rad),
        .y = rect.cy() + corner_dist * @sin(tl_rotation_rad),
    };

    const bl = Point{
        .x = rect.cx() + corner_dist * @cos(bl_rotation_rad),
        .y = rect.cy() + corner_dist * @sin(bl_rotation_rad),
    };

    var ret = [4]Point{ br, bl, tl, tr };

    const pointLessThan = struct {
        fn f(_: void, lhs: Point, rhs: Point) bool {
            return lhs.y < rhs.y;
        }
    }.f;

    const smallest_elem = std.sort.argMin(Point, &ret, {}, pointLessThan).?;
    std.mem.rotate(Point, &ret, smallest_elem);

    return ret;
}

const PixelIter = struct {
    corners: [4]Point,
    //stage: Stage,
    left_slope: f32,
    right_slope: f32,
    current_bounds: RowBounds,
    y: usize,
    x: usize,

    //const Stage = enum {
    //    expanding,
    //    middle,
    //    contracting,
    //    finished,
    //};

    const Output = struct {
        x: usize,
        y: usize,
    };

    fn init(rect: *const Rect) PixelIter {
        const corners = findRectCorners(rect.*);
        const left_slope = (corners[3].y - corners[0].y) / (corners[3].x - corners[0].x);
        const right_slope = (corners[1].y - corners[0].y) / (corners[1].x - corners[0].x);

        var ret: PixelIter = .{
            .corners = corners,
            //.stage = .expanding,
            .y = @intFromFloat(corners[0].y),
            .x = @intFromFloat(corners[0].x),
            .left_slope = left_slope,
            .right_slope = right_slope,
            .current_bounds = undefined,
        };

        ret.calcRowBounds();

        return ret;
    }

    const RowBounds = struct {
        start: f32,
        end: f32,
    };

    fn calcRowBounds(self: *PixelIter) void {
        // y = mx
        // y /m
        const y_f: f32 = @floatFromInt(self.y);

        var end = self.corners[0].x + (@as(f32, @floatFromInt(self.y)) - self.corners[0].y) / self.right_slope;
        if (y_f > self.corners[1].y) {
            // Second segment on right edge
            end = self.corners[1].x + (@as(f32, @floatFromInt(self.y)) - self.corners[1].y) / self.left_slope;
        }
        end = std.math.clamp(end, self.corners[3].x, self.corners[1].x);

        var start = self.corners[0].x + (@as(f32, @floatFromInt(self.y)) - self.corners[0].y) / self.left_slope;
        start = @max(self.corners[3].x, start);
        if (y_f > self.corners[3].y) {
            // Second segment on left edge
            start = self.corners[3].x + (@as(f32, @floatFromInt(self.y)) - self.corners[3].y) / self.right_slope;
            start = @min(self.corners[2].x, start);
        }
        start = std.math.clamp(start, self.corners[3].x, self.corners[1].x);

        self.current_bounds = .{
            .start = start,
            .end = end,
        };
        std.debug.print("{any}\n", .{self.current_bounds});
    }

    fn next(self: *PixelIter) ?Output {
        // FIXME: Round?
        if (self.x >= @as(usize, @intFromFloat(self.current_bounds.end))) {
            self.y += 1;
            self.calcRowBounds();
            self.x = @intFromFloat(self.current_bounds.start);
        }

        if (@as(f32, @floatFromInt(self.y)) > self.corners[2].y) {
            return null;
        }

        defer self.x += 1;

        return .{
            .x = self.x,
            .y = self.y,
        };
    }
};

pub fn main() !void {
    const f = try std.fs.cwd().createFile("test.bmp", .{});
    const width = 100;
    const height = 100;
    var data = [1]bmp_writer.BmpPixel{.{
        .b = 255,
        .a = 255,
        .g = 0,
        .r = 0,
    }} ** (width * height);

    const rect = Rect{
        .left = 30,
        .right = 90,
        .top = 30,
        .bottom = 50,
        .rotation_deg = 25,
    };

    const br = findRectCorners(rect);
    std.debug.print("{any}\n", .{br});

    var it = PixelIter.init(&rect);
    while (it.next()) |px| {
        std.debug.print("px: {any}\n", .{px});
        data[px.y * width + px.x] = .{
            .b = 0,
            .g = 255,
            .r = 0,
            .a = 255,
        };
    }

    try bmp_writer.writeBmp(f.writer(), &data, width);
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
