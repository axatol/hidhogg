package d200x

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
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
