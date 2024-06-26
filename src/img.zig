const types_2d = @import("types_2d.zig");
const Rect = types_2d.Rect;

const c = @cImport({
    @cInclude("stb_image.h");
});

pub fn isLightPixel(luma: u8) bool {
    return luma > 128;
}

pub fn IsLightIter(comptime T: type) type {
    return struct {
        it: T,

        const Self = @This();

        pub fn next(self: *Self) ?bool {
            const val = self.it.next() orelse {
                return null;
            };

            return isLightPixel(val);
        }
    };
}

pub fn isLightIter(it: anytype) IsLightIter(@TypeOf(it)) {
    return .{
        .it = it,
    };
}

pub fn isLightRoi(roi: *const Rect, image: *Image) bool {
    const start_y: usize = @intFromFloat(@ceil(roi.top));
    const end_y: usize = @intFromFloat(@floor(roi.bottom));
    const start_x: usize = @intFromFloat(@ceil(roi.left));
    const end_x: usize = @intFromFloat(@floor(roi.right));

    var val: usize = 0;
    for (start_y..end_y) |y| {
        for (start_x..end_x) |x| {
            val += image.get(x, y);
        }
    }

    return val > 128 * (end_y - start_y) * (end_x - start_x);
}

pub const HorizIter = struct {
    line: []const u8,
    i: usize,

    pub fn init(image: [*]u8, width: usize, y: usize) HorizIter {
        const start = width * y;
        const end = start + width;
        const line = image[start..end];

        return .{
            .line = line,
            .i = 0,
        };
    }

    pub fn next(self: *HorizIter) ?u8 {
        if (self.i >= self.line.len) {
            return null;
        }

        const val = self.line[self.i];
        self.i += 1;
        return val;
    }
};

pub const VertIter = struct {
    image: []const u8,
    idx: usize,
    width: usize,

    pub fn init(image: [*]u8, width: usize, height: usize, x: usize) VertIter {
        return .{
            .image = image[0 .. width * height],
            .idx = x,
            .width = width,
        };
    }

    pub fn next(self: *VertIter) ?u8 {
        if (self.idx >= self.image.len) {
            return null;
        }

        const val = self.image[self.idx];
        self.idx += self.width;
        return val;
    }
};

pub const Image = struct {
    width: usize,
    height: usize,
    data: [*]u8,

    pub fn open(path: [:0]const u8) !Image {
        var img_width_c: c_int = undefined;
        var img_height_c: c_int = undefined;
        var num_channels: c_int = undefined;
        const data = c.stbi_load(path, &img_width_c, &img_height_c, &num_channels, 1);

        return .{
            .width = @intCast(img_width_c),
            .height = @intCast(img_height_c),
            .data = data,
        };
    }

    pub fn fromArray(input: []const u8) !Image {
        var img_width_c: c_int = undefined;
        var img_height_c: c_int = undefined;
        var num_channels: c_int = undefined;
        const data = c.stbi_load_from_memory(input.ptr, @intCast(input.len), &img_width_c, &img_height_c, &num_channels, 1);

        return .{
            .width = @intCast(img_width_c),
            .height = @intCast(img_height_c),
            .data = data,
        };
    }

    pub fn deinit(self: *Image) void {
        c.stbi_image_free(self.data);
    }

    pub fn get(self: *Image, x: usize, y: usize) u8 {
        return self.data[y * self.width + x];
    }

    pub fn row(self: *Image, y: usize) HorizIter {
        return HorizIter.init(self.data, self.width, y);
    }

    pub fn col(self: *Image, x: usize) VertIter {
        return VertIter.init(self.data, self.width, self.height, x);
    }
};
