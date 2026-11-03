## Decode a PNG, draw it in the terminal, and lay it over a background for a
## library that takes RGB pixels without alpha.
## Run it with: roc examples/main.roc
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
	png: "../package/main.roc",
}

import pf.Stdout
import png.Png
import "glow.png" as glow : List(U8)

main! = |_args| {
	image = Png.decode(glow)?
	Stdout.line!("${image.width.to_str()} by ${image.height.to_str()} pixels")?

	# One character for each pixel, darker for a more opaque one.
	shades = " .:-=+*#%@".to_utf8()
	var $y = 0
	while $y < image.height {
		var $line = []
		var $x = 0
		while $x < image.width {
			alpha = image.pixels.get((($y * image.width + $x) * 4) + 3) ?? 0
			$line = $line.append(shades.get(alpha.to_u64() * (shades.len() - 1) // 255) ?? ' ')
			$x = $x + 1
		}
		Stdout.line!(Str.from_utf8_lossy($line))?
		$y = $y + 1
	}

	rgb = over(image.pixels, { red: 255, green: 255, blue: 255 })
	middle = (image.height // 2 * image.width + image.width // 2) * 3
	Stdout.line!("Over white: ${rgb.len().to_str()} bytes of RGB, the middle pixel is ${Str.inspect(rgb.sublist({ start: middle, len: 3 }))}")?
	Ok({})
}

## RGBA pixels laid over a background colour, as RGB. Each colour is mixed
## with the background by its alpha.
over : List(U8), { red : U8, green : U8, blue : U8 } -> List(U8)
over = |pixels, background| {
	mix = |value, alpha, under|
		((value.to_u64() * alpha.to_u64() + under.to_u64() * (255 - alpha.to_u64()) + 127) // 255).to_u8_wrap()
	pixels.chunks_of(4).fold(
		List.with_capacity(pixels.len() // 4 * 3),
		|out, rgba| {
			alpha = rgba.get(3) ?? 255
			out
				.append(mix(rgba.get(0) ?? 0, alpha, background.red))
				.append(mix(rgba.get(1) ?? 0, alpha, background.green))
				.append(mix(rgba.get(2) ?? 0, alpha, background.blue))
		},
	)
}
