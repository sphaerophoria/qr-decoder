const std = @import("std");
const img = @import("img.zig");
const types_2d = @import("types_2d.zig");
const Image = img.Image;
const Allocator = std.mem.Allocator;
const Rect = types_2d.Rect(f32);

pub fn calcluateThreshold(
    alloc: Allocator,
    image: *Image,
    roi: Rect,
) !u8 {
    const inputs = .{
        .source_image = image,
        .roi = roi,
        .hist_smoothing_radius = 5,
        .hist_smoothing_iterations = 5,
    };

    var outputs = try Outputs.calculate(&alloc, inputs);
    defer outputs.deinit();

    return @intCast(outputs.dark_light_threshold);
}

const Histogram = [256]usize;

const ClusterRange = struct {
    min: usize,
    max: usize,
};

const Clusters = struct {
    clusters: std.ArrayList(ClusterRange),

    fn init(alloc: Allocator) Clusters {
        return .{
            .clusters = std.ArrayList(ClusterRange).init(alloc),
        };
    }

    fn addCluster(self: *Clusters, min: usize, max: usize) !usize {
        try self.clusters.append(.{
            .min = min,
            .max = max,
        });
        return self.clusters.items.len - 1;
    }

    fn anyClusterContains(self: *Clusters, point: usize) bool {
        for (self.clusters.items) |*cluster| {
            if (point >= cluster.min and point <= cluster.max) {
                return true;
            }
        }

        return false;
    }

    fn toOwnedSlice(self: *Clusters) ![]ClusterRange {
        return try self.clusters.toOwnedSlice();
    }

    fn deinit(self: *Clusters) void {
        self.clusters.deinit();
    }
};

const ClusterFinder = struct {
    //counts of pixels at given brightness
    histogram: *Histogram,
    clusters: *Clusters,
    // Index into histogram array
    sorted_histogram_buckets: std.ArrayList(usize),
    // How much can we increase and still consume
    // NOTE: This is sketch, and can allow for climbing an adjacent hill that
    // we shouldn't Probably something that approximates slope and looks for
    // bottoming out is better, but we can save better solutions for later days
    jitter: f32 = 0.005,

    fn init(alloc: Allocator, histogram: *Histogram, clusters: *Clusters) !ClusterFinder {
        var sorted_histogram_buckets = try std.ArrayList(usize).initCapacity(alloc, 256);
        for (0..256) |i| {
            try sorted_histogram_buckets.append(i);
        }

        const lessThan = struct {
            pub fn f(h: *const Histogram, a: usize, b: usize) bool {
                return h[a] < h[b];
            }
        }.f;

        std.sort.pdq(usize, sorted_histogram_buckets.items, histogram, lessThan);

        return .{
            .histogram = histogram,
            .clusters = clusters,
            .sorted_histogram_buckets = sorted_histogram_buckets,
        };
    }

    fn deinit(self: *ClusterFinder) void {
        self.sorted_histogram_buckets.deinit();
    }

    fn shouldCountinueWalking(self: *ClusterFinder, from_idx: usize, to_idx: usize) bool {
        if (self.clusters.anyClusterContains(to_idx)) {
            return false;
        }

        const from: f32 = @floatFromInt(self.histogram[from_idx]);
        const to: f32 = @floatFromInt(self.histogram[to_idx]);
        const to_w_jitter: f32 = to - self.jitter * from;
        return to_w_jitter < from;
    }

    fn findBucketClusterMin(self: *ClusterFinder, bucket_idx: usize) usize {
        var min = bucket_idx;
        while (true) {
            if (min == 0) {
                return min;
            }

            const next_idx = min - 1;
            if (self.shouldCountinueWalking(min, next_idx)) {
                min = next_idx;
            } else {
                return min;
            }
        }
    }

    fn findBucketClusterMax(self: *ClusterFinder, bucket_idx: usize) usize {
        var max = bucket_idx;
        while (true) {
            if (max + 1 == self.histogram.len) {
                return max;
            }

            const next_idx = max + 1;
            if (self.shouldCountinueWalking(max, next_idx)) {
                max = next_idx;
            } else {
                return max;
            }
        }
    }

    fn next(self: *ClusterFinder) !?void {
        var biggest_bucket: usize = undefined;
        while (true) {
            biggest_bucket = self.sorted_histogram_buckets.popOrNull() orelse {
                return null;
            };

            if (self.clusters.anyClusterContains(biggest_bucket)) {
                continue;
            }

            break;
        }

        const min = self.findBucketClusterMin(biggest_bucket);
        const max = self.findBucketClusterMax(biggest_bucket);

        _ = try self.clusters.addCluster(min, max);
    }
};

fn findClusters(alloc: Allocator, histogram: *Histogram) ![]ClusterRange {
    var clusters = Clusters.init(alloc);
    errdefer clusters.deinit();

    {
        var cluster_finder = try ClusterFinder.init(alloc, histogram, &clusters);
        defer cluster_finder.deinit();

        while (try cluster_finder.next()) |_| {}
    }

    return clusters.toOwnedSlice();
}

pub const Inputs = struct {
    source_image: *Image,
    roi: Rect,
    hist_smoothing_radius: usize,
    hist_smoothing_iterations: usize,
};

pub const Outputs = struct {
    alloc: Allocator,
    histogram: Histogram,
    clusters: []ClusterRange,
    dark_light_threshold: usize,
    output_image: Image,
    binarized_image: Image,

    pub fn calculate(alloc: *const Allocator, inputs: Inputs) !Outputs {
        var output_image = try img.extractImageFromRoi(alloc, inputs.source_image, inputs.roi);
        errdefer output_image.deinit();
        try blurImage(alloc.*, &output_image, 1, 3);

        var histogram = img_histogram(&output_image, inputs.hist_smoothing_radius, inputs.hist_smoothing_iterations);

        const clusters = try findClusters(alloc.*, &histogram);
        errdefer alloc.free(clusters);

        const dark_light_threshold = extractLightDarkThreshold(&histogram, clusters);

        var binarized_image = try img.extractImageFromRoi(alloc, inputs.source_image, inputs.roi);
        errdefer binarized_image.deinit();
        try blurImage(alloc.*, &binarized_image, 1, 3);
        binarizeImage(&binarized_image, @intCast(dark_light_threshold));

        return .{
            .alloc = alloc.*,
            .histogram = histogram,
            .clusters = clusters,
            .dark_light_threshold = dark_light_threshold,
            .output_image = output_image,
            .binarized_image = binarized_image,
        };
    }

    pub fn deinit(self: *Outputs) void {
        self.alloc.free(self.clusters);
        self.output_image.deinit();
        self.binarized_image.deinit();
    }
};

fn extractLightDarkThreshold(histogram: []const usize, clusters: []ClusterRange) u8 {
    var dark_max: usize = 0;
    var bright_min: usize = 255;

    var dark_size: usize = 0;
    var light_size: usize = 0;

    const sortFn = struct {
        fn f(_: void, lhs: ClusterRange, rhs: ClusterRange) bool {
            return lhs.min < rhs.min;
        }
    }.f;

    std.sort.pdq(ClusterRange, clusters, {}, sortFn);

    var dark_cluster_idx: usize = 0;
    var light_cluster_idx: usize = clusters.len -| 1;

    for (0..clusters.len) |i| {
        var sum: usize = 0;
        for (clusters[i].min..clusters[i].max) |j| {
            sum += histogram[j];
        }
    }

    while (dark_cluster_idx <= light_cluster_idx) {
        while (dark_size <= light_size and dark_cluster_idx <= light_cluster_idx) {
            defer dark_cluster_idx += 1;
            const dark_cluster = clusters[dark_cluster_idx];
            for (dark_cluster.min..dark_cluster.max + 1) |i| {
                dark_size += histogram[i];
            }
            dark_max = dark_cluster.max;
        }

        while (light_size < dark_size and dark_cluster_idx <= light_cluster_idx) {
            defer light_cluster_idx -|= 1;
            const light_cluster = clusters[light_cluster_idx];
            for (light_cluster.min..light_cluster.max + 1) |i| {
                light_size += histogram[i];
            }
            bright_min = light_cluster.min;
        }
    }

    return @intCast(dark_max);
}

fn binarizeImage(image: *Image, threshold: u8) void {
    for (0..image.height) |y| {
        for (0..image.width) |x| {
            if (image.get(x, y) > threshold) {
                image.set(x, y, 255);
            } else {
                image.set(x, y, 0);
            }
        }
    }
}

fn blurImage(alloc: Allocator, image: *Image, num_iters: usize, kernel_size: usize) !void {
    std.debug.assert(kernel_size % 2 == 1); // Kernel size must be odd

    const buf = try alloc.alloc(u8, image.width * image.height);
    defer alloc.free(buf);

    for (0..num_iters) |_| {
        @memcpy(buf, image.data[0..buf.len]);

        for (0..image.height) |y| {
            for (0..image.width) |x| {
                var avg: u16 = 0;

                const y_start = y -| (kernel_size / 2);
                const x_start = x -| (kernel_size / 2);
                const y_end = @min(y + kernel_size / 2 + 1, image.height);
                const x_end = @min(x + kernel_size / 2 + 1, image.width);

                var num_elems: u16 = 0;
                for (y_start..y_end) |in_y| {
                    for (x_start..x_end) |in_x| {
                        avg += buf[in_y * image.width + in_x];
                        num_elems += 1;
                    }
                }

                // Integer rounding
                avg += num_elems / 2;
                avg /= num_elems;
                image.set(x, y, @intCast(avg));
            }
        }
    }
}

test "blur image" {
    const alloc = std.testing.allocator;
    const buf = try alloc.alloc(u8, 16);
    // Initialize with checkerboard pattern
    var image = Image.fromLuma(
        buf,
        4,
        4,
        img.freeImage,
        @constCast(&alloc),
    );
    defer image.deinit();

    for (0..image.height) |y| {
        for (0..image.width) |x| {
            image.set(x, y, @intCast(255 * ((x + (y % 2)) % 2)));
        }
    }

    // zig fmt: off
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0, 255, 0, 255,
        255, 0, 255, 0,
        0, 255, 0, 255,
        255, 0, 255, 0,
    }, buf);

    try blurImage(alloc, &image, 1, 3);

    // zig fmt: off
    try std.testing.expectEqualSlices(u8, &[_]u8{
        128, 128, 128, 128,
        128, 113, 142, 128,
        128, 142, 113, 128,
        128, 128, 128, 128,
    }, buf);

    try std.testing.expect(true);
}

fn img_histogram(image: *Image, smoothing_radius: usize, smoothing_iterations: usize) Histogram {
    var unsmoothed: Histogram = [1]usize{0} ** 256;

    for (image.data) |p| {
        unsmoothed[p] += 1;
    }

    var ret: Histogram = [1]usize{0} ** 256;
    for (0..smoothing_iterations) |_| {
        for (0..unsmoothed.len) |i| {
            const smoothing_start = i -| smoothing_radius / 2;
            const smoothing_end = @min(ret.len, i + smoothing_radius / 2 + smoothing_radius % 2);
            for (smoothing_start..smoothing_end) |j| {
                ret[i] += unsmoothed[j];
            }
            ret[i] /= (smoothing_end - smoothing_start);
        }
        @memcpy(&unsmoothed, &ret);
    }

    return ret;
}

test "histogram generation" {
    return error.Unimplemented;
}

