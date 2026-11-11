#!/usr/bin/env roc
## Writes tests/pngsuite.txt: what each image of PngSuite (tests/pngsuite/)
## decodes to, by a vote of three decoders. ImageMagick and netpbm's pngtopam
## read PNGs with libpng, ffmpeg with a decoder of its own, and each gets
## some of PngSuite wrong: ImageMagick shrinks the colours of 1, 2 and 4-bit
## palettes to as many bits, pngtopam ignores the transparent colour of RGB
## images, and ffmpeg ignores the transparent grey level and the CRCs. The
## script says which one was outvoted on each image. Whatever two of them
## agree on is the answer, and a file at least two refuse is one a decoder
## must refuse. Nothing in the file comes from this package.
## tests/harness.roc compares our decoder with it.
##
## Run it from the repository root in the dev shell, which has all three:
##
##     nix develop -c roc tests/update_fixtures.roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.28.0/2yhxoR7cZPSYbyUzPWULFw8AA6QEcdsgFNRmzu7pZbst.tar.zst",
	crc32: "https://github.com/niclas-ahden/roc-crc32/releases/download/2.0.0/Dpu6zTP4s6bYRC2U9jWK7CcNBNGEfViKQbp35xSRC2Cr.tar.zst",
}

import pf.Cmd
import pf.OsStr
import pf.Path
import pf.Stdout
import Expected

main! = |_args| {
	suite = Path.from_os_str(OsStr.from_str("tests/pngsuite"))
	files = Path.list!(suite)?
		.keep_oks(|path| path.filename().map_ok(|name| name.display()))
		.keep_if(|name| name.ends_with(".png"))
		.sort_with(compare_bytes)

	var $lines = ["# file width height crc32 of 8-bit RGBA, or error, made by tests/update_fixtures.roc"]
	var $undecided = 0.U64
	for file in files {
		path = suite.join(file)
		image = Path.to_os_str(path)
		# ffmpeg widens 8-bit samples to 16 bits by shifting them, so it is
		# asked for 16 bits only for a 16-bit image, by the bit depth in the
		# header.
		wide = (Path.read_bytes!(path)?).get(24) == Ok(16)
		votes = [
			("ImageMagick", pam!("magick", [image, OsStr.from_str("pam:-")])?),
			("ffmpeg", pam!("ffmpeg", [OsStr.from_str("-v"), OsStr.from_str("error"), OsStr.from_str("-i"), image, OsStr.from_str("-f"), OsStr.from_str("image2pipe"), OsStr.from_str("-c:v"), OsStr.from_str("pam"), OsStr.from_str("-pix_fmt"), OsStr.from_str(if wide "rgba64be" else "rgba"), OsStr.from_str("-")])?),
			("pngtopam", pam!("pngtopam", [OsStr.from_str("-alphapam"), image])?),
		]
		match majority(votes) {
			Ok({ answer, outvoted }) => {
				if !outvoted.is_empty() {
					Stdout.line!("  ${file}: ${Str.join_with(outvoted, " and ")} outvoted")?
				}
				entry =
					match answer {
						Ok(decoded) => Pixels({ width: decoded.width, height: decoded.height, checksum: Expected.checksum_of(decoded.pixels) })
						Err(_) => Refused
					}
				$lines = $lines.append(Expected.to_line({ file, image: entry }))
			}

			Err(NoMajority) => {
				Stdout.line!("  ${file}: no two decoders agree")?
				$undecided = $undecided + 1
			}
		}
	}
	if $undecided > 0 {
		return Err(Undecided($undecided))
	}
	Path.write_bytes!(Path.from_os_str(OsStr.from_str("tests/pngsuite.txt")), Str.join_with($lines, "\n").concat("\n").to_utf8())?
	Stdout.line!("Wrote ${files.len().to_str()} images to tests/pngsuite.txt")
}

Decoded : Try({ width : U64, height : U64, pixels : List(U8) }, [Failed])

## The answer at least two of the votes give, and who gave another.
majority : List((Str, Decoded)) -> Try({ answer : Decoded, outvoted : List(Str) }, [NoMajority])
majority = |votes| {
	same = |a, b|
		match (a, b) {
			(Ok(x), Ok(y)) => x == y
			(Err(_), Err(_)) => Bool.True
			_ => Bool.False
		}
	for (_, candidate) in votes {
		agreeing = votes.count_if(|(_, other)| same(candidate, other))
		if agreeing >= 2 {
			outvoted = votes.keep_if(|(_, other)| !same(candidate, other)).map(|(name, _)| name)
			return Ok({ answer: candidate, outvoted })
		}
	}
	Err(NoMajority)
}

## The image a program writes as PAM to its standard output, or `Failed`
## when it exits with an error.
pam! : Str, List(OsStr) => Try(Decoded, _)
pam! = |program, arguments| {
	output = Cmd.new(OsStr.from_str(program)).args(arguments).run!()?
	match output.status {
		Exited(0) => Ok(Ok(Expected.from_pam(output.stdout_bytes)?))
		_ => Ok(Err(Failed))
	}
}

compare_bytes : Str, Str -> [Before, Same, After]
compare_bytes = |a, b| {
	x = a.to_utf8()
	y = b.to_utf8()
	var $i = 0
	while $i < x.len() and $i < y.len() {
		p = x.get($i) ?? 0
		q = y.get($i) ?? 0
		if p < q {
			return Before
		}
		if p > q {
			return After
		}
		$i = $i + 1
	}
	if x.len() < y.len() Before else if x.len() > y.len() After else Same
}
