const std = @import("std");
const xml = @import("xml.zig");
const Allocator = std.mem.Allocator;
const vis = @import("visualizer.zig");
const libqr = @import("libqr");
const qr = libqr.qr;
const img = libqr.img;
const types_2d = libqr.types_2d;
const Rect = types_2d.Rect;

const ArgsHelper = struct {
    it: std.process.ArgIterator,
    process_name: []const u8,
    stderr: std.fs.File.Writer,

    fn init(alloc: Allocator) !ArgsHelper {
        var it = try std.process.argsWithAllocator(alloc);
        const process_name = it.next() orelse "qr-decoder";
        const stderr = std.io.getStdErr().writer();
        return .{
            .it = it,
            .process_name = process_name,
            .stderr = stderr,
        };
    }

    fn help(self: *const ArgsHelper) noreturn {
        self.print(
            \\Usage {s} --input [INPUT] --output [OUTPUT]
            \\
        , .{self.process_name});
        std.process.exit(1);
    }

    fn print(self: *const ArgsHelper, comptime fmt: []const u8, vals: anytype) void {
        self.stderr.print(fmt, vals) catch {};
    }

    fn next(self: *ArgsHelper) ?[:0]const u8 {
        return self.it.next();
    }

    fn nextStr(self: *ArgsHelper, name: []const u8) [:0]const u8 {
        return self.next() orelse {
            self.print("val for {s} not found\n", .{name});
            self.help();
        };
    }
};

const Args = struct {
    input: [:0]const u8,
    output: ?[]const u8,
    it: std.process.ArgIterator,

    fn parse(alloc: Allocator) !Args {
        var helper = try ArgsHelper.init(alloc);
        var input_opt: ?[:0]const u8 = null;
        var output: ?[]const u8 = null;

        while (helper.next()) |arg| {
            if (std.mem.eql(u8, arg, "--input")) {
                input_opt = helper.nextStr("--input");
            } else if (std.mem.eql(u8, arg, "--output")) {
                output = helper.nextStr("--output");
            } else if (std.mem.eql(u8, arg, "--help")) {
                helper.help();
            }
        }

        const input = input_opt orelse {
            helper.print("--input not provided\n", .{});
            helper.help();
        };

        return Args{
            .input = input,
            .output = output,
            .it = helper.it,
        };
    }

    fn deinit(self: *Args) void {
        self.it.deinit();
    }
};

fn cross(x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    return x1 * y2 - x2 * y1;
}

fn visualizeFinderState(alloc: Allocator, image: *img.Image, visualizer: anytype) !void {
    var detector_finder_algo = qr.DetectFinderAlgo.init(alloc, image);
    defer {
        switch (detector_finder_algo.state) {
            .finished => |v| v.deinit(),
            else => {},
        }
        detector_finder_algo.deinit();
    }

    while (try detector_finder_algo.step()) |item| {
        switch (item) {
            .vert_candidates => |candidates| {
                for (candidates) |candidate| {
                    try visualizer.drawCircle(candidate.cx(), candidate.cy(), 0.5, "blue");
                }
            },
            .horiz_candidates => |candidates| {
                for (candidates) |candidate| {
                    try visualizer.drawCircle(candidate.cx(), candidate.cy(), 0.5, "red");
                }
            },
            .combined_candidates => |buckets| {
                for (buckets) |bucket| {
                    for (bucket.items) |candidate| {
                        try visualizer.drawCircle(candidate.cx(), candidate.cy(), 0.5, "green");
                    }
                }
            },
            .rois => |rois| {
                try visualizer.drawBox(rois.rois[rois.ids.tl], "yellow", null);
                try visualizer.drawBox(rois.rois[rois.ids.tr], "red", null);
                try visualizer.drawBox(rois.rois[rois.ids.bl], "blue", null);
                // An approximation of the center of the QR code is the center
                // of the line between the top right and bottom left finders.
                // We can draw our axis here
                const mid_x = (rois.rois[rois.ids.tr].cx() + rois.rois[rois.ids.bl].cx()) / 2;
                const mid_y = (rois.rois[rois.ids.tr].cy() + rois.rois[rois.ids.bl].cy()) / 2;

                const rotation_rad = rois.rois[rois.ids.tl].rotation_deg * std.math.pi / 180.0;
                const axis_multiplier = 1000;
                const x_axis_x = axis_multiplier * std.math.cos(rotation_rad);
                const x_axis_y = axis_multiplier * std.math.sin(rotation_rad);
                try visualizer.drawLine(mid_x, mid_y, mid_x + x_axis_x, mid_y + x_axis_y, "red");

                // NOTE: x/y signs may seem flipped here. In image space Y is 0
                // in the top left, increasing as we move down. In human brain
                // space, we like Y to be up, so we flip the directions here
                const y_axis_x = axis_multiplier * std.math.sin(rotation_rad);
                const y_axis_y = -axis_multiplier * std.math.cos(rotation_rad);
                try visualizer.drawLine(mid_x, mid_y, mid_x + y_axis_x, mid_y + y_axis_y, "blue");
            },
        }
    }
}

fn inspectTiming(it: anytype, image: *img.Image, visualizer: anytype) !void {
    var expected = true;

    while (it.next()) |timing_rect| {
        try visualizer.drawBox(timing_rect, "red", null);

        if (img.isLightRoi(&timing_rect, image) != expected) {
            std.log.err("Timing value unexpected", .{});
            return error.InvalidData;
        }
        expected = !expected;
    }
}

fn drawFormatBoxes(it: anytype, visualizer: anytype) !void {
    while (it.next()) |roi| {
        try visualizer.drawBox(roi, "purple", null);
    }
}

fn visualize(alloc: Allocator, image: *img.Image, input_path: []const u8, output_dir: std.fs.Dir) !void {
    var input_splitter = std.mem.splitBackwards(u8, input_path, "/");
    const input_name = input_splitter.next() orelse input_path;
    try std.fs.cwd().copyFile(input_path, output_dir, input_name, .{});

    var svg_file = try output_dir.createFile("overlay.svg", .{});
    defer svg_file.close();

    var visualizer = try vis.Visualizer(@TypeOf(svg_file.writer())).init(alloc, svg_file.writer(), image.width, image.height, input_name);
    defer visualizer.finish() catch {};

    try visualizeFinderState(alloc, image, &visualizer);

    var qr_code = try qr.QrCode.init(alloc, image);
    defer qr_code.deinit();

    try visualizer.drawBox(qr_code.roi, "red", null);

    var unmasked_file = try output_dir.createFile("unmasked.svg", .{});
    defer unmasked_file.close();

    var unmasked_visualizer = try vis.Visualizer(@TypeOf(unmasked_file.writer())).init(
        alloc,
        unmasked_file.writer(),
        image.width,
        image.height,
        null,
    );
    defer unmasked_visualizer.finish() catch {};

    var horiz_timing_it = qr_code.horizTimings();
    try inspectTiming(&horiz_timing_it, image, &visualizer);

    var vert_timing_it = qr_code.vertTimings();
    try inspectTiming(&vert_timing_it, image, &visualizer);

    var horiz_format_it = qr_code.horizFormat();
    try drawFormatBoxes(&horiz_format_it, &visualizer);

    var vert_format_it = qr_code.vertFormat();
    try drawFormatBoxes(&vert_format_it, &visualizer);

    var alignment_finder = qr.AlignmentFinder.init(
        qr_code.roi,
        qr_code.elem_width,
        qr_code.elem_height,
        qr_code.grid_width,
        qr_code.grid_height,
        image,
    );

    while (alignment_finder.next()) |item| {
        try visualizer.drawBox(item.roi, "blue", null);
    }

    var bit_it = try qr_code.bitIter(image);

    var i: usize = 0;
    while (bit_it.next()) |item| {
        if (item.val) {
            try unmasked_visualizer.drawBox(item.roi, "black", "black");
        }

        try visualizer.drawBox(item.roi, "orange", null);
        var buf: [5]u8 = undefined;
        const i_s = try std.fmt.bufPrint(&buf, "{d}", .{i});

        try visualizer.drawText(item.roi.left + qr_code.elem_width / 3.0, item.roi.bottom - qr_code.elem_height / 3.0, "red", i_s);
        i += 1;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 99,
    }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args = try Args.parse(alloc);
    defer args.deinit();

    var image = try img.Image.open(args.input);
    defer image.deinit();

    if (args.output) |output_path| {
        try std.fs.cwd().makePath(output_path);
        const output_dir = try std.fs.cwd().openDir(output_path, .{});
        try visualize(alloc, &image, args.input, output_dir);
    }

    var qr_code = try qr.QrCode.init(alloc, &image);
    defer qr_code.deinit();

    var data_it = try qr_code.data(&image);
    while (data_it.next()) |b| {
        switch (data_it.encoding) {
            4 => std.debug.print("{c}", .{b}),
            else => {
                std.log.err("Unimplemented encoding: {d}", .{data_it.encoding});
                return error.Unimplemented;
            },
        }
    }
    std.debug.print("\n", .{});
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
