package d200x

import (
	"bytes"
	"compress/flate"
	"encoding/binary"
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

type displayArchiveFile struct {
	name             string
	compression      uint16
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
		writeUint16(&archive, 0)
		_, _ = archive.Write(name)
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
		writeUint16(&archive, 0)
		writeUint16(&archive, 0)
		writeUint16(&archive, 0)
		writeUint16(&archive, 0)
		writeUint32(&archive, 0)
		writeUint32(&archive, localOffsets[index])
		_, _ = archive.Write(name)
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
