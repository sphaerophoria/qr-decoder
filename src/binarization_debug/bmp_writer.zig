const std = @import("std");
const fs = std.fs;

const BmpFileHeader = packed struct {
    bf_type: u16 = 0x4d42,
    bf_size: u32,
    reserved: u16 = 0,
    reserved2: u16 = 0,
    bf_off_bits: u32,

    // note that due to alignment @sizeOf will produce something that may not
    // match what we expect
    const size = @bitSizeOf(BmpFileHeader) / 8;
};

const BmpInfoHeader = packed struct {
    bi_size: u32 = BmpInfoHeader.size,
    bi_width: i32,
    bi_height: i32,
    bi_planes: u16,
    bi_bit_count: u16,
    bi_compression: u32,
    bi_size_image: u32,
    bi_x_pels_per_meter: u32,
    bi_y_pels_per_meter: u32,
    bi_clr_used: u32,
    bi_clr_important: u32,

    // note that due to alignment @sizeOf will produce something that may not
    // match what we expect
    const size = @bitSizeOf(BmpInfoHeader) / 8;
};

const BmpHeader = packed struct {
    file_header: BmpFileHeader,
    info_header: BmpInfoHeader,
};

pub const BmpPixel = packed struct {
    b: u8,
    g: u8,
    r: u8,
    a: u8,
};

// Extremely naive bmp writer. Forces 32 bits per pixel, and top to bottom orientation
pub fn writeBmp(writer: anytype, data: []const BmpPixel, width: usize) !void {
    const file_header = BmpFileHeader{
        .bf_size = @intCast(BmpFileHeader.size + BmpInfoHeader.size + data.len * @sizeOf(u32)),
        .bf_off_bits = BmpInfoHeader.size + BmpFileHeader.size,
    };

    std.debug.assert(data.len % width == 0);

    const info = BmpInfoHeader{
        .bi_width = @intCast(width),
        .bi_height = -@as(i32, @intCast(data.len / width)),
        .bi_planes = 1,
        .bi_bit_count = 32,
        .bi_compression = 0,
        .bi_size_image = 0,
        .bi_x_pels_per_meter = 0,
        .bi_y_pels_per_meter = 0,
        .bi_clr_used = 0,
        .bi_clr_important = 0,
    };

    try writer.writeAll(std.mem.asBytes(&file_header)[0..BmpFileHeader.size]);
    try writer.writeAll(std.mem.asBytes(&info)[0..BmpInfoHeader.size]);
    try writer.writeAll(std.mem.sliceAsBytes(data));
}

test "sanity test" {
    const libqr = @import("libqr");
    var bmp = std.ArrayList(u8).init(std.testing.allocator);
    defer bmp.deinit();

    const pixel_data: []const u8 = &.{
        0,   5,   34,  128,
        99,  74,  192, 90,
        255, 255, 232, 143,
        55,  32,  11,  2,
    };

    var pixel_data_bmp: [pixel_data.len]BmpPixel = undefined;
    for (pixel_data, 0..) |p, i| {
        pixel_data_bmp[i] = .{ .r = p, .g = p, .b = p, .a = 255 };
    }

    try writeBmp(bmp.writer(), &pixel_data_bmp, 4);
    var img = try libqr.img.Image.fromArray(bmp.items);
    defer img.deinit();

    try std.testing.expectEqual(4, img.width);
    try std.testing.expectEqual(4, img.height);
    try std.testing.expectEqualSlices(u8, pixel_data, img.data);
}
