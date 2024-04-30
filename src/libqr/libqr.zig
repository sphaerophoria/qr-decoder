const std = @import("std");
pub const qr = @import("qr.zig");
pub const img = @import("img.zig");
pub const types_2d = @import("types_2d.zig");

test {
    std.testing.refAllDeclsRecursive(@This());
}
