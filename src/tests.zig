const std = @import("std");
const a = @import("root.zig");
const expect = std.testing.expect;
const eq = std.testing.expectEqual;

test "UJIT adds two C ABI arguments" {
    const Fn = fn (u32, u32) callconv(.c) u32;
    var rt = try a.Runtime.init();
    defer rt.deinit();
    var cc = try a.Compiler.init(.{ .logging = true });
    defer cc.deinit();
    try cc.beginFunction(Fn);
    const x = try cc.newGp(u32);
    const y = try cc.newGp(u32);
    try cc.setArg(0, x);
    try cc.setArg(1, y);
    try cc.add(x, x, y);
    try cc.ret(x);
    try cc.endFunction();
    try cc.finalize();
    const f = try rt.add(Fn, &cc);
    defer rt.release(f) catch unreachable;
    try eq(@as(u32, 42), f(20, 22));
    try eq(@as(u32, 0), f(std.math.maxInt(u32), 1));
    try expect(cc.codeSize() > 0);
    try expect(cc.log().len > 0);
}

test "loop and branch compute sum from one through n" {
    const Fn = fn (u64) callconv(.c) u64;
    var rt = try a.Runtime.init();
    defer rt.deinit();
    var cc = try a.Compiler.init(.{});
    defer cc.deinit();
    try cc.beginFunction(Fn);
    const n = try cc.newGp(u64);
    const sum = try cc.newGp(u64);
    try cc.setArg(0, n);
    try cc.mov(sum, 0);
    const loop = try cc.newLabel();
    const done = try cc.newLabel();
    try cc.jumpIf(done, a.compare(.eq, n, 0));
    try cc.bind(loop);
    try cc.add(sum, sum, n);
    try cc.sub(n, n, 1);
    try cc.jumpIf(loop, a.compare(.ne, n, 0));
    try cc.bind(done);
    try cc.ret(sum);
    try cc.endFunction();
    try cc.finalize();
    const f = try rt.add(Fn, &cc);
    try eq(@as(u64, 0), f(0));
    try eq(@as(u64, 55), f(10));
    try eq(@as(u64, 500500), f(1000));
}

test "signed loads, stores, stack allocation, and void return" {
    const Fn = fn (*i64, *const i8) callconv(.c) void;
    var rt = try a.Runtime.init();
    defer rt.deinit();
    var cc = try a.Compiler.init(.{});
    defer cc.deinit();
    try cc.beginFunction(Fn);
    const dst = try cc.newGp(*i64);
    const src = try cc.newGp(*const i8);
    const value = try cc.newGp(i64);
    try cc.setArg(0, dst);
    try cc.setArg(1, src);
    const stack = try cc.newStack(8, 8);
    try cc.load(i8, value, src.mem(0));
    try cc.store(i64, stack, value);
    try cc.mov(value, 0);
    try cc.load(i64, value, stack.offset(0));
    try cc.store(i64, dst.mem(0), value);
    try cc.ret({});
    try cc.endFunction();
    try cc.finalize();
    const f = try rt.add(Fn, &cc);
    var out: i64 = 0;
    const input: i8 = -93;
    f(&out, &input);
    try eq(@as(i64, -93), out);
}

test "scalar floating point through UJIT SIMD API" {
    const Fn = fn (f64, f64) callconv(.c) f64;
    var rt = try a.Runtime.init();
    defer rt.deinit();
    var cc = try a.Compiler.init(.{});
    defer cc.deinit();
    try cc.beginFunction(Fn);
    const x = try cc.newScalar(f64);
    const y = try cc.newScalar(f64);
    try cc.setArg(0, x);
    try cc.setArg(1, y);
    try cc.vecBinary(.mul_f64_s, x, x, y);
    try cc.ret(x);
    try cc.endFunction();
    try cc.finalize();
    const f = try rt.add(Fn, &cc);
    try eq(@as(f64, 10.5), f(3.5, 3.0));
}

test "SIMD adds four lanes from unaligned memory" {
    const Fn = fn ([*]u32, [*]const u32, [*]const u32) callconv(.c) void;
    var rt = try a.Runtime.init();
    defer rt.deinit();
    var cc = try a.Compiler.init(.{});
    defer cc.deinit();
    try cc.beginFunction(Fn);
    const dst = try cc.newGp([*]u32);
    const src1 = try cc.newGp([*]const u32);
    const src2 = try cc.newGp([*]const u32);
    try cc.setArg(0, dst);
    try cc.setArg(1, src1);
    try cc.setArg(2, src2);
    const x = try cc.newVec(.b128);
    const y = try cc.newVec(.b128);
    try cc.vecLoad(.load128_u32, x, src1.mem(0), 1, 0);
    try cc.vecLoad(.load128_u32, y, src2.mem(0), 1, 0);
    try cc.vecBinary(.add_u32, x, x, y);
    try cc.vecStore(.store128_u32, dst.mem(0), x, 1, 0);
    try cc.ret({});
    try cc.endFunction();
    try cc.finalize();
    const f = try rt.add(Fn, &cc);
    const xs = [_]u32{ 1, 10, 100, 1000 };
    const ys = [_]u32{ 2, 20, 200, 2000 };
    var result: [4]u32 = undefined;
    f(&result, &xs, &ys);
    try std.testing.expectEqualSlices(u32, &.{ 3, 30, 300, 3000 }, &result);
}

fn double(x: u64) callconv(.c) u64 {
    return x * 2;
}

test "invoke a native C ABI function" {
    const Fn = fn (u64) callconv(.c) u64;
    var rt = try a.Runtime.init();
    defer rt.deinit();
    var cc = try a.Compiler.init(.{});
    defer cc.deinit();
    try cc.beginFunction(Fn);
    const x = try cc.newGp(u64);
    try cc.setArg(0, x);
    try cc.call(Fn, &double, .{x}, x);
    try cc.add(x, x, 1);
    try cc.ret(x);
    try cc.endFunction();
    try cc.finalize();
    const f = try rt.add(Fn, &cc);
    try eq(@as(u64, 43), f(21));
}

test "unsigned immediate preserves all 64 bits and code outlives compiler" {
    const Fn = fn () callconv(.c) u64;
    var rt = try a.Runtime.init();
    defer rt.deinit();
    const f = blk: {
        var cc = try a.Compiler.init(.{});
        defer cc.deinit();
        try cc.beginFunction(Fn);
        const x = try cc.newGp(u64);
        try cc.mov(x, @as(u64, 0xfedcba9876543210));
        try cc.ret(x);
        try cc.endFunction();
        try cc.finalize();
        break :blk try rt.add(Fn, &cc);
    };
    try eq(@as(u64, 0xfedcba9876543210), f());
    try rt.release(f);
}

test "state and signature errors are Zig errors" {
    const Fn = fn (u32) callconv(.c) u32;
    var rt = try a.Runtime.init();
    defer rt.deinit();
    var cc = try a.Compiler.init(.{});
    defer cc.deinit();
    try std.testing.expectError(error.InvalidState, cc.finalize());
    try cc.beginFunction(Fn);
    const x = try cc.newGp(u32);
    try std.testing.expectError(error.InvalidArgument, cc.setArg(1, x));
    try cc.setArg(0, x);
    try std.testing.expectError(error.InvalidArgument, cc.newStack(8, 3));
    try std.testing.expectError(error.InvalidState, rt.add(Fn, &cc));
    try cc.ret(x);
    try cc.endFunction();
    try cc.finalize();
    try std.testing.expectError(error.InvalidState, cc.finalize());
    try std.testing.expectError(error.InvalidAssignment, rt.add(fn (u64) callconv(.c) u64, &cc));
}

test "unresolved labels produce an error and failed passes are not retried" {
    const Fn = fn () callconv(.c) void;
    var cc = try a.Compiler.init(.{});
    defer cc.deinit();
    try cc.beginFunction(Fn);
    const label = try cc.newLabel();
    try cc.jump(label);
    try cc.ret({});
    try cc.endFunction();
    if (cc.finalize()) |_| return error.ExpectedFailure else |_| {}
    if (cc.finalize()) |_| return error.ExpectedFailure else |_| {}
}

test "selection, conditional move, unary operations, and native instruction" {
    const Fn = fn (i32, i32) callconv(.c) i32;
    var rt = try a.Runtime.init();
    defer rt.deinit();
    var cc = try a.Compiler.init(.{});
    defer cc.deinit();
    try cc.beginFunction(Fn);
    const x = try cc.newGp(i32);
    const y = try cc.newGp(i32);
    const z = try cc.newGp(i32);
    try cc.setArg(0, x);
    try cc.setArg(1, y);
    try cc.select(z, x, y, a.compare(.signed_lt, x, y));
    try cc.cmov(z, y, a.compare(.eq, x, 0));
    try cc.unary(.neg, z, z);
    try cc.native(.nop, .{});
    try cc.ret(z);
    try cc.endFunction();
    try cc.finalize();
    const f = try rt.add(Fn, &cc);
    try eq(@as(i32, 7), f(-7, 10));
    try eq(@as(i32, -3), f(10, 3));
    try eq(@as(i32, -8), f(0, 8));
}

test "constant pool copies bytes into executable allocation" {
    const Fn = fn () callconv(.c) u64;
    var rt = try a.Runtime.init();
    defer rt.deinit();
    var cc = try a.Compiler.init(.{});
    defer cc.deinit();
    try cc.beginFunction(Fn);
    var value: u64 = 123456789;
    const m = try cc.constant(std.mem.asBytes(&value));
    value = 0;
    const x = try cc.newGp(u64);
    try cc.load(u64, x, m);
    try cc.ret(x);
    try cc.endFunction();
    try cc.finalize();
    const f = try rt.add(Fn, &cc);
    try eq(@as(u64, 123456789), f());
}

test "native emitter errors propagate and remain sticky" {
    var cc = try a.Compiler.init(.{});
    defer cc.deinit();
    try cc.beginFunction(fn () callconv(.c) void);
    try std.testing.expectError(error.InvalidInstruction, cc.native(.none, .{}));
    try std.testing.expectError(error.InvalidInstruction, cc.ret({}));
}

test "unsupported vector width is rejected on AArch64" {
    if (@import("builtin").cpu.arch != .aarch64) return;
    try std.testing.expectError(error.FeatureNotEnabled, a.Compiler.init(.{ .vector_width = .b256 }));
    var cc = try a.Compiler.init(.{});
    defer cc.deinit();
    try cc.beginFunction(fn () callconv(.c) void);
    try std.testing.expectError(error.FeatureNotEnabled, cc.newVec(.b256));
}
