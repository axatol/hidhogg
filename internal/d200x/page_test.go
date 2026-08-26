package d200x

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"image"
	"image/png"
	"testing"
)

func configuredTestPage() Page {
	positions := make([]Position, 0, DisplayPositionCount)
	for index := 0; index < DisplayPositionCount; index++ {
		spec, _ := PositionForWireIndex(byte(index))
		positions = append(positions, Position{
			ID:         "position-" + spec.Name,
			Position:   spec.Name,
			Label:      "Label " + spec.Name,
			Background: "#102030",
		})
	}
	return Page{Positions: positions}
}

func TestPageArchiveIsDeterministicAndMapsAllPositions(t *testing.T) {
	page := configuredTestPage()
	reversed := Page{Positions: append([]Position(nil), page.Positions...)}
	for left, right := 0, len(reversed.Positions)-1; left < right; left, right = left+1, right-1 {
		reversed.Positions[left], reversed.Positions[right] = reversed.Positions[right], reversed.Positions[left]
	}
	first, err := BuildPageArchive(page)
	if err != nil {
		t.Fatal(err)
	}
	second, err := BuildPageArchive(reversed)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first.Data, second.Data) || first.PaddingLength != second.PaddingLength {
		t.Fatal("archive changed when configured positions were reordered")
	}
	if len(first.Data) == 0 || len(first.Data) > MaxPayloadLength {
		t.Fatalf("archive length = %d", len(first.Data))
	}
	for offset := FirstPayloadCapacity; offset < len(first.Data); offset += ProtocolPacketSize {
		if first.Data[offset] == 0 || first.Data[offset] == 0x7c {
			t.Fatalf("archive has an unsafe continuation boundary at %d", offset)
		}
	}

	files := readArchiveFiles(t, first.Data)
	wantFiles := 1 + DisplayPositionCount
	if first.PaddingLength > 0 {
		wantFiles++
	}
	if len(files) != wantFiles {
		t.Fatalf("archive file count = %d, want %d", len(files), wantFiles)
	}
	manifestData := readArchiveFile(t, files, "manifest.json")
	var manifest map[string]struct {
		State     int `json:"State"`
		ViewParam []struct {
			Icon string `json:"Icon"`
		} `json:"ViewParam"`
	}
	if err := json.Unmarshal(manifestData, &manifest); err != nil {
		t.Fatalf("manifest JSON: %v", err)
	}
	if len(manifest) != DisplayPositionCount {
		t.Fatalf("manifest entries = %d, want %d", len(manifest), DisplayPositionCount)
	}
	for index := 0; index < DisplayPositionCount; index++ {
		spec, _ := PositionForWireIndex(byte(index))
		entry, ok := manifest[spec.Name]
		if !ok || entry.State != 0 || len(entry.ViewParam) != 1 {
			t.Fatalf("manifest entry %q = %+v", spec.Name, entry)
		}
		wantIcon := "icons/button-" + twoDigits(index) + ".png"
		if spec.Wide {
			wantIcon = "icons/wide-tile.png"
		}
		if entry.ViewParam[0].Icon != wantIcon {
			t.Fatalf("manifest %q icon = %q, want %q", spec.Name, entry.ViewParam[0].Icon, wantIcon)
		}
	}
	if _, ok := manifest["4_2"]; ok {
		t.Fatal("manifest unexpectedly contains unsupported 4_2 position")
	}

	button := decodeArchivePNG(t, files, "icons/button-00.png")
	if got := button.Bounds().Size(); got != image.Pt(displaySquareWidth, displayTileHeight) {
		t.Fatalf("square geometry = %v", got)
	}
	wide := decodeArchivePNG(t, files, "icons/wide-tile.png")
	if got := wide.Bounds().Size(); got != image.Pt(displayWideWidth, displayTileHeight) {
		t.Fatalf("wide geometry = %v", got)
	}
	r, g, b, a := button.At(20, 20).RGBA()
	if r != 0x10*257 || g != 0x20*257 || b != 0x30*257 || a != 0xffff {
		t.Fatalf("configured background = %#x %#x %#x %#x", r, g, b, a)
	}
}

func TestPageArchiveUsesConfiguredLabelAndColour(t *testing.T) {
	base := configuredTestPage()
	baseArchive, err := BuildPageArchive(base)
	if err != nil {
		t.Fatal(err)
	}
	labelPage := configuredTestPage()
	labelPage.Positions[0].Label = "DIFFERENT"
	labelArchive, err := BuildPageArchive(labelPage)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(baseArchive.Data, labelArchive.Data) {
		t.Fatal("changing a configured label did not change archive bytes")
	}
	colourPage := configuredTestPage()
	colourPage.Positions[0].Background = "#A0B0C0"
	colourArchive, err := BuildPageArchive(colourPage)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(baseArchive.Data, colourArchive.Data) {
		t.Fatal("changing a configured background did not change archive bytes")
	}

	frame, err := PageFrame(base)
	if err != nil {
		t.Fatal(err)
	}
	if frame.Command != CommandCompleteDisplayUpload || !bytes.Equal(frame.Payload, baseArchive.Data) {
		t.Fatal("PageFrame did not carry the configured archive")
	}
}

func TestValidatePageRejectsIncompleteDuplicateAndInvalidConfiguration(t *testing.T) {
	valid := configuredTestPage()
	cases := []struct {
		name   string
		mutate func(*Page)
	}{
		{name: "incomplete", mutate: func(page *Page) { page.Positions = page.Positions[:DisplayPositionCount-1] }},
		{name: "duplicate position", mutate: func(page *Page) { page.Positions[1].Position = page.Positions[0].Position }},
		{name: "duplicate ID", mutate: func(page *Page) { page.Positions[1].ID = page.Positions[0].ID }},
		{name: "unstable ID", mutate: func(page *Page) { page.Positions[0].ID = "not stable" }},
		{name: "unknown position", mutate: func(page *Page) { page.Positions[0].Position = "4_2" }},
		{name: "invalid colour", mutate: func(page *Page) { page.Positions[0].Background = "red" }},
		{name: "control label", mutate: func(page *Page) { page.Positions[0].Label = "bad\nlabel" }},
		{name: "empty label", mutate: func(page *Page) { page.Positions[0].Label = "   " }},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			page := Page{Positions: append([]Position(nil), valid.Positions...)}
			test.mutate(&page)
			if err := ValidatePage(page); err == nil {
				t.Fatal("ValidatePage accepted invalid configuration")
			}
		})
	}
	if parsed, err := ParseBackgroundColor("#10203080"); err != nil || parsed.A != 0x80 {
		t.Fatalf("ParseBackgroundColor alpha form = %#v, error=%v", parsed, err)
	}
	if _, err := ParseBackgroundColor("#zz2030"); err == nil {
		t.Fatal("ParseBackgroundColor accepted non-hex colour")
	}
}

type archiveFile struct {
	name string
	data []byte
}

func readArchiveFiles(t *testing.T, data []byte) []archiveFile {
	t.Helper()
	reader, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		t.Fatalf("zip reader: %v", err)
	}
	files := make([]archiveFile, 0, len(reader.File))
	for _, file := range reader.File {
		contents, err := file.Open()
		if err != nil {
			t.Fatalf("open %q: %v", file.Name, err)
		}
		var buffer bytes.Buffer
		_, copyErr := buffer.ReadFrom(contents)
		closeErr := contents.Close()
		if copyErr != nil || closeErr != nil {
			t.Fatalf("read %q: copy=%v close=%v", file.Name, copyErr, closeErr)
		}
		files = append(files, archiveFile{name: file.Name, data: buffer.Bytes()})
	}
	return files
}

func readArchiveFile(t *testing.T, files []archiveFile, name string) []byte {
	t.Helper()
	for _, file := range files {
		if file.name == name {
			return file.data
		}
	}
	t.Fatalf("archive does not contain %q", name)
	return nil
}

func decodeArchivePNG(t *testing.T, files []archiveFile, name string) image.Image {
	t.Helper()
	data := readArchiveFile(t, files, name)
	decoded, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatalf("decode %q: %v", name, err)
	}
	return decoded
}

func twoDigits(value int) string {
	return fmt.Sprintf("%02d", value)
}
