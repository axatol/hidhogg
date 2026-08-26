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
)

const (
	displaySquareWidth    = 196
	displayWideWidth      = 458
	displayTileHeight     = 196
	displayMaximumPadding = 4_096
)

type DisplayArchive struct {
	Data          []byte
	PaddingLength int
}

type displayArchiveFile struct {
	name             string
	compression      uint16
	uncompressedData []byte
	compressedData   []byte
	checksum         uint32
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
	if paddingLength < 0 || paddingLength >= displayMaximumPadding {
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

func drawBorder(imageData *image.RGBA, thickness int, border color.Color) {
	width := imageData.Bounds().Dx()
	height := imageData.Bounds().Dy()
	uniform := image.NewUniform(border)
	draw.Draw(imageData, image.Rect(0, 0, width, thickness), uniform, image.Point{}, draw.Src)
	draw.Draw(imageData, image.Rect(0, height-thickness, width, height), uniform, image.Point{}, draw.Src)
	draw.Draw(imageData, image.Rect(0, 0, thickness, height), uniform, image.Point{}, draw.Src)
	draw.Draw(imageData, image.Rect(width-thickness, 0, width, height), uniform, image.Point{}, draw.Src)
}
