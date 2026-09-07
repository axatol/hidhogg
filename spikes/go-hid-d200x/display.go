package d200x

import (
	"bytes"
	"compress/flate"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"image"
	"image/color"
	"image/draw"
	"image/png"
)

const (
	DiagnosticSquareIconCount = 13
	DiagnosticSquareWidth     = 196
	DiagnosticWideWidth       = 458
	DiagnosticTileHeight      = 196
	DiagnosticMaximumPadding  = 4_096
)

type DisplayArchive struct {
	Data          []byte
	PaddingLength int
}

func BuildDiagnosticDisplayArchive() (DisplayArchive, error) {
	files, err := diagnosticArchiveFiles()
	if err != nil {
		return DisplayArchive{}, err
	}
	for paddingLength := 0; paddingLength < DiagnosticMaximumPadding; paddingLength++ {
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
	return DisplayArchive{}, fmt.Errorf("no firmware-safe diagnostic archive padding below %d bytes", DiagnosticMaximumPadding)
}

func DiagnosticManifest() []byte {
	return append([]byte(nil), diagnosticManifest()...)
}

func DiagnosticDisplayFrame() (Frame, error) {
	archive, err := BuildDiagnosticDisplayArchive()
	if err != nil {
		return Frame{}, err
	}
	return CompleteDisplayUploadFrame(archive.Data)
}

const LiveBulkDisplayPreset = "live-bulk"

func BuildLiveBulkDisplayArchive() (DisplayArchive, error) {
	files, err := liveBulkArchiveFiles()
	if err != nil {
		return DisplayArchive{}, err
	}
	for paddingLength := 0; paddingLength < DiagnosticMaximumPadding; paddingLength++ {
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
	return DisplayArchive{}, fmt.Errorf("no firmware-safe live bulk archive padding below %d bytes", DiagnosticMaximumPadding)
}

func LiveBulkDisplayFrame() (Frame, error) {
	archive, err := BuildLiveBulkDisplayArchive()
	if err != nil {
		return Frame{}, err
	}
	return CompleteDisplayUploadFrame(archive.Data)
}

func liveBulkArchiveFiles() ([]displayArchiveFile, error) {
	icons := make([][]byte, DiagnosticSquareIconCount+1)
	paths := make([]string, len(icons))
	for index := 0; index < DiagnosticSquareIconCount; index++ {
		data, err := liveBulkPNG(DiagnosticSquareWidth, 20+index)
		if err != nil {
			return nil, fmt.Errorf("encode live bulk square tile %02d: %w", index, err)
		}
		icons[index] = data
		paths[index] = contentDerivedIconPath(data)
	}
	wide, err := liveBulkPNG(DiagnosticWideWidth, 20+DiagnosticSquareIconCount)
	if err != nil {
		return nil, fmt.Errorf("encode live bulk wide tile: %w", err)
	}
	icons[len(icons)-1] = wide
	paths[len(paths)-1] = contentDerivedIconPath(wide)

	manifest := liveBulkManifest(paths)
	manifestCompressed, err := deflateRaw(manifest)
	if err != nil {
		return nil, fmt.Errorf("compress live bulk manifest: %w", err)
	}
	files := []displayArchiveFile{{
		name:             "manifest.json",
		compression:      8,
		uncompressedData: manifest,
		compressedData:   manifestCompressed,
		checksum:         crc32.ChecksumIEEE(manifest),
	}}
	for index, data := range icons {
		compressed, err := deflateRaw(data)
		if err != nil {
			return nil, fmt.Errorf("compress live bulk tile %02d: %w", index, err)
		}
		files = append(files, displayArchiveFile{
			name:             paths[index],
			compression:      8,
			uncompressedData: data,
			compressedData:   compressed,
			checksum:         crc32.ChecksumIEEE(data),
		})
	}
	return files, nil
}

func contentDerivedIconPath(data []byte) string {
	digest := sha256.Sum256(data)
	return "Images/" + hex.EncodeToString(digest[:]) + ".png"
}

func liveBulkManifest(paths []string) []byte {
	type manifestEntry struct {
		coordinate string
		iconPath   string
	}
	entries := make([]manifestEntry, 0, DiagnosticSquareIconCount+1)
	for row := 0; row < 3; row++ {
		for column := 0; column < 5; column++ {
			if column == 4 && row == 2 {
				continue
			}
			position := row*5 + column
			iconPath := paths[position]
			if column == 3 && row == 2 {
				iconPath = paths[DiagnosticSquareIconCount]
			}
			entries = append(entries, manifestEntry{
				coordinate: fmt.Sprintf("%d_%d", column, row),
				iconPath:   iconPath,
			})
		}
	}
	var manifest bytes.Buffer
	manifest.WriteString("{\n")
	for index, entry := range entries {
		appendManifestEntry(&manifest, entry.coordinate, entry.iconPath, index == len(entries)-1)
	}
	manifest.WriteString("}")
	return manifest.Bytes()
}

const (
	partialDisplayPresetSquareA      = "square-a"
	partialDisplayPresetSquareB      = "square-b"
	partialDisplayPresetSquareBFresh = "square-b-fresh"
	partialDisplayPresetWide         = "wide"
	partialDisplayFontName           = "Source Han Sans SC"
	partialDisplaySquareIcon         = "Images/live-square.png"
	partialDisplayMaxExtra           = 4_096
)

type partialDisplayPresetDefinition struct {
	coordinate           string
	label                string
	width                int
	iconPath             string
	includeSmallViewMode bool
	border               color.RGBA
}

// BuildPartialDisplayUploadArchive creates the square-a compatibility
// archive. Its only members are the manifest and the bounded square tile.
func BuildPartialDisplayUploadArchive() (DisplayArchive, error) {
	return BuildPartialDisplayUploadArchiveForPreset(partialDisplayPresetSquareA)
}

// BuildPartialDisplayUploadArchiveForPreset creates one bounded experimental
// archive for the exact physical-probe preset name.
func BuildPartialDisplayUploadArchiveForPreset(preset string) (DisplayArchive, error) {
	definition, err := partialDisplayPreset(preset)
	if err != nil {
		return DisplayArchive{}, err
	}
	pngData, err := partialDisplayPNG(definition.width, definition.label, definition.border)
	if err != nil {
		return DisplayArchive{}, fmt.Errorf("encode partial display tile: %w", err)
	}
	iconPath := definition.iconPath
	if iconPath == "" {
		hash := sha256.Sum256(pngData)
		iconPath = "Images/" + hex.EncodeToString(hash[:]) + ".png"
	}
	manifest, err := partialDisplayManifest(definition.coordinate, iconPath, definition.label, definition.includeSmallViewMode)
	if err != nil {
		return DisplayArchive{}, fmt.Errorf("encode partial display manifest: %w", err)
	}
	manifestCompressed, err := deflateRaw(manifest)
	if err != nil {
		return DisplayArchive{}, fmt.Errorf("compress partial display manifest: %w", err)
	}
	pngCompressed, err := deflateRaw(pngData)
	if err != nil {
		return DisplayArchive{}, fmt.Errorf("compress partial display tile: %w", err)
	}
	files := []displayArchiveFile{
		{
			name:             "manifest.json",
			compression:      8,
			uncompressedData: manifest,
			compressedData:   manifestCompressed,
			checksum:         crc32.ChecksumIEEE(manifest),
		},
		{
			name:             iconPath,
			compression:      8,
			uncompressedData: pngData,
			compressedData:   pngCompressed,
			checksum:         crc32.ChecksumIEEE(pngData),
		},
	}
	return buildPartialDisplayArchive(files)
}

func partialDisplayPreset(preset string) (partialDisplayPresetDefinition, error) {
	switch preset {
	case partialDisplayPresetSquareA:
		return partialDisplayPresetDefinition{
			coordinate: partialDisplayCoordinateSquare,
			label:      "LIVE-A",
			width:      DiagnosticSquareWidth,
			iconPath:   partialDisplaySquareIcon,
			border:     color.RGBA{R: 0, G: 220, B: 255, A: 255},
		}, nil
	case partialDisplayPresetSquareB:
		return partialDisplayPresetDefinition{
			coordinate: partialDisplayCoordinateSquare,
			label:      "LIVE-B",
			width:      DiagnosticSquareWidth,
			iconPath:   partialDisplaySquareIcon,
			border:     color.RGBA{R: 255, G: 0, B: 220, A: 255},
		}, nil
	case partialDisplayPresetSquareBFresh:
		return partialDisplayPresetDefinition{
			coordinate: partialDisplayCoordinateSquare,
			label:      "LIVE-B",
			width:      DiagnosticSquareWidth,
			border:     color.RGBA{R: 255, G: 0, B: 220, A: 255},
		}, nil
	case partialDisplayPresetWide:
		return partialDisplayPresetDefinition{
			coordinate:           partialDisplayCoordinateWide,
			label:                "LIVE-WIDE",
			width:                DiagnosticWideWidth,
			includeSmallViewMode: true,
			border:               color.RGBA{R: 255, G: 220, B: 0, A: 255},
		}, nil
	default:
		return partialDisplayPresetDefinition{}, fmt.Errorf("unknown partial display preset %q", preset)
	}
}

// PartialDisplayUploadFrame returns the square-a logical experimental 0x000d
// frame for callers that do not need to select a preset.
func PartialDisplayUploadFrame() (Frame, error) {
	return PartialDisplayUploadFrameForPreset(partialDisplayPresetSquareA)
}

// PartialDisplayUploadFrameForPreset returns one logical experimental 0x000d
// frame for the exact physical-probe preset name.
func PartialDisplayUploadFrameForPreset(preset string) (Frame, error) {
	archive, err := BuildPartialDisplayUploadArchiveForPreset(preset)
	if err != nil {
		return Frame{}, err
	}
	return NewFrame(CommandPartialDisplayUpload, archive.Data), nil
}

const (
	partialDisplayCoordinateSquare = "0_0"
	partialDisplayCoordinateWide   = "3_2"
)

type partialDisplayManifestEntry struct {
	SmallViewMode int                       `json:"SmallViewMode,omitempty"`
	State         int                       `json:"State"`
	ViewParam     []partialDisplayViewParam `json:"ViewParam"`
}

type partialDisplayViewParam struct {
	Font partialDisplayFont `json:"Font"`
	Icon string             `json:"Icon"`
	Text string             `json:"Text"`
}

type partialDisplayFont struct {
	Align     string `json:"Align"`
	Color     int    `json:"Color"`
	FontName  string `json:"FontName"`
	ShowTitle bool   `json:"ShowTitle"`
	Size      int    `json:"Size"`
	Weight    int    `json:"Weight"`
}

func partialDisplayManifest(coordinate, iconPath, label string, includeSmallViewMode bool) ([]byte, error) {
	entry := partialDisplayManifestEntry{
		State: 0,
		ViewParam: []partialDisplayViewParam{{
			Font: partialDisplayFont{
				Align:     "bottom",
				Color:     16_777_215,
				FontName:  partialDisplayFontName,
				ShowTitle: true,
				Size:      10,
				Weight:    80,
			},
			Icon: iconPath,
			Text: label,
		}},
	}
	if includeSmallViewMode {
		entry.SmallViewMode = 2
	}
	return json.Marshal(map[string]partialDisplayManifestEntry{coordinate: entry})
}

func buildPartialDisplayArchive(files []displayArchiveFile) (DisplayArchive, error) {
	if len(files) != 2 {
		return DisplayArchive{}, fmt.Errorf("partial display archive has %d files, want exactly 2", len(files))
	}
	for extraLength := 0; extraLength <= partialDisplayMaxExtra; extraLength++ {
		candidateFiles := append([]displayArchiveFile(nil), files...)
		if extraLength > 0 {
			candidateFiles[0].extra = partialDisplayArchiveExtra(extraLength)
		}
		archive, err := assembleDisplayArchive(candidateFiles, 0)
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
			return DisplayArchive{Data: archive, PaddingLength: extraLength}, nil
		}
	}
	return DisplayArchive{}, fmt.Errorf("no firmware-safe partial display archive extra field below %d bytes", partialDisplayMaxExtra)
}

func partialDisplayArchiveExtra(length int) []byte {
	if length < 4 {
		return nil
	}
	extra := make([]byte, length)
	binary.LittleEndian.PutUint16(extra[0:2], 0xD200)
	binary.LittleEndian.PutUint16(extra[2:4], uint16(length-4))
	for index := 4; index < len(extra); index++ {
		extra[index] = 0xA5
	}
	return extra
}

type displayArchiveFile struct {
	name             string
	compression      uint16
	extra            []byte
	uncompressedData []byte
	compressedData   []byte
	checksum         uint32
}

func diagnosticArchiveFiles() ([]displayArchiveFile, error) {
	manifest := diagnosticManifest()
	manifestCompressed, err := deflateRaw(manifest)
	if err != nil {
		return nil, fmt.Errorf("compress diagnostic manifest: %w", err)
	}
	files := []displayArchiveFile{{
		name:             "manifest.json",
		compression:      8,
		uncompressedData: manifest,
		compressedData:   manifestCompressed,
		checksum:         crc32.ChecksumIEEE(manifest),
	}}
	for index := 0; index < DiagnosticSquareIconCount; index++ {
		pngData, err := diagnosticPNG(DiagnosticSquareWidth, index)
		if err != nil {
			return nil, fmt.Errorf("encode diagnostic tile %02d: %w", index, err)
		}
		compressed, err := deflateRaw(pngData)
		if err != nil {
			return nil, fmt.Errorf("compress diagnostic tile %02d: %w", index, err)
		}
		files = append(files, displayArchiveFile{
			name:             fmt.Sprintf("icons/button-%02d.png", index),
			compression:      8,
			uncompressedData: pngData,
			compressedData:   compressed,
			checksum:         crc32.ChecksumIEEE(pngData),
		})
	}
	widePNG, err := diagnosticPNG(DiagnosticWideWidth, DiagnosticSquareIconCount)
	if err != nil {
		return nil, fmt.Errorf("encode diagnostic wide tile: %w", err)
	}
	wideCompressed, err := deflateRaw(widePNG)
	if err != nil {
		return nil, fmt.Errorf("compress diagnostic wide tile: %w", err)
	}
	files = append(files, displayArchiveFile{
		name:             "icons/wide-tile.png",
		compression:      8,
		uncompressedData: widePNG,
		compressedData:   wideCompressed,
		checksum:         crc32.ChecksumIEEE(widePNG),
	})
	return files, nil
}

func diagnosticManifest() []byte {
	var manifest bytes.Buffer
	manifest.WriteString("{\n")
	for column := 0; column < 5; column++ {
		for row := 0; row < 3; row++ {
			if column == 4 && row == 2 {
				continue
			}
			if column == 3 && row == 2 {
				appendManifestEntry(&manifest, "3_2", "icons/wide-tile.png", false)
				continue
			}
			position := row*5 + column
			isLast := column == 4 && row == 1
			appendManifestEntry(&manifest, fmt.Sprintf("%d_%d", column, row), fmt.Sprintf("icons/button-%02d.png", position), isLast)
		}
	}
	manifest.WriteString("}")
	return manifest.Bytes()
}

func appendManifestEntry(manifest *bytes.Buffer, key, iconPath string, isLast bool) {
	fmt.Fprintf(manifest, "  \"%s\":{\n", key)
	manifest.WriteString("    \"State\":0,\n")
	manifest.WriteString("    \"ViewParam\":[\n")
	manifest.WriteString("      {\n")
	fmt.Fprintf(manifest, "        \"Icon\":\"%s\"\n", iconPath)
	manifest.WriteString("      }\n")
	manifest.WriteString("    ]\n")
	if isLast {
		manifest.WriteString("  }\n")
	} else {
		manifest.WriteString("  },\n")
	}
}

func deflateRaw(data []byte) ([]byte, error) {
	var compressed bytes.Buffer
	writer, err := flate.NewWriter(&compressed, flate.BestSpeed)
	if err != nil {
		return nil, err
	}
	if _, err := writer.Write(data); err != nil {
		_ = writer.Close()
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return compressed.Bytes(), nil
}

func assembleDisplayArchive(files []displayArchiveFile, paddingLength int) ([]byte, error) {
	if paddingLength < 0 || paddingLength >= DiagnosticMaximumPadding {
		return nil, fmt.Errorf("invalid display archive padding length %d", paddingLength)
	}
	ordered := make([]displayArchiveFile, 0, len(files)+1)
	if paddingLength > 0 {
		dummy := make([]byte, paddingLength)
		ordered = append(ordered, displayArchiveFile{
			name:             "dummy.txt",
			compression:      0,
			uncompressedData: dummy,
			compressedData:   dummy,
			checksum:         crc32.ChecksumIEEE(dummy),
		})
	}
	ordered = append(ordered, files...)
	if len(ordered) > 0xFFFF {
		return nil, fmt.Errorf("display archive contains too many files")
	}

	var archive bytes.Buffer
	localOffsets := make([]uint32, len(ordered))
	for index, file := range ordered {
		name, err := archiveName(file.name)
		if err != nil {
			return nil, err
		}
		if len(file.compressedData) > 0xFFFFFFFF || len(file.uncompressedData) > 0xFFFFFFFF || archive.Len() > 0xFFFFFFFF {
			return nil, fmt.Errorf("display archive field overflow")
		}
		if len(file.extra) > 0xFFFF {
			return nil, fmt.Errorf("display archive extra field too long")
		}
		localOffsets[index] = uint32(archive.Len())
		writeUint32(&archive, 0x04034B50)
		if file.compression == 0 {
			writeUint16(&archive, 10)
		} else {
			writeUint16(&archive, 20)
		}
		writeUint16(&archive, 0)
		writeUint16(&archive, file.compression)
		writeUint16(&archive, 0)
		writeUint16(&archive, 0x0021)
		writeUint32(&archive, file.checksum)
		writeUint32(&archive, uint32(len(file.compressedData)))
		writeUint32(&archive, uint32(len(file.uncompressedData)))
		writeUint16(&archive, uint16(len(name)))
		writeUint16(&archive, uint16(len(file.extra)))
		_, _ = archive.Write(name)
		_, _ = archive.Write(file.extra)
		_, _ = archive.Write(file.compressedData)
	}

	centralOffset := archive.Len()
	for index, file := range ordered {
		name, err := archiveName(file.name)
		if err != nil {
			return nil, err
		}
		writeUint32(&archive, 0x02014B50)
		writeUint16(&archive, 20)
		if file.compression == 0 {
			writeUint16(&archive, 10)
		} else {
			writeUint16(&archive, 20)
		}
		writeUint16(&archive, 0)
		writeUint16(&archive, file.compression)
		writeUint16(&archive, 0)
		writeUint16(&archive, 0x0021)
		writeUint32(&archive, file.checksum)
		writeUint32(&archive, uint32(len(file.compressedData)))
		writeUint32(&archive, uint32(len(file.uncompressedData)))
		writeUint16(&archive, uint16(len(name)))
		writeUint16(&archive, uint16(len(file.extra)))
		writeUint16(&archive, 0)
		writeUint16(&archive, 0)
		writeUint16(&archive, 0)
		writeUint32(&archive, 0)
		writeUint32(&archive, localOffsets[index])
		_, _ = archive.Write(name)
		_, _ = archive.Write(file.extra)
	}

	centralSize := archive.Len() - centralOffset
	if centralOffset > 0xFFFFFFFF || centralSize > 0xFFFFFFFF {
		return nil, fmt.Errorf("display archive directory field overflow")
	}
	writeUint32(&archive, 0x06054B50)
	writeUint16(&archive, 0)
	writeUint16(&archive, 0)
	writeUint16(&archive, uint16(len(ordered)))
	writeUint16(&archive, uint16(len(ordered)))
	writeUint32(&archive, uint32(centralSize))
	writeUint32(&archive, uint32(centralOffset))
	writeUint16(&archive, 0)
	return archive.Bytes(), nil
}

func archiveName(name string) ([]byte, error) {
	encoded := []byte(name)
	if len(encoded) > 0xFFFF {
		return nil, fmt.Errorf("display archive filename too long")
	}
	return encoded, nil
}

func writeUint16(buffer *bytes.Buffer, value uint16) {
	var encoded [2]byte
	binary.LittleEndian.PutUint16(encoded[:], value)
	_, _ = buffer.Write(encoded[:])
}

func writeUint32(buffer *bytes.Buffer, value uint32) {
	var encoded [4]byte
	binary.LittleEndian.PutUint32(encoded[:], value)
	_, _ = buffer.Write(encoded[:])
}

func firmwareSafeArchive(archive []byte) bool {
	for offset := FirstPayloadCapacity; offset < len(archive); offset += ProtocolPacketSize {
		if archive[offset] == 0 || archive[offset] == 0x7c {
			return false
		}
	}
	return true
}

func diagnosticPNG(width, label int) ([]byte, error) {
	imageData := image.NewRGBA(image.Rect(0, 0, width, DiagnosticTileHeight))
	draw.Draw(imageData, imageData.Bounds(), image.NewUniform(color.RGBA{R: 5, G: 12, B: 24, A: 255}), image.Point{}, draw.Src)
	accent := color.RGBA{R: uint8(80 + (label*29)%150), G: uint8(180 - (label*17)%100), B: uint8(220 - (label*11)%90), A: 255}
	drawBorder(imageData, 5, accent)
	drawNumber(imageData, label, accent)
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, imageData); err != nil {
		return nil, err
	}
	return encoded.Bytes(), nil
}

func liveBulkPNG(width, label int) ([]byte, error) {
	imageData := image.NewRGBA(image.Rect(0, 0, width, DiagnosticTileHeight))
	background := color.RGBA{
		R: uint8(18 + (label*7)%32),
		G: uint8(5 + (label*5)%24),
		B: uint8(30 + (label*11)%40),
		A: 255,
	}
	accent := color.RGBA{
		R: uint8(120 + (label*17)%120),
		G: uint8(50 + (label*31)%150),
		B: uint8(80 + (label*43)%150),
		A: 255,
	}
	draw.Draw(imageData, imageData.Bounds(), image.NewUniform(background), image.Point{}, draw.Src)
	drawBorder(imageData, 5, accent)
	drawNumber(imageData, label, accent)
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, imageData); err != nil {
		return nil, err
	}
	return encoded.Bytes(), nil
}

var partialDisplayGlyphs = map[rune][]string{
	'-': {
		"00000",
		"00000",
		"00000",
		"11111",
		"00000",
		"00000",
		"00000",
	},
	'0': {
		"11111",
		"10001",
		"10001",
		"10001",
		"10001",
		"10001",
		"11111",
	},
	'D': {
		"11110",
		"10001",
		"10001",
		"10001",
		"10001",
		"10001",
		"11110",
	},
	'E': {
		"11111",
		"10000",
		"10000",
		"11110",
		"10000",
		"10000",
		"11111",
	},
	'I': {
		"11111",
		"00100",
		"00100",
		"00100",
		"00100",
		"00100",
		"11111",
	},
	'L': {
		"10000",
		"10000",
		"10000",
		"10000",
		"10000",
		"10000",
		"11111",
	},
	'V': {
		"10001",
		"10001",
		"10001",
		"10001",
		"10001",
		"01010",
		"00100",
	},
	'W': {
		"10001",
		"10001",
		"10001",
		"10101",
		"10101",
		"11011",
		"10001",
	},
	'?': {
		"11110",
		"00001",
		"00010",
		"00100",
		"00100",
		"00000",
		"00100",
	},
}

func partialDisplayPNG(width int, label string, border color.RGBA) ([]byte, error) {
	if width <= 0 || DiagnosticTileHeight <= 0 {
		return nil, fmt.Errorf("partial display tile dimensions must be positive")
	}
	imageData := image.NewRGBA(image.Rect(0, 0, width, DiagnosticTileHeight))
	draw.Draw(imageData, imageData.Bounds(), image.NewUniform(color.RGBA{A: 255}), image.Point{}, draw.Src)
	drawBorder(imageData, 6, border)
	drawPartialDisplayLabel(imageData, label, color.RGBA{R: 255, G: 255, B: 255, A: 255})
	var encoded bytes.Buffer
	if err := png.Encode(&encoded, imageData); err != nil {
		return nil, err
	}
	return encoded.Bytes(), nil
}

func drawPartialDisplayLabel(imageData *image.RGBA, label string, foreground color.RGBA) {
	const (
		glyphWidth  = 5
		glyphHeight = 7
		glyphGap    = 1
		scale       = 3
	)
	runes := []rune(label)
	totalWidth := len(runes)*glyphWidth*scale + (len(runes)-1)*glyphGap*scale
	originX := (imageData.Bounds().Dx() - totalWidth) / 2
	originY := (imageData.Bounds().Dy() - glyphHeight*scale) / 2
	uniform := image.NewUniform(foreground)
	for index, value := range runes {
		pattern, ok := partialDisplayGlyphs[value]
		if !ok {
			pattern = partialDisplayGlyphs['?']
		}
		glyphX := originX + index*(glyphWidth+glyphGap)*scale
		for row, line := range pattern {
			for column, bit := range line {
				if bit != '1' {
					continue
				}
				x := glyphX + column*scale
				y := originY + row*scale
				draw.Draw(imageData, image.Rect(x, y, x+scale, y+scale), uniform, image.Point{}, draw.Src)
			}
		}
	}
}

func drawBorder(imageData *image.RGBA, thickness int, border color.Color) {
	width := imageData.Bounds().Dx()
	height := imageData.Bounds().Dy()
	uniform := image.NewUniform(border)
	draw.Draw(imageData, image.Rect(0, 0, width, thickness), uniform, image.Point{}, draw.Src)
	draw.Draw(imageData, image.Rect(0, height-thickness, width, height), uniform, image.Point{}, draw.Src)
	draw.Draw(imageData, image.Rect(0, 0, thickness, height), uniform, image.Point{}, draw.Src)
	draw.Draw(imageData, image.Rect(width-thickness, 0, width, height), uniform, image.Point{}, draw.Src)
}

func drawNumber(imageData *image.RGBA, value int, segmentColor color.Color) {
	digits := []int{value}
	if value >= 10 {
		digits = []int{value / 10, value % 10}
	}
	segmentHeight := min(imageData.Bounds().Dy()/2, imageData.Bounds().Dx()/5)
	digitWidth := segmentHeight / 2
	gap := max(8, segmentHeight/8)
	totalWidth := len(digits)*digitWidth + (len(digits)-1)*gap
	originX := (imageData.Bounds().Dx() - totalWidth) / 2
	originY := (imageData.Bounds().Dy() - segmentHeight) / 2
	for index, digit := range digits {
		drawDigit(imageData, digit, image.Point{X: originX + index*(digitWidth+gap), Y: originY}, digitWidth, segmentHeight, segmentColor)
	}
}

func drawDigit(imageData *image.RGBA, digit int, origin image.Point, width, height int, segmentColor color.Color) {
	if digit < 0 || digit > 9 {
		return
	}
	segments := [...]uint8{
		0b1111110,
		0b0110000,
		0b1101101,
		0b1111001,
		0b0110011,
		0b1011011,
		0b1011111,
		0b1110000,
		0b1111111,
		0b1111011,
	}
	thickness := max(4, width/5)
	verticalHeight := (height - 3*thickness) / 2
	uniform := image.NewUniform(segmentColor)
	drawSegment := func(rect image.Rectangle) {
		draw.Draw(imageData, rect, uniform, image.Point{}, draw.Src)
	}
	mask := segments[digit]
	if mask&0b1000000 != 0 {
		drawSegment(image.Rect(origin.X+thickness/2, origin.Y, origin.X+width-thickness/2, origin.Y+thickness))
	}
	if mask&0b0100000 != 0 {
		drawSegment(image.Rect(origin.X+width-thickness, origin.Y+thickness/2, origin.X+width, origin.Y+thickness+verticalHeight+thickness/2))
	}
	if mask&0b0010000 != 0 {
		drawSegment(image.Rect(origin.X+width-thickness, origin.Y+2*thickness+verticalHeight/2, origin.X+width, origin.Y+2*thickness+verticalHeight+thickness))
	}
	if mask&0b0001000 != 0 {
		drawSegment(image.Rect(origin.X+thickness/2, origin.Y+height-thickness, origin.X+width-thickness/2, origin.Y+height))
	}
	if mask&0b0000100 != 0 {
		drawSegment(image.Rect(origin.X, origin.Y+2*thickness+verticalHeight/2, origin.X+thickness, origin.Y+2*thickness+verticalHeight+thickness))
	}
	if mask&0b0000010 != 0 {
		drawSegment(image.Rect(origin.X, origin.Y+thickness/2, origin.X+thickness, origin.Y+thickness+verticalHeight+thickness/2))
	}
	if mask&0b0000001 != 0 {
		drawSegment(image.Rect(origin.X+thickness/2, origin.Y+height/2-thickness/2, origin.X+width-thickness/2, origin.Y+height/2+thickness/2))
	}
}
