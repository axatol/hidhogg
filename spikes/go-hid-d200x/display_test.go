package d200x

import (
	"archive/zip"
	"bytes"
	"image"
	"reflect"
	"sort"
	"testing"
)

func TestDiagnosticDisplayArchiveIsDeterministicAndFirmwareSafe(t *testing.T) {
	first, err := BuildDiagnosticDisplayArchive()
	if err != nil {
		t.Fatal(err)
	}
	second, err := BuildDiagnosticDisplayArchive()
	if err != nil {
		t.Fatal(err)
	}
	if first.PaddingLength != second.PaddingLength || !bytes.Equal(first.Data, second.Data) {
		t.Fatalf("archive is not deterministic: padding %d/%d, bytes equal=%v", first.PaddingLength, second.PaddingLength, bytes.Equal(first.Data, second.Data))
	}
	if len(first.Data) <= FirstPayloadCapacity {
		t.Fatalf("diagnostic archive length = %d, want continuation payload", len(first.Data))
	}
	for offset := FirstPayloadCapacity; offset < len(first.Data); offset += ProtocolPacketSize {
		if first.Data[offset] == 0 || first.Data[offset] == 0x7c {
			t.Fatalf("firmware-unsafe archive boundary at %d: 0x%02x", offset, first.Data[offset])
		}
	}
}

func TestDiagnosticDisplayArchiveContainsNumberedGeometryAndManifest(t *testing.T) {
	archive, err := BuildDiagnosticDisplayArchive()
	if err != nil {
		t.Fatal(err)
	}
	reader, err := zip.NewReader(bytes.NewReader(archive.Data), int64(len(archive.Data)))
	if err != nil {
		t.Fatalf("read ZIP: %v", err)
	}
	wantNames := []string{"manifest.json"}
	if archive.PaddingLength > 0 {
		wantNames = append(wantNames, "dummy.txt")
	}
	for index := 0; index < DiagnosticSquareIconCount; index++ {
		wantNames = append(wantNames, formatDiagnosticIconName(index))
	}
	wantNames = append(wantNames, "icons/wide-tile.png")
	gotNames := make([]string, 0, len(reader.File))
	for _, file := range reader.File {
		gotNames = append(gotNames, file.Name)
		data, err := readZIPFile(file)
		if err != nil {
			t.Fatalf("read %s: %v", file.Name, err)
		}
		if file.Name == "manifest.json" {
			if !bytes.Equal(data, DiagnosticManifest()) {
				t.Fatalf("manifest differs from canonical bytes")
			}
			continue
		}
		if file.Name == "dummy.txt" {
			continue
		}
		config, _, err := image.DecodeConfig(bytes.NewReader(data))
		if err != nil {
			t.Fatalf("decode %s: %v", file.Name, err)
		}
		wantWidth := DiagnosticSquareWidth
		if file.Name == "icons/wide-tile.png" {
			wantWidth = DiagnosticWideWidth
		}
		if config.Width != wantWidth || config.Height != DiagnosticTileHeight {
			t.Fatalf("%s geometry = %dx%d", file.Name, config.Width, config.Height)
		}
	}
	sort.Strings(gotNames)
	sort.Strings(wantNames)
	if !reflect.DeepEqual(gotNames, wantNames) {
		t.Fatalf("ZIP names = %v, want %v", gotNames, wantNames)
	}
}

func TestDiagnosticDisplayFrameUploadsThenUnlocks(t *testing.T) {
	display, err := DiagnosticDisplayFrame()
	if err != nil {
		t.Fatal(err)
	}
	if display.Command != CommandCompleteDisplayUpload || len(display.Payload) == 0 {
		t.Fatalf("display frame = %#v", display)
	}
	if unlock := UnlockScreenFrame(); unlock.Command != CommandUnlockScreen || len(unlock.Payload) != 0 {
		t.Fatalf("unlock frame = %#v", unlock)
	}
	reports, err := EncodeFrame(display)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeFrame(reports)
	if err != nil || decoded.Command != CommandCompleteDisplayUpload || !bytes.Equal(decoded.Payload, display.Payload) {
		t.Fatalf("display round trip = %#v, error=%v", decoded, err)
	}
}

func formatDiagnosticIconName(index int) string {
	return "icons/button-" + string([]byte{byte('0' + index/10), byte('0' + index%10)}) + ".png"
}

func readZIPFile(file *zip.File) ([]byte, error) {
	reader, err := file.Open()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	var data bytes.Buffer
	_, err = data.ReadFrom(reader)
	if err != nil {
		return nil, err
	}
	return data.Bytes(), nil
}
