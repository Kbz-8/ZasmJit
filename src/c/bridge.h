#ifndef ZASMJIT_BRIDGE_H
#define ZASMJIT_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C"
{
#endif
	typedef struct zaj_runtime zaj_runtime;
	typedef struct zaj_compiler zaj_compiler;

	typedef struct zaj_operand
	{
		uint32_t data[4];
	} zaj_operand;

	uint32_t zaj_runtime_create(zaj_runtime** out);
	void zaj_runtime_destroy(zaj_runtime* rt);
	uint32_t zaj_runtime_add(zaj_runtime* rt, zaj_compiler* cc, void** out);
	uint32_t zaj_runtime_release(zaj_runtime* rt, void* fn);
	uint32_t zaj_compiler_create(zaj_compiler** out, uint32_t vec_width, uint32_t flags);
	void zaj_compiler_destroy(zaj_compiler* cc);
	uint32_t zaj_begin(zaj_compiler* cc, uint8_t ret, const uint8_t* args, size_t count);
	uint32_t zaj_end(zaj_compiler* cc);
	uint32_t zaj_finalize(zaj_compiler* cc);
	uint32_t zaj_new_reg(zaj_compiler* cc, uint8_t type, zaj_operand* out);
	uint32_t zaj_set_arg(zaj_compiler* cc, size_t index, const zaj_operand* reg);
	uint32_t zaj_ret(zaj_compiler* cc, const zaj_operand* reg);
	uint32_t zaj_label(zaj_compiler* cc, zaj_operand* out);
	uint32_t zaj_bind(zaj_compiler* cc, const zaj_operand* label);
	uint32_t zaj_stack(zaj_compiler* cc, uint32_t size, uint32_t alignment, zaj_operand* out);
	uint32_t zaj_const(zaj_compiler* cc, const void* data, size_t size, zaj_operand* out);
	void zaj_imm(uint64_t bits, zaj_operand* out);
	void zaj_mem(const zaj_operand* base, int32_t offset, zaj_operand* out);
	void zaj_mem_offset(const zaj_operand* mem, int32_t offset, zaj_operand* out);
	uint32_t zaj_mov(zaj_compiler* cc, const zaj_operand* dst, const zaj_operand* src);
	uint32_t zaj_emit(zaj_compiler* cc,
	                  uint32_t family,
	                  uint32_t op,
	                  const zaj_operand* operands,
	                  uint32_t imm,
	                  uint32_t alignment);
	uint32_t zaj_jump(zaj_compiler* cc, const zaj_operand* target);
	uint32_t zaj_condition(zaj_compiler* cc,
	                       uint32_t action,
	                       uint32_t op,
	                       uint32_t cond,
	                       const zaj_operand* a,
	                       const zaj_operand* b,
	                       const zaj_operand* dst,
	                       const zaj_operand* x,
	                       const zaj_operand* y);
	uint32_t zaj_call(zaj_compiler* cc,
	                  const zaj_operand* target,
	                  uint8_t ret,
	                  const uint8_t* types,
	                  const zaj_operand* args,
	                  size_t count,
	                  const zaj_operand* result);
	uint32_t zaj_native(zaj_compiler* cc, uint32_t inst, const zaj_operand* operands, size_t count);
	const char* zaj_log(zaj_compiler* cc, size_t* size);
	size_t zaj_code_size(zaj_compiler* cc);

#ifdef __cplusplus
}
#endif

#endif
