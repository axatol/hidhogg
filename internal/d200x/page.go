package d200x

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"image/color"
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
	LabelAlignmentBottom   = "bottom"
	LabelAlignmentCenter   = "center"
	DefaultLabelAlignment  = LabelAlignmentBottom
	DefaultLabelSize       = 10
	MinimumLabelSize       = 8
	MaximumLabelSize       = 32
)

// Position is one explicitly configured D200X display position. Position is
// zero-based: 0 through 12 are square tiles and 13 is the wide tile.
type Position struct {
	ID             string
	Position       string
	Label          string
	Background     string
	LabelAlignment string
	LabelSize      int
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
	for index := range positions {
		positions[index] = effectivePositionStyle(positions[index])
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
		if !validLabelAlignment(position.LabelAlignment) {
			return nil, fmt.Errorf("D200X display position %d has an invalid label alignment", index)
		}
		if !validLabelSize(position.LabelSize) {
			return nil, fmt.Errorf("D200X display position %d has an invalid label size", index)
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

// ValidatePosition checks one configured display position without requiring a
// complete page. Targeted live updates use the same field and coordinate
// invariants as complete page uploads.
func ValidatePosition(position Position) error {
	if _, ok := LookupPosition(position.Position); !ok {
		return fmt.Errorf("D200X display position %q is unsupported", position.Position)
	}
	if !validPositionID(position.ID) {
		return fmt.Errorf("D200X display position has an invalid ID")
	}
	if !validPositionLabel(position.Label) {
		return fmt.Errorf("D200X display position has an invalid label")
	}
	if !validLabelAlignment(position.LabelAlignment) {
		return fmt.Errorf("D200X display position has an invalid label alignment")
	}
	if !validLabelSize(position.LabelSize) {
		return fmt.Errorf("D200X display position has an invalid label size")
	}
	if _, err := PositionBackground(position); err != nil {
		return fmt.Errorf("D200X display position background: %w", err)
	}
	return nil
}

func validLabelAlignment(value string) bool {
	return value == "" || value == LabelAlignmentBottom || value == LabelAlignmentCenter
}

func validLabelSize(value int) bool {
	return value == 0 || value >= MinimumLabelSize && value <= MaximumLabelSize
}

func effectivePositionStyle(position Position) Position {
	if position.LabelAlignment == "" {
		position.LabelAlignment = DefaultLabelAlignment
	}
	if position.LabelSize == 0 {
		position.LabelSize = DefaultLabelSize
	}
	return position
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
// page. Tile PNGs contain only the configured background and border; labels
// are rendered by firmware from the manifest's text and font fields.
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
	return completeDisplayUploadFrame(archive.Data)
}

// SendPageUpload validates and renders one configured complete-page upload
// before taking the session write lock. It is the typed operation for callers
// that need a page upload without startup brightness or wake primitives.
func (s *Session) SendPageUpload(ctx context.Context, page Page) error {
	if s == nil {
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	display, err := PageFrame(page)
	if err != nil {
		return err
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	return s.sendFrameLocked(ctx, display)
}

// SendPage builds the canonical content-addressed page update before any
// transport write, then delegates the startup transaction to
// SendStartupPageUpdate.
func (s *Session) SendPage(ctx context.Context, page Page, brightness int) error {
	if s == nil {
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	if brightness < 0 || brightness > 100 {
		return &ProtocolError{Kind: ErrorInvalidBrightness, Actual: brightness, Expected: 100}
	}
	update, err := BuildLivePageUpdate(page)
	if err != nil {
		return err
	}
	return s.SendStartupPageUpdate(ctx, update, brightness)
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
		var pngData []byte
		if spec.Wide {
			pngData, err = configuredWidePNG(position, background)
		} else {
			pngData, err = configuredPNG(width, background)
		}
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
		entry := positionManifestEntry(position, iconPath, spec.Wide)
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
