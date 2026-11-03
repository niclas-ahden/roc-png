import crc32.Crc32
import deflate.Deflate

## PNG images decoded to 8-bit RGBA, in pure Roc.
##
## ```roc
## image = Png.decode(bytes)?
## image.width # 640
## image.pixels # red, green, blue and alpha of each pixel, row by row
## ```
##
## It reads every PNG the specification allows: greyscale, RGB, palette,
## greyscale with alpha and RGBA, at every bit depth from 1 to 16, interlaced
## or not, with transparency from a tRNS chunk. It checks the CRC of every
## chunk and the Adler-32 of the image data, and rejects unknown critical
## chunks. The colours come out as they are stored: gamma, colour profiles
## and the background colour are not applied, and an animated PNG gives its
## default image.
Png :: [].{

	## An image as 8-bit RGBA: four bytes to a pixel, red, green, blue and
	## alpha, row by row from the top and each row from the left. Alpha 0 is
	## fully transparent and 255 opaque, and the colours are not multiplied
	## by it.
	Image : { width : U64, height : U64, pixels : List(U8) }

	## Why the bytes are not a PNG this package reads.
	##
	## - `NotPng`: they do not start with the PNG signature.
	## - `Truncated`: a chunk runs past the end, or there is no end chunk.
	## - `BadCrc(chunk)`: the named chunk's data does not match its CRC.
	## - `MissingHeader`: the first chunk is not the header.
	## - `InvalidSize`: the width or the height is 0 or more than 2^31 - 1.
	## - `InvalidFormat`: a bit depth that colour type does not have.
	## - `UnknownMethod`: a compression, filter or interlace method the
	##   specification does not define.
	## - `UnknownCriticalChunk(chunk)`: a chunk a decoder must understand to
	##   show the image, which this one does not.
	## - `MissingPalette`: a palette image without a palette.
	## - `InvalidPalette(length)`: a palette chunk that is not 1 to 256
	##   entries of three bytes.
	## - `MissingImageData`: no image data chunk.
	## - `BadCompression`: the image data is not a zlib stream.
	## - `BadChecksum`: the image data does not match its Adler-32.
	## - `TooLittleImageData`: the image data ends before the last row.
	## - `BadFilter(filter)`: a row with a filter type other than 0 to 4.
	## - `PaletteIndexOutOfRange(index)`: a pixel names a palette entry
	##   past the end of the palette.
	Error : [
		NotPng,
		Truncated,
		BadCrc(Str),
		MissingHeader,
		InvalidSize({ width : U64, height : U64 }),
		InvalidFormat({ bit_depth : U8, color_type : U8 }),
		UnknownMethod({ compression : U8, filter : U8, interlace : U8 }),
		UnknownCriticalChunk(Str),
		MissingPalette,
		InvalidPalette(U64),
		MissingImageData,
		BadCompression,
		BadChecksum,
		TooLittleImageData({ expected : U64, actual : U64 }),
		BadFilter(U8),
		PaletteIndexOutOfRange(U8),
	]

	## The image in `bytes`, the whole contents of a PNG file.
	decode : List(U8) -> Try(Png.Image, Png.Error)
	decode = |bytes| {
		if bytes.sublist({ start: 0, len: 8 }) != signature {
			return Err(NotPng)
		}
		chunks = read_chunks(bytes)?
		header = chunks.header
		channels = channels_of(header)?
		if header.color_type == 3 and chunks.palette.is_empty() {
			return Err(MissingPalette)
		}
		if chunks.data.is_empty() {
			return Err(MissingImageData)
		}
		raw = inflate(chunks.data)?
		layout = passes(header).map(
			|pass| {
				stride = (pass.columns * channels * header.bit_depth.to_u64() + 7) // 8
				{
					left: pass.left,
					top: pass.top,
					across: pass.across,
					down: pass.down,
					columns: pass.columns,
					rows: pass.rows,
					stride,
					size: if pass.columns == 0 or pass.rows == 0 0 else (stride + 1) * pass.rows,
				}
			},
		)
		expected = layout.fold(0, |sum, pass| sum + pass.size)
		if raw.len() < expected {
			return Err(TooLittleImageData({ expected, actual: raw.len() }))
		}

		format = {
			color_type: header.color_type,
			depth: header.bit_depth.to_u64(),
			channels,
			palette: chunks.palette,
			transparency: transparency_of(header, chunks.transparency),
		}
		bpp = (channels * header.bit_depth.to_u64() // 8).max(1)
		var $pixels = List.repeat(0.U8, header.width * header.height * 4)
		var $start = 0
		for pass in layout {
			if pass.size > 0 {
				rows = unfilter(raw.sublist({ start: $start, len: pass.size }), pass.stride, pass.rows, bpp)?
				var $row = 0
				while $row < pass.rows {
					line = rows.sublist({ start: $row * pass.stride, len: pass.stride })
					y = pass.top + $row * pass.down
					var $column = 0
					while $column < pass.columns {
						x = pass.left + $column * pass.across
						rgba = pixel(format, line, $column)?
						at = (y * header.width + x) * 4
						$pixels = $pixels.set(at, rgba.0) ?? $pixels
						$pixels = $pixels.set(at + 1, rgba.1) ?? $pixels
						$pixels = $pixels.set(at + 2, rgba.2) ?? $pixels
						$pixels = $pixels.set(at + 3, rgba.3) ?? $pixels
						$column = $column + 1
					}
					$row = $row + 1
				}
				$start = $start + pass.size
			}
		}
		Ok({ width: header.width, height: header.height, pixels: $pixels })
	}
}

signature : List(U8)
signature = [137, 80, 78, 71, 13, 10, 26, 10]

Header : { width : U64, height : U64, bit_depth : U8, color_type : U8, interlace : U8 }

Chunks : { header : Header, palette : List(U8), transparency : List(U8), data : List(U8) }

## The header, the palette, the transparency and the data of all image data
## chunks together, up to the end chunk.
read_chunks : List(U8) -> Try(Chunks, Png.Error)
read_chunks = |bytes| {
	var $at = 8
	var $header = Err(MissingHeader)
	var $palette = []
	var $transparency = []
	var $data = []
	while $at + 12 <= bytes.len() {
		length = be32(bytes, $at)
		start = $at + 8
		if length > bytes.len() or start + length + 4 > bytes.len() {
			return Err(Truncated)
		}
		kind = bytes.sublist({ start: $at + 4, len: 4 })
		name = Str.from_utf8_lossy(kind)
		if Crc32.checksum(bytes.sublist({ start: $at + 4, len: length + 4 })).to_u64() != be32(bytes, start + length) {
			return Err(BadCrc(name))
		}
		body = bytes.sublist({ start, len: length })
		if $at == 8 {
			if kind != ['I', 'H', 'D', 'R'] or length != 13 {
				return Err(MissingHeader)
			}
			$header = Ok(read_header(body)?)
		} else if kind == ['P', 'L', 'T', 'E'] {
			if length == 0 or length % 3 != 0 or length > 768 {
				return Err(InvalidPalette(length))
			}
			$palette = body
		} else if kind == ['t', 'R', 'N', 'S'] {
			$transparency = body
		} else if kind == ['I', 'D', 'A', 'T'] {
			$data = $data.concat(body)
		} else if kind == ['I', 'E', 'N', 'D'] {
			return Ok({ header: $header?, palette: $palette, transparency: $transparency, data: $data })
		} else if (kind.first() ?? 0).bitwise_and(0x20) == 0 and kind != ['I', 'H', 'D', 'R'] {
			# A lowercase first letter marks a chunk a decoder may skip.
			return Err(UnknownCriticalChunk(name))
		}
		$at = start + length + 4
	}
	match $header {
		Ok(_) => Err(Truncated)
		Err(_) => Err(if bytes.len() > 8 MissingHeader else Truncated)
	}
}

read_header : List(U8) -> Try(Header, Png.Error)
read_header = |body| {
	width = be32(body, 0)
	height = be32(body, 4)
	byte = |i| body.get(i) ?? 0
	if width == 0 or height == 0 or width > 0x7FFFFFFF or height > 0x7FFFFFFF {
		return Err(InvalidSize({ width, height }))
	}
	if byte(10) != 0 or byte(11) != 0 or byte(12) > 1 {
		return Err(UnknownMethod({ compression: byte(10), filter: byte(11), interlace: byte(12) }))
	}
	Ok({ width, height, bit_depth: byte(8), color_type: byte(9), interlace: byte(12) })
}

## The samples of each pixel, or `InvalidFormat` for a bit depth the colour
## type does not have.
channels_of : Header -> Try(U64, Png.Error)
channels_of = |header|
	match (header.color_type, header.bit_depth) {
		(0, 1) | (0, 2) | (0, 4) | (0, 8) | (0, 16) => Ok(1)
		(2, 8) | (2, 16) => Ok(3)
		(3, 1) | (3, 2) | (3, 4) | (3, 8) => Ok(1)
		(4, 8) | (4, 16) => Ok(2)
		(6, 8) | (6, 16) => Ok(4)
		_ => Err(InvalidFormat({ bit_depth: header.bit_depth, color_type: header.color_type }))
	}

## What makes a pixel transparent: one grey level or one colour, as raw
## samples, or an alpha for each of the first palette entries. A tRNS chunk
## too short for its colour type is ignored, as it may be.
Transparency : [Opaque, Grey(U64), Rgb(U64, U64, U64), Alphas(List(U8))]

transparency_of : Header, List(U8) -> Transparency
transparency_of = |header, body|
	if body.is_empty() {
		Opaque
	} else {
		match header.color_type {
			0 if body.len() >= 2 => Grey(be16(body, 0))
			2 if body.len() >= 6 => Rgb(be16(body, 0), be16(body, 2), be16(body, 4))
			3 => Alphas(body)
			_ => Opaque
		}
	}

## The pixel in column `column` of an unfiltered row, as 8-bit RGBA.
pixel : { color_type : U8, depth : U64, channels : U64, palette : List(U8), transparency : Transparency }, List(U8), U64 -> Try((U8, U8, U8, U8), Png.Error)
pixel = |format, line, column| {
	depth = format.depth
	at = |k| sample(line, column * format.channels + k, depth)
	match format.color_type {
		0 => {
			grey = at(0)
			value = to_8(grey, depth)
			alpha = if format.transparency == Grey(grey) 0 else 255
			Ok((value, value, value, alpha))
		}

		2 => {
			red = at(0)
			green = at(1)
			blue = at(2)
			alpha = if format.transparency == Rgb(red, green, blue) 0 else 255
			Ok((to_8(red, depth), to_8(green, depth), to_8(blue, depth), alpha))
		}

		3 => {
			index = at(0)
			if index * 3 + 2 >= format.palette.len() {
				return Err(PaletteIndexOutOfRange(index.to_u8_wrap()))
			}
			alpha =
				match format.transparency {
					Alphas(alphas) => alphas.get(index) ?? 255
					_ => 255
				}
			Ok((format.palette.get(index * 3) ?? 0, format.palette.get(index * 3 + 1) ?? 0, format.palette.get(index * 3 + 2) ?? 0, alpha))
		}

		4 => {
			value = to_8(at(0), depth)
			Ok((value, value, value, to_8(at(1), depth)))
		}

		_ => Ok((to_8(at(0), depth), to_8(at(1), depth), to_8(at(2), depth), to_8(at(3), depth)))
	}
}

## Sample `index` of a row of samples of `depth` bits each, most significant
## bits first.
sample : List(U8), U64, U64 -> U64
sample = |line, index, depth|
	if depth == 16 {
		be16(line, index * 2)
	} else if depth == 8 {
		(line.get(index) ?? 0).to_u64()
	} else {
		bit = index * depth
		byte = (line.get(bit // 8) ?? 0).to_u64()
		byte.shr_zf_wrap((8 - depth - bit % 8).to_u8_wrap()).bitwise_and(1.U64.shl_wrap(depth.to_u8_wrap()) - 1)
	}

## A sample of `depth` bits scaled to 8 bits, rounded to the nearest.
to_8 : U64, U64 -> U8
to_8 = |value, depth|
	if depth == 8 {
		value.to_u8_wrap()
	} else {
		most = 1.U64.shl_wrap(depth.to_u8_wrap()) - 1
		((value * 255 + most // 2) // most).to_u8_wrap()
	}

## The passes the rows are stored in: the whole image, or the seven of
## Adam7 interlacing, each with where its first pixel is and how far apart
## its pixels are.
passes : Header -> List({ left : U64, top : U64, across : U64, down : U64, columns : U64, rows : U64 })
passes = |header| {
	adam7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
	steps = if header.interlace == 1 adam7 else [(0, 0, 1, 1)]
	count = |size, first, step| if size > first (size - first + step - 1) // step else 0
	steps.map(
		|(left, top, across, down)| {
			left,
			top,
			across,
			down,
			columns: count(header.width, left, across),
			rows: count(header.height, top, down),
		},
	)
}

## The image data without its zlib wrapping, checked against its Adler-32.
inflate : List(U8) -> Try(List(U8), Png.Error)
inflate = |zlib| {
	if zlib.len() < 6 {
		return Err(BadCompression)
	}
	method = (zlib.get(0) ?? 0).to_u64()
	flags = (zlib.get(1) ?? 0).to_u64()
	# Deflate with a window of at most 32 KiB, a valid header check and no
	# preset dictionary.
	if method.bitwise_and(0x0F) != 8 or method.shr_zf_wrap(4) > 7 or (method * 256 + flags) % 31 != 0 or flags.bitwise_and(0x20) != 0 {
		return Err(BadCompression)
	}
	raw = Deflate.decompress(zlib.sublist({ start: 2, len: zlib.len() - 6 })) ? |_| BadCompression
	if adler32(raw) != be32(zlib, zlib.len() - 4) {
		return Err(BadChecksum)
	}
	Ok(raw)
}

adler32 : List(U8) -> U64
adler32 = |bytes| {
	(a, b) = bytes.fold((1.U64, 0.U64), |(low, high), byte| {
		next = (low + byte.to_u64()) % 65521
		(next, (high + next) % 65521)
	})
	b.shl_wrap(16).bitwise_or(a)
}

be32 : List(U8), U64 -> U64
be32 = |bytes, at| {
	byte = |i| (bytes.get(at + i) ?? 0).to_u64()
	byte(0).shl_wrap(24).bitwise_or(byte(1).shl_wrap(16)).bitwise_or(byte(2).shl_wrap(8)).bitwise_or(byte(3))
}

be16 : List(U8), U64 -> U64
be16 = |bytes, at| (bytes.get(at) ?? 0).to_u64().shl_wrap(8).bitwise_or((bytes.get(at + 1) ?? 0).to_u64())

## The rows without their filters: each row is a filter type byte and
## `stride` bytes, each byte stored as its difference from a prediction made
## from the byte `bpp` to its left, the one above it and the one above that
## left one (PNG specification, section 9).
unfilter : List(U8), U64, U64, U64 -> Try(List(U8), Png.Error)
unfilter = |raw, stride, rows, bpp| {
	var $out = List.with_capacity(stride * rows)
	var $row = 0
	while $row < rows {
		filter = raw.get($row * (stride + 1)) ?? 0
		if filter > 4 {
			return Err(BadFilter(filter))
		}
		base = $row * (stride + 1) + 1
		var $i = 0
		while $i < stride {
			x = raw.get(base + $i) ?? 0
			left = if $i >= bpp $out.get($row * stride + $i - bpp) ?? 0 else 0
			up = if $row > 0 $out.get(($row - 1) * stride + $i) ?? 0 else 0
			up_left = if $row > 0 and $i >= bpp $out.get(($row - 1) * stride + $i - bpp) ?? 0 else 0
			predicted =
				match filter {
					0 => 0
					1 => left
					2 => up
					3 => ((left.to_u64() + up.to_u64()) // 2).to_u8_wrap()
					_ => paeth(left, up, up_left)
				}
			$out = $out.append(x.plus_wrap(predicted))
			$i = $i + 1
		}
		$row = $row + 1
	}
	Ok($out)
}

## Whichever of the left, upper and upper left bytes is closest to
## left + up - upper left, in that order on a tie.
paeth : U8, U8, U8 -> U8
paeth = |a, b, c| {
	p = a.to_i64() + b.to_i64() - c.to_i64()
	pa = (p - a.to_i64()).abs()
	pb = (p - b.to_i64()).abs()
	pc = (p - c.to_i64()).abs()
	if pa <= pb and pa <= pc a else if pb <= pc b else c
}

# A tiny PNG writer for the tests below. It stores every row with filter
# type 0 and compresses with roc-deflate.

png_of : { width : U64, height : U64, bit_depth : U8, color_type : U8, interlace : U8 }, List(List(U8)), List(List(U8)) -> List(U8)
png_of = |header, extra, rows| {
	ihdr = be32_bytes(header.width).concat(be32_bytes(header.height)).concat([header.bit_depth, header.color_type, 0, 0, header.interlace])
	raw = rows.fold([], |acc, row| acc.append(0).concat(row))
	zlib = [0x78, 0x9C].concat(Deflate.compress(raw, 6)).concat(be32_bytes(adler32(raw)))
	signature
		.concat(chunk("IHDR", ihdr))
		.concat(extra.join())
		.concat(chunk("IDAT", zlib))
		.concat(chunk("IEND", []))
}

chunk : Str, List(U8) -> List(U8)
chunk = |name, body| {
	typed = name.to_utf8().concat(body)
	be32_bytes(body.len()).concat(typed).concat(be32_bytes(Crc32.checksum(typed).to_u64()))
}

be32_bytes : U64 -> List(U8)
be32_bytes = |n| [24, 16, 8, 0].map(|shift| n.shr_zf_wrap(shift).to_u8_wrap())

expect paeth(10, 20, 15) == 15
expect paeth(10, 20, 5) == 20
expect paeth(20, 10, 15) == 15
expect adler32("Wikipedia".to_utf8()) == 0x11E60398

# 8-bit RGBA, as stored.
expect Png.decode(png_of({ width: 2, height: 1, bit_depth: 8, color_type: 6, interlace: 0 }, [], [[1, 2, 3, 4, 5, 6, 7, 8]])) == Ok({ width: 2, height: 1, pixels: [1, 2, 3, 4, 5, 6, 7, 8] })

# 1-bit greyscale: 0 is black and 1 white, and a row ends on a byte.
expect Png.decode(png_of({ width: 3, height: 2, bit_depth: 1, color_type: 0, interlace: 0 }, [], [[0b1010_0000], [0b0110_0000]])).map_ok(|image| image.pixels) == Ok([255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 255])

# 2-bit greyscale scales to 0, 85, 170 and 255, and the tRNS level is
# transparent.
expect Png.decode(png_of({ width: 4, height: 1, bit_depth: 2, color_type: 0, interlace: 0 }, [chunk("tRNS", [0, 2])], [[0b00_01_10_11]])).map_ok(|image| image.pixels) == Ok([0, 0, 0, 255, 85, 85, 85, 255, 170, 170, 170, 0, 255, 255, 255, 255])

# 16-bit RGB rounds to 8 bits, and the tRNS colour, compared at 16 bits, is
# transparent.
expect Png.decode(png_of({ width: 2, height: 1, bit_depth: 16, color_type: 2, interlace: 0 }, [chunk("tRNS", [0x12, 0x34, 0, 0, 0xFF, 0xFF])], [[0x12, 0x34, 0, 0, 0xFF, 0xFF, 0x12, 0x35, 0x00, 0x80, 0x80, 0x80]])).map_ok(|image| image.pixels) == Ok([0x12, 0, 255, 0, 0x12, 0, 0x80, 255])

# A 4-bit palette with alphas for its first entries.
expect Png.decode(png_of({ width: 3, height: 1, bit_depth: 4, color_type: 3, interlace: 0 }, [chunk("PLTE", [10, 20, 30, 40, 50, 60, 70, 80, 90]), chunk("tRNS", [128])], [[0x01, 0x20]])).map_ok(|image| image.pixels) == Ok([10, 20, 30, 128, 40, 50, 60, 255, 70, 80, 90, 255])

expect Png.decode(png_of({ width: 1, height: 1, bit_depth: 8, color_type: 3, interlace: 0 }, [chunk("PLTE", [10, 20, 30])], [[1]])) == Err(PaletteIndexOutOfRange(1))
expect Png.decode(png_of({ width: 1, height: 1, bit_depth: 8, color_type: 3, interlace: 0 }, [], [[0]])) == Err(MissingPalette)

# 16-bit greyscale with alpha.
expect Png.decode(png_of({ width: 1, height: 1, bit_depth: 16, color_type: 4, interlace: 0 }, [], [[0x7F, 0xFF, 0x00, 0x80]])).map_ok(|image| image.pixels) == Ok([0x7F, 0x7F, 0x7F, 0])

# A 3 by 3 interlaced image: Adam7's passes 1, 4, 5, 6 and 7 hold pixels,
# 2 and 3 none.
expect {
	passes_rows = [[[1]], [[3]], [[7, 9]], [[2], [8]], [[4, 5, 6]]]
	png = png_of({ width: 3, height: 3, bit_depth: 8, color_type: 0, interlace: 1 }, [], passes_rows.join())
	Png.decode(png).map_ok(|image| image.pixels.chunks_of(4).map(|rgba| rgba.first() ?? 0)) == Ok([1, 2, 3, 4, 5, 6, 7, 8, 9])
}

# Unknown chunks: an ancillary one is skipped, a critical one refused.
expect Png.decode(png_of({ width: 1, height: 1, bit_depth: 8, color_type: 0, interlace: 0 }, [chunk("zzZz", [1, 2, 3])], [[9]])).map_ok(|image| image.pixels) == Ok([9, 9, 9, 255])
expect Png.decode(png_of({ width: 1, height: 1, bit_depth: 8, color_type: 0, interlace: 0 }, [chunk("ZZZZ", [])], [[9]])) == Err(UnknownCriticalChunk("ZZZZ"))

# Damage.
expect {
	png = png_of({ width: 1, height: 1, bit_depth: 8, color_type: 0, interlace: 0 }, [], [[9]])
	# The last byte of the header's CRC.
	Png.decode(png.set(32, (png.get(32) ?? 0).bitwise_xor(1)) ?? png) == Err(BadCrc("IHDR"))
}
expect {
	png = png_of({ width: 1, height: 1, bit_depth: 8, color_type: 0, interlace: 0 }, [], [[9]])
	Png.decode(png.take_first(png.len() - 12)) == Err(Truncated)
}
expect Png.decode([1, 2, 3]) == Err(NotPng)
expect Png.decode(signature) == Err(Truncated)
expect Png.decode(png_of({ width: 0, height: 1, bit_depth: 8, color_type: 0, interlace: 0 }, [], [])) == Err(InvalidSize({ width: 0, height: 1 }))
expect Png.decode(png_of({ width: 1, height: 1, bit_depth: 4, color_type: 2, interlace: 0 }, [], [[0]])) == Err(InvalidFormat({ bit_depth: 4, color_type: 2 }))
expect Png.decode(png_of({ width: 1, height: 1, bit_depth: 8, color_type: 0, interlace: 2 }, [], [[0]])) == Err(UnknownMethod({ compression: 0, filter: 0, interlace: 2 }))
expect Png.decode(png_of({ width: 2, height: 2, bit_depth: 8, color_type: 0, interlace: 0 }, [], [[1, 2]])) == Err(TooLittleImageData({ expected: 6, actual: 3 }))
expect {
	ihdr = be32_bytes(1).concat(be32_bytes(1)).concat([8, 0, 0, 0, 0])
	raw = [5, 9]
	zlib = [0x78, 0x9C].concat(Deflate.compress(raw, 6)).concat(be32_bytes(adler32(raw)))
	png = signature.concat(chunk("IHDR", ihdr)).concat(chunk("IDAT", zlib)).concat(chunk("IEND", []))
	Png.decode(png) == Err(BadFilter(5))
}
expect {
	ihdr = be32_bytes(1).concat(be32_bytes(1)).concat([8, 0, 0, 0, 0])
	raw = [0, 9]
	zlib = [0x78, 0x9C].concat(Deflate.compress(raw, 6)).concat(be32_bytes(adler32(raw) + 1))
	png = signature.concat(chunk("IHDR", ihdr)).concat(chunk("IDAT", zlib)).concat(chunk("IEND", []))
	Png.decode(png) == Err(BadChecksum)
}
expect {
	ihdr = be32_bytes(1).concat(be32_bytes(1)).concat([8, 0, 0, 0, 0])
	png = signature.concat(chunk("IHDR", ihdr)).concat(chunk("IEND", []))
	Png.decode(png) == Err(MissingImageData)
}
