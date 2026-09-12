package d200x

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/png"
	"testing"
)

func TestLivePageArchiveContainsCanonicalContentAddressedPage(t *testing.T) {
	page := configuredTestPage()
	archive, err := BuildLivePageArchive(page)
	if err != nil {
		t.Fatal(err)
	}
	files := readArchiveFiles(t, archive.Data)
	wantMembers := DisplayPositionCount + 1
	if archive.PaddingLength > 0 {
		wantMembers++
	}
	if len(files) != wantMembers {
		t.Fatalf("archive members = %d, want %d", len(files), wantMembers)
	}
	var manifest map[string]json.RawMessage
	if err := json.Unmarshal(readArchiveFile(t, files, livePositionManifestName), &manifest); err != nil {
		t.Fatalf("manifest JSON: %v", err)
	}
	if len(manifest) != DisplayPositionCount {
		t.Fatalf("manifest coordinates = %d, want %d", len(manifest), DisplayPositionCount)
	}
	for _, spec := range SupportedPositions() {
		entryData, ok := manifest[spec.Name]
		if !ok {
			t.Fatalf("manifest missing canonical coordinate %q", spec.Name)
		}
		var entry struct {
			SmallViewMode *int `json:"SmallViewMode"`
			ViewParam     []struct {
				Icon string `json:"Icon"`
			} `json:"ViewParam"`
		}
		if err := json.Unmarshal(entryData, &entry); err != nil {
			t.Fatalf("manifest entry %q: %v", spec.Name, err)
		}
		if len(entry.ViewParam) != 1 {
			t.Fatalf("manifest entry %q view count = %d, want one", spec.Name, len(entry.ViewParam))
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
