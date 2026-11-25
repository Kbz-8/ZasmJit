//! Zig bindings to AsmJit and its experimental Universal JIT.
//! Owning handles must be deinitialized exactly once and must not be copied.
//! Compiler operands belong to the compiler that created them.
const std = @import("std");
const raw = @import("raw.zig");
const errors = @import("errors.zig");
pub const Error = errors.Error;
const check = errors.check;
pub const ops = @import("ops.zig");
/// Native instruction IDs for the selected target and pinned AsmJit version.
pub const Inst = if (@import("builtin").cpu.arch == .aarch64) @import("inst_a64.zig").Inst else @import("inst_x86.zig").Inst;
/// Experimental target-independent API. Also available at the package root.
pub const ujit = struct {
    pub const Compiler = @import("root.zig").Compiler;
    pub const ops = @import("ops.zig");
};
pub const upstream_revision = "677a10bac2c24f7e068cf1f9e675bf51c7b534ea";

/// General-purpose virtual register. Use newGp(T) to select its width.
pub const Gp = struct {
    raw: raw.Operand,
    pub fn mem(self: Gp, displacement: i32) Mem {
        var result: Mem = undefined;
        raw.zaj_mem(&self.raw, displacement, &result.raw);
        return result;
    }
};
/// SIMD or floating-point virtual register.
pub const Vec = struct { raw: raw.Operand };
pub const Label = struct { raw: raw.Operand };
pub const Mem = struct {
    raw: raw.Operand,
    pub fn offset(self: Mem, displacement: i32) Mem {
        var result: Mem = undefined;
        raw.zaj_mem_offset(&self.raw, displacement, &result.raw);
        return result;
    }
};
pub const Imm = struct { raw: raw.Operand };

/// Integer bits are preserved, including unsigned values above maxInt(i64).
pub fn imm(value: anytype) Imm {
    const T = @TypeOf(value);
    const bits: u64 = switch (@typeInfo(T)) {
        .comptime_int => if (value < 0) @bitCast(@as(i64, value)) else @intCast(value),
        .int => |info| if (info.bits > 64) @compileError("immediate is wider than 64 bits") else if (info.signedness == .signed) @bitCast(@as(i64, value)) else @intCast(value),
        .pointer => @intFromPtr(value),
        else => @compileError("immediate must be an integer or pointer"),
    };
    var result: Imm = undefined;
    raw.zaj_imm(bits, &result.raw);
    return result;
}

fn operand(value: anytype) raw.Operand {
    const T = @TypeOf(value);
    if (T == Gp or T == Vec or T == Mem or T == Imm or T == Label) return value.raw;
    return imm(value).raw;
}
fn regOperand(value: anytype) raw.Operand {
    const T = @TypeOf(value);
    if (T != Gp and T != Vec) @compileError("expected a Gp or Vec register");
    return value.raw;
}

/// Executable memory owner. Functions remain valid until release() or deinit().
/// AsmJit allocates its internal state and executable pages with native allocators.
pub const Runtime = struct {
    handle: *raw.Runtime,

    pub fn init() Error!Runtime {
        var handle: *raw.Runtime = undefined;
        try check(raw.zaj_runtime_create(&handle));
        return .{ .handle = handle };
    }
    pub fn deinit(self: *Runtime) void {
        raw.zaj_runtime_destroy(self.handle);
        self.* = undefined;
    }
    /// Publish finalized code. Fn must exactly match beginFunction's C signature.
    /// The compiler can be deinitialized immediately after this call succeeds.
    pub fn add(self: *Runtime, comptime Fn: type, compiler: *Compiler) Error!*const Fn {
        const sig = comptime signature(Fn);
        if (compiler.return_type != sig.ret or compiler.argument_count != sig.args.len or !std.mem.eql(u8, compiler.argument_types[0..compiler.argument_count], &sig.args)) return error.InvalidAssignment;
        var address: ?*anyopaque = null;
        try check(raw.zaj_runtime_add(self.handle, compiler.handle, &address));
        return @ptrCast(@alignCast(address.?));
    }
    /// Release a function returned by this runtime. It must no longer be executing.
    pub fn release(self: *Runtime, function: anytype) Error!void {
        try check(raw.zaj_runtime_release(self.handle, @ptrCast(function)));
    }
};

pub const VecWidth = enum(u32) { b128 = 0, b256 = 1, b512 = 2 };
pub const Comparison = enum(u32) { eq, ne, signed_lt, signed_le, signed_gt, signed_ge, unsigned_lt, unsigned_le, unsigned_gt, unsigned_ge };
pub const Condition = struct {
    op: ops.UniOpCond = .compare,
    comparison: Comparison,
    a: raw.Operand,
    b: raw.Operand,
};
pub fn compare(comparison: Comparison, lhs: Gp, rhs: anytype) Condition {
    return .{ .comparison = comparison, .a = lhs.raw, .b = operand(rhs) };
}

/// One native function's code-generation context. Not thread-safe.
/// Methods report errors immediately, including upstream UJIT void emitters.
/// After an emission/finalization failure, discard the compiler.
pub const Compiler = struct {
    handle: *raw.Compiler,
    return_type: u8 = 0,
    argument_count: usize = 0,
    argument_types: [32]u8 = @splat(0),

    pub const Options = struct {
        /// A wider width requires matching features on the executing CPU.
        vector_width: VecWidth = .b128,
        logging: bool = false,
        /// Validate instructions as they are emitted. Disable for lower JIT
        /// latency once the generator has been verified.
        validate: bool = true,
    };

    pub fn init(options: Options) Error!Compiler {
        var handle: *raw.Compiler = undefined;
        const flags = @as(u32, @intFromBool(options.logging)) | (@as(u32, @intFromBool(options.validate)) << 1);
        try check(raw.zaj_compiler_create(&handle, @backingInt(options.vector_width), flags));
        return .{ .handle = handle };
    }
    pub fn deinit(self: *Compiler) void {
        raw.zaj_compiler_destroy(self.handle);
        self.* = undefined;
    }
    /// Start a single C ABI function, deriving its signature at comptime.
    /// Supported ABI types: void return, 8/16/32/64-bit integers, pointers, f32/f64.
    pub fn beginFunction(self: *Compiler, comptime Fn: type) Error!void {
        const sig = comptime signature(Fn);
        try check(raw.zaj_begin(self.handle, sig.ret, &sig.args, sig.args.len));
        self.return_type = sig.ret;
        self.argument_count = sig.args.len;
        @memcpy(self.argument_types[0..sig.args.len], &sig.args);
    }
    pub fn endFunction(self: *Compiler) Error!void {
        try check(raw.zaj_end(self.handle));
    }
    pub fn finalize(self: *Compiler) Error!void {
        try check(raw.zaj_finalize(self.handle));
    }

    /// Small integers occupy a 32-bit register. Pointers use the target word size.
    pub fn newGp(self: *Compiler, comptime T: type) Error!Gp {
        const id = comptime switch (@typeInfo(T)) {
            .pointer => 33,
            .int => |info| if (info.bits <= 32 and (info.bits == 8 or info.bits == 16 or info.bits == 32)) 39 else if (info.bits == 64) 41 else @compileError("unsupported GP integer width"),
            else => @compileError("GP register type must be an integer or pointer"),
        };
        var result: Gp = undefined;
        try check(raw.zaj_new_reg(self.handle, id, &result.raw));
        return result;
    }
    pub fn newVec(self: *Compiler, width: VecWidth) Error!Vec {
        var result: Vec = undefined;
        try check(raw.zaj_new_reg(self.handle, switch (width) {
            .b128 => 75,
            .b256 => 85,
            .b512 => 95,
        }, &result.raw));
        return result;
    }
    /// Allocate a SIMD register for scalar floating-point operations.
    pub fn newScalar(self: *Compiler, comptime T: type) Error!Vec {
        const id = if (T == f32) 59 else if (T == f64) 70 else @compileError("expected f32 or f64");
        var result: Vec = undefined;
        try check(raw.zaj_new_reg(self.handle, id, &result.raw));
        return result;
    }
    pub fn setArg(self: *Compiler, index: usize, reg: anytype) Error!void {
        const r = regOperand(reg);
        try check(raw.zaj_set_arg(self.handle, index, &r));
    }
    /// Pass a register for a value return, or {} for a void return.
    pub fn ret(self: *Compiler, value: anytype) Error!void {
        if (@TypeOf(value) == void) {
            try check(raw.zaj_ret(self.handle, null));
        } else {
            const r = regOperand(value);
            try check(raw.zaj_ret(self.handle, &r));
        }
    }
    pub fn newLabel(self: *Compiler) Error!Label {
        var result: Label = undefined;
        try check(raw.zaj_label(self.handle, &result.raw));
        return result;
    }
    pub fn bind(self: *Compiler, label: Label) Error!void {
        try check(raw.zaj_bind(self.handle, &label.raw));
    }
    pub fn newStack(self: *Compiler, size: u32, alignment: u32) Error!Mem {
        var result: Mem = undefined;
        try check(raw.zaj_stack(self.handle, size, alignment, &result.raw));
        return result;
    }
    /// Copy bytes into the function's constant pool. The input need not outlive
    /// this call. The returned memory operand belongs to this compiler.
    pub fn constant(self: *Compiler, bytes: []const u8) Error!Mem {
        var result: Mem = undefined;
        try check(raw.zaj_const(self.handle, bytes.ptr, bytes.len, &result.raw));
        return result;
    }
    pub fn mov(self: *Compiler, dst: Gp, src: anytype) Error!void {
        const s = operand(src);
        try check(raw.zaj_mov(self.handle, &dst.raw, &s));
    }

    fn emit(self: *Compiler, family: u32, op: anytype, operands: anytype, immediate: u32, alignment: u32) Error!void {
        if ((family == 6 or family == 7) and (alignment == 0 or !std.math.isPowerOfTwo(alignment))) return error.InvalidArgument;
        var data: [operands.len]raw.Operand = undefined;
        inline for (operands, 0..) |o, i| data[i] = operand(o);
        try check(raw.zaj_emit(self.handle, family, @backingInt(op), &data, immediate, alignment));
    }
    pub fn memory(self: *Compiler, op: ops.UniOpM, dst: Mem) Error!void {
        try self.emit(0, op, .{dst}, 0, 1);
    }
    pub fn loadOp(self: *Compiler, op: ops.UniOpRM, dst: Gp, src: Mem) Error!void {
        try self.emit(1, op, .{ dst, src }, 0, 1);
    }
    pub fn storeOp(self: *Compiler, op: ops.UniOpMR, dst: Mem, src: Gp) Error!void {
        try self.emit(2, op, .{ dst, src }, 0, 1);
    }
    pub fn load(self: *Compiler, comptime T: type, dst: Gp, src: Mem) Error!void {
        const op: ops.UniOpRM = if (T == i8) .load_i8 else if (T == u8) .load_u8 else if (T == i16) .load_i16 else if (T == u16) .load_u16 else if (T == i32) .load_i32 else if (T == u32) .load_u32 else if (T == i64) .load_i64 else if (T == u64) .load_u64 else @compileError("unsupported load type");
        try self.loadOp(op, dst, src);
    }
    pub fn store(self: *Compiler, comptime T: type, dst: Mem, src: Gp) Error!void {
        const op: ops.UniOpMR = if (T == i8 or T == u8) .store_u8 else if (T == i16 or T == u16) .store_u16 else if (T == i32 or T == u32) .store_u32 else if (T == i64 or T == u64) .store_u64 else @compileError("unsupported store type");
        try self.storeOp(op, dst, src);
    }
    pub fn unary(self: *Compiler, op: ops.UniOpRR, dst: Gp, src: anytype) Error!void {
        try self.emit(3, op, .{ dst, src }, 0, 1);
    }
    pub fn binary(self: *Compiler, op: ops.UniOpRRR, dst: Gp, lhs: anytype, rhs: anytype) Error!void {
        try self.emit(4, op, .{ dst, lhs, rhs }, 0, 1);
    }
    pub fn add(self: *Compiler, dst: Gp, lhs: anytype, rhs: anytype) Error!void {
        try self.binary(.add, dst, lhs, rhs);
    }
    pub fn sub(self: *Compiler, dst: Gp, lhs: anytype, rhs: anytype) Error!void {
        try self.binary(.sub, dst, lhs, rhs);
    }
    pub fn mul(self: *Compiler, dst: Gp, lhs: anytype, rhs: anytype) Error!void {
        try self.binary(.mul, dst, lhs, rhs);
    }
    /// Move/convert/insert/extract between scalar and vector registers.
    pub fn vecScalar(self: *Compiler, op: ops.UniOpVR, dst: anytype, src: anytype, index: u32) Error!void {
        try self.emit(5, op, .{ dst, src }, index, 1);
    }
    pub fn vecLoad(self: *Compiler, op: ops.UniOpVM, dst: Vec, src: Mem, alignment: u32, index: u32) Error!void {
        try self.emit(6, op, .{ dst, src }, index, alignment);
    }
    pub fn vecStore(self: *Compiler, op: ops.UniOpMV, dst: Mem, src: Vec, alignment: u32, index: u32) Error!void {
        try self.emit(7, op, .{ dst, src }, index, alignment);
    }
    pub fn vecUnary(self: *Compiler, op: ops.UniOpVV, dst: Vec, src: anytype) Error!void {
        try self.emit(8, op, .{ dst, src }, 0, 1);
    }
    pub fn vecUnaryImm(self: *Compiler, op: ops.UniOpVVI, dst: Vec, src: anytype, immediate: u32) Error!void {
        try self.emit(9, op, .{ dst, src }, immediate, 1);
    }
    pub fn vecBinary(self: *Compiler, op: ops.UniOpVVV, dst: Vec, lhs: anytype, rhs: anytype) Error!void {
        try self.emit(10, op, .{ dst, lhs, rhs }, 0, 1);
    }
    pub fn vecBinaryImm(self: *Compiler, op: ops.UniOpVVVI, dst: Vec, lhs: anytype, rhs: anytype, immediate: u32) Error!void {
        try self.emit(11, op, .{ dst, lhs, rhs }, immediate, 1);
    }
    pub fn vecTernary(self: *Compiler, op: ops.UniOpVVVV, dst: Vec, a: anytype, b: anytype, c: anytype) Error!void {
        try self.emit(12, op, .{ dst, a, b, c }, 0, 1);
    }
    pub fn jump(self: *Compiler, label: Label) Error!void {
        try check(raw.zaj_jump(self.handle, &label.raw));
    }
    pub fn jumpIf(self: *Compiler, label: Label, condition: Condition) Error!void {
        try self.emitCondition(0, condition, label.raw, null, null);
    }
    pub fn cmov(self: *Compiler, dst: Gp, src: anytype, condition: Condition) Error!void {
        try self.emitCondition(1, condition, dst.raw, operand(src), null);
    }
    pub fn select(self: *Compiler, dst: Gp, a: anytype, b: anytype, condition: Condition) Error!void {
        try self.emitCondition(2, condition, dst.raw, operand(a), operand(b));
    }
    fn emitCondition(self: *Compiler, action: u32, c: Condition, dst: raw.Operand, a: ?raw.Operand, b: ?raw.Operand) Error!void {
        try check(raw.zaj_condition(self.handle, action, @backingInt(c.op), @backingInt(c.comparison), &c.a, &c.b, &dst, if (a) |*v| v else null, if (b) |*v| v else null));
    }
    /// Call a C ABI function. args is a tuple of registers/immediates; result is
    /// a register, or {} for void. The signature supplies ABI argument types.
    pub fn call(self: *Compiler, comptime Fn: type, target: anytype, args: anytype, result: anytype) Error!void {
        const sig = comptime signature(Fn);
        if (args.len != sig.args.len) @compileError("call argument count does not match signature");
        if ((sig.ret == 0) != (@TypeOf(result) == void)) @compileError("result must be a register for a value return and {} for void");
        const t = operand(target);
        var data: [args.len]raw.Operand = undefined;
        inline for (args, 0..) |a, i| data[i] = operand(a);
        const r: ?raw.Operand = if (@TypeOf(result) == void) null else regOperand(result);
        try check(raw.zaj_call(self.handle, &t, sig.ret, &sig.args, &data, data.len, if (r) |*v| v else null));
    }
    /// Escape hatch: emit a native AsmJit instruction ID and operand tuple.
    /// IDs are specific to the pinned upstream version and target architecture.
    pub fn native(self: *Compiler, instruction: Inst, operands: anytype) Error!void {
        try self.nativeId(@backingInt(instruction), operands);
    }
    pub fn nativeId(self: *Compiler, instruction_id: u32, operands: anytype) Error!void {
        var data: [operands.len]raw.Operand = undefined;
        inline for (operands, 0..) |o, i| data[i] = operand(o);
        try check(raw.zaj_native(self.handle, instruction_id, &data, data.len));
    }
    /// Borrowed log; invalidated by further emission or deinit().
    pub fn log(self: *Compiler) []const u8 {
        var len: usize = 0;
        const data = raw.zaj_log(self.handle, &len) orelse return "";
        return data[0..len];
    }
    pub fn codeSize(self: *Compiler) usize {
        return raw.zaj_code_size(self.handle);
    }
};

fn validateFunction(comptime Fn: type) void {
    if (@typeInfo(Fn) != .@"fn") @compileError("expected a function type, e.g. fn (u32) callconv(.c) u32");
    const info = @typeInfo(Fn).@"fn";
    if (!std.meta.eql(info.attrs.@"callconv", std.builtin.CallingConvention.c)) @compileError("JIT functions must use callconv(.c)");
    if (info.attrs.varargs or info.is_generic) @compileError("variadic and generic functions are unsupported");
    if (info.param_types.len > 32) @compileError("AsmJit supports at most 32 arguments");
}
fn typeId(comptime T: type) u8 {
    if (T == void) return 0;
    return switch (@typeInfo(T)) {
        .pointer => 33,
        .int => |i| @as(u8, switch (i.bits) {
            8 => 34,
            16 => 36,
            32 => 38,
            64 => 40,
            else => @compileError("unsupported integer ABI width"),
        }) + @intFromBool(i.signedness == .unsigned),
        .float => |f| switch (f.bits) {
            32 => 42,
            64 => 43,
            else => @compileError("unsupported float ABI width"),
        },
        else => @compileError("unsupported C ABI type; use integers, pointers, f32, or f64"),
    };
}
fn signature(comptime Fn: type) struct { ret: u8, args: [@typeInfo(Fn).@"fn".param_types.len]u8 } {
    validateFunction(Fn);
    const info = @typeInfo(Fn).@"fn";
    var args: [info.param_types.len]u8 = undefined;
    for (info.param_types, 0..) |p, i| args[i] = typeId(p.?);
    return .{ .ret = typeId(info.return_type.?), .args = args };
}

test {
    _ = @import("tests.zig");
}
