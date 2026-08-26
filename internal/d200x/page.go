package d200x

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"sort"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	DisplayPositionCount   = 14
	MaximumPositionIDBytes = 64
	MaximumLabelRunes      = 64
	MaximumLabelBytes      = 4 * MaximumLabelRunes
)

// Position is one explicitly configured D200X display position. Position is
// zero-based: 0 through 12 are square tiles and 13 is the wide tile.
type Position struct {
	ID         string
	Position   string
	Label      string
	Background string
}

// Page is the single configured display page supported by this milestone.
type Page struct {
	Positions []Position
}

type PositionSpec struct {
	Name      string
	WireIndex byte
	Wide      bool
}

var supportedPositionSpecs = [...]PositionSpec{
	{Name: "0_0", WireIndex: 0},
	{Name: "1_0", WireIndex: 1},
	{Name: "2_0", WireIndex: 2},
	{Name: "3_0", WireIndex: 3},
	{Name: "4_0", WireIndex: 4},
	{Name: "0_1", WireIndex: 5},
	{Name: "1_1", WireIndex: 6},
	{Name: "2_1", WireIndex: 7},
	{Name: "3_1", WireIndex: 8},
	{Name: "4_1", WireIndex: 9},
	{Name: "0_2", WireIndex: 10},
	{Name: "1_2", WireIndex: 11},
	{Name: "2_2", WireIndex: 12},
	{Name: "3_2", WireIndex: 13, Wide: true},
}

var supportedPositionByName = func() map[string]PositionSpec {
	result := make(map[string]PositionSpec, len(supportedPositionSpecs))
	for _, spec := range supportedPositionSpecs {
		result[spec.Name] = spec
	}
	return result
}()

func SupportedPositions() []PositionSpec {
	return append([]PositionSpec(nil), supportedPositionSpecs[:]...)
}

func LookupPosition(name string) (PositionSpec, bool) {
	spec, ok := supportedPositionByName[name]
	return spec, ok
}

func PositionForWireIndex(index byte) (PositionSpec, bool) {
	if int(index) >= len(supportedPositionSpecs) {
		return PositionSpec{}, false
	}
	return supportedPositionSpecs[index], true
}

func NewPage(positions []Position) Page {
	return Page{Positions: append([]Position(nil), positions...)}
}

// ValidatePage checks the complete 14-position archive contract without
// touching HID.
func ValidatePage(page Page) error {
	_, err := validatedPage(page)
	return err
}

func validatedPage(page Page) ([]Position, error) {
	positions, err := pagePositions(page)
	if err != nil {
		return nil, err
	}
	sort.SliceStable(positions, func(left, right int) bool {
		leftSpec, leftOK := LookupPosition(positions[left].Position)
		rightSpec, rightOK := LookupPosition(positions[right].Position)
		if leftOK && rightOK {
			return leftSpec.WireIndex < rightSpec.WireIndex
		}
		if leftOK {
			return true
		}
		if rightOK {
			return false
		}
		return positions[left].Position < positions[right].Position
	})
	seenIDs := make(map[string]struct{}, len(positions))
	for index, position := range positions {
		spec, ok := LookupPosition(position.Position)
		if !ok || int(spec.WireIndex) != index {
			return nil, fmt.Errorf("D200X display position %q is not configured exactly once", position.Position)
		}
		if !validPositionID(position.ID) {
			return nil, fmt.Errorf("D200X display position %d has an invalid ID", index)
		}
		if _, exists := seenIDs[position.ID]; exists {
			return nil, fmt.Errorf("D200X display position ID %q is duplicated", position.ID)
		}
		seenIDs[position.ID] = struct{}{}
		if !validPositionLabel(position.Label) {
			return nil, fmt.Errorf("D200X display position %d has an invalid label", index)
		}
		if _, err := PositionBackground(position); err != nil {
			return nil, fmt.Errorf("D200X display position %d background: %w", index, err)
		}
	}
	return positions, nil
}

func validPositionID(id string) bool {
	if !utf8.ValidString(id) || id == "" || len([]byte(id)) > MaximumPositionIDBytes {
		return false
	}
	for index, character := range id {
		if index == 0 {
			if !isASCIIAlphaNumeric(character) {
				return false
			}
			continue
		}
		if !isASCIIAlphaNumeric(character) && character != '.' && character != '_' && character != '-' {
			return false
		}
	}
	return true
}

func isASCIIAlphaNumeric(character rune) bool {
	return character >= 'a' && character <= 'z' || character >= 'A' && character <= 'Z' || character >= '0' && character <= '9'
}

func validPositionLabel(label string) bool {
	if !utf8.ValidString(label) || strings.TrimSpace(label) == "" || utf8.RuneCountInString(label) > MaximumLabelRunes || len([]byte(label)) > MaximumLabelBytes {
		return false
	}
	for _, character := range label {
		if unicode.IsControl(character) {
			return false
		}
	}
	return true
}

func pagePositions(page Page) ([]Position, error) {
	source := page.Positions
	if len(source) != DisplayPositionCount {
		return nil, fmt.Errorf("D200X page has %d positions, want %d", len(source), DisplayPositionCount)
	}
	return append([]Position(nil), source...), nil
}

// PositionBackground accepts the strict hex colour form used by the
// milestone configuration.
func PositionBackground(position Position) (color.RGBA, error) {
	if position.Background == "" {
		return color.RGBA{}, fmt.Errorf("colour is required")
	}
	return ParseBackgroundColor(position.Background)
}

func ParseBackgroundColor(value string) (color.RGBA, error) {
	if len(value) != 7 && len(value) != 9 || value[0] != '#' {
		return color.RGBA{}, fmt.Errorf("colour must be #RRGGBB or #RRGGBBAA")
	}
	red, err := strconv.ParseUint(value[1:3], 16, 8)
	if err != nil {
		return color.RGBA{}, fmt.Errorf("invalid red component")
	}
	green, err := strconv.ParseUint(value[3:5], 16, 8)
	if err != nil {
		return color.RGBA{}, fmt.Errorf("invalid green component")
	}
	blue, err := strconv.ParseUint(value[5:7], 16, 8)
	if err != nil {
		return color.RGBA{}, fmt.Errorf("invalid blue component")
	}
	alpha := uint64(255)
	if len(value) == 9 {
		alpha, err = strconv.ParseUint(value[7:9], 16, 8)
		if err != nil {
			return color.RGBA{}, fmt.Errorf("invalid alpha component")
		}
	}
	return color.RGBA{R: uint8(red), G: uint8(green), B: uint8(blue), A: uint8(alpha)}, nil
}

// BuildPageArchive creates a deterministic ZIP archive for one configured
// page and renders configured labels and colours into each tile.
func BuildPageArchive(page Page) (DisplayArchive, error) {
	positions, err := validatedPage(page)
	if err != nil {
		return DisplayArchive{}, err
	}
	files, err := configuredArchiveFiles(positions)
	if err != nil {
		return DisplayArchive{}, err
	}
	return buildFirmwareSafeArchive(files)
}

func PageFrame(page Page) (Frame, error) {
	archive, err := BuildPageArchive(page)
	if err != nil {
		return Frame{}, err
	}
	return CompleteDisplayUploadFrame(archive.Data)
}

// SendPage performs the only supported page-start sequence. Archive creation
// and page validation happen before any transport write; each primitive is
// serialized as one write transaction and a failed write invalidates the
// session.
func (s *Session) SendPage(ctx context.Context, page Page, brightness int) error {
	if s == nil {
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	if brightness < 0 || brightness > 100 {
		return &ProtocolError{Kind: ErrorInvalidBrightness, Actual: brightness, Expected: 100}
	}
	display, err := PageFrame(page)
	if err != nil {
		return err
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	ctx = normalizeContext(ctx)
	for _, frame := range []Frame{
		display,
		BrightnessFrame(brightness),
		UnlockScreenFrame(),
		EnableInputStreamFrame(),
	} {
		if err := s.sendFrameLocked(ctx, frame); err != nil {
			return err
		}
	}
	return nil
}

func configuredArchiveFiles(positions []Position) ([]displayArchiveFile, error) {
	manifest := configuredManifest(positions)
	manifestCompressed, err := deflateRaw(manifest)
	if err != nil {
		return nil, fmt.Errorf("compress D200X page manifest: %w", err)
	}
	files := []displayArchiveFile{{
		name:             "manifest.json",
		compression:      8,
		uncompressedData: manifest,
		compressedData:   manifestCompressed,
		checksum:         crc32.ChecksumIEEE(manifest),
	}}
	for index, position := range positions {
		background, err := PositionBackground(position)
		if err != nil {
			return nil, fmt.Errorf("render D200X display position %d: %w", index, err)
		}
		spec, ok := LookupPosition(position.Position)
		if !ok {
			return nil, fmt.Errorf("render D200X display position %q: unsupported position", position.Position)
		}
		width := displaySquareWidth
		name := fmt.Sprintf("icons/button-%02d.png", spec.WireIndex)
		if spec.Wide {
			width = displayWideWidth
			name = "icons/wide-tile.png"
		}
		pngData, err := configuredPNG(width, position.Label, background)
		if err != nil {
			return nil, fmt.Errorf("encode D200X display position %d: %w", index, err)
		}
		compressed, err := deflateRaw(pngData)
		if err != nil {
			return nil, fmt.Errorf("compress D200X display position %d: %w", index, err)
		}
		files = append(files, displayArchiveFile{
			name:             name,
			compression:      8,
			uncompressedData: pngData,
			compressedData:   compressed,
			checksum:         crc32.ChecksumIEEE(pngData),
		})
	}
	return files, nil
}

func configuredManifest(positions []Position) []byte {
	var manifest bytes.Buffer
	manifest.WriteByte('{')
	for index, position := range positions {
		if index > 0 {
			manifest.WriteByte(',')
		}
		spec, _ := LookupPosition(position.Position)
		coordinate := spec.Name
		iconPath := fmt.Sprintf("icons/button-%02d.png", spec.WireIndex)
		if spec.Wide {
			iconPath = "icons/wide-tile.png"
		}
		entry := struct {
			State     int `json:"State"`
			ViewParam []struct {
				Icon string `json:"Icon"`
			} `json:"ViewParam"`
		}{
			State: 0,
			ViewParam: []struct {
				Icon string `json:"Icon"`
			}{{Icon: iconPath}},
		}
		encoded, _ := json.Marshal(entry)
		coordinateEncoded, _ := json.Marshal(coordinate)
		manifest.Write(coordinateEncoded)
		manifest.WriteByte(':')
		manifest.Write(encoded)
	}
	manifest.WriteByte('}')
	return manifest.Bytes()
}

func buildFirmwareSafeArchive(files []displayArchiveFile) (DisplayArchive, error) {
	for paddingLength := 0; paddingLength < displayMaximumPadding; paddingLength++ {
		archive, err := assembleDisplayArchive(files, paddingLength)
		if err != nil {
			return DisplayArchive{}, err
		}
		if len(archive) > MaxPayloadLength {
			return DisplayArchive{}, &ProtocolError{
				Kind:     ErrorPayloadTooLarge,
				Declared: uint32(len(archive)),
				Limit:    MaxPayloadLength,
			}
		}
		if firmwareSafeArchive(archive) {
			return DisplayArchive{Data: archive, PaddingLength: paddingLength}, nil
		}
	}
	return DisplayArchive{}, fmt.Errorf("no firmware-safe D200X archive padding below %d bytes", displayMaximumPadding)
}

func configuredPNG(width int, label string, background color.RGBA) ([]byte, error) {
	imageData := image.NewRGBA(image.Rect(0, 0, width, displayTileHeight))
	draw.Draw(imageData, imageData.Bounds(), image.NewUniform(background), image.Point{}, draw.Src)
	accent := color.RGBA{R: 255 - background.R/3, G: 255 - background.G/3, B: 255 - background.B/3, A: 255}
	drawBorder(imageData, 5, accent)
	drawLabel(imageData, label, textColor(background))
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

func drawLabel(imageData *image.RGBA, label string, foreground color.RGBA) {
	runes := []rune(strings.ToUpper(label))
	if len(runes) == 0 {
		return
	}
	maxRunes := imageData.Bounds().Dx() / 18
	if maxRunes < 1 {
		return
	}
	if len(runes) > maxRunes {
		runes = runes[:maxRunes]
	}
	scale := imageData.Bounds().Dx() / (len(runes)*6 + 1)
	if scale > 5 {
		scale = 5
	}
	if scale < 1 {
		scale = 1
	}
	glyphWidth := 5 * scale
	glyphGap := scale
	totalWidth := len(runes)*glyphWidth + (len(runes)-1)*glyphGap
	origin := image.Point{
		X: (imageData.Bounds().Dx() - totalWidth) / 2,
		Y: (imageData.Bounds().Dy() - 7*scale) / 2,
	}
	for index, value := range runes {
		drawGlyph(imageData, value, image.Point{X: origin.X + index*(glyphWidth+glyphGap), Y: origin.Y}, scale, foreground)
	}
}

func drawGlyph(imageData *image.RGBA, value rune, origin image.Point, scale int, foreground color.RGBA) {
	pattern, ok := glyphPatterns[value]
	if !ok {
		pattern = glyphPatterns['?']
	}
	uniform := image.NewUniform(foreground)
	for row, bits := range pattern {
		for column := 0; column < 5; column++ {
			if bits&(1<<(4-column)) == 0 {
				continue
			}
			rect := image.Rect(origin.X+column*scale, origin.Y+row*scale, origin.X+(column+1)*scale, origin.Y+(row+1)*scale)
			draw.Draw(imageData, rect, uniform, image.Point{}, draw.Src)
		}
	}
}

var glyphPatterns = map[rune][7]uint8{
	' ': {0, 0, 0, 0, 0, 0, 0},
	'?': {0b01110, 0b10001, 0b00010, 0b00100, 0b00100, 0, 0b00100},
	'0': {0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110},
	'1': {0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110},
	'2': {0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111},
	'3': {0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110},
	'4': {0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010},
	'5': {0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110},
	'6': {0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110},
	'7': {0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000},
	'8': {0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110},
	'9': {0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b11100},
	'A': {0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001},
	'B': {0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110},
	'C': {0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110},
	'D': {0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110},
	'E': {0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111},
	'F': {0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000},
	'G': {0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110},
	'H': {0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001},
	'I': {0b01110, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110},
	'J': {0b00111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100},
	'K': {0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001},
	'L': {0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111},
	'M': {0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001},
	'N': {0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001},
	'O': {0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110},
	'P': {0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000},
	'Q': {0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101},
	'R': {0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001},
	'S': {0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110},
	'T': {0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100},
	'U': {0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110},
	'V': {0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100},
	'W': {0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001},
	'X': {0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001},
	'Y': {0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100},
	'Z': {0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111},
	'-': {0, 0, 0, 0b11111, 0, 0, 0},
	'_': {0, 0, 0, 0, 0, 0, 0b11111},
	'.': {0, 0, 0, 0, 0, 0b00110, 0b00110},
	':': {0, 0b00110, 0b00110, 0, 0, 0b00110, 0b00110},
	'/': {0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0, 0},
}
