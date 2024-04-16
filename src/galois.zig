const std = @import("std");
const galois = @This();
const Allocator = std.mem.Allocator;

fn mostSignificantBitPlus1(val: anytype) @TypeOf(val) {
    return @bitSizeOf(@TypeOf(val)) - @clz(val);
}

test "msb" {
    try std.testing.expectEqual(@as(u8, 5), mostSignificantBitPlus1(@as(u8, 0b10110)));
    try std.testing.expectEqual(@as(u8, 0), mostSignificantBitPlus1(@as(u8, 0b00000)));
    try std.testing.expectEqual(@as(u8, 8), mostSignificantBitPlus1(@as(u8, 0xff)));
}

fn bitIsSet(val: anytype, bit: anytype) bool {
    return ((@as(@TypeOf(val), 1) << @intCast(bit)) & val) != 0;
}

test "bit is set" {
    const val: u8 = 0b1100;
    try std.testing.expectEqual(bitIsSet(val, 0), false);
    try std.testing.expectEqual(bitIsSet(val, 1), false);
    try std.testing.expectEqual(bitIsSet(val, 2), true);
    try std.testing.expectEqual(bitIsSet(val, 3), true);
    try std.testing.expectEqual(bitIsSet(val, 4), false);
    try std.testing.expectEqual(bitIsSet(val, 5), false);
    try std.testing.expectEqual(bitIsSet(val, 6), false);
    try std.testing.expectEqual(bitIsSet(val, 7), false);
}

// https://en.wikipedia.org/wiki/Finite_field_arithmetic
// https://en.wikiversity.org/wiki/Reed%E2%80%93Solomon_codes_for_coders
//
// Working in GF(2), addition is xor, and multiplication is logical and.
// GF(p^n) (where p is 2 in our case) can be represented as polynomials
// where their coefficients are modulo p (in this case 2)
//
// So we represent each bit in the type as a coefficient of a polynomial.
// E.g. 101 would represent 1x^2 + 0x + 1

pub fn add(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    // For a single bit the truth table is
    // 0 + 0 = 0
    // 0 + 1 = 1
    // 1 + 0 = 1
    // 1 + 1 = 0
    //
    // i.e. xor
    //
    // In the case of a polynomial, x^2 is added with x^2, x is added with
    // x, etc. There is no crossover from one power to the next, so we can
    // just apply the xor to all bits

    return a ^ b;
}

pub fn sub(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    // For a single bit the truth table is
    // 0 - 0 = 0
    // 0 - 1 = 1
    // 1 - 0 = 1
    // 1 + 1 = 0
    //
    // i.e. xor
    //
    // In the case of a polynomial, x^2 is added with x^2, x is added with
    // x, etc. There is no crossover from one power to the next, so we can
    // just apply the xor to all bits

    return a ^ b;
}

pub fn DivRes(comptime T: type) type {
    return struct {
        val: T,
        remainder: T,
    };
}

pub fn div(a: anytype, b: @TypeOf(a)) DivRes(@TypeOf(a)) {
    // Remembering that our values can be thought of as polynomials
    //
    // 0b1110 / 0b0110 would map to
    //
    // x^3 + x^2 + x
    // -------------
    //   x^2 + x
    //
    // Using long division...
    //                     x
    //         -------------
    // x^2 + x|x^3 + x^2 + x
    //        -x^3 + x^2
    //        --------------
    //                     x
    //
    // Maybe not the best example, but we end up with x remainder x. We would
    // normally repeat this process until our denominator has a larger order of
    // magnitude than our numerator

    const T = @TypeOf(a);
    var input = a;
    var res: T = 0;
    while (input > b) {
        var shift: u3 = @intCast(mostSignificantBitPlus1(input) - mostSignificantBitPlus1(b));
        res = add(res, @as(T, 1) << shift);
        input = sub(input, b << shift);
    }

    return .{
        .val = res,
        .remainder = input,
    };
}

test "simple div test" {
    // Polynomial division
    var ret = div(@as(u8, 0b1110), 0b0110);
    try std.testing.expectEqual(@as(u8, 0b10), ret.val);
    try std.testing.expectEqual(@as(u8, 0b10), ret.remainder);

    ret = div(@as(u8, 0b0001), 0b0010);
    try std.testing.expectEqual(@as(u8, 0b0000), ret.val);
    try std.testing.expectEqual(@as(u8, 0b0001), ret.remainder);

    var ret2 = div(@as(u16, 0b1010001111010), 0b100011101);
    try std.testing.expectEqual(@as(u16, 0b000010101), ret2.val);
    try std.testing.expectEqual(@as(u16, 0b011000011), ret2.remainder);
}

pub const GF256 = struct {
    val: u8,

    pub fn init(val: u8) GF256 {
        return .{ .val = val };
    }

    pub fn add(a: GF256, b: GF256) GF256 {
        return .{
            .val = galois.add(a.val, b.val),
        };
    }

    pub fn sub(a: GF256, b: GF256) GF256 {
        return .{
            .val = galois.sub(a.val, b.val),
        };
    }

    pub fn div(a: GF256, b: GF256) DivRes(GF256) {
        const ret = galois.div(a.val, b.val);
        return .{
            .val = GF256.init(ret.val),
            .remainder = GF256.init(ret.remainder),
        };
    }

    pub fn mul(a: GF256, b: GF256) GF256 {
        // Multiplication is a little trickier.
        //
        // Since our numbers represent polynomials, we have to do the
        // polynomial multiplication from high school
        //
        // E.g. 0b101 * 0b110
        // (x^2 + 1) * (x^2 + x)
        // x^4 + x^3 + x^2 + x
        // 0b11110
        //
        // Generalized, for each element in A, we increase the power of that
        // element for each element in B
        // e.g. the x^2 element in A is raised by 2, and 1, for the x^2 and x
        // term in B
        // We then have to add the terms that ended up at the same power, using
        // Galois field arithmetic

        var ret: u16 = 0;

        for (0..8) |a_pow| {
            if (!bitIsSet(a.val, a_pow)) {
                continue;
            }

            for (0..8) |b_pow| {
                if (!bitIsSet(b.val, b_pow)) {
                    continue;
                }

                ret = galois.add(ret, @as(u16, 1) << @intCast(a_pow + b_pow));
            }
        }

        // We may end up in a scenario where the result is greater than 8 bits.
        // The intuition here might be to just truncate, however we need to
        // uphold constraints for division, (a * b) / b = a type stuff. The math
        // says we need to perform a division by some primitive polynomial, but
        // using the polynomial division rules. Our polynomial is copied from
        // the internet
        const GF256_MUL_MOD = 0b100011101;
        return .{
            .val = @intCast(galois.div(ret, GF256_MUL_MOD).remainder),
        };
    }
};

test "mul" {
    // Example stolen from https://en.wikiversity.org/wiki/Reed%E2%80%93Solomon_codes_for_coders
    var ret = GF256.init(0b10001001).mul(GF256.init(0b00101010));
    try std.testing.expectEqual(@as(u8, 0b11000011), ret.val);
}

pub fn SortedPoly(comptime T: type) type {
    return struct {
        larger: T,
        smaller: T,

        const Self = @This();

        fn init(a: T, b: T) Self {
            if (a.coefficients.len > b.coefficients.len) {
                return .{
                    .larger = a,
                    .smaller = b,
                };
            } else {
                return .{
                    .larger = b,
                    .smaller = a,
                };
            }
        }
    };
}

// Helper type for testing the polynomial struct without needing to worry about
// galois math
fn Primitive(comptime T: type) type {
    return struct {
        val: T,
        const Self = @This();

        pub fn init(val: T) Self {
            return .{
                .val = val,
            };
        }

        pub fn add(a: Self, b: Self) Self {
            return .{
                .val = a.val + b.val,
            };
        }

        pub fn sub(a: Self, b: Self) Self {
            return .{
                .val = a.val - b.val,
            };
        }

        pub fn div(a: Self, b: Self) DivRes(Self) {
            return .{
                .val = a / b,
                .remainder = a % b,
            };
        }

        pub fn mul(a: Self, b: Self) Self {
            return .{
                .val = a.val * b.val,
            };
        }
    };
}

pub fn Poly(comptime Elem: type) type {
    return struct {
        // Stored from lowest to highest order. Bigger numbers require more space
        coefficients: []const Elem,

        const Self = @This();

        // Initialize using a reference to other data. Mathematical operations will
        // result in allocations, but initial data does not
        pub fn initRef(coefficients: []const Elem) Self {
            return .{
                .coefficients = coefficients,
            };
        }

        // Must be called with same allocator used to generate, note that this
        // should only be called on allocated variants of the type
        pub fn deinit(self: *Self, alloc: Allocator) void {
            alloc.free(self.coefficients);
        }

        pub fn add(a: Self, b: Self, alloc: Allocator) !Self {
            const sorted = SortedPoly(Self).init(a, b);
            const larger = sorted.larger.coefficients;
            const smaller = sorted.smaller.coefficients;

            var ret = try alloc.alloc(Elem, larger.len);
            errdefer alloc.free(ret);
            @memcpy(ret[smaller.len..], larger[smaller.len..]);

            for (0..smaller.len) |i| {
                ret[i] = larger[i].add(smaller[i]);
            }

            return .{
                .coefficients = ret,
            };
        }

        pub fn mul(a: Self, b: Self, alloc: Allocator) !Self {
            // len 5 == max index 4
            // index == power
            // x^4 + x^4 = 8, max power 8, len 9
            const new_order = a.coefficients.len + b.coefficients.len - 1;
            var ret = try alloc.alloc(Elem, new_order);
            errdefer alloc.free(ret);
            @memset(ret, Elem.init(0));

            for (0..a.coefficients.len) |a_pow| {
                for (0..b.coefficients.len) |b_pow| {
                    ret[a_pow + b_pow] = ret[a_pow + b_pow].add(a.coefficients[a_pow].mul(b.coefficients[b_pow]));
                }
            }

            return .{
                .coefficients = ret,
            };
        }

        pub fn eval(self: *const Self, x: Elem) Elem {
            var x_pow = x;
            var ret = self.coefficients[0];

            for (1..self.coefficients.len) |idx| {
                ret = ret.add(x_pow.mul(self.coefficients[idx]));
                x_pow = x_pow.mul(x);
            }

            return ret;
        }
    };
}

// A polynomial where the coefficients are represented by galois fields with
// order 256. Note the potential for confusion between the polynomials that
// make up a galois field, and one that is using galois fields for coefficients.
const GF256Poly = Poly(GF256);

test "poly add" {
    const alloc = std.testing.allocator;

    const T = Primitive(u32);

    const a_coeff = [_]T{
        T.init(3),
        T.init(7),
        T.init(10),
    };
    var a = Poly(T).initRef(&a_coeff);

    const b_coeff = [_]T{
        T.init(1),
        T.init(7),
        T.init(255),
        T.init(4),
        T.init(9),
        T.init(3),
    };
    var b = Poly(T).initRef(&b_coeff);

    var c = try a.add(b, alloc);
    defer c.deinit(alloc);

    try std.testing.expectEqualSlices(T, &[_]T{
        T.init(4),
        T.init(14),
        T.init(265),
        T.init(4),
        T.init(9),
        T.init(3),
    }, c.coefficients);
}

test "poly mul" {
    const alloc = std.testing.allocator;

    const T = Primitive(u32);
    const a_coeff = [_]T{
        T.init(3),
        T.init(7),
        T.init(10),
    };
    var a = Poly(T).initRef(&a_coeff);

    const b_coeff = [_]T{
        T.init(1),
        T.init(7),
    };
    var b = Poly(T).initRef(&b_coeff);

    var c = try a.mul(b, alloc);
    defer c.deinit(alloc);

    try std.testing.expectEqualSlices(T, &[_]T{
        T.init(3),
        T.init(28),
        T.init(59),
        T.init(70),
    }, c.coefficients);
}

test "poly eval" {
    const T = Primitive(u32);
    const a_coeff = [_]T{
        T.init(4),
        T.init(2),
        T.init(7),
        T.init(1),
    };
    var a = Poly(T).initRef(&a_coeff);

    // x^3 + 7*x^2 + 2*x + 4
    // 64 + 7 * 16 + 2 * 4 + 4
    // 64 + 112 + 8 + 4
    // 188
    try std.testing.expectEqual(@as(u32, 188), a.eval(T.init(4)).val);
}
