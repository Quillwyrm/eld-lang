# Wisp VM and Embedding Direction

This note records the intended ownership and embedding shape for Wisp.

It is architecture guidance, not a VM specification or an instruction to add
every described field immediately. Current code should grow into this shape as
the compiler, functions, files, modules, and REPL make each part necessary.

Kiln is evidence for useful runtime boundaries. Wisp does not inherit Kiln's
names, multiple-result machinery, module model, or other implementation details.

## Core Runtime Invariant

One `VM` owns one complete Wisp execution world.

That world includes:

```text
global bindings
compiled code
runtime objects
execution slots
active call frames
loaded dependency state when modules exist
the current error
```

The host may create more than one VM over the lifetime of the process, but only
one VM is selected for a Wisp operation at a time.

The VM and everything it owns may eventually be destroyed together. Wisp does
not need independently managed lifetimes for every piece of runtime state.

For a normal program, one VM owns one entry file and its loaded dependency
graph.

For a REPL, one VM owns one persistent REPL session.

## Active VM

Public host operations receive a `^VM` and select it:

```odin
Active_VM = vm
```

Package-internal reader, compiler, and runtime operations may then use
`Active_VM` instead of threading `^VM` through every internal procedure.

This is based on the explicit invariant that Wisp has one active VM operation at
a time. It is not intended to provide concurrent or reentrant VM execution.

Host native procedures still receive `^VM` explicitly. A native procedure is an
embedding boundary, not merely an internal helper, and the runtime handle is
useful to host code.

## Eventual Public Operations

The likely host-facing surface is:

```odin
run_file :: proc(vm: ^VM, path: string) -> (Value, string)

run_string :: proc(
	vm:          ^VM,
	source:      string,
	source_name: string,
) -> (Value, string)

repl_submit :: proc(vm: ^VM, source: string) -> (Value, string)
```

The exact names are not locked, but these are three distinct operations.

`run_file` owns file-path resolution and reading before running the source as the
entry file.

`run_string` runs an already-provided source buffer as a synthetic entry file.

`repl_submit` runs source inside the persistent synthetic REPL lexical scope. It is
not merely an alias for `run_string`.

VM construction and destruction operations become earned when the VM owns
resources that require whole-world initialization and release. They should not
be added merely to wrap a zero-value `VM`.

## Operation Boundary

`run_file`, `run_string`, and `repl_submit` select the supplied VM and own the
complete host operation:

```text
clear the previous operation error
read source
compile source
retain compiled state still reachable from runtime values
execute entry code
return the result or current error
```

Direct code execution remains an internal VM primitive. The primary embedding
surface should talk in source files, source strings, and REPL submissions rather
than requiring the host to install an arbitrary current `Code`.

## Runtime Ownership

### VM

The eventual conceptual VM state is:

```text
VM
  current error
  global environment
  compiled code reachable from entry and function values
  execution slots
  call frames
  runtime allocation ownership
  loaded dependency records when modules exist
```

This is not a current field checklist. Each field should be added only when its
feature exists.

The VM owns mutable runtime state. Compiled files and runtime objects do not
need lifetimes independent from the VM that loaded them.

### Normal File Execution

A Wisp file can compile as an entry `Code` executed through an ordinary frame.
File-scope definitions may occupy slots in that entry frame.

An uncaptured file binding does not need storage after the entry frame returns.
A file binding captured by a nested function must move or refer to persistent
upvalue or cell storage when the entry frame closes.

This is the same useful lifetime distinction as an ordinary function:

```text
uncaptured binding  frame slot
captured binding    open then closed upvalue or cell
```

Wisp's lexical file scope does not by itself require a permanent runtime file
environment.

Future module semantics may require retained module records, exported bindings,
or module result values. Those requirements remain undecided.

### Code

`Code` is immutable executable data after compilation:

```text
bytecode
constants
frame slot count
function metadata when functions exist
source metadata when diagnostics require it
```

Runtime function objects may reference stable `Code`, and active call frames
temporarily borrow it. The VM owns the allocation lifetime of compiled code
reachable from entry execution or runtime function values.

This gives code the lifetime required by functions and closures without making
`Code` itself a runtime callable value.

The current hand-written, synchronously executed by-value `Code` does not need
to change until stable retained code is required.

### Function Values

A native function and a Wisp function are both callable runtime values but have
different concrete storage.

```text
NativeFunctionObject
  native Odin procedure

FunctionObject
  Code reference
  captured binding references
```

`FunctionObject` should be added when Wisp functions are implemented. It should
not be predeclared as an empty future shape.

### Call Frames

Call frames become necessary when bytecode-backed Wisp functions execute.

The minimum expected frame information is:

```text
current Code
instruction position
slot window base
function or closure context when capture access requires it
```

Do not copy Kiln's requested-result counts, open-result ranges, or other
multiple-result state. Wisp currently specifies one result per call.

When frames exist, entry code executes through the same frame machinery as
function code. Native calls execute directly without creating Wisp call frames.

## Binding Storage

Wisp's binding classes have different lifetimes:

```text
global bindings          VM global environment
uncaptured file bindings entry-frame slots
ordinary local bindings  active frame slots
captured bindings        persistent upvalues, cells, or equivalent
REPL bindings            persistent REPL session storage
```

The exact closure representation remains deferred, but captured mutable
bindings cannot remain ordinary disposable frame values.

File bindings may begin as entry-frame slots. When a nested function captures
one, closure compilation gives that binding persistent storage. This preserves
Wisp's binding-capture semantics without giving every file a permanent runtime
environment.

Stable numeric binding indexes remain a good bytecode target. The compiler may
resolve a name to a local slot, captured binding, REPL binding, or global
binding. The VM should not perform source-name lookup for every ordinary read.

Compiled code may initially be tied to the VM and loaded-file layout against
which it was compiled. Portable bytecode and a separate linker are not current
requirements.

## Native Procedure Boundary

The current single-result native shape remains appropriate:

```odin
NativeProc :: proc(vm: ^VM, args: []Value) -> Value
```

The argument slice borrows the contiguous call slots for the duration of the
native call. A native procedure must not retain it.

The explicit VM parameter gives host code access to the calling Wisp world.
Runtime failure is reported through the VM error latch. A successful native
procedure returns one Wisp value.

Kiln's result-slot ABI exists for Kiln's result-shaping and multiple-value
semantics. Wisp does not need that machinery for its current single-result call
model.

## REPL Model

A REPL session is one persistent VM with one synthetic lexical scope, such as
`<repl>`.

Unlike a normal file, each REPL submission executes as a separate code chunk.
Bindings that must be visible to later submissions therefore need persistent
REPL session storage rather than slots in a completed earlier frame.

Each submission:

```text
uses the existing REPL lexical scope
may read bindings created by successful earlier submissions
may append new REPL bindings
executes in the same global environment
may create closures that retain earlier bindings and Code
```

Top-level forms in a submission should be compiled and executed in source order.
This matches normal file evaluation and prevents a later unexecuted definition
from appearing in the persistent REPL scope.

### Duplicate Definitions

The initial REPL should preserve ordinary Wisp file-scope rules:

```scheme
(def x 1)
(def x 2) ; duplicate definition error
(set x 2) ; mutation of the existing binding
```

A special REPL redefinition rule may be designed later, but should not appear as
an accidental exception.

### REPL Errors

Reader and compile errors execute nothing from the failing form and preserve
the previously successful REPL world.

A runtime error preserves mutations and other effects completed before the
error. Wisp does not need transactional rollback.

Before the next submission, transient execution state is reset:

```text
current error
active frames
temporary execution slots
failed code-builder state
```

Persistent state remains:

```text
globals
successful REPL bindings
loaded Code needed by functions
runtime objects
effects completed before a runtime error
```

This distinguishes disposable operation state from the persistent REPL world.

## Files and Future Modules

The language reference specifies file scopes but does not yet specify imports,
exports, module identity, loading order, caching, or cycles.

The VM may eventually own multiple loaded-file records, but this architecture
does not imply any particular module semantics.

The module system should be designed separately. It can reuse the loaded-file
ownership boundary without forcing Wisp to inherit Kiln's environment or module
model.

## Current Implementation Guidance

The durable parts already visible in the current prototype are:

```text
host-owned VM
VM-owned globals and error state
Code separated from runtime values
single-result native procedures
contiguous call arguments
stable global binding indexes
package-level code construction state
```

The architecture does not currently require:

```text
CallFrame before Wisp functions
FunctionObject before `fn`
REPL binding storage before the REPL exists
module records before module semantics exist
heap lifecycle wrappers before whole-world cleanup exists
portable bytecode or linking
multiple-result call machinery
```

The next implementation discussion should decide the entry-frame slot model
needed by the first compiler pass. Closure storage, module retention, and REPL
session bindings can wait for the features that require them.
