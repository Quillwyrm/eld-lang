## Modules

Possible module surface.

Modules are loaded by path string.

```scheme
(import "path")
(import alias "path")
```

`import` loads a module and makes its exported bindings available through a namespace prefix.

```scheme
(import "math")

(math/square 4)
; 16
```

The default namespace prefix is derived from the module path.

An alias may be supplied to choose the namespace prefix.

```scheme
(import m "math")

(m/square 4)
; 16
```

## Use

```scheme
(use "path")
(use "path" name...)
```

`use` loads a module and binds exported names directly into the current file scope.

With no names, `use` imports all exported names.

```scheme
(use "math")

(square 4)
; 16
```

With names, `use` imports only those selected exports.

```scheme
(use "math" square pi)

(square 4)
; 16
```

## Export

```scheme
(export)
(export name...)
```

`export` marks file-scope bindings as module exports.

With names, only those bindings are exported.

```scheme
(def pi 3.14159)

(def (square x)
  (* x x))

(export pi square)
```

With no names, all file-scope bindings defined by the current file are exported.

```scheme
(def pi 3.14159)

(def (square x)
  (* x x))

(export)
```

`export` does not export imported bindings or global bindings.

## Collision Rules

Module import collisions are errors.

```scheme
(import "math")
```

Errors if any generated `math/name` binding already exists in the same file scope.

```scheme
(import m "math")
```

Errors if any generated `m/name` binding already exists in the same file scope.

```scheme
(use "math")
```

Errors if any exported name already exists in the same file scope.

```scheme
(use "math" sin cos)
```

Errors if any selected name does not exist in the module exports.

Errors if any selected name already exists in the same file scope.

## Scoped `use`

`use` is a definition form.

Unlike `import`, `use` does not need to be a file-header form.

A `use` form is valid anywhere definitions are valid: at file top level or directly inside a body.

```scheme
(use "math" square pi)
```

At file top level, `use` creates file-scope bindings.

Inside a body, `use` creates bindings in that body scope.

Used bindings are ordered like other definitions. They are visible only after the `use` form has evaluated.

```scheme
(do
  (use "math" square)
  (square 4))
; 16
```

This is invalid because `square` is read before the `use` form has evaluated.

```scheme
(do
  (square 4)
  (use "math" square))
; error
```

A `use` form is not an expression, so it cannot appear directly in expression positions.

```scheme
(if ready
  (use "math" square)
  nil)
; error
```

Use `do` when a branch needs scoped used bindings.

```scheme
(if ready
  (do
    (use "math" square)
    (square 4))
  nil)
```

A module is loaded and evaluated at most once.

Each `use` form creates bindings in its current scope when that `use` form is evaluated.

```scheme
(def (area r)
  (use "math" square pi)
  (* pi (square r)))
```

If no names are supplied, `use` creates bindings for all exports from the module.

```scheme
(use "math")
```

If names are supplied, `use` creates bindings only for those selected exports.

```scheme
(use "math" square pi)
```

Using a name that does not exist in the module exports is an error.

Using a name that already exists in the same scope is an error.

A local `use` may shadow an outer binding, the same way a local `def` may shadow an outer binding.
