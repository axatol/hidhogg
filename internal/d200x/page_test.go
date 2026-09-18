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
	manifest := readManifest(t, manifestData)
	if len(manifest) != DisplayPositionCount {
		t.Fatalf("manifest entries = %d, want %d", len(manifest), DisplayPositionCount)
	}
	for index := 0; index < DisplayPositionCount; index++ {
		spec, _ := PositionForWireIndex(byte(index))
		entry, ok := manifest[spec.Name]
		if !ok || entry.State != 0 || len(entry.ViewParam) != 1 {
			t.Fatalf("manifest entry %q = %+v", spec.Name, entry)
		}
		if entry.ViewParam[0].Font.Align != DefaultLabelAlignment || entry.ViewParam[0].Font.Size != DefaultLabelSize {
			t.Fatalf("manifest %q style = %+v, want %s/%d", spec.Name, entry.ViewParam[0].Font, DefaultLabelAlignment, DefaultLabelSize)
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
	baseFiles := readArchiveFiles(t, baseArchive.Data)
	labelFiles := readArchiveFiles(t, labelArchive.Data)
	if !bytes.Equal(readArchiveFile(t, baseFiles, "icons/button-00.png"), readArchiveFile(t, labelFiles, "icons/button-00.png")) {
		t.Fatal("changing a configured label changed PNG bytes")
	}
	if bytes.Equal(readArchiveFile(t, baseFiles, "manifest.json"), readArchiveFile(t, labelFiles, "manifest.json")) {
		t.Fatal("changing a configured label did not change manifest bytes")
	}

	styledPage := configuredTestPage()
	styledPage.Positions[0].LabelAlignment = LabelAlignmentCenter
	styledPage.Positions[0].LabelSize = 24
	styledArchive, err := BuildPageArchive(styledPage)
	if err != nil {
		t.Fatal(err)
	}
	styledFiles := readArchiveFiles(t, styledArchive.Data)
	styledEntry := readManifest(t, readArchiveFile(t, styledFiles, "manifest.json"))["0_0"]
	if styledEntry.ViewParam[0].Font.Align != LabelAlignmentCenter || styledEntry.ViewParam[0].Font.Size != 24 {
		t.Fatalf("configured style = %+v, want %s/24", styledEntry.ViewParam[0].Font, LabelAlignmentCenter)
	}
	if !bytes.Equal(readArchiveFile(t, baseFiles, "icons/button-00.png"), readArchiveFile(t, styledFiles, "icons/button-00.png")) {
		t.Fatal("changing label style changed PNG bytes")
	}
	if bytes.Equal(readArchiveFile(t, baseFiles, "manifest.json"), readArchiveFile(t, styledFiles, "manifest.json")) {
		t.Fatal("changing label style did not change manifest bytes")
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
	colourFiles := readArchiveFiles(t, colourArchive.Data)
	if bytes.Equal(readArchiveFile(t, baseFiles, "icons/button-00.png"), readArchiveFile(t, colourFiles, "icons/button-00.png")) {
		t.Fatal("changing a configured background did not change PNG bytes")
	}

	frame, err := PageFrame(base)
	if err != nil {
		t.Fatal(err)
	}
	if frame.Command != CommandCompleteDisplayUpload || !bytes.Equal(frame.Payload, baseArchive.Data) {
		t.Fatal("PageFrame did not carry the configured archive")
	}
}

func TestPageArchiveWideLabelFallbackRendersOnlyWideTile(t *testing.T) {
	base := configuredTestPage()
	baseArchive, err := BuildPageArchive(base)
	if err != nil {
		t.Fatal(err)
	}
	baseFiles := readArchiveFiles(t, baseArchive.Data)
	baseWide := readArchiveFile(t, baseFiles, "icons/wide-tile.png")
	baseSquare := readArchiveFile(t, baseFiles, "icons/button-00.png")
	if !hasConfiguredInteriorInk(t, baseWide, base.Positions[13].Background) {
		t.Fatal("default wide label did not render visible interior pixels")
	}

	labelPage := configuredTestPage()
	labelPage.Positions[13].Label = "Enter 0123456789.*+"
	labelArchive, err := BuildPageArchive(labelPage)
	if err != nil {
		t.Fatal(err)
	}
	labelFiles := readArchiveFiles(t, labelArchive.Data)
	labelWide := readArchiveFile(t, labelFiles, "icons/wide-tile.png")
	if bytes.Equal(baseWide, labelWide) {
		t.Fatal("changing the wide label did not change rendered PNG bytes")
	}
	if !bytes.Equal(baseSquare, readArchiveFile(t, labelFiles, "icons/button-00.png")) {
		t.Fatal("changing the wide label changed square PNG bytes")
	}

	styledPage := labelPage
	styledPage.Positions[13].LabelAlignment = LabelAlignmentCenter
	styledPage.Positions[13].LabelSize = 24
	styledArchive, err := BuildPageArchive(styledPage)
	if err != nil {
		t.Fatal(err)
	}
	styledFiles := readArchiveFiles(t, styledArchive.Data)
	styledWide := readArchiveFile(t, styledFiles, "icons/wide-tile.png")
	if bytes.Equal(labelWide, styledWide) {
		t.Fatal("changing the wide label style did not change rendered PNG bytes")
	}
	if !bytes.Equal(baseSquare, readArchiveFile(t, styledFiles, "icons/button-00.png")) {
		t.Fatal("changing the wide label style changed square PNG bytes")
	}

	repeated, err := BuildPageArchive(styledPage)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(styledArchive.Data, repeated.Data) || styledArchive.PaddingLength != repeated.PaddingLength {
		t.Fatal("wide label rendering was nondeterministic")
	}

	manifest := readManifest(t, readArchiveFile(t, labelFiles, "manifest.json"))
	wideEntry := manifest["3_2"]
	if wideEntry.SmallViewMode == nil || *wideEntry.SmallViewMode != 2 {
		t.Fatalf("wide SmallViewMode = %v, want 2", wideEntry.SmallViewMode)
	}
	if wideEntry.ViewParam[0].Text != labelPage.Positions[13].Label {
		t.Fatalf("wide manifest text = %q, want %q", wideEntry.ViewParam[0].Text, labelPage.Positions[13].Label)
	}
	if wideEntry.ViewParam[0].Font.ShowTitle {
		t.Fatal("wide manifest retained a firmware title after baking the label into the PNG")
	}
}

func hasConfiguredInteriorInk(t *testing.T, data []byte, backgroundValue string) bool {
	t.Helper()
	background, err := ParseBackgroundColor(backgroundValue)
	if err != nil {
		t.Fatalf("background: %v", err)
	}
	decoded := decodeArchivePNG(t, []archiveFile{{name: "wide", data: data}}, "wide")
	inner := decoded.Bounds().Inset(5)
	for y := inner.Min.Y; y < inner.Max.Y; y++ {
		for x := inner.Min.X; x < inner.Max.X; x++ {
			r, g, b, a := decoded.At(x, y).RGBA()
			if r != uint32(background.R)*257 || g != uint32(background.G)*257 || b != uint32(background.B)*257 || a != uint32(background.A)*257 {
				return true
			}
		}
	}
	return false
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
		{name: "invalid label alignment", mutate: func(page *Page) { page.Positions[0].LabelAlignment = "top" }},
		{name: "label size below minimum", mutate: func(page *Page) { page.Positions[0].LabelSize = MinimumLabelSize - 1 }},
		{name: "label size above maximum", mutate: func(page *Page) { page.Positions[0].LabelSize = MaximumLabelSize + 1 }},
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

type testManifestEntry struct {
	SmallViewMode *int               `json:"SmallViewMode"`
	State         int                `json:"State"`
	ViewParam     []testManifestView `json:"ViewParam"`
}

type testManifestView struct {
	Font testManifestFont `json:"Font"`
	Icon string           `json:"Icon"`
	Text string           `json:"Text"`
}

type testManifestFont struct {
	Align     string `json:"Align"`
	Color     int    `json:"Color"`
	FontName  string `json:"FontName"`
	ShowTitle bool   `json:"ShowTitle"`
	Size      int    `json:"Size"`
	Weight    int    `json:"Weight"`
}

func readManifest(t *testing.T, data []byte) map[string]testManifestEntry {
	t.Helper()
	var manifest map[string]testManifestEntry
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatalf("manifest JSON: %v", err)
	}
	return manifest
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
