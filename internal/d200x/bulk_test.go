package d200x

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"image"
	"image/png"
	"testing"
)

func TestLivePageArchiveContainsCanonicalContentAddressedPage(t *testing.T) {
	page := configuredTestPage()
	update, err := BuildLivePageUpdate(page)
	if err != nil {
		t.Fatal(err)
	}
	if effective := update.Page().Positions[0]; effective.LabelAlignment != DefaultLabelAlignment || effective.LabelSize != DefaultLabelSize {
		t.Fatalf("effective full-page update style = %s/%d, want %s/%d", effective.LabelAlignment, effective.LabelSize, DefaultLabelAlignment, DefaultLabelSize)
	}
	archive, err := BuildLivePageArchive(page)
	if err != nil {
		t.Fatal(err)
	}
	files := readArchiveFiles(t, archive.Data)
	wantIconPaths := make(map[string]struct{})
	for _, position := range page.Positions {
		spec, ok := LookupPosition(position.Position)
		if !ok {
			t.Fatalf("test position %q is not supported", position.Position)
		}
		if spec.Wide {
			wantIconPaths["wide"] = struct{}{}
		} else {
			wantIconPaths["square"] = struct{}{}
		}
	}
	wantMembers := 1 + len(wantIconPaths)
	if archive.PaddingLength > 0 {
		wantMembers++
	}
	if len(files) != wantMembers {
		t.Fatalf("archive members = %d, want %d", len(files), wantMembers)
	}
	manifest := readManifest(t, readArchiveFile(t, files, livePositionManifestName))
	if len(manifest) != DisplayPositionCount {
		t.Fatalf("manifest coordinates = %d, want %d", len(manifest), DisplayPositionCount)
	}
	for _, spec := range SupportedPositions() {
		entryData, ok := manifest[spec.Name]
		if !ok {
			t.Fatalf("manifest missing canonical coordinate %q", spec.Name)
		}
		entry := entryData
		if len(entry.ViewParam) != 1 {
			t.Fatalf("manifest entry %q view count = %d, want one", spec.Name, len(entry.ViewParam))
		}
		if entry.ViewParam[0].Text != page.Positions[spec.WireIndex].Label {
			t.Fatalf("manifest entry %q text = %q, want %q", spec.Name, entry.ViewParam[0].Text, page.Positions[spec.WireIndex].Label)
		}
		if entry.ViewParam[0].Font.Align != DefaultLabelAlignment || entry.ViewParam[0].Font.Size != DefaultLabelSize {
			t.Fatalf("manifest entry %q style = %+v, want %s/%d", spec.Name, entry.ViewParam[0].Font, DefaultLabelAlignment, DefaultLabelSize)
		}
		if spec.Wide {
			if entry.SmallViewMode == nil || *entry.SmallViewMode != 2 {
				t.Fatalf("wide entry %q SmallViewMode = %v, want 2", spec.Name, entry.SmallViewMode)
			}
		} else if entry.SmallViewMode != nil {
			t.Fatalf("square entry %q SmallViewMode = %d, want omitted", spec.Name, *entry.SmallViewMode)
		}
		iconPath := entry.ViewParam[0].Icon
		iconData := readArchiveFile(t, files, iconPath)
		digest := sha256.Sum256(iconData)
		wantPath := livePositionIconPrefix + hex.EncodeToString(digest[:]) + ".png"
		if iconPath != wantPath {
			t.Fatalf("coordinate %q icon path = %q, want %q", spec.Name, iconPath, wantPath)
		}
		config, err := png.DecodeConfig(bytes.NewReader(iconData))
		if err != nil {
			t.Fatalf("coordinate %q PNG: %v", spec.Name, err)
		}
		wantSize := image.Pt(displaySquareWidth, displayTileHeight)
		if spec.Wide {
			wantSize = image.Pt(displayWideWidth, displayTileHeight)
		}
		if config.Width != wantSize.X || config.Height != wantSize.Y {
			t.Fatalf("coordinate %q geometry = %dx%d, want %dx%d", spec.Name, config.Width, config.Height, wantSize.X, wantSize.Y)
		}
	}
	for offset := FirstPayloadCapacity; offset < len(archive.Data); offset += ProtocolPacketSize {
		if archive.Data[offset] == 0 || archive.Data[offset] == 0x7c {
			t.Fatalf("unsafe continuation byte at %d: %#x", offset, archive.Data[offset])
		}
	}
}

func TestLivePageArchiveIsDeterministicAndContentSensitive(t *testing.T) {
	base := configuredTestPage()
	first, err := BuildLivePageArchive(base)
	if err != nil {
		t.Fatal(err)
	}
	second, err := BuildLivePageArchive(base)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first.Data, second.Data) || first.PaddingLength != second.PaddingLength {
		t.Fatal("same page produced nondeterministic live archive bytes")
	}
	changed := base
	changed.Positions[0].Label = "Changed"
	third, err := BuildLivePageArchive(changed)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(first.Data, third.Data) {
		t.Fatal("changed page produced identical live archive bytes")
	}
	baseFiles := readArchiveFiles(t, first.Data)
	thirdFiles := readArchiveFiles(t, third.Data)
	baseManifest := readArchiveFile(t, baseFiles, livePositionManifestName)
	if bytes.Equal(baseManifest, readArchiveFile(t, thirdFiles, livePositionManifestName)) {
		t.Fatal("changed label did not change full-page manifest bytes")
	}
	baseManifestEntries := readManifest(t, baseManifest)
	thirdManifestEntries := readManifest(t, readArchiveFile(t, thirdFiles, livePositionManifestName))
	basePath := baseManifestEntries["0_0"].ViewParam[0].Icon
	thirdPath := thirdManifestEntries["0_0"].ViewParam[0].Icon
	if basePath != thirdPath || !bytes.Equal(readArchiveFile(t, baseFiles, basePath), readArchiveFile(t, thirdFiles, thirdPath)) {
		t.Fatal("changed label changed full-page PNG content address")
	}
	styled := base
	styled.Positions[0].LabelAlignment = LabelAlignmentCenter
	styled.Positions[0].LabelSize = 24
	styledArchive, err := BuildLivePageArchive(styled)
	if err != nil {
		t.Fatal(err)
	}
	styledUpdate, err := BuildLivePageUpdate(styled)
	if err != nil {
		t.Fatal(err)
	}
	if effective := styledUpdate.Page().Positions[0]; effective.LabelAlignment != LabelAlignmentCenter || effective.LabelSize != 24 {
		t.Fatalf("explicit full-page update style = %s/%d, want %s/24", effective.LabelAlignment, effective.LabelSize, LabelAlignmentCenter)
	}
	styledFiles := readArchiveFiles(t, styledArchive.Data)
	styledManifestData := readArchiveFile(t, styledFiles, livePositionManifestName)
	if bytes.Equal(baseManifest, styledManifestData) {
		t.Fatal("changed label style did not change full-page manifest bytes")
	}
	styledEntries := readManifest(t, styledManifestData)
	styledEntry := styledEntries["0_0"]
	if styledEntry.ViewParam[0].Font.Align != LabelAlignmentCenter || styledEntry.ViewParam[0].Font.Size != 24 {
		t.Fatalf("full-page manifest style = %+v, want %s/24", styledEntry.ViewParam[0].Font, LabelAlignmentCenter)
	}
	styledPath := styledEntry.ViewParam[0].Icon
	if basePath != styledPath || !bytes.Equal(readArchiveFile(t, baseFiles, basePath), readArchiveFile(t, styledFiles, styledPath)) {
		t.Fatal("changed label style changed full-page PNG content address")
	}
	coloured := base
	coloured.Positions[0].Background = "#A0B0C0"
	colouredArchive, err := BuildLivePageArchive(coloured)
	if err != nil {
		t.Fatal(err)
	}
	colouredFiles := readArchiveFiles(t, colouredArchive.Data)
	colouredEntry := readManifest(t, readArchiveFile(t, colouredFiles, livePositionManifestName))["0_0"]
	colouredPath := colouredEntry.ViewParam[0].Icon
	if basePath == colouredPath || bytes.Equal(readArchiveFile(t, baseFiles, basePath), readArchiveFile(t, colouredFiles, colouredPath)) {
		t.Fatal("changed background did not change full-page PNG content address")
	}
}

func TestLivePageArchiveWideLabelFallbackIsContentAddressed(t *testing.T) {
	base := configuredTestPage()
	labelled := Page{Positions: append([]Position(nil), base.Positions...)}
	labelled.Positions[13].Label = "Enter 0123456789.*+"
	styled := Page{Positions: append([]Position(nil), labelled.Positions...)}
	styled.Positions[13].LabelAlignment = LabelAlignmentCenter
	styled.Positions[13].LabelSize = 24

	baseArchive, err := BuildLivePageArchive(base)
	if err != nil {
		t.Fatal(err)
	}
	labelArchive, err := BuildLivePageArchive(labelled)
	if err != nil {
		t.Fatal(err)
	}
	styleArchive, err := BuildLivePageArchive(styled)
	if err != nil {
		t.Fatal(err)
	}

	baseFiles := readArchiveFiles(t, baseArchive.Data)
	labelFiles := readArchiveFiles(t, labelArchive.Data)
	styleFiles := readArchiveFiles(t, styleArchive.Data)
	baseEntries := readManifest(t, readArchiveFile(t, baseFiles, livePositionManifestName))
	labelEntries := readManifest(t, readArchiveFile(t, labelFiles, livePositionManifestName))
	styleEntries := readManifest(t, readArchiveFile(t, styleFiles, livePositionManifestName))
	baseWidePath := baseEntries["3_2"].ViewParam[0].Icon
	labelWidePath := labelEntries["3_2"].ViewParam[0].Icon
	styleWidePath := styleEntries["3_2"].ViewParam[0].Icon
	if baseWidePath == labelWidePath || baseWidePath == styleWidePath || labelWidePath == styleWidePath {
		t.Fatalf("wide label/style did not change content path: base=%q label=%q style=%q", baseWidePath, labelWidePath, styleWidePath)
	}
	baseWide := readArchiveFile(t, baseFiles, baseWidePath)
	if bytes.Equal(baseWide, readArchiveFile(t, labelFiles, labelWidePath)) || bytes.Equal(baseWide, readArchiveFile(t, styleFiles, styleWidePath)) {
		t.Fatal("wide label/style did not change full-page PNG bytes")
	}
	baseSquarePath := baseEntries["0_0"].ViewParam[0].Icon
	if baseSquarePath != labelEntries["0_0"].ViewParam[0].Icon || baseSquarePath != styleEntries["0_0"].ViewParam[0].Icon {
		t.Fatal("wide label/style changed square content path")
	}
	if !bytes.Equal(readArchiveFile(t, baseFiles, baseSquarePath), readArchiveFile(t, labelFiles, baseSquarePath)) || !bytes.Equal(readArchiveFile(t, baseFiles, baseSquarePath), readArchiveFile(t, styleFiles, baseSquarePath)) {
		t.Fatal("wide label/style changed square PNG bytes")
	}

	wideEntry := labelEntries["3_2"]
	if wideEntry.SmallViewMode == nil || *wideEntry.SmallViewMode != 2 {
		t.Fatalf("wide SmallViewMode = %v, want 2", wideEntry.SmallViewMode)
	}
	if wideEntry.ViewParam[0].Font.ShowTitle {
		t.Fatal("wide manifest retained a firmware title after baking the label into the PNG")
	}
}

func TestSessionSendLivePageRejectsInvalidLabelStyleBeforeWrite(t *testing.T) {
	for _, test := range []struct {
		name   string
		mutate func(*Position)
	}{
		{name: "invalid label alignment", mutate: func(position *Position) { position.LabelAlignment = "top" }},
		{name: "label size below minimum", mutate: func(position *Position) { position.LabelSize = MinimumLabelSize - 1 }},
		{name: "label size above maximum", mutate: func(position *Position) { position.LabelSize = MaximumLabelSize + 1 }},
	} {
		t.Run(test.name, func(t *testing.T) {
			page := configuredTestPage()
			test.mutate(&page.Positions[0])
			transport := newFakeTransport()
			session, _ := openTestSession(t, transport)
			if err := session.SendLivePage(context.Background(), page); err == nil {
				t.Fatal("invalid label style page was accepted")
			}
			if calls, _, _ := transport.stats(); calls != 0 {
				t.Fatalf("invalid label style page write calls = %d, want 0", calls)
			}
			if _, active := session.Current(); !active {
				t.Fatal("invalid label style page validation invalidated the session")
			}
			_ = session.Close()
		})
	}
}

func TestSessionSendLivePageEmitsExactlyOneCompleteUpload(t *testing.T) {
	page := configuredTestPage()
	want, err := BuildLivePageUpdate(page)
	if err != nil {
		t.Fatal(err)
	}
	transport := newFakeTransport()
	session, _ := openTestSession(t, transport)
	if err := session.SendLivePage(context.Background(), page); err != nil {
		t.Fatal(err)
	}
	commands, err := commandsFromReports(transport.snapshotWrites())
	if err != nil {
		t.Fatal(err)
	}
	if len(commands) != 1 || commands[0] != CommandCompleteDisplayUpload {
		t.Fatalf("live page commands = %v, want one complete upload", commands)
	}
	frames := decodeWrittenFrames(t, transport.snapshotWrites())
	if len(frames) != 1 || frames[0].Command != CommandCompleteDisplayUpload || !bytes.Equal(frames[0].Payload, want.Archive().Data) {
		t.Fatal("live page frame did not carry the prebuilt archive")
	}
	_ = session.Close()
}

func TestSessionSendLivePageFailureIsTerminalWithoutRetry(t *testing.T) {
	page := configuredTestPage()
	update, err := BuildLivePageUpdate(page)
	if err != nil {
		t.Fatal(err)
	}
	reports, err := EncodeFrame(update.Frame())
	if err != nil {
		t.Fatal(err)
	}
	transport := newFakeTransport()
	transport.failAt = 2
	transport.failErr = errors.New("synthetic full-page failure")
	session, _ := openTestSession(t, transport)
	if err := session.SendLivePageUpdate(context.Background(), update); err == nil {
		t.Fatal("failed live page write returned nil")
	}
	if calls, _, _ := transport.stats(); calls != transport.failAt {
		t.Fatalf("writes after failed live page = %d, want %d", calls, transport.failAt)
	}
	if _, active := session.Current(); active {
		t.Fatal("failed live page write left session active")
	}
	beforeRetry := len(transport.snapshotWrites())
	if err := session.SendLivePage(context.Background(), page); err == nil {
		t.Fatal("live page retry returned nil after uncertain write")
	}
	if got := len(transport.snapshotWrites()); got != beforeRetry {
		t.Fatalf("writes after live page retry = %d, want %d", got, beforeRetry)
	}
	if len(reports) < transport.failAt {
		t.Fatalf("test setup expected at least %d reports, got %d", transport.failAt, len(reports))
	}
}

func TestSessionSendStartupPageUpdateUsesPrebuiltContentAddressedArchive(t *testing.T) {
	page := configuredTestPage()
	update, err := BuildLivePageUpdate(page)
	if err != nil {
		t.Fatal(err)
	}
	wantArchive, err := BuildLivePageArchive(page)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(update.Archive().Data, wantArchive.Data) || update.Archive().PaddingLength != wantArchive.PaddingLength {
		t.Fatal("live page update archive drifted from the canonical archive builder")
	}

	transport := newFakeTransport()
	session, _ := openTestSession(t, transport)
	if err := session.SendStartupPageUpdate(context.Background(), update, 73); err != nil {
		t.Fatalf("SendStartupPageUpdate: %v", err)
	}
	frames := decodeWrittenFrames(t, transport.snapshotWrites())
	wantCommands := []Command{
		CommandUnlockScreen,
		CommandCompleteDisplayUpload,
		CommandBrightness,
		CommandEnableInputStream,
	}
	if len(frames) != len(wantCommands) {
		t.Fatalf("startup frames = %d, want %d", len(frames), len(wantCommands))
	}
	for index, wantCommand := range wantCommands {
		if frames[index].Command != wantCommand {
			t.Fatalf("startup frame %d command = %s, want %s", index, frames[index].Command, wantCommand)
		}
	}
	if !bytes.Equal(frames[1].Payload, update.Archive().Data) {
		t.Fatal("startup upload did not use the prebuilt update archive")
	}
	_ = session.Close()
}

func TestSessionSendStartupPageUpdateRejectsInvalidInputWithoutWrites(t *testing.T) {
	valid, err := BuildLivePageUpdate(configuredTestPage())
	if err != nil {
		t.Fatal(err)
	}
	invalidFrame := valid
	invalidFrame.frame.Payload = []byte("not-the-archive")
	tests := []struct {
		name       string
		update     LivePageUpdate
		brightness int
		wantKind   ProtocolErrorKind
	}{
		{name: "zero update", update: LivePageUpdate{}, brightness: 73},
		{name: "invalid brightness below range", update: valid, brightness: -1, wantKind: ErrorInvalidBrightness},
		{name: "invalid brightness above range", update: valid, brightness: 101, wantKind: ErrorInvalidBrightness},
		{name: "mismatched frame", update: invalidFrame, brightness: 73},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			transport := newFakeTransport()
			session, _ := openTestSession(t, transport)
			err := session.SendStartupPageUpdate(context.Background(), test.update, test.brightness)
			if err == nil {
				t.Fatal("invalid startup input returned nil")
			}
			if test.wantKind != "" && !hasProtocolKind(err, test.wantKind) {
				t.Fatalf("error = %v, want %s", err, test.wantKind)
			}
			if calls, _, _ := transport.stats(); calls != 0 {
				t.Fatalf("invalid startup input wrote %d reports, want zero", calls)
			}
			if _, active := session.Current(); !active {
				t.Fatal("invalid startup input invalidated an active session")
			}
			_ = session.Close()
		})
	}
}

func TestSessionSendStartupPageUpdateStopsAtEveryWriteBoundary(t *testing.T) {
	update, err := BuildLivePageUpdate(configuredTestPage())
	if err != nil {
		t.Fatal(err)
	}
	frames := []Frame{
		UnlockScreenFrame(),
		update.Frame(),
		BrightnessFrame(73),
		EnableInputStreamFrame(),
	}
	reportsPerFrame := make([]int, len(frames))
	for index, frame := range frames {
		reports, err := EncodeFrame(frame)
		if err != nil {
			t.Fatalf("encode frame %d: %v", index, err)
		}
		reportsPerFrame[index] = len(reports)
	}

	for index := range frames {
		t.Run(fmt.Sprintf("failed primitive %d", index), func(t *testing.T) {
			failAt := 1
			for previous := 0; previous < index; previous++ {
				failAt += reportsPerFrame[previous]
			}
			transport := newFakeTransport()
			transport.failAt = failAt
			transport.failErr = errors.New("synthetic startup failure")
			session, _ := openTestSession(t, transport)
			if err := session.SendStartupPageUpdate(context.Background(), update, 73); err == nil {
				t.Fatal("failed startup primitive returned nil")
			}
			if calls, _, closes := transport.stats(); calls != failAt || closes != 1 {
				t.Fatalf("failed startup reports/close = %d/%d, want %d/1", calls, closes, failAt)
			}
			if _, active := session.Current(); active {
				t.Fatal("failed startup primitive left session active")
			}
			beforeRetry, _, _ := transport.stats()
			if err := session.SendStartupPageUpdate(context.Background(), update, 73); err == nil {
				t.Fatal("startup retry returned nil after uncertain write")
			}
			if calls, _, _ := transport.stats(); calls != beforeRetry {
				t.Fatalf("startup retry wrote %d reports, want %d", calls, beforeRetry)
			}
		})

		t.Run(fmt.Sprintf("short primitive %d", index), func(t *testing.T) {
			failAt := 1
			for previous := 0; previous < index; previous++ {
				failAt += reportsPerFrame[previous]
			}
			transport := newFakeTransport()
			transport.shortAt = failAt
			session, _ := openTestSession(t, transport)
			err := session.SendStartupPageUpdate(context.Background(), update, 73)
			if !hasProtocolKind(err, ErrorTransportShortWrite) {
				t.Fatalf("short startup error = %v, want %s", err, ErrorTransportShortWrite)
			}
			if calls, _, closes := transport.stats(); calls != failAt || closes != 1 {
				t.Fatalf("short startup reports/close = %d/%d, want %d/1", calls, closes, failAt)
			}
			if _, active := session.Current(); active {
				t.Fatal("short startup primitive left session active")
			}
		})
	}
}
