# Wisp Pipe Reference

This document describes a proposed post-MVP `pipe` form for Wisp.

`pipe` is readability syntax for left-to-right value flow.

It does not add new call semantics.

## Placeholder

`^` is the pipe placeholder.

`^` is reserved syntax.

It is meaningful only inside a `pipe` step.

Using `^` outside a `pipe` step is an error.

## Pipe Form

```scheme
(pipe initial
  step...)
```

`pipe` is an expression special form.

It evaluates `initial` first.

Each `step` is an expression template containing exactly one `^`.

For each step, the previous result replaces `^`, then the resulting expression is evaluated.

Steps are evaluated in order.

The result of the last step is the result of the `pipe`.

If there are no steps, `pipe` returns the initial value.

```scheme
(pipe 10)
; 10
```

```scheme
(pipe 10
  (+ ^ 1)
  (* ^ 2))
; 22
```

## Step Rules

A step must contain exactly one placeholder.

```scheme
(pipe 10
  (+ 1 2))
; error
```

```scheme
(pipe 10
  (+ ^ ^))
; error
```

A step is an expression position.

Definitions are not valid as steps.

```scheme
(pipe 10
  (def x ^))
; error
```

## Argument Position

The placeholder may appear in any expression position inside the step.

```scheme
(pipe x
  (f ^ a)
  (g b ^)
  (h a ^ b))
```

This avoids separate thread-first and thread-last forms.

## Callable Values

The placeholder may appear as the callee expression.

```scheme
(pipe f
  (^ 10))
```

With callable containers, this gives direct nested lookup.

```scheme
(pipe player
  (^ :stats)
  (^ :hp))
```

## Evaluation

`initial` is evaluated once.

A step is not evaluated until it is reached.

Only the replaced step expression is evaluated.

```scheme
(pipe (make-player)
  (normalize-player ^)
  (format-player ^)
  (print ^))
```

## Nested Pipe Forms

A nested `pipe` form is its own pipe expression.

Placeholders do not cross pipe boundaries.

Each `pipe` checks its own steps.

## Examples

```scheme
(print
  (format-player
    (normalize-player
      (load-player :rook))))
```

Can be written as:

```scheme
(pipe :rook
  (load-player ^)
  (normalize-player ^)
  (format-player ^)
  (print ^))
```

```scheme
(do
  (def raw (load-player :rook))
  (def normalized (normalize-player raw))
  (def text (format-player normalized))
  (print text))
```

Can be written as:

```scheme
(pipe :rook
  (load-player ^)
  (normalize-player ^)
  (format-player ^)
  (print ^))
```

Possible spellings:
```lisp
(pipe value
  (f ^ a)
  (g b ^))

(=> value
  (f ^ a)
  (g b ^))

(-> value
  (f ^ a)
  (g b ^))
```
