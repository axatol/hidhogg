package d200x

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"image"
	"image/color"
	"image/png"
	"reflect"
	"sync"
	"testing"
	"time"
)

func TestLivePositionArchiveCoversEveryCoordinate(t *testing.T) {
	for _, position := range configuredTestPage().Positions {
		position := position
		t.Run(position.Position, func(t *testing.T) {
			update, err := BuildLivePositionUpdate(position)
			if err != nil {
				t.Fatal(err)
			}
			archive := update.Archive()
			if len(archive.Data) == 0 || len(archive.Data) > MaxPayloadLength {
				t.Fatalf("archive length = %d", len(archive.Data))
			}
			for offset := FirstPayloadCapacity; offset < len(archive.Data); offset += ProtocolPacketSize {
				if archive.Data[offset] == 0 || archive.Data[offset] == 0x7c {
					t.Fatalf("unsafe continuation byte at %d: %#x", offset, archive.Data[offset])
				}
			}

			files := readArchiveFiles(t, archive.Data)
			if len(files) != 2 {
				t.Fatalf("archive members = %d, want exactly 2", len(files))
			}
			manifestData := readArchiveFile(t, files, livePositionManifestName)
			var manifest map[string]json.RawMessage
			if err := json.Unmarshal(manifestData, &manifest); err != nil {
				t.Fatalf("manifest JSON: %v", err)
			}
			if len(manifest) != 1 {
				t.Fatalf("manifest coordinates = %d, want 1", len(manifest))
			}
			entryData, ok := manifest[position.Position]
			if !ok {
				t.Fatalf("manifest does not target %q", position.Position)
			}
			var entry struct {
				SmallViewMode *int `json:"SmallViewMode"`
				State         int  `json:"State"`
				ViewParam     []struct {
					Font struct {
						Align     string `json:"Align"`
						Color     int    `json:"Color"`
						FontName  string `json:"FontName"`
						ShowTitle bool   `json:"ShowTitle"`
						Size      int    `json:"Size"`
						Weight    int    `json:"Weight"`
					} `json:"Font"`
					Icon string `json:"Icon"`
					Text string `json:"Text"`
				} `json:"ViewParam"`
			}
			if err := json.Unmarshal(entryData, &entry); err != nil {
				t.Fatalf("manifest entry JSON: %v", err)
			}
			if entry.State != 0 || len(entry.ViewParam) != 1 {
				t.Fatalf("manifest entry = %+v", entry)
			}
			view := entry.ViewParam[0]
			if view.Text != position.Label {
				t.Fatalf("manifest text = %q, want %q", view.Text, position.Label)
			}
			if view.Font.Align != "bottom" || view.Font.Color != 16_777_215 || view.Font.FontName != livePositionFontName || !view.Font.ShowTitle || view.Font.Size != 10 || view.Font.Weight != 80 {
				t.Fatalf("manifest font = %+v", view.Font)
			}
			spec, ok := LookupPosition(position.Position)
			if !ok {
				t.Fatalf("test position %q is not supported", position.Position)
			}
			if spec.Wide {
				if entry.SmallViewMode == nil || *entry.SmallViewMode != 2 {
					t.Fatalf("wide SmallViewMode = %v, want 2", entry.SmallViewMode)
				}
			} else if entry.SmallViewMode != nil {
				t.Fatalf("square SmallViewMode = %d, want omitted", *entry.SmallViewMode)
			}

			if len(view.Icon) != len(livePositionIconPrefix)+64+len(".png") || view.Icon[:len(livePositionIconPrefix)] != livePositionIconPrefix || view.Icon[len(view.Icon)-4:] != ".png" {
				t.Fatalf("manifest icon path = %q", view.Icon)
			}
			iconData := readArchiveFile(t, files, view.Icon)
			digest := sha256.Sum256(iconData)
			wantPath := livePositionIconPrefix + hex.EncodeToString(digest[:]) + ".png"
			if view.Icon != wantPath {
				t.Fatalf("manifest icon path = %q, want %q", view.Icon, wantPath)
			}
			config, err := png.DecodeConfig(bytes.NewReader(iconData))
			if err != nil {
				t.Fatalf("decode PNG config: %v", err)
			}
			wantSize := image.Pt(displaySquareWidth, displayTileHeight)
			if spec.Wide {
				wantSize = image.Pt(displayWideWidth, displayTileHeight)
			}
			if config.Width != wantSize.X || config.Height != wantSize.Y {
				t.Fatalf("PNG geometry = %dx%d, want %dx%d", config.Width, config.Height, wantSize.X, wantSize.Y)
			}
			if config.ColorModel != color.RGBAModel && config.ColorModel != color.NRGBAModel {
				t.Fatalf("PNG color model = %v, want RGBA-compatible model", config.ColorModel)
			}
			memberNames := map[string]bool{}
			for _, file := range files {
				if memberNames[file.name] {
					t.Fatalf("duplicate archive member %q", file.name)
				}
				memberNames[file.name] = true
			}
			if !memberNames[livePositionManifestName] || !memberNames[view.Icon] || len(memberNames) != 2 {
				t.Fatalf("archive members = %v", memberNames)
			}
			if got := update.Frame().Command; got != CommandPartialDisplayUpload {
				t.Fatalf("typed frame command = %s, want %s", got, CommandPartialDisplayUpload)
			}
			if !bytes.Equal(update.Frame().Payload, archive.Data) {
				t.Fatal("typed frame payload differs from archive")
			}
		})
	}
}

func TestLivePositionArchivePathIsStableAndContentAddressed(t *testing.T) {
	base := configuredTestPage().Positions[0]
	first, err := BuildLivePositionArchive(base)
	if err != nil {
		t.Fatal(err)
	}
	second, err := BuildLivePositionArchive(base)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first.Data, second.Data) || first.PaddingLength != second.PaddingLength {
		t.Fatal("same position produced nondeterministic archive bytes")
	}
	changedLabel := base
	changedLabel.Label = "Different"
	labelArchive, err := BuildLivePositionArchive(changedLabel)
	if err != nil {
		t.Fatal(err)
	}
	changedColour := base
	changedColour.Background = "#A0B0C0"
	colourArchive, err := BuildLivePositionArchive(changedColour)
	if err != nil {
		t.Fatal(err)
	}
	basePath := liveArchiveIconPath(t, first.Data)
	labelPath := liveArchiveIconPath(t, labelArchive.Data)
	colourPath := liveArchiveIconPath(t, colourArchive.Data)
	if basePath == labelPath || basePath == colourPath {
		t.Fatalf("content path did not change: base=%q label=%q colour=%q", basePath, labelPath, colourPath)
	}
}

func TestLivePositionBatchIsCanonicalAndExact(t *testing.T) {
	page := configuredTestPage()
	reversed := append([]Position(nil), page.Positions...)
	for left, right := 0, len(reversed)-1; left < right; left, right = left+1, right-1 {
		reversed[left], reversed[right] = reversed[right], reversed[left]
	}
	firstTransport := newFakeTransport()
	firstSession, _ := openTestSession(t, firstTransport)
	if err := firstSession.SendLivePositionBatch(context.Background(), reversed); err != nil {
		t.Fatal(err)
	}
	secondTransport := newFakeTransport()
	secondSession, _ := openTestSession(t, secondTransport)
	if err := secondSession.SendLivePositionBatch(context.Background(), page.Positions); err != nil {
		t.Fatal(err)
	}
	firstWrites := firstTransport.snapshotWrites()
	secondWrites := secondTransport.snapshotWrites()
	if !reflect.DeepEqual(firstWrites, secondWrites) {
		t.Fatal("reordering input positions changed batch report bytes")
	}
	frames := decodeWrittenFrames(t, firstWrites)
	if len(frames) != DisplayPositionCount {
		t.Fatalf("logical frames = %d, want %d", len(frames), DisplayPositionCount)
	}
	for index, frame := range frames {
		if frame.Command != CommandPartialDisplayUpload {
			t.Fatalf("frame %d command = %s, want %s", index, frame.Command, CommandPartialDisplayUpload)
		}
		want, err := BuildLivePositionArchive(page.Positions[index])
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(frame.Payload, want.Data) {
			t.Fatalf("frame %d payload differs from typed archive", index)
		}
		reports, err := EncodeFrame(frame)
		if err != nil {
			t.Fatal(err)
		}
		if len(reports) == 0 || len(reports[0]) != TransportReportSize {
			t.Fatalf("frame %d encoded reports = %d", index, len(reports))
		}
	}
	_, maxActive, _ := firstTransport.stats()
	if maxActive != 1 {
		t.Fatalf("concurrent report writes = %d, want 1", maxActive)
	}
	_ = firstSession.Close()
	_ = secondSession.Close()
}

func TestLivePositionBatchRejectsBeforeAnyWrite(t *testing.T) {
	page := configuredTestPage()
	transport := newFakeTransport()
	session, _ := openTestSession(t, transport)
	if err := session.SendLivePositionBatch(context.Background(), nil); err == nil {
		t.Fatal("empty live position batch was accepted")
	}
	if calls, _, _ := transport.stats(); calls != 0 {
		t.Fatalf("empty batch write calls = %d, want 0", calls)
	}
	if _, active := session.Current(); !active {
		t.Fatal("empty batch validation invalidated the session")
	}
	tooMany := append([]Position(nil), page.Positions...)
	tooMany = append(tooMany, page.Positions[0])
	if err := session.SendLivePositionBatch(context.Background(), tooMany); err == nil {
		t.Fatal("oversized live position batch was accepted")
	}
	if calls, _, _ := transport.stats(); calls != 0 {
		t.Fatalf("oversized batch write calls = %d, want 0", calls)
	}
	if _, active := session.Current(); !active {
		t.Fatal("oversized batch validation invalidated the session")
	}
	invalid := append([]Position(nil), page.Positions...)
	invalid[4].Label = "invalid\nlabel"
	if err := session.SendLivePositionBatch(context.Background(), invalid); err == nil {
		t.Fatal("invalid live position batch was accepted")
	}
	if calls, _, _ := transport.stats(); calls != 0 {
		t.Fatalf("invalid batch write calls = %d, want 0", calls)
	}
	duplicate := []Position{page.Positions[0], page.Positions[0]}
	if err := session.SendLivePositionBatch(context.Background(), duplicate); err == nil {
		t.Fatal("duplicate live position batch was accepted")
	}
	if calls, _, _ := transport.stats(); calls != 0 {
		t.Fatalf("duplicate batch write calls = %d, want 0", calls)
	}
	if err := session.SendLivePositionUpdates(context.Background(), []LivePositionUpdate{{}}); err == nil {
		t.Fatal("zero live update was accepted")
	}
	if calls, _, _ := transport.stats(); calls != 0 {
		t.Fatalf("zero update write calls = %d, want 0", calls)
	}
	if err := session.SendLivePosition(context.Background(), page.Positions[0]); err != nil {
		t.Fatalf("session unusable after validation-only rejections: %v", err)
	}
	if calls, _, _ := transport.stats(); calls == 0 {
		t.Fatal("valid batch did not write after validation-only rejections")
	}
	_ = session.Close()
}

func TestLivePositionBatchFailureStopsLaterWritesAndInvalidates(t *testing.T) {
	page := configuredTestPage()
	first, err := BuildLivePositionUpdate(page.Positions[0])
	if err != nil {
		t.Fatal(err)
	}
	firstReports, err := EncodeFrame(first.Frame())
	if err != nil {
		t.Fatal(err)
	}
	transport := newFakeTransport()
	transport.failAt = len(firstReports) + 1
	transport.failErr = errors.New("synthetic hid failure")
	session, _ := openTestSession(t, transport)
	if err := session.SendLivePositionBatch(context.Background(), page.Positions[:3]); err == nil {
		t.Fatal("failed live batch returned nil")
	}
	if calls, _, _ := transport.stats(); calls != len(firstReports)+1 {
		t.Fatalf("writes after failed second frame = %d, want %d", calls, len(firstReports)+1)
	}
	if _, active := session.Current(); active {
		t.Fatal("failed live batch left session active")
	}
	if err := session.SendLivePosition(context.Background(), page.Positions[0]); err == nil {
		t.Fatal("session accepted update after uncertain failure")
	}
	if calls, _, _ := transport.stats(); calls != len(firstReports)+1 {
		t.Fatalf("writes after retry = %d, want %d", calls, len(firstReports)+1)
	}
}

func TestLivePositionBatchHoldsOneWriteLockWithoutInterleaving(t *testing.T) {
	page := configuredTestPage()
	transport := newFakeTransport()
	transport.writeDelay = time.Millisecond
	session, _ := openTestSession(t, transport)
	var wait sync.WaitGroup
	errorsFound := make(chan error, 2)
	wait.Add(2)
	go func() {
		defer wait.Done()
		errorsFound <- session.SendLivePositionBatch(context.Background(), page.Positions[:2])
	}()
	go func() {
		defer wait.Done()
		errorsFound <- session.SendLivePositionBatch(context.Background(), page.Positions[2:4])
	}()
	wait.Wait()
	close(errorsFound)
	for err := range errorsFound {
		if err != nil {
			t.Fatal(err)
		}
	}
	_, maxActive, _ := transport.stats()
	if maxActive != 1 {
		t.Fatalf("concurrent report writes = %d, want 1", maxActive)
	}
	coordinates := make([]string, 0, 4)
	for _, frame := range decodeWrittenFrames(t, transport.snapshotWrites()) {
		coordinates = append(coordinates, liveFrameCoordinate(t, frame))
	}
	if !reflect.DeepEqual(coordinates, []string{"0_0", "1_0", "2_0", "3_0"}) && !reflect.DeepEqual(coordinates, []string{"2_0", "3_0", "0_0", "1_0"}) {
		t.Fatalf("batch frames interleaved or reordered within a batch: %v", coordinates)
	}
	_ = session.Close()
}

func TestGenericSendFrameRejectsDisplayUploadsWithoutInvalidatingSession(t *testing.T) {
	transport := newFakeTransport()
	session, _ := openTestSession(t, transport)
	for _, command := range []Command{CommandCompleteDisplayUpload, CommandPartialDisplayUpload} {
		if err := session.SendFrame(context.Background(), NewFrame(command, []byte("not-typed"))); !hasProtocolKind(err, ErrorUnsafeOutboundCommand) {
			t.Fatalf("generic %s send error = %v", command, err)
		}
		if calls, _, _ := transport.stats(); calls != 0 {
			t.Fatalf("generic %s writes = %d, want 0", command, calls)
		}
		if _, active := session.Current(); !active {
			t.Fatalf("generic %s rejection invalidated session", command)
		}
	}
	if err := session.SendFrame(context.Background(), BrightnessFrame(1)); err != nil {
		t.Fatalf("safe frame after display rejection: %v", err)
	}
	if calls, _, _ := transport.stats(); calls != 1 {
		t.Fatalf("safe frame writes after display rejection = %d, want 1", calls)
	}
	_ = session.Close()
}

func liveArchiveIconPath(t *testing.T, data []byte) string {
	t.Helper()
	files := readArchiveFiles(t, data)
	var manifest map[string]struct {
		ViewParam []struct {
			Icon string `json:"Icon"`
		} `json:"ViewParam"`
	}
	if err := json.Unmarshal(readArchiveFile(t, files, livePositionManifestName), &manifest); err != nil {
		t.Fatalf("manifest JSON: %v", err)
	}
	for _, entry := range manifest {
		if len(entry.ViewParam) != 1 {
			t.Fatalf("manifest view params = %d", len(entry.ViewParam))
		}
		return entry.ViewParam[0].Icon
	}
	t.Fatal("manifest had no entries")
	return ""
}

func decodeWrittenFrames(t *testing.T, reports [][]byte) []Frame {
	t.Helper()
	frames := make([]Frame, 0)
	for offset := 0; offset < len(reports); {
		assembler, err := NewFrameAssembler(reports[offset])
		if err != nil {
			t.Fatalf("frame %d start: %v", offset, err)
		}
		offset++
		for !assembler.Complete() {
			if offset >= len(reports) {
				t.Fatalf("frame at report %d was truncated", offset-1)
			}
			if err := assembler.Append(reports[offset]); err != nil {
				t.Fatalf("frame continuation %d: %v", offset, err)
			}
			offset++
		}
		frame, err := assembler.Frame()
		if err != nil {
			t.Fatalf("frame %d decode: %v", len(frames), err)
		}
		frames = append(frames, frame)
	}
	return frames
}

func liveFrameCoordinate(t *testing.T, frame Frame) string {
	t.Helper()
	files := readArchiveFiles(t, frame.Payload)
	var manifest map[string]json.RawMessage
	if err := json.Unmarshal(readArchiveFile(t, files, livePositionManifestName), &manifest); err != nil {
		t.Fatalf("frame manifest JSON: %v", err)
	}
	for coordinate := range manifest {
		return coordinate
	}
	t.Fatal("frame manifest had no coordinate")
	return ""
}

func TestLivePositionArchiveZipHasValidMemberOffsets(t *testing.T) {
	archive, err := BuildLivePositionArchive(configuredTestPage().Positions[0])
	if err != nil {
		t.Fatal(err)
	}
	reader, err := zip.NewReader(bytes.NewReader(archive.Data), int64(len(archive.Data)))
	if err != nil {
		t.Fatal(err)
	}
	if len(reader.File) != 2 {
		t.Fatalf("zip member count = %d, want 2", len(reader.File))
	}
	for _, file := range reader.File {
		opened, err := file.Open()
		if err != nil {
			t.Fatalf("open %q: %v", file.Name, err)
		}
		if closeErr := opened.Close(); closeErr != nil {
			t.Fatalf("close %q: %v", file.Name, closeErr)
		}
		if file.CompressedSize64 == 0 || file.UncompressedSize64 == 0 {
			t.Fatalf("member %q has empty size", file.Name)
		}
	}
}

func TestLivePositionFramePacketHeaderIsExact(t *testing.T) {
	position := configuredTestPage().Positions[0]
	frame, err := LivePositionFrame(position)
	if err != nil {
		t.Fatal(err)
	}
	wantReports, err := EncodeFrame(frame)
	if err != nil {
		t.Fatal(err)
	}
	transport := newFakeTransport()
	session, _ := openTestSession(t, transport)
	if err := session.SendLivePosition(context.Background(), position); err != nil {
		t.Fatal(err)
	}
	gotReports := transport.snapshotWrites()
	if !reflect.DeepEqual(gotReports, wantReports) {
		t.Fatal("typed live send reports differ from EncodeFrame output")
	}
	packet, err := NormalizeReport(gotReports[0])
	if err != nil {
		t.Fatal(err)
	}
	if packet[0] != 0x7c || packet[1] != 0x7c || Command(binary.BigEndian.Uint16(packet[2:4])) != CommandPartialDisplayUpload {
		t.Fatalf("packet header = %#x %#x command %#x", packet[0], packet[1], binary.BigEndian.Uint16(packet[2:4]))
	}
	_ = session.Close()
}
