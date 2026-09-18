package d200x

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash/crc32"
	"sort"
)

const (
	livePositionManifestName = "manifest.json"
	livePositionIconPrefix   = "Images/"
	livePositionFontName     = "Source Han Sans SC"
	livePositionMaxMembers   = 2
)

// LivePositionUpdate is an immutable, typed targeted display update. Values
// are created by BuildLivePositionUpdate; the unexported fields prevent a
// caller from turning the 0x000d write path into a generic frame sender.
type LivePositionUpdate struct {
	position  Position
	wireIndex byte
	archive   DisplayArchive
	frame     Frame
}

// BuildLivePositionUpdate validates one position and builds its complete
// content-addressed 0x000d archive before any transport write.
func BuildLivePositionUpdate(position Position) (LivePositionUpdate, error) {
	position = effectivePositionStyle(position)
	spec, err := validatedLivePosition(position)
	if err != nil {
		return LivePositionUpdate{}, err
	}
	archive, err := BuildLivePositionArchive(position)
	if err != nil {
		return LivePositionUpdate{}, err
	}
	return LivePositionUpdate{
		position:  position,
		wireIndex: spec.WireIndex,
		archive:   archive,
		frame:     NewFrame(CommandPartialDisplayUpload, archive.Data),
	}, nil
}

// Position returns the validated position used to build the update.
func (update LivePositionUpdate) Position() Position {
	return update.position
}

// Archive returns a defensive copy of the update's ZIP archive.
func (update LivePositionUpdate) Archive() DisplayArchive {
	return DisplayArchive{
		Data:          append([]byte(nil), update.archive.Data...),
		PaddingLength: update.archive.PaddingLength,
	}
}

// Frame returns a defensive copy of the typed 0x000d frame.
func (update LivePositionUpdate) Frame() Frame {
	return NewFrame(update.frame.Command, update.frame.Payload)
}

// BuildLivePositionArchive creates the deterministic two-member archive used
// for one targeted live display update. The PNG carries only background and
// border artwork; the manifest carries firmware-rendered label text and style.
func BuildLivePositionArchive(position Position) (DisplayArchive, error) {
	position = effectivePositionStyle(position)
	spec, err := validatedLivePosition(position)
	if err != nil {
		return DisplayArchive{}, err
	}
	width := displaySquareWidth
	if spec.Wide {
		width = displayWideWidth
	}
	background, err := PositionBackground(position)
	if err != nil {
		return DisplayArchive{}, fmt.Errorf("render D200X live position %q background: %w", spec.Name, err)
	}
	var pngData []byte
	if spec.Wide {
		pngData, err = configuredWidePNG(position, background)
	} else {
		pngData, err = configuredPNG(width, background)
	}
	if err != nil {
		return DisplayArchive{}, fmt.Errorf("encode D200X live position %q: %w", spec.Name, err)
	}
	iconPath := contentAddressedIconPath(pngData)
	manifest, err := livePositionManifest(spec.Name, iconPath, position, spec.Wide)
	if err != nil {
		return DisplayArchive{}, fmt.Errorf("encode D200X live position %q manifest: %w", spec.Name, err)
	}
	manifestCompressed, err := deflateRaw(manifest)
	if err != nil {
		return DisplayArchive{}, fmt.Errorf("compress D200X live position %q manifest: %w", spec.Name, err)
	}
	pngCompressed, err := deflateRaw(pngData)
	if err != nil {
		return DisplayArchive{}, fmt.Errorf("compress D200X live position %q image: %w", spec.Name, err)
	}
	files := []displayArchiveFile{
		{
			name:             livePositionManifestName,
			compression:      8,
			uncompressedData: manifest,
			compressedData:   manifestCompressed,
			checksum:         crc32.ChecksumIEEE(manifest),
		},
		{
			name:             iconPath,
			compression:      8,
			uncompressedData: pngData,
			compressedData:   pngCompressed,
			checksum:         crc32.ChecksumIEEE(pngData),
		},
	}
	return buildLivePositionArchive(files)
}

// LivePositionFrame builds the typed 0x000d frame for one validated position.
// It is intentionally separate from NewFrame: arbitrary 0x000d payloads must
// not become reachable through the production API.
func LivePositionFrame(position Position) (Frame, error) {
	update, err := BuildLivePositionUpdate(position)
	if err != nil {
		return Frame{}, err
	}
	return update.Frame(), nil
}

type livePositionManifestEntry struct {
	SmallViewMode int                     `json:"SmallViewMode,omitempty"`
	State         int                     `json:"State"`
	ViewParam     []livePositionViewParam `json:"ViewParam"`
}

type livePositionViewParam struct {
	Font livePositionFont `json:"Font"`
	Icon string           `json:"Icon"`
	Text string           `json:"Text"`
}

type livePositionFont struct {
	Align     string `json:"Align"`
	Color     int    `json:"Color"`
	FontName  string `json:"FontName"`
	ShowTitle bool   `json:"ShowTitle"`
	Size      int    `json:"Size"`
	Weight    int    `json:"Weight"`
}

func positionManifestEntry(position Position, iconPath string, wide bool) livePositionManifestEntry {
	position = effectivePositionStyle(position)
	entry := livePositionManifestEntry{
		State: 0,
		ViewParam: []livePositionViewParam{{
			Font: livePositionFont{
				Align:     position.LabelAlignment,
				Color:     16_777_215,
				FontName:  livePositionFontName,
				ShowTitle: !wide,
				Size:      position.LabelSize,
				Weight:    80,
			},
			Icon: iconPath,
			Text: position.Label,
		}},
	}
	if wide {
		entry.SmallViewMode = 2
	}
	return entry
}

func validatedLivePosition(position Position) (PositionSpec, error) {
	if err := ValidatePosition(position); err != nil {
		return PositionSpec{}, err
	}
	spec, _ := LookupPosition(position.Position)
	return spec, nil
}

func contentAddressedIconPath(pngData []byte) string {
	digest := sha256.Sum256(pngData)
	return livePositionIconPrefix + hex.EncodeToString(digest[:]) + ".png"
}

func livePositionManifest(coordinate, iconPath string, position Position, wide bool) ([]byte, error) {
	entry := positionManifestEntry(position, iconPath, wide)
	encodedEntry, err := json.Marshal(entry)
	if err != nil {
		return nil, err
	}
	encodedCoordinate, err := json.Marshal(coordinate)
	if err != nil {
		return nil, err
	}
	var manifest bytes.Buffer
	manifest.WriteByte('{')
	_, _ = manifest.Write(encodedCoordinate)
	manifest.WriteByte(':')
	_, _ = manifest.Write(encodedEntry)
	manifest.WriteByte('}')
	return manifest.Bytes(), nil
}

func buildLivePositionArchive(files []displayArchiveFile) (DisplayArchive, error) {
	if len(files) != livePositionMaxMembers {
		return DisplayArchive{}, fmt.Errorf("D200X live archive has %d members, want %d", len(files), livePositionMaxMembers)
	}
	for extraLength := 0; extraLength <= displayMaximumPadding; {
		extra := livePositionArchiveExtra(extraLength)
		candidate := append([]displayArchiveFile(nil), files...)
		candidate[0].extra = extra
		archive, err := assembleDisplayArchive(candidate, 0)
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
			return DisplayArchive{Data: archive, PaddingLength: extraLength}, nil
		}
		if extraLength == 0 {
			extraLength = 4
		} else {
			extraLength++
		}
	}
	return DisplayArchive{}, fmt.Errorf("no firmware-safe D200X live archive extra field below %d bytes", displayMaximumPadding)
}

func livePositionArchiveExtra(length int) []byte {
	if length == 0 {
		return nil
	}
	if length < 4 || length > 0xFFFF {
		return nil
	}
	extra := make([]byte, length)
	binary.LittleEndian.PutUint16(extra[0:2], 0xD200)
	binary.LittleEndian.PutUint16(extra[2:4], uint16(length-4))
	for index := 4; index < len(extra); index++ {
		extra[index] = 0xA5
	}
	return extra
}

// SendLivePositionBatch prebuilds every typed update before taking the write
// lock, then emits the canonical coordinate order as one serialized batch.
// The bounded batch accepts one through all fourteen supported positions;
// duplicate coordinates are rejected before any write.
func (s *Session) SendLivePositionBatch(ctx context.Context, positions []Position) error {
	if s == nil {
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	updates, err := buildLivePositionUpdates(positions)
	if err != nil {
		return err
	}
	return s.SendLivePositionUpdates(ctx, updates)
}

// SendLivePosition sends one typed targeted update. It is a convenience over
// SendLivePositionBatch and retains the same prebuild and write semantics.
func (s *Session) SendLivePosition(ctx context.Context, position Position) error {
	return s.SendLivePositionBatch(ctx, []Position{position})
}

// SendLivePositionUpdates emits already-built typed updates while holding the
// session write lock for the complete batch. The method is useful to callers
// that need an explicit prebuild boundary before serialization.
func (s *Session) SendLivePositionUpdates(ctx context.Context, updates []LivePositionUpdate) error {
	if s == nil {
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	ordered, err := canonicalLivePositionUpdates(updates)
	if err != nil {
		return err
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	ctx = normalizeContext(ctx)
	for _, update := range ordered {
		if err := s.sendLivePositionFrameLocked(ctx, update.frame); err != nil {
			return err
		}
	}
	return nil
}

func buildLivePositionUpdates(positions []Position) ([]LivePositionUpdate, error) {
	if len(positions) == 0 {
		return nil, fmt.Errorf("D200X live position batch is empty")
	}
	if len(positions) > DisplayPositionCount {
		return nil, fmt.Errorf("D200X live position batch has %d positions, want at most %d", len(positions), DisplayPositionCount)
	}
	updates := make([]LivePositionUpdate, 0, len(positions))
	for index, position := range positions {
		update, err := BuildLivePositionUpdate(position)
		if err != nil {
			return nil, fmt.Errorf("D200X live position batch item %d: %w", index, err)
		}
		updates = append(updates, update)
	}
	return canonicalLivePositionUpdates(updates)
}

func canonicalLivePositionUpdates(updates []LivePositionUpdate) ([]LivePositionUpdate, error) {
	if len(updates) == 0 {
		return nil, fmt.Errorf("D200X live position batch is empty")
	}
	if len(updates) > DisplayPositionCount {
		return nil, fmt.Errorf("D200X live position batch has %d positions, want at most %d", len(updates), DisplayPositionCount)
	}
	ordered := append([]LivePositionUpdate(nil), updates...)
	seen := make(map[byte]struct{}, len(ordered))
	for index := range ordered {
		update := &ordered[index]
		spec, err := validatedLivePosition(update.position)
		if err != nil {
			return nil, fmt.Errorf("D200X live position batch item %d: %w", index, err)
		}
		if _, exists := seen[spec.WireIndex]; exists {
			return nil, fmt.Errorf("D200X live position batch repeats coordinate %q", spec.Name)
		}
		seen[spec.WireIndex] = struct{}{}
		if update.wireIndex != spec.WireIndex || update.frame.Command != CommandPartialDisplayUpload || !bytes.Equal(update.frame.Payload, update.archive.Data) || len(update.archive.Data) == 0 || len(update.archive.Data) > MaxPayloadLength {
			return nil, fmt.Errorf("D200X live position batch item %d is not a valid typed update", index)
		}
	}
	sort.SliceStable(ordered, func(left, right int) bool {
		return ordered[left].wireIndex < ordered[right].wireIndex
	})
	return ordered, nil
}

func (s *Session) sendLivePositionFrameLocked(ctx context.Context, frame Frame) error {
	if frame.Command != CommandPartialDisplayUpload {
		return &ProtocolError{Kind: ErrorUnsafeOutboundCommand, Command: frame.Command}
	}
	reports, err := EncodeFrame(frame)
	if err != nil {
		return err
	}
	for packetIndex, report := range reports {
		if err := s.writeReportLocked(ctx, report); err != nil {
			return err
		}
		s.logOutboundPacket(frame.Command, packetIndex, len(reports), report)
	}
	return nil
}
