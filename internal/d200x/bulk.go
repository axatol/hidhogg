package d200x

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"hash/crc32"
)

// LivePageUpdate is an immutable, typed full-page display update. It is the
// live profile redraw operation and intentionally has the same complete-page
// command as startup while omitting startup-only brightness and wake writes.
// The unexported fields prevent callers from turning the operation into a
// generic 0x0001 sender.
type LivePageUpdate struct {
	page    Page
	archive DisplayArchive
	frame   Frame
}

// BuildLivePageUpdate validates and renders a complete page before any HID
// write. Every rendered image is addressed by the SHA-256 digest of its exact
// PNG bytes, so replacing a profile cannot reuse a stale firmware cache path.
func BuildLivePageUpdate(page Page) (LivePageUpdate, error) {
	positions, err := validatedPage(page)
	if err != nil {
		return LivePageUpdate{}, err
	}
	canonical := NewPage(positions)
	archive, err := BuildLivePageArchive(canonical)
	if err != nil {
		return LivePageUpdate{}, err
	}
	return LivePageUpdate{
		page:    canonical,
		archive: archive,
		frame:   NewFrame(CommandCompleteDisplayUpload, archive.Data),
	}, nil
}

// Page returns the validated page used to build the update.
func (update LivePageUpdate) Page() Page {
	return NewPage(update.page.Positions)
}

// Archive returns a defensive copy of the update's ZIP archive.
func (update LivePageUpdate) Archive() DisplayArchive {
	return DisplayArchive{
		Data:          append([]byte(nil), update.archive.Data...),
		PaddingLength: update.archive.PaddingLength,
	}
}

// Frame returns a defensive copy of the typed full-page frame.
func (update LivePageUpdate) Frame() Frame {
	return NewFrame(update.frame.Command, update.frame.Payload)
}

// BuildLivePageArchive creates the deterministic full-page archive used for a
// live profile transition. The manifest contains all fourteen canonical
// coordinates, firmware-rendered labels, thirteen 196x196 square images, and
// one 458x196 wide image.
func BuildLivePageArchive(page Page) (DisplayArchive, error) {
	positions, err := validatedPage(page)
	if err != nil {
		return DisplayArchive{}, err
	}
	files, err := livePageArchiveFiles(positions)
	if err != nil {
		return DisplayArchive{}, err
	}
	return buildFirmwareSafeArchive(files)
}

// SendLivePage builds the complete typed operation before taking the session
// write lock, then emits exactly one complete-display-upload frame.
func (s *Session) SendLivePage(ctx context.Context, page Page) error {
	if s == nil {
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	update, err := BuildLivePageUpdate(page)
	if err != nil {
		return err
	}
	return s.SendLivePageUpdate(ctx, update)
}

// SendLivePageUpdate emits one already-built typed full-page update while
// holding the session write lock. A failed report invalidates the session;
// later writes, retries, and rollback are therefore impossible.
func (s *Session) SendLivePageUpdate(ctx context.Context, update LivePageUpdate) error {
	if s == nil {
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	if err := validateLivePageUpdate(update); err != nil {
		return err
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	return s.sendFrameLocked(ctx, update.frame)
}

// SendStartupPageUpdate emits the verified startup transaction using one
// session write lock. The unlock, complete-page upload, brightness, and input
// enable primitives are deliberately fail-stop and are never retried or
// rolled back after a transport failure.
func (s *Session) SendStartupPageUpdate(ctx context.Context, update LivePageUpdate, brightness int) error {
	if s == nil {
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	if err := validateLivePageUpdate(update); err != nil {
		return err
	}
	if brightness < 0 || brightness > 100 {
		return &ProtocolError{Kind: ErrorInvalidBrightness, Actual: brightness, Expected: 100}
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	ctx = normalizeContext(ctx)
	for _, frame := range []Frame{
		UnlockScreenFrame(),
		update.frame,
		BrightnessFrame(brightness),
		EnableInputStreamFrame(),
	} {
		if err := s.sendFrameLocked(ctx, frame); err != nil {
			return err
		}
	}
	return nil
}

func validateLivePageUpdate(update LivePageUpdate) error {
	if err := ValidatePage(update.page); err != nil {
		return fmt.Errorf("D200X live page update page: %w", err)
	}
	if update.frame.Command != CommandCompleteDisplayUpload {
		return fmt.Errorf("D200X live page update command is %s", update.frame.Command)
	}
	if len(update.archive.Data) == 0 || len(update.archive.Data) > MaxPayloadLength {
		return fmt.Errorf("D200X live page update archive length %d is outside 1..%d", len(update.archive.Data), MaxPayloadLength)
	}
	if !bytes.Equal(update.frame.Payload, update.archive.Data) {
		return errorsForInvalidLivePageUpdate("frame payload differs from archive")
	}
	return nil
}

func errorsForInvalidLivePageUpdate(message string) error {
	return fmt.Errorf("invalid D200X live page update: %s", message)
}

type livePageRenderedPosition struct {
	position Position
	iconPath string
	pngData  []byte
}

func livePageArchiveFiles(positions []Position) ([]displayArchiveFile, error) {
	rendered := make([]livePageRenderedPosition, 0, len(positions))
	for index, position := range positions {
		spec, ok := LookupPosition(position.Position)
		if !ok {
			return nil, fmt.Errorf("render D200X live page position %q: unsupported position", position.Position)
		}
		width := displaySquareWidth
		if spec.Wide {
			width = displayWideWidth
		}
		background, err := PositionBackground(position)
		if err != nil {
			return nil, fmt.Errorf("render D200X live page position %d background: %w", index, err)
		}
		var pngData []byte
		if spec.Wide {
			pngData, err = configuredWidePNG(position, background)
		} else {
			pngData, err = configuredPNG(width, background)
		}
		if err != nil {
			return nil, fmt.Errorf("encode D200X live page position %d: %w", index, err)
		}
		rendered = append(rendered, livePageRenderedPosition{
			position: position,
			iconPath: contentAddressedIconPath(pngData),
			pngData:  pngData,
		})
	}

	manifest, err := livePageManifest(rendered)
	if err != nil {
		return nil, fmt.Errorf("encode D200X live page manifest: %w", err)
	}
	manifestCompressed, err := deflateRaw(manifest)
	if err != nil {
		return nil, fmt.Errorf("compress D200X live page manifest: %w", err)
	}
	files := []displayArchiveFile{{
		name:             livePositionManifestName,
		compression:      8,
		uncompressedData: manifest,
		compressedData:   manifestCompressed,
		checksum:         crc32.ChecksumIEEE(manifest),
	}}
	seenIcons := make(map[string]struct{}, len(rendered))
	for index, item := range rendered {
		if _, exists := seenIcons[item.iconPath]; exists {
			continue
		}
		seenIcons[item.iconPath] = struct{}{}
		compressed, err := deflateRaw(item.pngData)
		if err != nil {
			return nil, fmt.Errorf("compress D200X live page position %d image: %w", index, err)
		}
		files = append(files, displayArchiveFile{
			name:             item.iconPath,
			compression:      8,
			uncompressedData: item.pngData,
			compressedData:   compressed,
			checksum:         crc32.ChecksumIEEE(item.pngData),
		})
	}
	return files, nil
}

func livePageManifest(positions []livePageRenderedPosition) ([]byte, error) {
	var manifest bytes.Buffer
	manifest.WriteByte('{')
	for index, item := range positions {
		if index > 0 {
			manifest.WriteByte(',')
		}
		spec, ok := LookupPosition(item.position.Position)
		if !ok {
			return nil, fmt.Errorf("position %q is unsupported", item.position.Position)
		}
		entry := positionManifestEntry(item.position, item.iconPath, spec.Wide)
		encodedCoordinate, err := json.Marshal(spec.Name)
		if err != nil {
			return nil, err
		}
		encodedEntry, err := json.Marshal(entry)
		if err != nil {
			return nil, err
		}
		_, _ = manifest.Write(encodedCoordinate)
		manifest.WriteByte(':')
		_, _ = manifest.Write(encodedEntry)
	}
	manifest.WriteByte('}')
	return manifest.Bytes(), nil
}
