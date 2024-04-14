const std = @import("std");
const xml = @import("xml.zig");
const Allocator = std.mem.Allocator;
const img = @import("img.zig");
const vis = @import("visualizer.zig");
const qr = @import("qr.zig");

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
    var visualizer = try vis.Visualizer(@TypeOf(svg_file.writer())).init(alloc, svg_file.writer(), image.width, image.height, args.input);
    defer visualizer.finish() catch {};

    try qr.findFinderPatterns(alloc, &image, &visualizer);
}

test {
    std.testing.refAllDecls(@This());
}
