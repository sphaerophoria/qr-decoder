const std = @import("std");
const libqr = @import("libqr");
const Image = libqr.img.Image;
const Server = @import("Server.zig");
const App = @import("App.zig");
const Allocator = std.mem.Allocator;

var sigint_caught = std.atomic.Value(bool).init(false);

fn shouldQuit() bool {
    return sigint_caught.load(std.builtin.AtomicOrder.unordered);
}

fn signal_handler(_: c_int) align(1) callconv(.C) void {
    sigint_caught.store(true, std.builtin.AtomicOrder.unordered);
}

fn registerSignalHandler() !void {
    var sa = std.posix.Sigaction{
        .handler = .{
            .handler = &signal_handler,
        },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };

    try std.posix.sigaction(std.posix.SIG.INT, &sa, null);
}

const Args = struct {
    image_path: [:0]const u8,
    www_root: ?[]const u8,
    const ArgPurpose = enum {
        image_path,
        www_root,

        fn parse(arg: []const u8) ?ArgPurpose {
            for (mappings) |mapping| {
                if (std.mem.eql(u8, mapping.arg, arg)) {
                    return mapping.purpose;
                }
            }
            return null;
        }
    };

    const Mapping = struct { arg: []const u8, purpose: ArgPurpose, help: []const u8 };
    const mappings: []const Mapping = &.{
        .{ .arg = "--www-root", .purpose = .www_root, .help = "optional www root override" },
        .{ .arg = "--image-path", .purpose = .image_path, .help = "image to binarize" },
    };

    fn parse(args: anytype, writer: anytype) !Args {
        var image_path_opt: ?[:0]const u8 = null;
        var www_root: ?[]const u8 = null;
        const process_name = args.next() orelse "binarization-debug";
        while (args.next()) |arg| {
            const purpose = ArgPurpose.parse(arg) orelse {
                writer.print("Invalid arg {s}\n", .{arg}) catch {};
                return help(process_name, writer);
            };

            switch (purpose) {
                .image_path => {
                    image_path_opt = args.next();
                },
                .www_root => {
                    www_root = args.next();
                },
            }
        }

        const image_path = image_path_opt orelse {
            writer.print("--image-path not provided\n", .{}) catch {};
            return help(process_name, writer);
        };

        return .{
            .image_path = image_path,
            .www_root = www_root,
        };
    }

    fn help(process_name: []const u8, writer: anytype) anyerror {
        writer.print(
            \\Usage:
            \\{s} [ARGS]
            \\
            \\Args:
            \\
        , .{process_name}) catch {};

        for (mappings) |mapping| {
            writer.print("{s}: {s}\n", .{ mapping.arg, mapping.help }) catch {};
        }
        return error.InvalidArgument;
    }
};

test "arg parsing" {
    const It = struct {
        items: []const [:0]const u8,
        idx: usize,

        const Self = @This();
        fn init(items: []const [:0]const u8) Self {
            return .{
                .items = items,
                .idx = 0,
            };
        }

        fn next(self: *Self) ?[:0]const u8 {
            if (self.idx >= self.items.len) {
                return null;
            }
            defer self.idx += 1;
            return self.items[self.idx];
        }
    };

    var it = It.init(&.{
        "process_name",
        "--image-path",
        "asdf",
    });
    var args = try Args.parse(&it, std.io.null_writer);

    try std.testing.expectEqual("asdf", args.image_path);
    try std.testing.expectEqual(null, args.www_root);

    it = It.init(&.{
        "process_name",
        "--image-path",
        "asdf",
        "--www-root",
        "root",
    });
    args = try Args.parse(&it, std.io.null_writer);
    try std.testing.expectEqual("asdf", args.image_path);
    try std.testing.expectEqual("root", args.www_root);

    it = It.init(&.{
        "process_name",
        "--www-root",
        "root",
    });

    if (Args.parse(&it, std.io.null_writer)) |_| {
        try std.testing.expect(false);
    } else |_| {}
}

pub fn main() !void {
    try registerSignalHandler();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    var args_it = try std.process.argsWithAllocator(alloc);
    defer args_it.deinit();

    const args = Args.parse(&args_it, std.io.getStdErr().writer()) catch {
        std.process.exit(1);
    };

    std.debug.print("server starting\n", .{});

    var image = try Image.open(args.image_path);
    defer image.deinit();

    var app = try App.init(&alloc, &image);
    defer app.deinit();

    var server = try Server.init(alloc, &app, args.www_root, "0.0.0.0", 9999);

    while (!shouldQuit()) {
        try server.run();
    }
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
