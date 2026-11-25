#include "bridge.h"
#include <asmjit/ujit.h>
#include <cstring>
#include <new>
#include <optional>

using namespace asmjit;
#include "abi_checks.inc"

static_assert(sizeof(Operand) == sizeof(zaj_operand));
static_assert(sizeof(host::Gp) == sizeof(zaj_operand));
static_assert(sizeof(host::Vec) == sizeof(zaj_operand));
static_assert(sizeof(host::Mem) == sizeof(zaj_operand));

template<class T = Operand>
static T get(const zaj_operand* p)
{
	T out;
	out.set_signature(p->data[0]);
	out._base_id = p->data[1];
	out._data[0] = p->data[2];
	out._data[1] = p->data[3];
	return out;
}

static void put(zaj_operand* p, const Operand_& op)
{
	p->data[0] = op.signature().bits();
	p->data[1] = op._base_id;
	p->data[2] = op._data[0];
	p->data[3] = op._data[1];
}

static uint32_t status(Error e)
{
	return uint32_t(e);
}

struct zaj_runtime : JitRuntime
{
};

struct CaptureError : ErrorHandler
{
	Error error = Error::kOk;
	void handle_error(Error e, const char*, BaseEmitter*) override
	{
		if(error == Error::kOk)
			error = e;
	}
};

struct zaj_compiler
{
	CaptureError errors;
	StringLogger logger;
	CodeHolder code;
	host::Compiler cc;
	std::optional<ujit::UniCompiler> u;
	bool finalized = false;
	bool started = false;
	uint32_t max_vec_width = 0;
	Error ready(bool function = true) const
	{
		if(errors.error != Error::kOk)
			return errors.error;
		if(finalized || (function && !cc.func()))
			return Error::kInvalidState;
		return Error::kOk;
	}
};

#define READY()                                                                                                                \
	do                                                                                                                         \
	{                                                                                                                          \
		Error e = p->ready();                                                                                                  \
		if(e != Error::kOk)                                                                                                    \
			return status(e);                                                                                                  \
	} while(0)
#define DONE() return status(p->errors.error)

uint32_t zaj_runtime_create(zaj_runtime** out)
{
	*out = new zaj_runtime;
	return status(*out ? Error::kOk : Error::kOutOfMemory);
}

void zaj_runtime_destroy(zaj_runtime* rt)
{
	delete rt;
}

uint32_t zaj_runtime_add(zaj_runtime* rt, zaj_compiler* p, void** out)
{
	if(!p->finalized)
		return status(Error::kInvalidState);
	if(p->errors.error != Error::kOk)
		return status(p->errors.error);
	return status(rt->_add(out, &p->code));
}

uint32_t zaj_runtime_release(zaj_runtime* rt, void* fn)
{
	return status(rt->_release(fn));
}

uint32_t zaj_compiler_create(zaj_compiler** out, uint32_t width, uint32_t flags)
{
	*out = nullptr;
	auto p = new(std::nothrow) zaj_compiler;
	if(!p)
		return status(Error::kOutOfMemory);
	Error e = p->code.init(Environment::host(), CpuInfo::host().features());
	if(e == Error::kOk)
	{
		p->code.set_error_handler(&p->errors);
		if(flags & 1)
			p->code.set_logger(&p->logger);
		e = p->code.attach(&p->cc);
		if(e == Error::kOk && (flags & 2))
			p->cc.add_diagnostic_options(DiagnosticOptions::kValidateIntermediate);
	}
	if(e == Error::kOk)
	{
		p->u.emplace(&p->cc, CpuInfo::host().features(), CpuInfo::host().hints());
		p->max_vec_width = uint32_t(p->u->max_vec_width_from_cpu_features());
		if(width > p->max_vec_width)
			e = Error::kFeatureNotEnabled;
		else
			p->u->init_vec_width(ujit::VecWidth(width));
	}
	if(e != Error::kOk)
	{
		delete p;
		return status(e);
	}
	*out = p;
	return 0;
}

void zaj_compiler_destroy(zaj_compiler* p)
{
	delete p;
}

static FuncSignature signature(uint8_t ret, const uint8_t* args, size_t count)
{
	FuncSignature sig;
	sig.set_ret(TypeId(ret));
	for(size_t i = 0; i < count; i++)
		sig.add_arg(TypeId(args[i]));
	return sig;
}

uint32_t zaj_begin(zaj_compiler* p, uint8_t ret, const uint8_t* args, size_t count)
{
	Error e = p->ready(false);
	if(e != Error::kOk)
		return status(e);
	// One entry point per compiler; create another compiler for another function.
	if(p->started || count > Globals::kMaxFuncArgs)
		return status(Error::kInvalidState);
	FuncNode* fn = nullptr;
	e = p->cc.add_func_node(Out(fn), signature(ret, args, count));
	if(e != Error::kOk)
		return status(e);
	p->u->hook_func();
	p->started = true;
	DONE();
}

uint32_t zaj_end(zaj_compiler* p)
{
	READY();
	return status(p->u->end_func());
}

uint32_t zaj_finalize(zaj_compiler* p)
{
	Error e = p->ready(false);
	if(e != Error::kOk)
		return status(e);
	if(!p->started || p->cc.func())
		return status(Error::kInvalidState);
	// Mark even on failure: AsmJit's passes cannot safely be rerun after errors.
	p->finalized = true;
	e = p->u->finalize();
	if(e != Error::kOk)
		p->errors.error = e;
	DONE();
}

uint32_t zaj_new_reg(zaj_compiler* p, uint8_t type, zaj_operand* out)
{
	READY();
	if((type == uint8_t(TypeId::kInt32x8) && p->max_vec_width < 1) ||
	   (type == uint8_t(TypeId::kInt32x16) && p->max_vec_width < 2))
		return status(Error::kFeatureNotEnabled);
	Reg reg;
	Error e = p->cc._new_reg(Out(reg), TypeId(type));
	if(e != Error::kOk)
		return status(e);
	put(out, reg);
	DONE();
}

uint32_t zaj_set_arg(zaj_compiler* p, size_t index, const zaj_operand* reg)
{
	READY();
	if(index >= p->cc.func()->arg_count())
		return status(Error::kInvalidArgument);
	p->cc.func()->set_arg(index, get<Reg>(reg));
	DONE();
}

uint32_t zaj_ret(zaj_compiler* p, const zaj_operand* reg)
{
	READY();
	return status(reg ? p->u->ret(get<Reg>(reg)) : p->u->ret());
}

uint32_t zaj_label(zaj_compiler* p, zaj_operand* out)
{
	READY();
	put(out, p->u->new_label());
	DONE();
}

uint32_t zaj_bind(zaj_compiler* p, const zaj_operand* label)
{
	READY();
	return status(p->u->bind(get<Label>(label)));
}

uint32_t zaj_stack(zaj_compiler* p, uint32_t size, uint32_t alignment, zaj_operand* out)
{
	READY();
	if(!size || !alignment || (alignment & (alignment - 1)))
		return status(Error::kInvalidArgument);
	put(out, p->u->new_stack(size, alignment));
	DONE();
}

uint32_t zaj_const(zaj_compiler* p, const void* data, size_t size, zaj_operand* out)
{
	READY();
	if(!size)
		return status(Error::kInvalidArgument);
	put(out, p->cc.new_const(ConstPoolScope::kLocal, data, size));
	DONE();
}

void zaj_imm(uint64_t bits, zaj_operand* out)
{
	put(out, Imm(bits));
}

void zaj_mem(const zaj_operand* base, int32_t offset, zaj_operand* out)
{
#if defined(ASMJIT_UJIT_X86)
	put(out, x86::ptr(get<host::Gp>(base), offset));
#else
	put(out, a64::ptr(get<host::Gp>(base), offset));
#endif
}

void zaj_mem_offset(const zaj_operand* mem, int32_t offset, zaj_operand* out)
{
	auto m = get<host::Mem>(mem);
	m.add_offset(offset);
	put(out, m);
}

uint32_t zaj_mov(zaj_compiler* p, const zaj_operand* dst, const zaj_operand* src)
{
	READY();
	p->u->emit_mov(get<host::Gp>(dst), get(src));
	DONE();
}

uint32_t zaj_emit(zaj_compiler* p, uint32_t family, uint32_t op, const zaj_operand* a, uint32_t imm, uint32_t alignment)
{
	READY();
	switch(family)
	{
		case 0:
			p->u->emit_m(ujit::UniOpM(op), get<host::Mem>(a));
			break;
		case 1:
			p->u->emit_rm(ujit::UniOpRM(op), get<host::Gp>(a), get<host::Mem>(a + 1));
			break;
		case 2:
			p->u->emit_mr(ujit::UniOpMR(op), get<host::Mem>(a), get<host::Gp>(a + 1));
			break;
		case 3:
			p->u->emit_2i(ujit::UniOpRR(op), get<host::Gp>(a), get(a + 1));
			break;
		case 4:
			p->u->emit_3i(ujit::UniOpRRR(op), get<host::Gp>(a), get(a + 1), get(a + 2));
			break;
		case 5:
			p->u->emit_2vs(ujit::UniOpVR(op), get(a), get(a + 1), imm);
			break;
		case 6:
			p->u->emit_vm(ujit::UniOpVM(op), get<host::Vec>(a), get<host::Mem>(a + 1), ujit::Alignment(alignment), imm);
			break;
		case 7:
			p->u->emit_mv(ujit::UniOpMV(op), get<host::Mem>(a), get<host::Vec>(a + 1), ujit::Alignment(alignment), imm);
			break;
		case 8:
			p->u->emit_2v(ujit::UniOpVV(op), get(a), get(a + 1));
			break;
		case 9:
			p->u->emit_2vi(ujit::UniOpVVI(op), get(a), get(a + 1), imm);
			break;
		case 10:
			p->u->emit_3v(ujit::UniOpVVV(op), get(a), get(a + 1), get(a + 2));
			break;
		case 11:
			p->u->emit_3vi(ujit::UniOpVVVI(op), get(a), get(a + 1), get(a + 2), imm);
			break;
		case 12:
			p->u->emit_4v(ujit::UniOpVVVV(op), get(a), get(a + 1), get(a + 2), get(a + 3));
			break;
		default:
			return status(Error::kInvalidArgument);
	}
	DONE();
}

uint32_t zaj_jump(zaj_compiler* p, const zaj_operand* target)
{
	READY();
	p->u->emit_j(get(target));
	DONE();
}

uint32_t zaj_condition(zaj_compiler* p,
                       uint32_t action,
                       uint32_t op,
                       uint32_t cond,
                       const zaj_operand* a,
                       const zaj_operand* b,
                       const zaj_operand* dst,
                       const zaj_operand* x,
                       const zaj_operand* y)
{
	READY();
	// Architecture-independent comparison values in the public Zig API.
	static const host::CondCode codes[] = { host::CondCode::kEqual,      host::CondCode::kNotEqual,
		                                    host::CondCode::kSignedLT,   host::CondCode::kSignedLE,
		                                    host::CondCode::kSignedGT,   host::CondCode::kSignedGE,
		                                    host::CondCode::kUnsignedLT, host::CondCode::kUnsignedLE,
		                                    host::CondCode::kUnsignedGT, host::CondCode::kUnsignedGE };
	if(cond >= sizeof(codes) / sizeof(codes[0]))
		return status(Error::kInvalidArgument);
	ujit::UniCondition condition(ujit::UniOpCond(op), codes[cond], get(a), get(b));
	switch(action)
	{
		case 0:
			p->u->emit_j_if(get<Label>(dst), condition);
			break;
		case 1:
			p->u->emit_cmov(get<host::Gp>(dst), get(x), condition);
			break;
		case 2:
			p->u->emit_select(get<host::Gp>(dst), get(x), get(y), condition);
			break;
		default:
			return status(Error::kInvalidArgument);
	}
	DONE();
}

uint32_t zaj_call(zaj_compiler* p,
                  const zaj_operand* target,
                  uint8_t ret,
                  const uint8_t* types,
                  const zaj_operand* args,
                  size_t count,
                  const zaj_operand* result)
{
	READY();
	if(count > Globals::kMaxFuncArgs)
		return status(Error::kInvalidArgument);
	InvokeNode* node = nullptr;
	auto t = get(target);
	auto sig = signature(ret, types, count);
	Error e;
	if(t.is_reg())
		e = p->cc.invoke(Out(node), t.as<host::Gp>(), sig);
	else if(t.is_label())
		e = p->cc.invoke(Out(node), t.as<Label>(), sig);
	else if(t.is_imm())
		e = p->cc.invoke(Out(node), t.as<Imm>(), sig);
	else
		return status(Error::kInvalidOperandSize);
	if(e != Error::kOk)
		return status(e);
	for(size_t i = 0; i < count; i++)
	{
		auto a = get(args + i);
		if(a.is_reg())
			node->set_arg(i, a.as<Reg>());
		else if(a.is_imm())
			node->set_arg(i, a.as<Imm>());
		else
			return status(Error::kInvalidArgument);
	}
	if(result)
		node->set_ret(0, get<Reg>(result));
	DONE();
}

uint32_t zaj_native(zaj_compiler* p, uint32_t inst, const zaj_operand* a, size_t count)
{
	READY();
	if(!inst || !host::Inst::is_defined_id(inst))
		return status(p->cc.report_error(Error::kInvalidInstruction));
	if(count > Globals::kMaxOpCount)
		return status(Error::kInvalidArgument);
	Operand operands[Globals::kMaxOpCount];
	for(size_t i = 0; i < count; i++)
		operands[i] = get(a + i);
	return status(p->cc.emit_op_array(inst, operands, count));
}

const char* zaj_log(zaj_compiler* p, size_t* size)
{
	*size = p->logger.data_size();
	return p->logger.data();
}

size_t zaj_code_size(zaj_compiler* p)
{
	return p->code.code_size();
}
