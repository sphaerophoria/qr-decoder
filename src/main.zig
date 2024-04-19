const std = @import("std");
const xml = @import("xml.zig");
const Allocator = std.mem.Allocator;
const img = @import("img.zig");
const vis = @import("visualizer.zig");
const qr = @import("qr.zig");
const types_2d = @import("types_2d.zig");
const Rect = types_2d.Rect;

const ArgsHelper = struct {
    it: std.process.ArgIterator,
    process_name: []const u8,
    stderr: std.fs.File.Writer,

    fn init(alloc: Allocator) !ArgsHelper {
        var it = try std.process.argsWithAllocator(alloc);
        var process_name = it.next() orelse "qr-decoder";
        var stderr = std.io.getStdErr().writer();
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

        var input = input_opt orelse {
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
                for (rois) |roi| {
                    try visualizer.drawBox(roi, "yellow", null);
                }
            },
        }
    }
}

fn inspectTiming(it: anytype, image: *img.Image, visualizer: anytype) !void {
    var expected = true;

    while (it.next()) |timing_rect| {
        try visualizer.drawBox(timing_rect, "red", null);

        if (img.isLightRoi(&timing_rect, image) != expected) {
            std.debug.panic("Unexpected timing value", .{});
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
    try std.fs.cwd().copyFile(input_path, output_dir, input_path, .{});

    var svg_file = try output_dir.createFile("overlay.svg", .{});
    defer svg_file.close();

    var visualizer = try vis.Visualizer(@TypeOf(svg_file.writer())).init(alloc, svg_file.writer(), image.width, image.height, input_path);
    defer visualizer.finish() catch {};

    try visualizeFinderState(alloc, image, &visualizer);

    var qr_code = try qr.QrCode.init(alloc, image);
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

    var bit_it = try qr_code.bitIter(image);

    var i: usize = 0;
    while (bit_it.next()) |item| {
        if (item.val) {
            try unmasked_visualizer.drawBox(item.roi, "black", "black");
        }

        try visualizer.drawBox(item.roi, "orange", null);
        var i_s = try std.fmt.allocPrint(alloc, "{d}", .{i});
        defer alloc.free(i_s);

        try visualizer.drawText(item.roi.left + qr_code.elem_width / 3.0, item.roi.bottom - qr_code.elem_height / 3.0, "red", i_s);
        i += 1;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .stack_trace_frames = 99,
    }){};
    defer _ = gpa.deinit();
    var alloc = gpa.allocator();

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
    std.testing.refAllDecls(@This());
}
