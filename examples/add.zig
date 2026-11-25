const std = @import("std");
const asmjit = @import("asmjit");

pub fn main() !void {
    const Add = fn (u32, u32) callconv(.c) u32;
    var runtime = try asmjit.Runtime.init();
    defer runtime.deinit();
    var compiler = try asmjit.Compiler.init(.{});
    defer compiler.deinit();

    try compiler.beginFunction(Add);
    const a = try compiler.newGp(u32);
    const b = try compiler.newGp(u32);
    try compiler.setArg(0, a);
    try compiler.setArg(1, b);
    try compiler.add(a, a, b);
    try compiler.ret(a);
    try compiler.endFunction();
    try compiler.finalize();

    const add = try runtime.add(Add, &compiler);
    defer runtime.release(add) catch unreachable;
    std.debug.print("UJIT: 20 + 22 = {d}\n", .{add(20, 22)});
}
