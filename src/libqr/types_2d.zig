pub const Rect = struct {
    top: f32,
    bottom: f32,
    left: f32,
    right: f32,

    pub fn initCenterSize(cx_: f32, cy_: f32, width_: f32, height_: f32) Rect {
        const half_width: f32 = width_ / 2.0;
        const half_height: f32 = height_ / 2.0;
        return .{
            .top = cy_ - half_height,
            .bottom = cy_ + half_height,
            .right = cx_ + half_width,
            .left = cx_ - half_width,
        };
    }

    pub fn height(self: *const Rect) f32 {
        return self.bottom - self.top;
    }

    pub fn width(self: *const Rect) f32 {
        return self.right - self.left;
    }

    pub fn cx(self: *const Rect) f32 {
        return (self.left + self.right) / 2.0;
    }

    pub fn cy(self: *const Rect) f32 {
        return (self.top + self.bottom) / 2.0;
    }
};
