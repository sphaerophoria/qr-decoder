pub const Point = struct {
    x: f32,
    y: f32,
};

pub fn Rect(comptime T: type) type {
    return struct {
        top: T,
        bottom: T,
        left: T,
        right: T,
        rotation_deg: f32 = 0,

        const Self = @This();

        pub fn initCenterSize(cx_: T, cy_: T, width_: T, height_: T) Self {
            const half_width: T = width_ / 2.0;
            const half_height: T = height_ / 2.0;
            return .{
                .top = cy_ - half_height,
                .bottom = cy_ + half_height,
                .right = cx_ + half_width,
                .left = cx_ - half_width,
            };
        }

        pub fn height(self: *const Self) T {
            return self.bottom - self.top;
        }

        pub fn width(self: *const Self) T {
            return self.right - self.left;
        }

        pub fn cx(self: *const Self) T {
            return (self.left + self.right) / 2;
        }

        pub fn cy(self: *const Self) T {
            return (self.top + self.bottom) / 2;
        }
    };
}
