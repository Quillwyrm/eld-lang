# Wisp Maps and Name Strings

Post-MVP extension spec.

## Name Strings

A name string is source syntax for a string.

```scheme
:name
```

It evaluates to the tail text as a string. The leading `:` is not part of the string.

```scheme
:hp           ; "hp"
:player-name  ; "player-name"
:+            ; "+"
:<=           ; "<="
:nil          ; "nil"
:def          ; "def"
```

The tail must be non-empty and name-shaped.

```scheme
:             ; error
```

A name string is an ordinary string value.

```scheme
(= :hp "hp")
; true
```

## Maps

This extension adds `map` as a runtime value kind.

A map is a mutable associative container.

```scheme
{}
{:hp 100 :name "Rook"}
```

A map literal creates a fresh mutable map.

```scheme
{key-expr value-expr ...}
```

A map literal contains zero or more key/value expression pairs. The number of forms must be even.

Entries evaluate left-to-right. For each pair, the key expression evaluates first, then the value expression, then the map is updated.

```scheme
(def k :hp)

{k 100
 :name "Rook"}
```

If multiple entries produce equal keys, later entries replace earlier entries.

```scheme
{:hp 100
 :hp 90}
; {:hp 90}
```

## Keys and Values

Any non-`nil` value may be a map key.

`nil` cannot be used as a map key.

Maps cannot store `nil` values.

Looking up a missing key returns `nil`.

Setting a map slot to `nil` deletes the key.

```scheme
(def player {:hp 100})

(player :hp)
; 100

(player :missing)
; nil

(set (player :hp) nil)
; nil

(player :hp)
; nil
```

## Map Calls

Maps are callable by key.

A map call requires exactly one key argument.

```scheme
(def player {:hp 100 :name "Rook"})

(player :hp)
; 100

(player :name)
; "Rook"
```

Calling a map with `nil` as the key is an error.

## Map Mutation

Indexed `set` works on maps.

```scheme
(set (map-expr key-expr) value-expr)
```

For maps, the key may be any non-`nil` value.

A non-`nil` value inserts or replaces the entry.

A `nil` value deletes the entry.

```scheme
(def player {:hp 100})

(set (player :hp) 90)
; 90

(set (player :name) "Rook")
; "Rook"

(set (player :hp) nil)
; nil
```

Evaluation order is:

```text
map expression
key expression
value expression
mutation
```

## Key Equality

Map key equality matches Wisp equality.

```text
bools compare by value
numbers compare by numeric value
strings compare by contents
lists compare by identity
vectors compare by identity
maps compare by identity
functions compare by identity
```

Numeric keys use numeric equality.

```scheme
(def m {1 "one"})

(m 1.0)
; "one"
```

## Map Equality

Maps compare by identity.

```scheme
(= {:hp 100} {:hp 100})
; false

(def m {:hp 100})

(= m m)
; true
```

## Length

`len` accepts maps.

For maps, `len` returns the number of entries.

```scheme
(len {:hp 100 :name "Rook"})
; 2
```

## Display

Maps display as braced key/value pairs.

Map display order is unspecified.

```scheme
(print {:hp 100 :name "Rook"})
; {:hp 100 :name Rook}
```
