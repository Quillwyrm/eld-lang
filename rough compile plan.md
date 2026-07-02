Yeah — for the **first compiler pass**, walking the reader tree to bytecode should be pretty easy.

Not “language implementation is easy,” but this specific Wisp compiler boundary is much easier than Kiln’s parse-lower path because the reader already solved the annoying syntax nesting. Your compiler starts from actual tree values:

```text
top-level forms: []Value
list form:       ^ListObject.items
vector literal:  ^VectorObject.items
name:            ^SymbolObject
literal:         nil/bool/int/float/string
```

So the compiler is basically a semantic tree walker.

The important thing: **do not invent an AST yet.** Your reader value tree is the syntax tree for now.

## Why this should be simpler than Kiln

Kiln had to do this all at once:

```text
token stream
precedence parsing
statement parsing
expression parsing
scope tracking
bytecode lowering
```

Wisp already has the structure:

```scheme
(print (+ 1 2))
```

is already:

```text
List[
  Symbol("print"),
  List[
    Symbol("+"),
    Int(1),
    Int(2),
  ],
]
```

So the compiler can just pattern-match.

That is exactly where Lisp shape pays off.

## No source locations is fine for now

I agree with deferring source-location metadata.

For Wisp right now, these are good enough:

```text
compile error: undefined name `x`
compile error: `def` expects a name and value
compile error: `+` expects two or more operands
compile error: `def` is not valid in expression position
compile error: empty list is not an expression
compile error: cannot set immutable binding `print`
```

That is descriptive enough while the language is small. You can add source spans later when pain becomes real.

The tree debug printer already gives you structure. That’s enough while the compiler is forming.

## Current source is in a good shape for this

The source already has the right split:

```text
reader -> Value tree
emitters -> bytecode
VM -> runs Code
```

The current ref also fits this compiler shape: definitions are only valid at file top level or directly inside bodies, bodies are ordered, and list forms decide between special forms, ordinary calls, and core operations. 

That means the compiler can be very direct:

```odin
compile_expr(value, dst)
compile_definition(list)
compile_body(forms, dst)
compile_list_expr(list, dst)
compile_vector_expr(vector, dst)
compile_name_expr(symbol, dst)
```

No parser objects. No visitor system. No AST taxonomy.

## The first compiler subset I’d target

Compile the exact style your hand-built smoke already represents:

```scheme
(def label "dog")
(def values [10 20 30])
(def output print)

(set (values 1)
  (+ (values 0) (values 2)))

(print label)
(print (push values 50))
(print (pop values))
(print values)
(print (values 1))
(print [nil true false 2.5])
(print (+ 1 2.5 3))
(print (- 20 3 2))
(print (* 2 3 4))
(print (/ 20 2 5))
(output "saved native function")
```

That requires only:

```text
literal expressions
name reads
top-level def
vector literals
ordinary calls
native print call
vector calls
indexed set
primitive arithmetic
primitive push/pop
```

No `if`.

No `while`.

No `fn`.

No closures.

No modules.

That is a really good first compiler target because it replaces the hand-built bytecode one-for-one.

## Minimal compiler state

I’d start with one package-level compiler singleton, matching your current reader/code style:

```odin
Compiler :: struct {
	error_string: string

	scopes: [dynamic]Scope
	next_slot: int
}

Scope :: struct {
	bindings: [dynamic]Binding
}

Binding :: struct {
	symbol:  ^SymbolObject
	slot:    int
	mutable: bool
}
```

For now, top-level file bindings can just be slots in the entry frame. That is enough until `fn`/closures force binding cells.

This is not dishonest. Non-captured lexical bindings really are slots. Later closure-captured bindings can become cells only when `fn` earns them.

## Ordered `def`

For normal value def:

```scheme
(def x expr)
```

compile as:

```text
1. validate syntax
2. check same-scope duplicate
3. allocate slot for x, but do not make it visible yet
4. compile expr into that slot
5. append binding x -> slot to current scope
```

That preserves this rule:

```scheme
(def x x)
; error unless outer x exists
```

because the new `x` is not visible during its own RHS.

For named function recursion later, you’ll need a special case. Not now.

## Name lookup

Name lookup should return a binding target or global target:

```text
local/body/file binding -> slot
global builtin          -> global index
not found               -> unresolved
```

Expression position:

```text
name expr:
  if visible binding -> MOVE/GET_GLOBAL
  else -> compile error
```

Call-head position is slightly special because primitive ops are fallback syntax:

```text
bare head in list:
  if special form name -> special form
  else if visible binding/global exists -> ordinary call
  else if primitive op name -> primitive opcode
  else -> undefined name
```

That matches the corrected ref model.

So:

```scheme
(+ 1 2)
```

becomes primitive `ADD`.

But:

```scheme
(def + something)
(+ 1 2)
```

becomes ordinary call through the user binding.

And:

```scheme
(def add +)
```

is an undefined-name error because `+` is not a value in expression position.

## Expression slots

Use destination-passing:

```odin
compile_expr :: proc(value: Value, dst: int)
```

Then a call compiles like:

```text
base = dst
callee -> base
arg0   -> base + 1
arg1   -> base + 2
CALL base, arg_count
```

For primitive arithmetic:

```text
arg0 -> dst
arg1 -> dst + 1
arg2 -> dst + 2
ADD dst, dst, count
```

That is very clean with your current n-ary opcodes.

For vector literal:

```text
NEW_VECTOR dst, count
for each element:
  compile element -> temp
  VECTOR_PUSH dst, temp
```

For push:

```scheme
(push values 50)
```

since `push` is now a primitive operation, not a runtime function:

```text
compile vector expr -> dst
compile value expr  -> temp
VECTOR_PUSH dst, temp
; dst remains the result vector
```

For pop:

```text
compile vector expr -> temp/source
VECTOR_POP dst, temp
```

## Body compiler

A body is not hard:

```odin
compile_body :: proc(forms: []Value, dst: int)
```

Rules:

```text
empty body:
  LOAD_NIL dst

for each form except last:
  if definition -> compile_definition
  else expression -> compile_expr into scratch/discard slot

last form:
  if definition -> error, unless file top level
  else compile_expr into dst
```

File top level is slightly different:

```text
file may end with definition
file may contain only definitions
file may be empty
```

So compile file as:

```text
if no final expression:
  LOAD_NIL result_slot
else:
  compile final expression into result_slot

RETURN result_slot
```

## The one design edge: no source locations means no hidden metadata

Because you want to avoid source meta, don’t wrap values in syntax nodes yet.

But then compiler errors should include the local syntactic fact:

```text
compile error: `if` expects 2 or 3 operands
compile error: `def` name must be a symbol
compile error: vector literal cannot contain definition forms
```

That will be fine.

## What I would not do yet

Do **not** add:

```text
SyntaxNode
AST
source spans
CallFrame
FunctionObject
closure cells
module envs
SET_GLOBAL
compiler manager/builder object
```

For this next pass, none of that is required.

Even `CallFrame` can wait until `fn`, because `run_code(vm, code)` is fine while there is only entry code. You were right to focus on shape, but compiler-first does not require frames yet.

## The real first pass architecture

I’d make the compiler section look like:

```text
Compiler state
  Compiler
  Scope
  Binding

Compiler errors
  compile_error

Compiler utilities
  symbol_name
  list_head_symbol
  is_special_name
  is_primitive_name
  lookup_binding
  declare_binding
  temp allocation maybe

Compiler entry
  compile_forms(forms) -> Code

Definitions
  compile_definition
  compile_value_def

Expressions
  compile_expr
  compile_name_expr
  compile_vector_expr
  compile_list_expr

List forms
  compile_special_form
  compile_call
  compile_primitive_op
  compile_set
```

No clever abstraction. Just sections.

## My blunt take

Yes, walking tree to bytecode in Wisp should be quite easy **for the subset before functions/closures**.

The hard parts later are not the tree walk. They are:

```text
closures capture bindings, not snapshots
recursive named functions
while/if jump patching
source diagnostics
modules
```

But the first compiler pass can be beautifully small.

I’d replace the hand-built smoke next. That is the right next move.

~~~

after more discussion:

Yeah, good catch. I should not have made `Scope` sound like an earned object. It was shorthand.

The **actual thing you need** is not necessarily:

```odin
Scope :: struct { ... }
```

The actual thing you need is:

```text
where does lookup start/stop?
where do duplicate-def checks apply?
which bindings disappear when leaving a do body?
which slot number do new bindings/temps get?
```

You can solve that with a flatter Kiln-ish model.

## I would probably not use a `Scope` type

For your style, this is better:

```odin
Local_Binding :: struct {
	name:    ^SymbolObject,
	slot:    int,
	mutable: bool,
}

Compiler :: struct {
	error_string: string,

	bindings: [dynamic]Local_Binding,

	scope_binding_marks: [dynamic]int,
	scope_slot_marks:    [dynamic]int,

	next_slot:        int,
	frame_slot_count: int,
}
```

Then scope is just marks into the flat binding list:

```odin
begin_scope :: proc() {
	append(&Compiler.scope_binding_marks, len(Compiler.bindings))
	append(&Compiler.scope_slot_marks, Compiler.next_slot)
}

end_scope :: proc() {
	binding_mark := pop(&Compiler.scope_binding_marks)
	slot_mark    := pop(&Compiler.scope_slot_marks)

	resize(&Compiler.bindings, binding_mark)
	Compiler.next_slot = slot_mark
}
```

That is probably cleaner than nested `Scope` structs.

## What this solves

### 1. Same-scope duplicate `def`

Current scope starts at:

```odin
scope_start := Compiler.scope_binding_marks[len(Compiler.scope_binding_marks) - 1]
```

When compiling:

```scheme
(def x 10)
```

check only:

```text
bindings[scope_start:]
```

for duplicate `x`.

That allows shadowing outer scopes but rejects duplicates in the same scope.

### 2. Lookup

Lookup scans backwards:

```text
for i := len(bindings)-1; i >= 0; i -= 1
```

First matching name wins.

That gives lexical shadowing naturally.

### 3. Ordered definitions

For:

```scheme
(def x expr)
```

do this:

```text
1. check same-scope duplicate
2. allocate slot
3. compile RHS into slot
4. append binding x -> slot
```

Because the binding is appended **after** compiling RHS, this works correctly:

```scheme
(def x x)
```

It sees an outer `x` if one exists, or errors if not. It does not see itself.

### 4. Leaving `do`

When leaving a `do`, truncate bindings and reset `next_slot`.

So locals from the `do` are gone.

## What is `next_slot`?

`next_slot` is just “next free frame slot.”

Wisp bytecode is register/slot based. So every local binding needs somewhere to live:

```scheme
(def x 10)
```

could become:

```text
slot 0 = 10
binding x -> slot 0
```

Then:

```scheme
(def y (+ x 1))
```

might be:

```text
slot 1 = result of (+ x 1)
binding y -> slot 1
```

So:

```text
next_slot = where the next local/temp can go
```

You also need temp slots for intermediate expression results:

```scheme
(print (+ 1 (* 2 3)))
```

The compiler may need slots for:

```text
callee
arg0
arg1
nested result
```

So `next_slot` is how codegen knows where scratch space can start.

The minimal model:

```text
local def allocates next_slot, increments it
temporary expression allocates next_slot, increments it
scope exit resets next_slot to earlier mark
frame_slot_count records max slot ever touched
```

This is exactly what `frame_slot_count` is for: how many slots the VM needs available when running this code.

## Do you need separate local slots and temp slots?

Maybe not immediately.

But the nice model is:

```text
bindings own stable slots inside their scope
temps are allocated above current next_slot and released after expression
```

For example:

```odin
alloc_slot :: proc() -> int {
	slot := Compiler.next_slot
	Compiler.next_slot += 1
	Compiler.frame_slot_count = max(Compiler.frame_slot_count, Compiler.next_slot)
	return slot
}
```

If you want temp release:

```odin
mark := Compiler.next_slot
compile_expr(...)
Compiler.next_slot = mark
```

That is enough. No fancy allocator.

## What I meant by `body`

In Wisp, a body is the sequence of forms that allows definitions before a final expression.

So yes:

```text
do body
fn body later
while body
file top-level is body-like, but with special ending rules
```

The important shared rule is:

```text
a body can contain definitions and expressions
definitions are valid directly inside it
non-empty expression body must end in expression
```

So:

```scheme
(do
  (def x 10)
  (+ x 1))
```

is a body.

```scheme
(fn (x)
  (def y 10)
  (+ x y))
```

is a body later.

```scheme
(while cond
  (def x 10)
  (print x))
```

is a body too, though its result is discarded.

File top-level is “body-like” but not exactly the same because the file may end with a definition or contain only definitions.

So I’d probably have:

```text
compile_body(forms, dst, require_final_expr: bool)
```

or two procs if clearer:

```text
compile_body_expr(forms, dst)     ; do/fn style: final form must be expression unless empty
compile_file_forms(forms, dst)    ; file style: may end in def
```

I slightly prefer separate procs because the rules are meaningfully different.

## `do` early is perfect

`do` is the first real scope test.

Compile:

```scheme
(do
  (def x 10)
  (+ x 1))
```

as:

```text
begin_scope
compile body into dst
end_scope
```

Empty `do`:

```scheme
(do)
```

emits:

```text
LOAD_NIL dst
```

A `do` ending in `def` is compile error.

That gets you lexical scopes before functions, which is exactly right.

## Closures: do not paint into corner

Your instinct that captures can be “like `^Value`” is close, but there is one dangerous edge:

```scheme
(def (make-counter)
  (def n 0)

  (fn ()
    (set n (+ n 1))
    n))
```

When `make-counter` returns, its stack slots are gone/reused. So a closure cannot safely capture a pointer to a stack slot forever.

So the KISS closure object is not “pointer to stack slot.” It is:

```text
captured binding storage must outlive the stack frame
```

The simplest durable thing is a heap cell:

```odin
CellObject :: struct {
	header: Object,
	value:  Value,
}
```

Then closures capture pointers to cells:

```odin
FunctionObject :: struct {
	header: Object,
	code:   ^Code,
	cells:  []^CellObject,
}
```

A captured mutable binding is a cell. `set` mutates the cell’s `value`.

That matches your ref rule:

```text
closures capture bindings, not snapshots
```

## How to avoid painting into a corner now

Do **not** implement cells now.

But avoid hardcoding every name read/write as “slot forever” in scattered places.

The earned abstraction later is:

```text
BindingPlace
```

Not a big manager. Just a target kind.

Eventually:

```odin
BindingPlaceKind :: enum {
	LOCAL_SLOT,
	GLOBAL,
	CELL,
	UPVALUE,
}

Binding :: struct {
	name:    ^SymbolObject,
	kind:    BindingPlaceKind,
	slot:    int,
	mutable: bool,
}
```

For now you only need:

```text
LOCAL_SLOT
GLOBAL maybe for builtins
```

Later closures add:

```text
CELL / UPVALUE
```

The important thing is to have name read/write compile through one obvious path:

```text
compile name read
compile set name
```

Not scattered ad-hoc `emit_move` everywhere.

That way later:

```scheme
x
```

can compile to:

```text
MOVE dst, slot
```

or:

```text
GET_CELL dst, cell_slot
```

depending on the binding.

## Simplest closure strategy later

When you finally do `fn`, there are two possible levels.

### Level 1: all captured locals become heap cells

Compiler detects which outer bindings are referenced by nested functions.

For each captured local:

```text
store a CellObject in its slot instead of raw value
reads/writes unwrap/mutate cell
FunctionObject captures pointer to that CellObject
```

That is correct and relatively simple.

### Level 2: all locals are cells from the start

This makes closures simpler, but it is too much allocation and worse VM shape.

I would **not** do this. Keep normal locals as slots; promote only captured ones later.

## For now

The current first compiler should only know:

```text
bindings map names to slots
do creates a scope mark
def allocates a slot and appends binding after RHS
set writes a visible mutable slot
```

That does not block closures.

It just means when closures arrive, you extend binding storage from:

```text
slot only
```

to:

```text
slot or cell/upvalue
```

## My corrected recommendation

Use this, not `Scope`:

```odin
Local_Binding :: struct {
	name:    ^SymbolObject,
	slot:    int,
	mutable: bool,
}

Compiler :: struct {
	error_string: string

	bindings: [dynamic]Local_Binding

	scope_binding_marks: [dynamic]int
	scope_slot_marks:    [dynamic]int

	next_slot:        int
	frame_slot_count: int
}
```

That solves:

```text
lexical lookup
shadowing
same-scope duplicate errors
ordered defs
slot allocation
do scopes
future fn body scopes
```

And it stays flat, grug, and easy to inspect.
