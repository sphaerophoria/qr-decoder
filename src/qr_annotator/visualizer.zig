const std = @import("std");
const libqr = @import("libqr");
const xml = @import("xml.zig");
const types_2d = libqr.types_2d;
const Allocator = std.mem.Allocator;
const Rect = types_2d.Rect(f32);

pub fn Visualizer(comptime Writer: type) type {
    return struct {
        svg_builder: xml.XmlBuilder(Writer),
        stroke_width: f32,
        font_size: f32,

        const Self = @This();

        pub fn init(alloc: Allocator, writer: anytype, width: usize, height: usize, image_path: ?[]const u8) !Self {
            var svg_builder = xml.xmlBuilder(alloc, writer);

            try svg_builder.addNode("svg");
            try svg_builder.addAttribute("version", "1.1");
            try svg_builder.addAttribute("xmlns", "http://www.w3.org/2000/svg");
            try svg_builder.addAttributeNum("width", width);
            try svg_builder.addAttributeNum("height", height);
            try svg_builder.finishAttributes();

            if (image_path) |path| {
                try svg_builder.addNode("image");
                try svg_builder.addAttribute("x", "0");
                try svg_builder.addAttribute("y", "0");
                try svg_builder.addAttributeNum("width", width);
                try svg_builder.addAttributeNum("height", height);
                try svg_builder.addAttribute("href", path);
                try svg_builder.finishNode();
            }

            return .{
                .svg_builder = svg_builder,
                .stroke_width = @as(f32, @floatFromInt(width)) / 1000.0,
                .font_size = @as(f32, @floatFromInt(width)) / 50.0,
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

        pub fn drawBox(self: *Self, rect: Rect, stroke: []const u8, fill: ?[]const u8) !void {
            try self.svg_builder.addNode("rect");
            try self.svg_builder.addAttributeNum("x", rect.left);
            try self.svg_builder.addAttributeNum("y", rect.top);
            try self.svg_builder.addAttributeNum("width", rect.width());
            try self.svg_builder.addAttributeNum("height", rect.height());
            const fill_val = fill orelse "none";
            try self.svg_builder.addAttribute("fill", fill_val);
            try self.svg_builder.addAttribute("stroke", stroke);
            try self.svg_builder.finishNode();
        }

        pub fn drawText(self: *Self, x: f32, y: f32, color: []const u8, text: []const u8) !void {
            // <text x="20" y="35" stroke="red" stroke-width="0.1" fill="red" font-size="2">1</text>
            try self.svg_builder.addNode("text");
            try self.svg_builder.addAttributeNum("x", x);
            try self.svg_builder.addAttributeNum("y", y);
            try self.svg_builder.addAttributeNum("stroke-width", self.stroke_width);
            try self.svg_builder.addAttribute("fill", color);
            try self.svg_builder.addAttribute("stroke", color);
            try self.svg_builder.addAttributeNum("font-size", self.font_size);
            try self.svg_builder.finishAttributes();
            try self.svg_builder.addData(text);

            try self.svg_builder.finishNode();
        }
    };
}
