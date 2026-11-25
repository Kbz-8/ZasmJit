# ZAsmJit

Zig bindings to [AsmJit](https://asmjit.com/), focused on its experimental [Universal JIT (UJIT)](https://asmjit.com/doc/group__asmjit__ujit.html).

The package exports an `asmjit` module with Zig error unions, `init`/`deinit`
ownership, C signatures derived from Zig function types, distinct register and
memory types, and scalar and SIMD emission. Native AsmJit instruction emission
is available alongside UJIT.
