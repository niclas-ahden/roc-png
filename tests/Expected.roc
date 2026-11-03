import crc32.Crc32

## What a PngSuite image should decode to, one line of tests/pngsuite.txt:
## the file name, then either its width, its height and the CRC-32 of its
## 8-bit RGBA pixels, or `error` for a file a decoder must refuse.
Expected :: [].{

	Entry : { file : Str, image : [Pixels({ width : U64, height : U64, checksum : Str }), Refused] }

	to_line : Entry -> Str
	to_line = |entry|
		match entry.image {
			Pixels(p) => "${entry.file} ${p.width.to_str()} ${p.height.to_str()} ${p.checksum}"
			Refused => "${entry.file} error"
		}

	from_line : Str -> Try(Entry, [BadLine(Str)])
	from_line = |line|
		match line.split_on(" ") {
			[file, "error"] => Ok({ file, image: Refused })
			[file, width, height, checksum] =>
				match (U64.from_str(width), U64.from_str(height)) {
					(Ok(w), Ok(h)) => Ok({ file, image: Pixels({ width: w, height: h, checksum }) })
					_ => Err(BadLine(line))
				}

			_ => Err(BadLine(line))
		}

	## The CRC-32 of `bytes` as 8 hexadecimal digits.
	checksum_of : List(U8) -> Str
	checksum_of = |bytes| {
		sum = Crc32.checksum(bytes)
		Str.from_utf8_lossy([28, 24, 20, 16, 12, 8, 4, 0].map(|shift| hex_digit(sum.shr_zf_wrap(shift).bitwise_and(0xF).to_u8_wrap())))
	}

	## A PAM image, as ImageMagick and pngtopam write them, as 8-bit RGBA with
	## each sample scaled from its MAXVAL and rounded to the nearest.
	from_pam : List(U8) -> Try({ width : U64, height : U64, pixels : List(U8) }, [BadPam(Str)])
	from_pam = |bytes| {
		end = find(bytes, "ENDHDR\n".to_utf8()) ? |_| BadPam("no ENDHDR")
		fields = Str.from_utf8_lossy(bytes.take_first(end)).split_on("\n").map(|line| line.split_on(" "))
		number = |key| {
			found = fields.find_first(|words| words.first() == Ok(key)) ? |_| BadPam("no ${key}")
			U64.from_str(found.get(1) ?? "").map_err(|_| BadPam("bad ${key}"))
		}
		width = number("WIDTH")?
		height = number("HEIGHT")?
		depth = number("DEPTH")?
		most = number("MAXVAL")?
		size = if most > 255 2 else 1
		data = bytes.drop_first(end + 7)
		if data.len() < width * height * depth * size {
			return Err(BadPam("short"))
		}
		at = |i| if size == 2 (data.get(i * 2) ?? 0).to_u64().shl_wrap(8).bitwise_or((data.get(i * 2 + 1) ?? 0).to_u64()) else (data.get(i) ?? 0).to_u64()
		scaled = |i| ((at(i) * 255 + most // 2) // most).to_u8_wrap()
		var $pixels = List.with_capacity(width * height * 4)
		var $p = 0
		while $p < width * height {
			first = $p * depth
			rgba =
				match depth {
					1 => [scaled(first), scaled(first), scaled(first), 255]
					2 => [scaled(first), scaled(first), scaled(first), scaled(first + 1)]
					3 => [scaled(first), scaled(first + 1), scaled(first + 2), 255]
					_ => [scaled(first), scaled(first + 1), scaled(first + 2), scaled(first + 3)]
				}
			$pixels = $pixels.concat(rgba)
			$p = $p + 1
		}
		Ok({ width, height, pixels: $pixels })
	}
}

find : List(U8), List(U8) -> Try(U64, [NotFound])
find = |haystack, needle| {
	var $i = 0
	while $i + needle.len() <= haystack.len() {
		if haystack.sublist({ start: $i, len: needle.len() }) == needle {
			return Ok($i)
		}
		$i = $i + 1
	}
	Err(NotFound)
}

hex_digit : U8 -> U8
hex_digit = |n| if n < 10 '0' + n else 'a' + n - 10
