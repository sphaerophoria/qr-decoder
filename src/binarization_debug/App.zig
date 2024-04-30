const std = @import("std");
const libqr = @import("libqr");
const Image = libqr.img.Image;
const Allocator = std.mem.Allocator;
const Rect = libqr.types_2d.Rect(f32);
const Inputs = libqr.binarization.Inputs;
const Outputs = libqr.binarization.Outputs;

alloc: *const Allocator,
inputs: Inputs,
outputs: Outputs,
const Self = @This();

pub fn init(alloc: *const Allocator, source_image: *Image) !Self {
    const full_roi: Rect = .{
        .left = 0,
        .top = 0,
        .right = @floatFromInt(source_image.width),
        .bottom = @floatFromInt(source_image.height),
    };

    const inputs: Inputs = .{
        .source_image = source_image,
        .roi = full_roi,
        .hist_smoothing_radius = 1,
        .hist_smoothing_iterations = 1,
    };

    const outputs = try Outputs.calculate(alloc, inputs);

    return .{
        .alloc = alloc,
        .inputs = inputs,
        .outputs = outputs,
    };
}

pub fn deinit(self: *Self) void {
    self.outputs.deinit();
}

pub fn setHistSmoothingParams(self: *Self, radius: usize, num_iterations: usize) !void {
    self.inputs.hist_smoothing_radius = radius;
    self.inputs.hist_smoothing_iterations = num_iterations;
    try self.recalculateOutputs();
}

pub fn setRoi(self: *Self, roi: Rect) !void {
    self.inputs.roi = roi;
    try self.recalculateOutputs();
}

fn recalculateOutputs(self: *Self) !void {
    const outputs = try Outputs.calculate(self.alloc, self.inputs);

    self.outputs.deinit();
    self.outputs = outputs;
}
