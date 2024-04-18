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
    output: []const u8,
    it: std.process.ArgIterator,

    fn parse(alloc: Allocator) !Args {
        var helper = try ArgsHelper.init(alloc);
        var input_opt: ?[:0]const u8 = null;
        var output_opt: ?[]const u8 = null;

        while (helper.next()) |arg| {
            if (std.mem.eql(u8, arg, "--input")) {
                input_opt = helper.nextStr("--input");
            } else if (std.mem.eql(u8, arg, "--output")) {
                output_opt = helper.nextStr("--output");
            } else if (std.mem.eql(u8, arg, "--help")) {
                helper.help();
            }
        }

        var input = input_opt orelse {
            helper.print("--input not provided\n", .{});
            helper.help();
        };

        var output = output_opt orelse {
            helper.print("--output not provided\n", .{});
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
                    try visualizer.drawBox(roi, "yellow");
                }
            },
        }
    }
}

fn inspectTiming(it: anytype, image: *img.Image, visualizer: anytype) !void {
    var expected = true;

    while (it.next()) |timing_rect| {
        try visualizer.drawBox(timing_rect, "red");

        if (img.isLightRoi(&timing_rect, image) != expected) {
            std.debug.panic("Unexpected timing value", .{});
        }
        expected = !expected;
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

    var svg_file = try std.fs.cwd().createFile(args.output, .{});
    defer svg_file.close();

    var visualizer = try vis.Visualizer(@TypeOf(svg_file.writer())).init(alloc, svg_file.writer(), image.width, image.height, args.input);
    defer visualizer.finish() catch {};

    try visualizeFinderState(alloc, &image, &visualizer);

    var qr_code = try qr.QrCode.init(alloc, &image);
    try visualizer.drawBox(qr_code.roi, "red");

    var horiz_timing_it = qr_code.horizTimings();
    try inspectTiming(&horiz_timing_it, &image, &visualizer);

    var vert_timing_it = qr_code.vertTimings();
    try inspectTiming(&vert_timing_it, &image, &visualizer);

    var data_it = qr_code.data();
    var i: usize = 0;
    while (data_it.next()) |roi| {
        if (i >= 200) {
            return;
        }
        try visualizer.drawBox(roi, "orange");
        var i_s = try std.fmt.allocPrint(alloc, "{d}", .{i});
        defer alloc.free(i_s);

        try visualizer.drawText(roi.left + qr_code.elem_width / 3.0, roi.bottom - qr_code.elem_height / 3.0, "red", i_s);
        i += 1;
    }
}

test {
    std.testing.refAllDecls(@This());
}
