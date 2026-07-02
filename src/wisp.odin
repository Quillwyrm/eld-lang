package main

import "core:fmt"
import "core:strconv"
import "core:strings"


// Value model ====================================================================================

ObjectKind :: enum u8 {
	STRING,
	SYMBOL,
	LIST,
	VECTOR,
	NATIVE_FUNCTION,
}

// Every heap object starts with this header so ^Object can dispatch by kind.
Object :: struct {
	kind: ObjectKind,
}

StringObject :: struct {
	header: Object,
	text:   string,
}

SymbolObject :: struct {
	header: Object,
	text:   string,
}

ListObject :: struct {
	header: Object,

	// Lists are immutable Wisp values. This storage is built once and is not
	// mutated by language operations.
	items: [dynamic]Value,
}

VectorObject :: struct {
	header: Object,
	items:  [dynamic]Value,
}

// The zero value of this union represents Wisp nil.
Value :: union {
	bool,
	i64,
	f64,
	^Object,
}

// args borrows a contiguous VM slot range for the duration of the call.
// Native procs must not retain the slice.
NativeProc :: proc(vm: ^VM, args: []Value) -> Value

NativeFunctionObject :: struct {
	header: Object,
	native: NativeProc,
}


// VM data ========================================================================================

Opcode :: enum u8 {
	LOAD_NIL,   // ABx: A=dst
	LOAD_TRUE,  // ABx: A=dst
	LOAD_FALSE, // ABx: A=dst
	LOAD_CONST, // ABx: A=dst, Bx=constant index

	MOVE, // ABC: A=dst, B=src

	GET_GLOBAL, // ABx: A=dst, Bx=global index

	ADD, // ABC: A=dst, B=first operand, C=operand count
	SUB, // ABC: A=dst, B=first operand, C=operand count
	MUL, // ABC: A=dst, B=first operand, C=operand count
	DIV, // ABC: A=dst, B=first operand, C=operand count

	CALL, // ABC: A=callee, B=argument count -> result replaces A; arguments start at A+1

	NEW_VECTOR,  // ABx: A=dst, Bx=initial capacity
	VECTOR_PUSH, // ABC: A=vector, B=value -> A remains the vector
	VECTOR_POP,  // ABC: A=dst, B=vector -> removed value goes to A
	SET_VECTOR,  // ABC: A=vector, B=index, C=value -> expression result remains in C

	RETURN, // ABx: A=src
}

InstABC :: bit_field u32 {
	op: Opcode | 8,
	a:  u8     | 8,
	b:  u8     | 8,
	c:  u8     | 8,
}

InstABx :: bit_field u32 {
	op: Opcode | 8,
	a:  u8     | 8,
	b:  u16    | 16,
}

Code :: struct {
	bytecode:         [dynamic]u32,
	constants:        [dynamic]Value,
	frame_slot_count: int,
}

GlobalBinding :: struct {
	symbol:  ^SymbolObject,
	value:   Value,
	mutable: bool,
}

Active_Code: Code

VM :: struct {
	slots:        [dynamic]Value,
	globals:      [dynamic]GlobalBinding,
	error_string: string,
}

// Public VM operations select one disposable Wisp world at a time.
Active_VM: ^VM


// Symbol interning ===============================================================================

Symbol_Table: [dynamic]^SymbolObject

// Symbols currently represent source atoms used as names.
// User-visible symbol values remain deferred.
// Equal symbol text always returns the same SymbolObject pointer.
intern_symbol :: proc(text: string) -> ^SymbolObject {
	for symbol in Symbol_Table {
		if symbol.text == text { return symbol }
	}

	symbol := new(SymbolObject)
	symbol.header.kind = .SYMBOL
	// Copy text because interned symbols outlive Reader.source.
	symbol.text = strings.clone(text)

	append(&Symbol_Table, symbol)
	return symbol
}


// Object construction ============================================================================

new_string_object :: proc(text: string) -> ^StringObject {
	object := new(StringObject)
	object.header.kind = .STRING
	// Copy text because the returned object may outlive Reader.source.
	object.text = strings.clone(text)
	return object
}

// Aggregate constructors take ownership of the dynamic item array.
new_list_object :: proc(items: [dynamic]Value) -> ^ListObject {
	object := new(ListObject)
	object.header.kind = .LIST
	object.items = items
	return object
}

new_vector_object :: proc(items: [dynamic]Value) -> ^VectorObject {
	object := new(VectorObject)
	object.header.kind = .VECTOR
	object.items = items
	return object
}


// Reader state ===================================================================================

// Reader is single-active; error_string latches failure until the next read_source.
// Values returned after failure are disposable placeholders that callers ignore.
Reader := struct {
	source: string,
	index: int,
	error_string: string,
}{}


// Reader errors ==================================================================================

reader_error :: proc(message: string) {
	Reader.error_string = fmt.tprintf("read error at byte %d: %s", Reader.index, message)
}


// Reader character utilities =====================================================================

is_digit :: proc(ch: u8) -> bool {
	return ch >= '0' && ch <= '9'
}

is_whitespace :: proc(ch: u8) -> bool {
	return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'
}

is_delimiter :: proc(ch: u8) -> bool {
	return is_whitespace(ch) ||
	       ch == '(' ||
	       ch == ')' ||
	       ch == '"' ||
	       ch == '\'' ||
	       ch == ';' ||
	       ch == '[' ||
	       ch == ']'
}

// Leaves Reader.index at the next form byte or the end of source.
skip_trivia :: proc() {
	for Reader.index < len(Reader.source) {
		ch := Reader.source[Reader.index]

		if is_whitespace(ch) {
			Reader.index += 1
			continue
		}

		if ch == ';' {
			for Reader.index < len(Reader.source) && Reader.source[Reader.index] != '\n' {
				Reader.index += 1
			}
			continue
		}

		break
	}
}


// Reader scans ===================================================================================

read_atom :: proc() -> Value {
	// The caller positions Reader.index at the first byte of an atom.
	token_start := Reader.index

	// Stop before the delimiter so the enclosing reader can consume it.
	for Reader.index < len(Reader.source) && !is_delimiter(Reader.source[Reader.index]) {
		Reader.index += 1
	}

	text := Reader.source[token_start:Reader.index]
	if text == "nil" { return Value{} }
	if text == "true" { return Value(bool(true)) }
	if text == "false" { return Value(bool(false)) }

	// Numeric-looking atoms start with a digit, .digit, -digit, or - followed by a dot.
	looks_numeric :=
		is_digit(text[0]) ||
		(len(text) > 1 && text[0] == '.' && is_digit(text[1])) ||
		(len(text) > 1 && text[0] == '-' &&
			(is_digit(text[1]) || text[1] == '.'))

	// Malformed numeric-looking atoms are errors; other atoms become symbols.
	if looks_numeric {
		number_index := 0
		is_negative := false

		if text[number_index] == '-' {
			is_negative = true
			number_index += 1
		}

		// Scan decimal digits on either side of an optional decimal point.
		digit_count := 0
		for number_index < len(text) && is_digit(text[number_index]) {
			digit_count += 1
			number_index += 1
		}

		is_float := number_index < len(text) && text[number_index] == '.'
		if is_float {
			number_index += 1

			for number_index < len(text) && is_digit(text[number_index]) {
				digit_count += 1
				number_index += 1
			}
		}

		// Valid numbers contain a digit and consume the entire atom.
		if digit_count == 0 || number_index != len(text) {
			reader_error("invalid number literal")
			return Value{}
		}

		// Odin converts the value only after Wisp accepts its spelling.
		if is_float {
			float_value, float_ok := strconv.parse_f64(text)
			if !float_ok {
				reader_error("float literal out of range")
				return Value{}
			}

			return Value(float_value)
		}

		// Unsigned magnitude handles the extra negative i64 value without overflow.
		magnitude_limit := u64(max(i64))
		if is_negative {
			magnitude_limit += 1
		}

		magnitude: u64
		digit_index := 1 if is_negative else 0

		for digit_index < len(text) {
			digit := u64(text[digit_index] - '0')

			if magnitude > (magnitude_limit - digit) / 10 {
				reader_error("integer literal out of range")
				return Value{}
			}

			magnitude = magnitude * 10 + digit
			digit_index += 1
		}

		if is_negative {
			if magnitude == magnitude_limit { return Value(min(i64)) }
			return Value(-i64(magnitude))
		}

		return Value(i64(magnitude))
	}

	return Value(cast(^Object)intern_symbol(text))
}

read_string :: proc() -> Value {
	// current char is '"'
	Reader.index += 1
	start := Reader.index

	for Reader.index < len(Reader.source) {
		ch := Reader.source[Reader.index]

		if ch == '\n' || ch == '\r' {
			reader_error("unterminated string")
			return Value{}
		}

		if ch == '\\' {
			reader_error("string escapes not implemented")
			return Value{}
		}

		if ch == '"' {
			text := Reader.source[start:Reader.index]
			Reader.index += 1
			return Value(cast(^Object)new_string_object(text))
		}

		Reader.index += 1
	}

	reader_error("unterminated string")
	return Value{}
}

read_list :: proc() -> Value {
	// current char is '('
	Reader.index += 1

	// Build locally; the ListObject takes ownership only after the closing ')'.
	items := make([dynamic]Value)

	for {
		skip_trivia()

		if Reader.index >= len(Reader.source) {
			reader_error("unterminated list")
			delete(items)
			return Value{}
		}

		if Reader.source[Reader.index] == ')' {
			Reader.index += 1
			return Value(cast(^Object)new_list_object(items))
		}

		item := read_form()
		if Reader.error_string != "" {
			delete(items)
			return Value{}
		}

		append(&items, item)
	}
}

read_vector :: proc() -> Value {
	// current char is '['
	Reader.index += 1

	// Build locally; the VectorObject takes ownership only after the closing ']'.
	items := make([dynamic]Value)

	for {
		skip_trivia()

		if Reader.index >= len(Reader.source) {
			reader_error("unterminated vector")
			delete(items)
			return Value{}
		}

		if Reader.source[Reader.index] == ']' {
			Reader.index += 1
			return Value(cast(^Object)new_vector_object(items))
		}

		item := read_form()
		if Reader.error_string != "" {
			delete(items)
			return Value{}
		}

		append(&items, item)
	}
}

read_form :: proc() -> Value {
	// Whitespace is already skipped; this proc only dispatches the current form.
	ch := Reader.source[Reader.index]

	switch ch {
	case '(':
		return read_list()

	case ')':
		reader_error("unexpected ')'")
		return Value{}

	case '"':
		return read_string()

	case '\'':
		reader_error("quote not implemented")
		return Value{}

	case '[':
		return read_vector()

	case ']':
		reader_error("unexpected ']'")
		return Value{}

	case:
		return read_atom()
	}
}

read_all_forms :: proc() -> [dynamic]Value {
	// This loop owns whitespace between top-level forms.
	forms := make([dynamic]Value)

	for {
		skip_trivia()

		if Reader.index >= len(Reader.source) {
			break
		}

		form := read_form()
		if Reader.error_string != "" {
			return forms
		}

		append(&forms, form)
	}

	return forms
}

read_source :: proc(source: string) -> ([dynamic]Value, string) {
	// Reset the singleton reader for one complete source operation.
	Reader.source = source
	Reader.index = 0
	Reader.error_string = ""

	forms := read_all_forms()
	if Reader.error_string != "" {
		delete(forms)
		return nil, Reader.error_string
	}

	return forms, ""
}


// Debug tree printer =============================================================================

// Each entry says whether that ancestor has another sibling below it.
debug_print_value_tree :: proc(value: Value, continuations: ^[dynamic]bool) {
	for i := 0; i + 1 < len(continuations); i += 1 {
		if continuations[i] {
			fmt.print("│  ")
		} else {
			fmt.print("   ")
		}
	}

	if len(continuations) > 0 {
		if continuations[len(continuations) - 1] {
			fmt.print("├─ ")
		} else {
			fmt.print("└─ ")
		}
	}

	if value == nil {
		fmt.println("Nil")
		return
	}

	switch v in value {
	case bool:
		fmt.printf("Bool(%v)\n", v)

	case i64:
		fmt.printf("Int(%d)\n", v)

	case f64:
		fmt.printf("Float(%.15g)\n", v)

	case ^Object:
		switch v.kind {
		case .STRING:
			object := cast(^StringObject)v
			fmt.printf("String(\"%s\")\n", object.text)

		case .SYMBOL:
			object := cast(^SymbolObject)v
			fmt.printf("Symbol(`%s`)\n", object.text)

		case .LIST:
			object := cast(^ListObject)v
			fmt.printf("List(%d)\n", len(object.items))

			for i := 0; i < len(object.items); i += 1 {
				append(continuations, i + 1 < len(object.items))
				debug_print_value_tree(object.items[i], continuations)
				pop(continuations)
			}

		case .VECTOR:
			object := cast(^VectorObject)v
			fmt.printf("Vector(%d)\n", len(object.items))

			for i := 0; i < len(object.items); i += 1 {
				append(continuations, i + 1 < len(object.items))
				debug_print_value_tree(object.items[i], continuations)
				pop(continuations)
			}

		case .NATIVE_FUNCTION:
			assert(false, "function in source tree")
		}
	}
}

debug_print_source_tree :: proc(forms: [dynamic]Value) {
	continuations := make([dynamic]bool)

	for i := 0; i < len(forms); i += 1 {
		debug_print_value_tree(forms[i], &continuations)

		if i + 1 < len(forms) {
			fmt.println()
		}
	}

	delete(continuations)
}


// Runtime display ================================================================================

// parents contains only composite objects currently above this value.
print_value_inner :: proc(value: Value, parents: ^[dynamic]^Object) {
	if value == nil {
		fmt.print("nil")
		return
	}

	switch v in value {
	case bool:
		fmt.print(v)

	case i64:
		fmt.print(v)

	case f64:
		text := fmt.tprintf("%.15g", v)
		fmt.print(text)

		whole_number_text := true
		for i := 0; i < len(text); i += 1 {
			if i == 0 && text[i] == '-' {
				continue
			}
			if !is_digit(text[i]) {
				whole_number_text = false
				break
			}
		}

		if whole_number_text {
			fmt.print(".0")
		}

	case ^Object:
		switch v.kind {
		case .STRING:
			object := cast(^StringObject)v
			fmt.print(object.text)

		case .SYMBOL:
			object := cast(^SymbolObject)v
			fmt.printf("<symbol %s>", object.text)

		case .LIST:
			for parent in parents {
				if parent == v {
					fmt.print("(...)")
					return
				}
			}
			append(parents, v)

			object := cast(^ListObject)v
			fmt.print("(")
			for i := 0; i < len(object.items); i += 1 {
				if i > 0 {
					fmt.print(" ")
				}
				print_value_inner(object.items[i], parents)
			}
			fmt.print(")")

			pop(parents)

		case .VECTOR:
			for parent in parents {
				if parent == v {
					fmt.print("[...]")
					return
				}
			}
			append(parents, v)

			object := cast(^VectorObject)v
			fmt.print("[")
			for i := 0; i < len(object.items); i += 1 {
				if i > 0 {
					fmt.print(" ")
				}
				print_value_inner(object.items[i], parents)
			}
			fmt.print("]")

			pop(parents)

		case .NATIVE_FUNCTION:
			fmt.print("<function>")

		case:
			assert(false, "invalid object tag")
		}
	}
}

print_value :: proc(value: Value) {
	parents := make([dynamic]^Object)
	print_value_inner(value, &parents)
	delete(parents)
}


// Runtime errors =================================================================================

runtime_error :: proc(message: string) {
	Active_VM.error_string = fmt.tprintf("runtime error: %s", message)
}


// Globals ========================================================================================

find_global :: proc(vm: ^VM, symbol: ^SymbolObject) -> (int, bool) {
	for i := 0; i < len(vm.globals); i += 1 {
		if vm.globals[i].symbol == symbol {
			return i, true
		}
	}

	return -1, false
}

// Supplied native globals are immutable but may be shadowed by user bindings.
bind_native_global :: proc(vm: ^VM, name: string, native: NativeProc) -> int {
	symbol := intern_symbol(name)
	_, found := find_global(vm, symbol)
	assert(!found, "duplicate supplied global binding")

	function := new(NativeFunctionObject)
	function.header.kind = .NATIVE_FUNCTION
	function.native = native

	append(&vm.globals, GlobalBinding{
		symbol  = symbol,
		value   = Value(cast(^Object)function),
		mutable = false,
	})
	return len(vm.globals) - 1
}


// Code construction ==============================================================================

begin_code :: proc() {
	Active_Code = Code{
		bytecode         = make([dynamic]u32),
		constants        = make([dynamic]Value),
		frame_slot_count = 0,
	}
}

// The returned Code takes ownership of the active dynamic arrays.
end_code :: proc() -> Code {
	code := Active_Code
	Active_Code = Code{}
	return code
}


// Constants ======================================================================================

const_value :: proc(value: Value) -> int {
	append(&Active_Code.constants, value)
	return len(Active_Code.constants) - 1
}

const_int :: proc(value: i64) -> int {
	return const_value(Value(value))
}

const_float :: proc(value: f64) -> int {
	return const_value(Value(value))
}

const_string :: proc(text: string) -> int {
	return const_value(Value(cast(^Object)new_string_object(text)))
}


// Bytecode emission ==============================================================================

// frame_slot_count is the highest touched frame slot plus one.
record_slots :: proc(slots: ..int) {
	for slot in slots {
		assert(slot >= 0 && slot <= int(max(u8)), "frame slot does not fit u8")

		needed_slot_count := slot + 1
		if needed_slot_count > Active_Code.frame_slot_count {
			Active_Code.frame_slot_count = needed_slot_count
		}
	}
}

emit_ABC :: proc(op: Opcode, a, b, c: int) {
	append(&Active_Code.bytecode, u32(InstABC{
		op = op,
		a  = u8(a),
		b  = u8(b),
		c  = u8(c),
	}))
}

emit_ABx :: proc(op: Opcode, a, b: int) {
	append(&Active_Code.bytecode, u32(InstABx{
		op = op,
		a  = u8(a),
		b  = u16(b),
	}))
}

emit_load_nil :: proc(dst: int) {
	record_slots(dst)
	emit_ABx(.LOAD_NIL, dst, 0)
}

emit_load_true :: proc(dst: int) {
	record_slots(dst)
	emit_ABx(.LOAD_TRUE, dst, 0)
}

emit_load_false :: proc(dst: int) {
	record_slots(dst)
	emit_ABx(.LOAD_FALSE, dst, 0)
}

emit_load_const :: proc(dst, constant_index: int) {
	record_slots(dst)
	emit_ABx(.LOAD_CONST, dst, constant_index)
}

emit_move :: proc(dst, src: int) {
	record_slots(dst, src)
	emit_ABC(.MOVE, dst, src, 0)
}

emit_get_global :: proc(dst, global_index: int) {
	record_slots(dst)
	emit_ABx(.GET_GLOBAL, dst, global_index)
}

emit_add :: proc(dst, first_slot, count: int) {
	assert(count >= 2 && count <= int(max(u8)), "ADD argument count does not fit u8")
	record_slots(dst, first_slot, first_slot + count - 1)
	emit_ABC(.ADD, dst, first_slot, count)
}

emit_sub :: proc(dst, first_slot, count: int) {
	assert(count >= 2 && count <= int(max(u8)), "SUB argument count does not fit u8")
	record_slots(dst, first_slot, first_slot + count - 1)
	emit_ABC(.SUB, dst, first_slot, count)
}

emit_mul :: proc(dst, first_slot, count: int) {
	assert(count >= 2 && count <= int(max(u8)), "MUL argument count does not fit u8")
	record_slots(dst, first_slot, first_slot + count - 1)
	emit_ABC(.MUL, dst, first_slot, count)
}

emit_div :: proc(dst, first_slot, count: int) {
	assert(count >= 2 && count <= int(max(u8)), "DIV argument count does not fit u8")
	record_slots(dst, first_slot, first_slot + count - 1)
	emit_ABC(.DIV, dst, first_slot, count)
}

emit_call :: proc(base, argument_count: int) {
	assert(argument_count >= 0 && argument_count <= int(max(u8)), "call argument count does not fit u8")

	record_slots(base)
	if argument_count > 0 {
		record_slots(base + argument_count)
	}
	emit_ABC(.CALL, base, argument_count, 0)
}

emit_new_vector :: proc(dst, capacity: int) {
	assert(capacity >= 0 && capacity <= int(max(u16)), "vector capacity does not fit u16")
	record_slots(dst)
	emit_ABx(.NEW_VECTOR, dst, capacity)
}

emit_vector_push :: proc(vector_slot, value_slot: int) {
	record_slots(vector_slot, value_slot)
	emit_ABC(.VECTOR_PUSH, vector_slot, value_slot, 0)
}

emit_vector_pop :: proc(dst, vector_slot: int) {
	record_slots(dst, vector_slot)
	emit_ABC(.VECTOR_POP, dst, vector_slot, 0)
}

emit_set_vector :: proc(vector_slot, index_slot, value_slot: int) {
	record_slots(vector_slot, index_slot, value_slot)
	emit_ABC(.SET_VECTOR, vector_slot, index_slot, value_slot)
}

emit_return :: proc(src: int) {
	record_slots(src)
	emit_ABx(.RETURN, src, 0)
}


// Core operations ================================================================================

core_add :: proc(args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("+ expects two or more arguments")
		return Value{}
	}

	all_int := true
	int_result: i64
	float_result: f64

	for arg in args {
		int_value, is_int := arg.(i64)
		if is_int {
			if all_int {
				int_result += int_value
			} else {
				float_result += f64(int_value)
			}
			continue
		}

		float_value, is_float := arg.(f64)
		if is_float {
			if all_int {
				float_result = f64(int_result)
				all_int = false
			}
			float_result += float_value
			continue
		}

		runtime_error("+ expects numbers")
		return Value{}
	}

	if all_int {
		return Value(int_result)
	}
	return Value(float_result)
}

core_sub :: proc(args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("- expects two or more arguments")
		return Value{}
	}

	int_result, first_is_int := args[0].(i64)
	float_result, first_is_float := args[0].(f64)
	if !first_is_int && !first_is_float {
		runtime_error("- expects numbers")
		return Value{}
	}

	all_int := first_is_int

	for i := 1; i < len(args); i += 1 {
		int_value, is_int := args[i].(i64)
		if is_int {
			if all_int {
				int_result -= int_value
			} else {
				float_result -= f64(int_value)
			}
			continue
		}

		float_value, is_float := args[i].(f64)
		if is_float {
			if all_int {
				float_result = f64(int_result)
				all_int = false
			}
			float_result -= float_value
			continue
		}

		runtime_error("- expects numbers")
		return Value{}
	}

	if all_int {
		return Value(int_result)
	}
	return Value(float_result)
}

core_mul :: proc(args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("* expects two or more arguments")
		return Value{}
	}

	all_int := true
	int_result: i64 = 1
	float_result: f64 = 1

	for arg in args {
		int_value, is_int := arg.(i64)
		if is_int {
			if all_int {
				int_result *= int_value
			} else {
				float_result *= f64(int_value)
			}
			continue
		}

		float_value, is_float := arg.(f64)
		if is_float {
			if all_int {
				float_result = f64(int_result)
				all_int = false
			}
			float_result *= float_value
			continue
		}

		runtime_error("* expects numbers")
		return Value{}
	}

	if all_int {
		return Value(int_result)
	}
	return Value(float_result)
}

core_div :: proc(args: []Value) -> Value {
	if len(args) < 2 {
		runtime_error("/ expects two or more arguments")
		return Value{}
	}

	int_value, first_is_int := args[0].(i64)
	float_result, first_is_float := args[0].(f64)
	if first_is_int {
		float_result = f64(int_value)
	} else if !first_is_float {
		runtime_error("/ expects numbers")
		return Value{}
	}

	for i := 1; i < len(args); i += 1 {
		int_divisor, is_int := args[i].(i64)
		if is_int {
			if int_divisor == 0 {
				runtime_error("/ divisor cannot be zero")
				return Value{}
			}

			float_result /= f64(int_divisor)
			continue
		}

		float_divisor, is_float := args[i].(f64)
		if is_float {
			if float_divisor == 0 {
				runtime_error("/ divisor cannot be zero")
				return Value{}
			}

			float_result /= float_divisor
			continue
		}

		runtime_error("/ expects numbers")
		return Value{}
	}

	return Value(float_result)
}


// Native builtins ================================================================================

native_print :: proc(vm: ^VM, args: []Value) -> Value {
	if len(args) != 1 {
		runtime_error("print expects one argument")
		return Value{}
	}

	print_value(args[0])
	fmt.println()
	return Value{}
}


// VM execution ===================================================================================

run_code :: proc(vm: ^VM, code: ^Code) -> (Value, string) {
	Active_VM = vm

	delete(vm.slots)
	vm.slots = make([dynamic]Value, code.frame_slot_count)
	vm.error_string = ""

	ip := 0

	for {
		assert(ip < len(code.bytecode), "code ended without RETURN")

		word := code.bytecode[ip]
		ip += 1

		op := InstABC(word).op

		switch op {
		case .LOAD_NIL:
			inst := InstABx(word)
			vm.slots[int(inst.a)] = Value{}

		case .LOAD_TRUE:
			inst := InstABx(word)
			vm.slots[int(inst.a)] = Value(bool(true))

		case .LOAD_FALSE:
			inst := InstABx(word)
			vm.slots[int(inst.a)] = Value(bool(false))

		case .LOAD_CONST:
			inst := InstABx(word)
			constant_index := int(inst.b)
			assert(constant_index < len(code.constants), "constant index out of range")
			vm.slots[int(inst.a)] = code.constants[constant_index]

		case .MOVE:
			inst := InstABC(word)
			vm.slots[int(inst.a)] = vm.slots[int(inst.b)]

		case .GET_GLOBAL:
			inst := InstABx(word)
			global_index := int(inst.b)
			assert(global_index < len(vm.globals), "global index out of range")
			vm.slots[int(inst.a)] = vm.globals[global_index].value

		case .ADD, .SUB, .MUL, .DIV:
			inst := InstABC(word)
			dst := int(inst.a)
			first_slot := int(inst.b)
			argument_count := int(inst.c)
			args := vm.slots[first_slot:first_slot + argument_count]

			result: Value
			#partial switch op {
			case .ADD:
				result = core_add(args)
			case .SUB:
				result = core_sub(args)
			case .MUL:
				result = core_mul(args)
			case .DIV:
				result = core_div(args)
			}

			if vm.error_string != "" {
				return Value{}, vm.error_string
			}
			vm.slots[dst] = result

		case .CALL:
			inst := InstABC(word)
			base := int(inst.a)
			argument_count := int(inst.b)
			callee := vm.slots[base]

			callee_object, callee_is_object := callee.(^Object)
			if !callee_is_object {
				runtime_error("value is not callable")
				return Value{}, vm.error_string
			}

			args := vm.slots[base + 1:base + 1 + argument_count]

			switch callee_object.kind {
			case .NATIVE_FUNCTION:
				function := cast(^NativeFunctionObject)callee_object

				result := function.native(vm, args)
				if vm.error_string != "" {
					return Value{}, vm.error_string
				}

				vm.slots[base] = result

			case .VECTOR:
				if argument_count != 1 {
					runtime_error("vector call expects one index")
					return Value{}, vm.error_string
				}

				index, index_is_int := vm.slots[base + 1].(i64)
				if !index_is_int {
					runtime_error("vector index must be int")
					return Value{}, vm.error_string
				}

				vector := cast(^VectorObject)callee_object
				if index < 0 || index >= i64(len(vector.items)) {
					runtime_error("vector index out of range")
					return Value{}, vm.error_string
				}

				vm.slots[base] = vector.items[int(index)]

			case .STRING, .SYMBOL, .LIST:
				runtime_error("value is not callable")
				return Value{}, vm.error_string
			}

		case .NEW_VECTOR:
			inst := InstABx(word)
			dst := int(inst.a)
			capacity := int(inst.b)

			items := make([dynamic]Value)
			if capacity > 0 {
				reserve(&items, capacity)
			}

			vm.slots[dst] = Value(cast(^Object)new_vector_object(items))

		case .VECTOR_PUSH:
			inst := InstABC(word)
			vector_value := vm.slots[int(inst.a)]

			vector_object, vector_is_object := vector_value.(^Object)
			if !vector_is_object || vector_object.kind != .VECTOR {
				runtime_error("vector push receiver must be vector")
				return Value{}, vm.error_string
			}

			vector := cast(^VectorObject)vector_object
			append(&vector.items, vm.slots[int(inst.b)])

		case .VECTOR_POP:
			inst := InstABC(word)
			vector_value := vm.slots[int(inst.b)]

			vector_object, vector_is_object := vector_value.(^Object)
			if !vector_is_object || vector_object.kind != .VECTOR {
				runtime_error("vector pop receiver must be vector")
				return Value{}, vm.error_string
			}

			vector := cast(^VectorObject)vector_object
			if len(vector.items) == 0 {
				runtime_error("cannot pop empty vector")
				return Value{}, vm.error_string
			}

			vm.slots[int(inst.a)] = pop(&vector.items)

		case .SET_VECTOR:
			inst := InstABC(word)
			vector_value := vm.slots[int(inst.a)]
			index_value := vm.slots[int(inst.b)]
			new_value := vm.slots[int(inst.c)]

			vector_object, vector_is_object := vector_value.(^Object)
			if !vector_is_object || vector_object.kind != .VECTOR {
				runtime_error("vector set receiver must be vector")
				return Value{}, vm.error_string
			}

			index, index_is_int := index_value.(i64)
			if !index_is_int {
				runtime_error("vector set index must be int")
				return Value{}, vm.error_string
			}

			vector := cast(^VectorObject)vector_object
			if index < 0 || index >= i64(len(vector.items)) {
				runtime_error("vector index out of range")
				return Value{}, vm.error_string
			}

			vector.items[int(index)] = new_value

		case .RETURN:
			inst := InstABx(word)
			return vm.slots[int(inst.a)], ""

		case:
			assert(false, "invalid opcode")
		}
	}
}


