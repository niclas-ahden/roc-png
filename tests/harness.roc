## Our decoder against PngSuite (tests/pngsuite/), Willem van Schaik's test
## images for PNG decoders: every colour type at every bit depth, interlaced
## and not, odd sizes, every filter, transparency, ancillary chunks, and 14
## broken files a decoder must refuse. tests/pngsuite.txt says what each one
## decodes to (see update_fixtures.roc), and every image must decode to the
## same size and pixels, or be refused.
##
##     ./tests.roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	png: "../package/main.roc",
	crc32: "https://github.com/niclas-ahden/roc-crc32/releases/download/2.0.0/Dpu6zTP4s6bYRC2U9jWK7CcNBNGEfViKQbp35xSRC2Cr.tar.zst",
}

import pf.OsStr
import pf.Path
import pf.Stdout
import png.Png
import Expected

main! = |_args| {
	listing = Path.read_bytes!(Path.from_os_str(OsStr.from_str("tests/pngsuite.txt")))?
	entries = Str.from_utf8_lossy(listing)
		.split_on("\n")
		.drop_if(|line| line.is_empty() or line.starts_with("#"))
		.map_try(Expected.from_line)?

	Stdout.line!("== ${entries.len().to_str()} PngSuite images")?
	var $failed = 0.U64
	for entry in entries {
		bytes = Path.read_bytes!(Path.from_os_str(OsStr.from_str("tests/pngsuite/${entry.file}")))?
		problem =
			match (Png.decode(bytes), entry.image) {
				(Ok(image), Pixels(expected)) =>
					if image.width != expected.width or image.height != expected.height {
						Err("decodes to ${image.width.to_str()} by ${image.height.to_str()}")
					} else if Expected.checksum_of(image.pixels) != expected.checksum {
						Err("decodes to pixels with CRC-32 ${Expected.checksum_of(image.pixels)}")
					} else {
						Ok({})
					}

				(Ok(_), Refused) => Err("decodes, but should be refused")
				(Err(error), Pixels(_)) => Err("is refused with ${Str.inspect(error)}")
				(Err(_), Refused) => Ok({})
			}
		match problem {
			Ok({}) => {}
			Err(why) => {
				Stdout.line!("  ${entry.file} ${why}")?
				$failed = $failed + 1
			}
		}
	}

	if $failed == 0 {
		Stdout.line!("All passed")
	} else {
		Stdout.line!("${$failed.to_str()} failed")?
		Err(Exit(1))
	}
}
