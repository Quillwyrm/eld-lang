package main

import "core:fmt"
import "core:os"


main :: proc() {
	debug_tree := false
	if len(os.args) > 1 {
		if len(os.args) != 2 || os.args[1] != "dbg" {
			fmt.eprintln("usage: wisp [dbg]")
			return
		}
		debug_tree = true
	}

	source :=
	`
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
	`

	forms, read_error := read_source(source)
	if read_error != "" {
		fmt.eprintln(read_error)
		return
	}

	if debug_tree {
		fmt.println("SOURCE-----------------")
		fmt.print(source)
		fmt.println()

		fmt.println("TREE-------------------")
		fmt.println()
		debug_print_source_tree(forms)
		fmt.println()

		fmt.println("OUTPUT-----------------")
		fmt.println()
	}

	vm: VM
	vm.globals = make([dynamic]GlobalBinding)

	print_index := bind_native_global(&vm, "print", native_print)

	begin_code()

	label_constant := const_string("dog")
	saved_native_constant := const_string("saved native function")
	c2_5 := const_float(2.5)
	c0 := const_int(0)
	c1 := const_int(1)
	c2 := const_int(2)
	c3 := const_int(3)
	c4 := const_int(4)
	c5 := const_int(5)
	c10 := const_int(10)
	c20 := const_int(20)
	c30 := const_int(30)
	c50 := const_int(50)

	// Build the source above by hand.
	//
	// slot 0 = label
	// slot 1 = values
	// slot 2 = output
	// slot 3..6 = call and expression temporaries
	emit_load_const(0, label_constant)

	emit_new_vector(1, 3)
	emit_load_const(3, c10)
	emit_vector_push(1, 3)
	emit_load_const(3, c20)
	emit_vector_push(1, 3)
	emit_load_const(3, c30)
	emit_vector_push(1, 3)

	emit_get_global(2, print_index)

	// values[1] = values[0] + values[2]
	emit_move(3, 1)
	emit_load_const(4, c0)
	emit_call(3, 1)

	emit_move(4, 1)
	emit_load_const(5, c2)
	emit_call(4, 1)

	emit_add(3, 3, 2)
	emit_load_const(5, c1)
	emit_set_vector(1, 5, 3)

	// print label
	emit_get_global(3, print_index)
	emit_move(4, 0)
	emit_call(3, 1)

	// print (push values 50)
	emit_get_global(3, print_index)
	emit_move(4, 1)
	emit_load_const(5, c50)
	emit_vector_push(4, 5)
	emit_call(3, 1)

	// print (pop values)
	emit_get_global(3, print_index)
	emit_vector_pop(4, 1)
	emit_call(3, 1)

	// print values
	emit_get_global(3, print_index)
	emit_move(4, 1)
	emit_call(3, 1)

	// print values[1]
	emit_get_global(3, print_index)
	emit_move(4, 1)
	emit_load_const(5, c1)
	emit_call(4, 1)
	emit_call(3, 1)

	// print [nil true false 2.5]
	emit_get_global(3, print_index)
	emit_new_vector(4, 4)
	emit_load_nil(5)
	emit_vector_push(4, 5)
	emit_load_true(5)
	emit_vector_push(4, 5)
	emit_load_false(5)
	emit_vector_push(4, 5)
	emit_load_const(5, c2_5)
	emit_vector_push(4, 5)
	emit_call(3, 1)

	// print (+ 1 2.5 3)
	emit_get_global(3, print_index)
	emit_load_const(4, c1)
	emit_load_const(5, c2_5)
	emit_load_const(6, c3)
	emit_add(4, 4, 3)
	emit_call(3, 1)

	// print (- 20 3 2)
	emit_get_global(3, print_index)
	emit_load_const(4, c20)
	emit_load_const(5, c3)
	emit_load_const(6, c2)
	emit_sub(4, 4, 3)
	emit_call(3, 1)

	// print (* 2 3 4)
	emit_get_global(3, print_index)
	emit_load_const(4, c2)
	emit_load_const(5, c3)
	emit_load_const(6, c4)
	emit_mul(4, 4, 3)
	emit_call(3, 1)

	// print (/ 20 2 5)
	emit_get_global(3, print_index)
	emit_load_const(4, c20)
	emit_load_const(5, c2)
	emit_load_const(6, c5)
	emit_div(4, 4, 3)
	emit_call(3, 1)

	// output "saved native function"
	emit_move(3, 2)
	emit_load_const(4, saved_native_constant)
	emit_call(3, 1)
	emit_return(3)

	code := end_code()

	_, run_error := run_code(&vm, &code)
	if run_error != "" {
		fmt.eprintln(run_error)
		return
	}
}
