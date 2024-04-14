const std = @import("std");
const xml = @import("xml.zig");
const Allocator = std.mem.Allocator;

pub fn Visualizer(comptime Writer: type) type {
    return struct {
        svg_builder: xml.XmlBuilder(Writer),

        const Self = @This();

        pub fn init(alloc: Allocator, writer: anytype, width: usize, height: usize, image_path: []const u8) !Self {
            var svg_builder = xml.xmlBuilder(alloc, writer);

            try svg_builder.addNode("svg");
            try svg_builder.addAttribute("version", "1.1");
            try svg_builder.addAttribute("xmlns", "http://www.w3.org/2000/svg");
            try svg_builder.addAttributeNum("width", width);
            try svg_builder.addAttributeNum("height", height);
            try svg_builder.finishAttributes();

            try svg_builder.addNode("image");
            try svg_builder.addAttribute("x", "0");
            try svg_builder.addAttribute("y", "0");
            try svg_builder.addAttributeNum("width", width);
            try svg_builder.addAttributeNum("height", height);
            try svg_builder.addAttribute("href", image_path);
            try svg_builder.finishNode();

            return .{
                .svg_builder = svg_builder,
            };
        }

        pub fn finish(self: *Self) !void {
            try self.svg_builder.finish();
        }

        pub fn drawCircle(self: *Self, cx: f32, cy: f32, r: f32, fill: []const u8) !void {
            try self.svg_builder.addNode("circle");
            try self.svg_builder.addAttributeNum("cx", cx);
            try self.svg_builder.addAttributeNum("cy", cy);
            try self.svg_builder.addAttributeNum("r", r);
            try self.svg_builder.addAttribute("fill", fill);
            try self.svg_builder.finishNode();
        }
    };
}
