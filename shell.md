Yeah. run is better for launching a program. shell is only better when you specifically want to execute shell language.

Why shell exists at all

These two commands are not equivalent:

(os/run ["git" "status" "--short"])
(os/shell "git status --short | grep modified > result.txt")

os/run launches one executable and passes exact arguments:

executable: git
arguments:  status, --short

os/shell launches a command interpreter and asks it to evaluate source code:

run git
pipe its output into grep
redirect that output into a file

The shell provides another programming language with operators such as:

|       pipeline
>       redirect output
<       redirect input
&&      run next command after success
||      run next command after failure
*       filename expansion
$VAR    environment expansion

Direct execution does none of that.

Could direct execution do the same work?

Yes, but not through one basic run call. To reproduce:

git status --short | grep modified > result.txt

without a shell, your process API would need to:

spawn git;
create a pipe;
spawn grep with that pipe as stdin;
open result.txt;
direct grep stdout into the file;
wait for both processes.

That is cleaner and safer in a serious process API, but wildly more machinery than one shell string.

So shell is valuable for quick orchestration, build scripts, tooling glue, and letting someone paste a familiar terminal command.

Why run is usually preferable

For anything programmatic:

(os/run ["tool" user-path "--output" output-path])

is better because each argument has an exact boundary. A filename like:

my weird file; delete everything.txt

remains one boring filename.

With a shell string, punctuation may be interpreted as shell syntax unless correctly quoted. Python therefore defaults subprocess.run to direct execution and makes shell use explicit; its documentation recommends run() for subprocess cases it handles.

The honest conclusion for Obel

You do not automatically need both.

Add direct execution when you want Obel programs to launch tools reliably.
Add shell execution only if terminal-style command composition is an intended Obel capability.

Given Obel’s low-surface ethos, just supporting direct execution initially is entirely reasonable. os/shell is not a missing half of os/run; it is an optional escape hatch into an external language.

Prior art is genuinely split:

Lua exposes shell execution through os.execute, passing the string to the operating-system shell.
Janet exposes both direct vector-based os/execute and string-based os/shell.
Python defaults to direct execution and has an explicit shell option.

So neither “every scripting language needs shell” nor “shell is useless” is correct.
