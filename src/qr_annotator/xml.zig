const std = @import("std");
const Allocator = std.mem.Allocator;

const State = enum {
    attribute,
    other,
};

pub fn XmlBuilder(comptime Writer: type) type {
    const WriteError = Writer.Error;
    const XmlError = error{
        InvalidState,
    } || WriteError || Allocator.Error;

    const TagStack = std.ArrayList([]const u8);
    return struct {
        writer: Writer,
        state: State,
        tag_stack: TagStack,

        const Self = @This();

        pub fn init(alloc: Allocator, writer: Writer) Self {
            return .{
                .writer = writer,
                .state = .other,
                .tag_stack = TagStack.init(alloc),
            };
        }

        pub fn addNode(self: *Self, key: []const u8) XmlError!void {
            switch (self.state) {
                .other => {},
                else => {
                    std.log.err("Cannot add node while in {any} state", .{self.state});
                    return XmlError.InvalidState;
                },
            }

            try self.insertIndent();
            try self.tag_stack.append(key);
            try self.writer.print("<{s}", .{key});
            self.state = .attribute;
        }

        pub fn addData(self: *Self, data: []const u8) XmlError!void {
            switch (self.state) {
                .other => {},
                else => {
                    std.log.err("Cannot add node while in {any} state", .{self.state});
                    return XmlError.InvalidState;
                },
            }

            try self.insertIndent();
            try self.writer.print("{s}\n", .{data});
        }

        fn checkAttributeState(self: *const Self) XmlError!void {
            switch (self.state) {
                .attribute => {},
                else => {
                    std.log.err("Cannot add attributes while not in attribute state", .{});
                    return XmlError.InvalidState;
                },
            }
        }

        pub fn addAttribute(self: *Self, key: []const u8, val: []const u8) XmlError!void {
            try self.checkAttributeState();
            try self.writer.print(" {s}=\"{s}\"", .{ key, val });
        }

        pub fn addAttributeNum(self: *Self, key: []const u8, val: anytype) XmlError!void {
            try self.checkAttributeState();
            try self.writer.print(" {s}=\"{d}\"", .{ key, val });
        }

        pub fn finishAttributes(self: *Self) XmlError!void {
            try self.writer.print(" >\n", .{});
            self.state = .other;
        }

        pub fn finishNode(self: *Self) XmlError!void {
            const tag_opt = self.tag_stack.popOrNull();
            switch (self.state) {
                .attribute => {
                    try self.writer.print(" />\n", .{});
                    self.state = .other;
                },
                .other => {
                    const tag = tag_opt orelse {
                        std.log.err("No child node to close", .{});
                        return XmlError.InvalidState;
                    };
                    try self.insertIndent();
                    try self.writer.print("</{s}>\n", .{tag});
                },
            }
        }

        pub fn finish(self: *Self) XmlError!void {
            defer self.tag_stack.deinit();

            while (self.tag_stack.items.len > 0) {
                try self.finishNode();
            }
        }

        fn insertIndent(self: *Self) XmlError!void {
            for (0..self.tag_stack.items.len) |_| {
                try self.writer.writeByte('\t');
            }
        }
    };
}

pub fn xmlBuilder(alloc: Allocator, writer: anytype) XmlBuilder(@TypeOf(writer)) {
    return XmlBuilder(@TypeOf(writer)).init(alloc, writer);
}

test "xml sanity test" {
    const alloc = std.testing.allocator;
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    var xml_builder = xmlBuilder(alloc, buf.writer());
    try xml_builder.addNode("root");
    try xml_builder.addAttribute("key1", "test");
    try xml_builder.addAttributeNum("key2", 3.5);
    try xml_builder.finishAttributes();

    try xml_builder.addNode("child");
    try xml_builder.addAttribute("key3", "val");
    try xml_builder.finishNode();

    try xml_builder.addNode("child2");
    try xml_builder.finishAttributes();
    try xml_builder.addData("hello");
    try xml_builder.finishNode();

    try xml_builder.finish();

    const expected =
        \\<root key1="test" key2="3.5" >
        \\	<child key3="val" />
        \\	<child2 >
        \\		hello
        \\	</child2>
        \\</root>
        \\
    ;
    try std.testing.expectEqualStrings(expected, buf.items);
}
