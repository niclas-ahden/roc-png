#!/usr/bin/env roc
## All tests: the package's `expect` blocks, then PngSuite.
##
## The `expect` blocks in Png.roc decode small images written by a tiny
## writer in the same file: each colour type, low and 16-bit depths,
## transparency, an interlaced image, and each kind of damage the decoder
## reports. tests/harness.roc decodes all of PngSuite (tests/pngsuite/) and
## compares the pixels with tests/pngsuite.txt, which three other decoders
## agreed on. It needs no programs installed. It is built with --opt=speed,
## like the code that uses the package.
##
##     ./tests.roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.0/2yhxoR7cZPSYbyUzPWULFw8AA6QEcdsgFNRmzu7pZbst.tar.zst",
}

import pf.Stdout
import pf.Cmd
import pf.OsStr

main! = |_| {
	Stdout.line!("== unit tests")?
	run!("roc", ["test", "package/main.roc"])?

	Stdout.line!("== against PngSuite (compiled --opt=speed)")?
	build!("tests/harness.roc", "tests/harness")?
	run!("./tests/harness", [])?
	Ok({})
}

# Build a .roc file to a named binary with the LLVM speed backend.
build! : Str, Str => Try({}, [Exit(I32)])
build! = |src, out| run!("roc", ["build", "--opt=speed", src, "--output=${out}"])

# Run a command with inherited stdio, failing the script on a nonzero exit.
run! : Str, List(Str) => Try({}, [Exit(I32)])
run! = |program, arguments| {
	Cmd.call!(OsStr.from_str(program), arguments.map(OsStr.from_str)) ? |_| Exit(1)
	Ok({})
}
