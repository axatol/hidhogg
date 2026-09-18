package d200x

import (
	"bytes"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"strings"

	"golang.org/x/image/font"
	"golang.org/x/image/font/gofont/goregular"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
)

var (
	wideLabelFont, wideLabelFontErr = opentype.Parse(goregular.TTF)
)

func configuredImage(width int, background color.RGBA) *image.RGBA {
	imageData := image.NewRGBA(image.Rect(0, 0, width, displayTileHeight))
	draw.Draw(imageData, imageData.Bounds(), image.NewUniform(background), image.Point{}, draw.Src)
	accent := color.RGBA{R: 255 - background.R/3, G: 255 - background.G/3, B: 255 - background.B/3, A: 255}
	drawBorder(imageData, 5, accent)
	return imageData
}

func configuredPNG(width int, background color.RGBA) ([]byte, error) {
	return encodeConfiguredPNG(configuredImage(width, background))
}

func configuredWidePNG(position Position, background color.RGBA) ([]byte, error) {
	imageData := configuredImage(displayWideWidth, background)
	if err := drawWideLabel(imageData, position.Label, position.LabelAlignment, position.LabelSize, textColor(background)); err != nil {
		return nil, err
	}
	return encodeConfiguredPNG(imageData)
}

func encodeConfiguredPNG(imageData image.Image) ([]byte, error) {
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, imageData); err != nil {
		return nil, err
	}
	return encoded.Bytes(), nil
}

func textColor(background color.RGBA) color.RGBA {
	luminance := 299*int(background.R) + 587*int(background.G) + 114*int(background.B)
	if luminance >= 128_000 {
		return color.RGBA{A: 255}
	}
	return color.RGBA{R: 255, G: 255, B: 255, A: 255}
}

func drawWideLabel(imageData *image.RGBA, label, alignment string, size int, foreground color.RGBA) error {
	if imageData == nil || imageData.Bounds().Empty() || label == "" {
		return nil
	}
	if alignment == "" {
		alignment = DefaultLabelAlignment
	}
	if size == 0 {
		size = DefaultLabelSize
	}
	if size < MinimumLabelSize {
		size = MinimumLabelSize
	}
	if size > MaximumLabelSize {
		size = MaximumLabelSize
	}
	inner := imageData.Bounds().Inset(5)
	if inner.Empty() {
		return nil
	}
	face, lines, err := wideLabelLayout(label, size, inner.Dx())
	if err != nil {
		return err
	}
	defer face.Close()

	metrics := face.Metrics()
	lineHeight := metrics.Height.Ceil()
	if lineHeight < 1 {
		lineHeight = 1
	}
	ascent := metrics.Ascent.Ceil()
	descent := metrics.Descent.Ceil()
	blockHeight := lineHeight * len(lines)
	firstBaseline := inner.Max.Y - descent - (len(lines)-1)*lineHeight
	if alignment == LabelAlignmentCenter {
		firstBaseline = inner.Min.Y + (inner.Dy()-blockHeight)/2 + ascent
	}

	for index, line := range lines {
		lineWidth := font.MeasureString(face, line).Ceil()
		x := inner.Min.X + (inner.Dx()-lineWidth)/2
		drawer := font.Drawer{
			Dst:  imageData,
			Src:  image.NewUniform(foreground),
			Face: face,
			Dot:  fixed.P(x, firstBaseline+index*lineHeight),
		}
		drawer.DrawString(line)
	}
	return nil
}

func wideLabelLayout(label string, requestedSize, maxWidth int) (font.Face, []string, error) {
	for size := requestedSize; size >= MinimumLabelSize; size-- {
		face, err := newWideLabelFace(size)
		if err != nil {
			return nil, nil, err
		}
		lines := strings.Split(label, "\n")
		if wideLabelLinesFit(face, lines, maxWidth) {
			return face, lines, nil
		}
		_ = face.Close()
	}

	face, err := newWideLabelFace(MinimumLabelSize)
	if err != nil {
		return nil, nil, err
	}
	return face, wrapWideLabel(label, face, maxWidth), nil
}

func newWideLabelFace(size int) (font.Face, error) {
	if wideLabelFontErr != nil {
		return nil, fmt.Errorf("parse bundled wide-label font: %w", wideLabelFontErr)
	}
	return opentype.NewFace(wideLabelFont, &opentype.FaceOptions{
		Size:    float64(size),
		DPI:     144,
		Hinting: font.HintingNone,
	})
}

func wideLabelLinesFit(face font.Face, lines []string, maxWidth int) bool {
	for _, line := range lines {
		if font.MeasureString(face, line).Ceil() > maxWidth {
			return false
		}
	}
	return true
}

func wrapWideLabel(label string, face font.Face, maxWidth int) []string {
	wrapped := make([]string, 0, 1)
	for _, sourceLine := range strings.Split(label, "\n") {
		runes := []rune(sourceLine)
		if len(runes) == 0 {
			wrapped = append(wrapped, "")
			continue
		}
		current := ""
		for _, character := range runes {
			candidate := current + string(character)
			if current != "" && font.MeasureString(face, candidate).Ceil() > maxWidth {
				wrapped = append(wrapped, current)
				current = string(character)
				continue
			}
			current = candidate
		}
		wrapped = append(wrapped, current)
	}
	return wrapped
}
