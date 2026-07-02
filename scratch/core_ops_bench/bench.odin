package main

import "core:fmt"
import "core:time"

// Design probe only. The callable CoreFunction model was evaluated and rejected.
// Wisp core operations now use direct opcodes and are not runtime values.
//
// The direct path executes ADD + LOOP per iteration.
// Both call paths execute MOVE + CALL + MOVE + LOOP per iteration.
// The callable is already stored in slot 0, so this measures call/dispatch cost
// without adding global lookup. Every path uses the same core_add operation.


Value :: union {
	i64,
	^Object,
}

ObjectKind :: enum u8 {
	CORE_FUNCTION,
	NATIVE_FUNCTION,
}

Object :: struct {
	kind: ObjectKind,
}

CoreOp :: enum u8 {
	ADD,
}

CoreFunctionObject :: struct {
	header: Object,
	op:     CoreOp,
}

NativeProc :: proc(vm: ^VM, args: []Value) -> Value

NativeFunctionObject :: struct {
	header: Object,
	native: NativeProc,
}


Opcode :: enum u8 {
	ADD,
	MOVE,
	CALL,
	LOOP,
	RETURN,
}

InstABC :: bit_field u32 {
	op: Opcode | 8,
	a:  u8     | 8,
	b:  u8     | 8,
	c:  u8     | 8,
}

VM :: struct {
	slots: [8]Value,
}


core_add :: proc(args: []Value) -> Value {
	result, result_is_int := args[0].(i64)
	if !result_is_int {
		return Value{}
	}

	for i := 1; i < len(args); i += 1 {
		value, value_is_int := args[i].(i64)
		if !value_is_int {
			return Value{}
		}

		result += value
	}

	return Value(result)
}

native_add :: proc(vm: ^VM, args: []Value) -> Value {
	return core_add(args)
}


run_code :: proc(code: []u32, callee: Value, iteration_count: i64) -> Value {
	vm: VM
	vm.slots[0] = callee
	vm.slots[2] = Value(i64(1))
	vm.slots[3] = Value(i64(1))
	vm.slots[4] = Value(iteration_count)

	ip := 0

	for {
		word := code[ip]
		ip += 1

		switch InstABC(word).op {
		case .ADD:
			inst := InstABC(word)
			dst := int(inst.a)
			first := int(inst.b)
			count := int(inst.c)
			vm.slots[dst] = core_add(vm.slots[first:first + count])

		case .MOVE:
			inst := InstABC(word)
			vm.slots[int(inst.a)] = vm.slots[int(inst.b)]

		case .CALL:
			inst := InstABC(word)
			base := int(inst.a)
			arg_count := int(inst.b)

			header, is_object := vm.slots[base].(^Object)
			if !is_object {
				return Value{}
			}

			args := vm.slots[base + 1:base + 1 + arg_count]

			switch header.kind {
			case .CORE_FUNCTION:
				function := cast(^CoreFunctionObject)header

				switch function.op {
				case .ADD:
					vm.slots[base] = core_add(args)
				}

			case .NATIVE_FUNCTION:
				function := cast(^NativeFunctionObject)header
				vm.slots[base] = function.native(&vm, args)
			}

		case .LOOP:
			inst := InstABC(word)
			counter_slot := int(inst.a)
			counter, counter_is_int := vm.slots[counter_slot].(i64)
			if !counter_is_int {
				return Value{}
			}

			counter -= 1
			vm.slots[counter_slot] = Value(counter)
			if counter > 0 {
				ip = 0
			}

		case .RETURN:
			inst := InstABC(word)
			return vm.slots[int(inst.a)]
		}
	}
}


Sink: i64

measure :: proc(
	label:           string,
	code:            []u32,
	callee:          Value,
	iteration_count: i64,
) -> f64 {
	start := time.tick_now()
	result := run_code(code, callee, iteration_count)
	elapsed := time.tick_since(start)

	result_int, result_is_int := result.(i64)
	assert(result_is_int)
	Sink += result_int

	ns_per_operation :=
		time.duration_seconds(elapsed) * 1e9 /
		f64(iteration_count)

	fmt.printf("%s: %.3f ns/op\n", label, ns_per_operation)
	return ns_per_operation
}


main :: proc() {
	direct_code := [?]u32{
		u32(InstABC{op = .ADD, a = 2, b = 2, c = 2}),
		u32(InstABC{op = .LOOP, a = 4}),
		u32(InstABC{op = .RETURN, a = 2}),
	}

	call_code := [?]u32{
		u32(InstABC{op = .MOVE, a = 1, b = 0}),
		u32(InstABC{op = .CALL, a = 1, b = 2}),
		u32(InstABC{op = .MOVE, a = 2, b = 1}),
		u32(InstABC{op = .LOOP, a = 4}),
		u32(InstABC{op = .RETURN, a = 2}),
	}

	core_function := new(CoreFunctionObject)
	core_function.header.kind = .CORE_FUNCTION
	core_function.op = .ADD
	core_value := Value(cast(^Object)core_function)

	native_function := new(NativeFunctionObject)
	native_function.header.kind = .NATIVE_FUNCTION
	native_function.native = native_add
	native_value := Value(cast(^Object)native_function)

	warmup_count: i64 = 1_000_000
	_ = run_code(direct_code[:], Value{}, warmup_count)
	_ = run_code(call_code[:], core_value, warmup_count)
	_ = run_code(call_code[:], native_value, warmup_count)

	iteration_count: i64 = 20_000_000
	sample_count := 9
	totals: [3]f64

	fmt.printf("%d operations per sample\n\n", iteration_count)

	for sample := 0; sample < sample_count; sample += 1 {
		fmt.printf("sample %d\n", sample + 1)

		switch sample % 3 {
		case 0:
			totals[0] += measure("direct ADD opcode", direct_code[:], Value{}, iteration_count)
			totals[1] += measure("CoreFunction CALL", call_code[:], core_value, iteration_count)
			totals[2] += measure("NativeFunction CALL", call_code[:], native_value, iteration_count)

		case 1:
			totals[1] += measure("CoreFunction CALL", call_code[:], core_value, iteration_count)
			totals[2] += measure("NativeFunction CALL", call_code[:], native_value, iteration_count)
			totals[0] += measure("direct ADD opcode", direct_code[:], Value{}, iteration_count)

		case 2:
			totals[2] += measure("NativeFunction CALL", call_code[:], native_value, iteration_count)
			totals[0] += measure("direct ADD opcode", direct_code[:], Value{}, iteration_count)
			totals[1] += measure("CoreFunction CALL", call_code[:], core_value, iteration_count)
		}

		fmt.println()
	}

	fmt.println("average")
	fmt.printf("direct ADD opcode: %.3f ns/op\n", totals[0] / f64(sample_count))
	fmt.printf("CoreFunction CALL: %.3f ns/op\n", totals[1] / f64(sample_count))
	fmt.printf("NativeFunction CALL: %.3f ns/op\n", totals[2] / f64(sample_count))
	fmt.printf("\nchecksum: %d\n", Sink)
}
