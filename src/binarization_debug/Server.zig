const std = @import("std");
const App = @import("App.zig");
const bmp_writer = @import("bmp_writer.zig");
const libqr = @import("libqr");
const resources = @import("resources");
const Image = libqr.img.Image;
const Allocator = std.mem.Allocator;
const NetAddr = std.net.Address;
const HttpServer = std.http.Server;
const TcpServer = std.net.Server;
const Self = @This();
const Rect = libqr.types_2d.Rect(f32);

inner: TcpServer,
alloc: Allocator,
www_root: ?std.fs.Dir,
app: *App,

pub fn init(alloc: Allocator, app: *App, www_root_path: ?[]const u8, ip: []const u8, port: u16) !Self {
    const addy = try NetAddr.parseIp(ip, port);
    var inner = try addy.listen(.{
        .reuse_port = true,
    });
    errdefer inner.deinit();

    var www_root: ?std.fs.Dir = null;
    if (www_root_path) |p| {
        www_root = try std.fs.cwd().openDir(p, .{});
    }

    return .{
        .alloc = alloc,
        .inner = inner,
        .www_root = www_root,
        .app = app,
    };
}

pub fn deinit(self: *Self) void {
    self.inner.deinit();
}

pub fn run(self: *Self) !void {
    while (true) {
        switch (try waitForSocket(&self.inner.stream)) {
            .ready => {},
            .signal_caught => {
                return;
            },
        }

        const connection = try self.inner.accept();
        defer connection.stream.close();

        var read_buffer: [4096]u8 = undefined;
        var server = HttpServer.init(connection, &read_buffer);
        var request = server.receiveHead() catch {
            std.log.err("error handling request", .{});
            continue;
        };

        self.handleHttpRequest(&request) catch {
            std.log.err("error handling request", .{});
        };
    }
}

const SocketState = enum {
    ready,
    signal_caught,
};

fn waitForSocket(stream: *std.net.Stream) !SocketState {
    var pfd = std.mem.zeroInit(std.posix.pollfd, .{});
    pfd.fd = stream.handle;
    pfd.events = std.posix.POLL.IN;

    var pfds = [1]std.posix.pollfd{pfd};
    const num_set = std.posix.ppoll(&pfds, null, null) catch |e| {
        if (e == std.posix.PPollError.SignalInterrupt) {
            return .signal_caught;
        }
        return e;
    };
    std.debug.assert(num_set == 1); // Should have got something
    return .ready;
}

fn mimetypeFromPath(p: []const u8) ![]const u8 {
    const Mapping = struct {
        ext: []const u8,
        mime: []const u8,
    };

    const mappings = [_]Mapping{
        .{ .ext = ".js", .mime = "text/javascript" },
        .{ .ext = ".html", .mime = "text/html" },
        .{ .ext = ".png", .mime = "image/png" },
    };

    for (mappings) |mapping| {
        if (std.mem.endsWith(u8, p, mapping.ext)) {
            return mapping.mime;
        }
    }

    std.log.err("Unknown mimetype for {s}", .{p});
    return error.Unknown;
}

const QueryParamIt = struct {
    query_params: []const u8,

    const Output = struct {
        key: []const u8,
        val: []const u8,
    };

    fn init(target: []const u8) QueryParamIt {
        const query_param_idx = std.mem.indexOfScalar(u8, target, '?') orelse target.len - 1;
        return .{
            .query_params = target[query_param_idx + 1 ..],
        };
    }

    fn next(self: *QueryParamIt) ?Output {
        const key_end = std.mem.indexOfScalar(u8, self.query_params, '=') orelse {
            return null;
        };
        const val_end = std.mem.indexOfScalar(u8, self.query_params, '&') orelse self.query_params.len;
        const key = self.query_params[0..key_end];
        const val = self.query_params[key_end + 1 .. val_end];

        self.query_params = self.query_params[@min(val_end + 1, self.query_params.len)..];

        return .{
            .key = key,
            .val = val,
        };
    }
};

test "query param it" {
    return error.Unimplemented;
}

fn handleClusters(self: *Self, request: *std.http.Server.Request) !void {
    const clusters = self.app.outputs.clusters;

    var send_buffer: [4096]u8 = undefined;
    var response_writer = request.respondStreaming(.{ .send_buffer = &send_buffer, .respond_options = .{
        .keep_alive = false,
        .extra_headers = &.{
            .{
                .name = "content-type",
                .value = "application/json",
            },
        },
    } });

    var json_writer = std.json.writeStream(response_writer.writer(), .{});
    try json_writer.beginArray();
    for (clusters) |cluster| {
        try json_writer.beginArray();
        try json_writer.write(cluster.min);
        try json_writer.write(cluster.max);
        try json_writer.endArray();
    }
    try json_writer.endArray();

    try response_writer.end();
}

fn handleDarkLightParition(self: *Self, request: *std.http.Server.Request) !void {
    var send_buffer: [4096]u8 = undefined;
    var response_writer = request.respondStreaming(.{ .send_buffer = &send_buffer, .respond_options = .{
        .keep_alive = false,
        .extra_headers = &.{
            .{
                .name = "content-type",
                .value = "application/json",
            },
        },
    } });

    var buf: [3]u8 = undefined;
    const dlts = try std.fmt.bufPrint(&buf, "{d}", .{self.app.outputs.dark_light_threshold});
    try response_writer.writeAll(dlts);
    try response_writer.end();
}

fn handleSetHistSmoothing(self: *Self, request: *std.http.Server.Request) !void {
    var it = QueryParamIt.init(request.head.target);
    var smoothing_radius_opt: ?usize = null;
    var smoothing_iterations_opt: ?usize = null;
    while (it.next()) |param| {
        if (std.mem.eql(u8, "smoothing_radius", param.key)) {
            smoothing_radius_opt = try std.fmt.parseInt(usize, param.val, 10);
        } else if (std.mem.eql(u8, "smoothing_iterations", param.key)) {
            smoothing_iterations_opt = try std.fmt.parseInt(usize, param.val, 10);
        }
    }

    const smoothing_radius = smoothing_radius_opt orelse {
        std.log.err("smoothing radius not provided", .{});
        return error.InvalidArgument;
    };

    const smoothing_iterations = smoothing_iterations_opt orelse {
        std.log.err("smoothing iterations not provided", .{});
        return error.InvalidArgument;
    };

    try self.app.setHistSmoothingParams(smoothing_radius, smoothing_iterations);
    try respondEmpty(request);
}

fn handleHistogram(self: *Self, request: *std.http.Server.Request) !void {
    const histogram = self.app.outputs.histogram;

    var send_buffer: [4096]u8 = undefined;
    var response_writer = request.respondStreaming(.{ .send_buffer = &send_buffer, .respond_options = .{
        .keep_alive = false,
        .extra_headers = &.{
            .{
                .name = "content-type",
                .value = "application/json",
            },
        },
    } });

    var json_writer = std.json.writeStream(response_writer.writer(), .{});
    try json_writer.beginArray();
    for (histogram) |elem| {
        try json_writer.write(elem);
    }
    try json_writer.endArray();

    try response_writer.end();
}

fn parseSetRoiParams(request: *std.http.Server.Request) !Rect {
    var it = QueryParamIt.init(request.head.target);

    var left: ?f32 = null;
    var right: ?f32 = null;
    var top: ?f32 = null;
    var bottom: ?f32 = null;
    while (it.next()) |query_param| {
        const val = std.fmt.parseFloat(f32, query_param.val) catch {
            std.log.err("Invalid query param", .{});
            continue;
        };
        if (std.mem.eql(u8, query_param.key, "start_x")) {
            left = val;
        } else if (std.mem.eql(u8, query_param.key, "start_y")) {
            top = val;
        } else if (std.mem.eql(u8, query_param.key, "end_x")) {
            right = val;
        } else if (std.mem.eql(u8, query_param.key, "end_y")) {
            bottom = val;
        }
    }

    var roi = Rect{
        .left = left orelse {
            std.log.err("start_x not provided", .{});
            return error.InvalidData;
        },
        .right = right orelse {
            std.log.err("end_x not provided", .{});
            return error.InvalidData;
        },
        .top = top orelse {
            std.log.err("start_y not provided", .{});
            return error.InvalidData;
        },
        .bottom = bottom orelse {
            std.log.err("end_y not provided", .{});
            return error.InvalidData;
        },
    };

    if (roi.left > roi.right) {
        std.mem.swap(f32, &roi.right, &roi.left);
    }

    if (roi.top > roi.bottom) {
        std.mem.swap(f32, &roi.top, &roi.bottom);
    }

    return roi;
}

test "set roi param parsing" {
    return error.Unimplemented;
}

fn writeImageAsBmp(alloc: Allocator, image: *Image, writer: anytype) !void {
    var output_bmp_data = try alloc.alloc(bmp_writer.BmpPixel, image.width * image.height);
    defer alloc.free(output_bmp_data);

    for (0..image.height) |y| {
        for (0..image.width) |x| {
            const luma = image.get(x, y);
            output_bmp_data[y * image.width + x] = .{
                .r = luma,
                .g = luma,
                .b = luma,
                .a = 0xff,
            };
        }
    }

    try bmp_writer.writeBmp(writer, output_bmp_data, image.width);
}

fn handleSetRoi(self: *Self, request: *std.http.Server.Request) !void {
    const roi: Rect = try parseSetRoiParams(request);
    try self.app.setRoi(roi);
    try respondEmpty(request);
}

fn handleInputImage(self: *Self, request: *std.http.Server.Request) !void {
    var send_buffer: [4096]u8 = undefined;
    var response_writer = request.respondStreaming(.{ .send_buffer = &send_buffer, .respond_options = .{
        .keep_alive = false,
        .extra_headers = &.{
            .{
                .name = "content-type",
                .value = "image/bmp",
            },
        },
    } });

    try writeImageAsBmp(self.alloc, self.app.inputs.source_image, &response_writer);
    try response_writer.end();
}

fn handleBinarizedImage(self: *Self, request: *std.http.Server.Request) !void {
    var send_buffer: [4096]u8 = undefined;
    var response_writer = request.respondStreaming(.{ .send_buffer = &send_buffer, .respond_options = .{
        .keep_alive = false,
        .extra_headers = &.{
            .{
                .name = "content-type",
                .value = "image/bmp",
            },
        },
    } });

    try writeImageAsBmp(self.alloc, &self.app.outputs.binarized_image, &response_writer);
    try response_writer.end();
}

fn handleOutputImage(self: *Self, request: *std.http.Server.Request) !void {
    var send_buffer: [4096]u8 = undefined;
    var response_writer = request.respondStreaming(.{ .send_buffer = &send_buffer, .respond_options = .{
        .keep_alive = false,
        .extra_headers = &.{
            .{
                .name = "content-type",
                .value = "image/bmp",
            },
        },
    } });

    try writeImageAsBmp(self.alloc, &self.app.outputs.output_image, &response_writer);
    try response_writer.end();
}

fn respondEmpty(request: *std.http.Server.Request) !void {
    try request.respond("", .{
        .keep_alive = false,
    });
}

fn handleHttpRequest(self: *Self, request: *std.http.Server.Request) !void {
    const purpose = UriPurpose.parse(request.head.target) orelse {
        if (std.mem.eql(u8, request.head.target, "/")) {
            try self.sendFile(request, "/index.html");
        } else {
            try self.sendFile(request, request.head.target);
        }
        return;
    };

    switch (purpose) {
        .set_roi => {
            try self.handleSetRoi(request);
        },
        .set_hist_smoothing => {
            try self.handleSetHistSmoothing(request);
        },
        .clusters => {
            try self.handleClusters(request);
        },
        .histogram => {
            try self.handleHistogram(request);
        },
        .image_input => {
            try self.handleInputImage(request);
        },
        .image_output => {
            try self.handleOutputImage(request);
        },
        .dark_light_partition => {
            try self.handleDarkLightParition(request);
        },
        .binarized_image => {
            try self.handleBinarizedImage(request);
            return error.Unimplemented;
        },
    }
}

fn copyFile(response: *HttpServer.Response, reader: anytype) !void {
    var fifo = std.fifo.LinearFifo(u8, .{
        .Static = 4096,
    }).init();

    try fifo.pump(reader, response);
}

fn embeddedLookup(path: []const u8) ?[]const u8 {
    for (resources.resources) |resource| {
        if (std.mem.eql(u8, path, resource.path)) {
            return resource.data;
        }
    }

    return null;
}

fn sendFile(self: *Self, request: *HttpServer.Request, path_abs: []const u8) !void {
    const path = path_abs[1..];
    const http_headers = &[_]std.http.Header{
        .{ .name = "content-type", .value = try mimetypeFromPath(path) },
    };

    var send_buffer: [4096]u8 = undefined;

    var response = request.respondStreaming(.{ .send_buffer = &send_buffer, .respond_options = .{
        .keep_alive = false,
        .extra_headers = http_headers,
    } });

    if (self.www_root) |d| {
        try copyFile(&response, (try d.openFile(path, .{})).reader());
    } else {
        const data = embeddedLookup(path) orelse {
            std.log.err("no file found for {s}", .{path});
            return error.InvalidData;
        };
        try response.writeAll(data);
    }

    try response.end();
}

const UriPurpose = enum {
    image_input,
    image_output,
    histogram,
    clusters,
    set_roi,
    set_hist_smoothing,
    binarized_image,
    dark_light_partition,

    fn parse(target: []const u8) ?UriPurpose {
        const Mapping = struct {
            uri: []const u8,
            match_type: enum {
                begin,
                exact,
            } = .exact,
            purpose: UriPurpose,
        };

        const mappings = [_]Mapping{
            .{ .uri = "/image_input", .purpose = .image_input },
            .{ .uri = "/image_output", .purpose = .image_output, .match_type = .begin },
            .{ .uri = "/binarized_image", .purpose = .binarized_image, .match_type = .begin },
            .{ .uri = "/dark_light_partition", .purpose = .dark_light_partition },
            .{ .uri = "/set_roi", .purpose = .set_roi, .match_type = .begin },
            .{ .uri = "/histogram", .purpose = .histogram },
            .{ .uri = "/set_hist_smoothing", .purpose = .set_hist_smoothing, .match_type = .begin },
            .{ .uri = "/clusters", .purpose = .clusters },
        };

        for (mappings) |mapping| {
            switch (mapping.match_type) {
                .begin => {
                    if (std.mem.startsWith(u8, target, mapping.uri)) {
                        return mapping.purpose;
                    }
                },
                .exact => {
                    if (std.mem.eql(u8, target, mapping.uri)) {
                        return mapping.purpose;
                    }
                },
            }
        }

        return null;
    }
};

test "url parsing" {
    return error.Unimplemented;
}
