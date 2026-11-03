# roc-png

PNG images decoded to 8-bit RGBA, in pure Roc.

- Every PNG the specification allows: greyscale, RGB, palette, greyscale with alpha and RGBA, at every bit depth from 1 to 16, interlaced or not.
- Transparency from a tRNS chunk: a transparent grey level or colour, or alphas for the palette.
- The CRC of every chunk and the Adler-32 of the image data are checked, and an unknown critical chunk is refused, as the specification asks.
- Decompression comes from [roc-deflate](https://github.com/niclas-ahden/roc-deflate) and the CRC from [roc-crc32](https://github.com/niclas-ahden/roc-crc32).

See the documentation at [https://niclas-ahden.github.io/roc-png/](https://niclas-ahden.github.io/roc-png/).

## Usage

```roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	png: "https://github.com/niclas-ahden/roc-png/releases/download/0.1.0/2ikyaoQrU3aMTjQsTgbTpvYPGQuj1yasnSequJQf5PRY.tar.zst",
}

import pf.Path
import pf.Stdout
import png.Png

main! = |_args| {
	bytes = Path.read_bytes!(Path.unix("photo.png"))?
	match Png.decode(bytes) {
		Ok(image) => {
			# Four bytes to a pixel, row by row from the top: red, green,
			# blue and alpha.
			first = image.pixels.take_first(4)
			Stdout.line!("${image.width.to_str()} by ${image.height.to_str()}, the top left pixel is ${Str.inspect(first)}")?
		}

		Err(BadCrc(chunk)) => Stdout.line!("The ${chunk} chunk is damaged")?
		Err(other) => Stdout.line!("Not a PNG I can read: ${Str.inspect(other)}")?
	}
	Ok({})
}
```

The pixels are not multiplied by their alpha. To hand them to something that takes RGB without alpha, such as a PDF writer, lay them over a background colour first. [examples/main.roc](examples/main.roc) does that.

## Limitations

- It decodes and does not encode.
- 16-bit samples are rounded to 8 bits.
- The colours come out as they are stored. Gamma (gAMA), chromaticities (cHRM), colour profiles (iCCP, sRGB) and significant bits (sBIT) are not applied, and the background colour (bKGD) is left to the caller.
- An animated PNG gives its default image.
- The whole file is decoded at once, so it and the image have to fit in memory.
