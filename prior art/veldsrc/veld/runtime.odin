package veld

import "core:fmt"
import "core:os"


run_string :: proc(vm: ^VM, source: string) -> string {
	code, compile_error := compile_source(source)
	if compile_error != "" {
		vm.error_string = compile_error
		return compile_error
	}

	return run_code(vm, &code)
}

run_file :: proc(vm: ^VM, path: string) -> string {
	bytes, read_error := os.read_entire_file(path, context.allocator)
	if read_error != nil {
		vm.error_string = fmt.tprintf("could not read file `%s`: %v", path, read_error)
		return vm.error_string
	}
	defer delete(bytes)

	return run_string(vm, string(bytes))
}
