package d200x

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
)

const (
	defaultDiagnosticLineBytes = 512
	maximumDiagnosticLineBytes = 4 * 1024
	defaultPacketPreviewBytes  = 16
	maximumPacketPreviewBytes  = 32
	diagnosticDigestBytes      = 8
)

// InputDiagnostic contains bounded metadata for one decoded input frame. It
// deliberately does not carry RawPayload or any device identity.
type InputDiagnostic struct {
	WireIndex     byte
	Marker        InputMarker
	Action        InputAction
	PayloadBytes  int
	PayloadDigest [diagnosticDigestBytes]byte
}

// InputEventSink receives bounded decoded-event metadata. Implementations must
// not infer a device identity from these protocol values.
type InputEventSink interface {
	InputEvent(InputDiagnostic)
}

// SessionOptions controls optional diagnostics. Input events are delivered to
// Sink whenever one is configured; outbound packet diagnostics and text output
// require Verbose and Writer. Writers and sinks never receive raw
// payloads or device identities.
type SessionOptions struct {
	Verbose                bool
	Writer                 io.Writer
	Sink                   InputEventSink
	MaxDiagnosticLineBytes int
	MaxPacketPreviewBytes  int
}

func (options SessionOptions) lineLimit() int {
	if options.MaxDiagnosticLineBytes <= 0 {
		return defaultDiagnosticLineBytes
	}
	if options.MaxDiagnosticLineBytes > maximumDiagnosticLineBytes {
		return maximumDiagnosticLineBytes
	}
	return options.MaxDiagnosticLineBytes
}

func (options SessionOptions) previewLimit() int {
	if options.MaxPacketPreviewBytes <= 0 {
		return defaultPacketPreviewBytes
	}
	if options.MaxPacketPreviewBytes > maximumPacketPreviewBytes {
		return maximumPacketPreviewBytes
	}
	return options.MaxPacketPreviewBytes
}

func (s *Session) logOutboundPacket(command Command, packetIndex, packetCount int, report []byte) {
	if s == nil || !s.diagnostics.verbose {
		return
	}
	s.diagnosticMu.Lock()
	defer s.diagnosticMu.Unlock()
	digest := sha256.Sum256(report)
	var shortDigest [diagnosticDigestBytes]byte
	copy(shortDigest[:], digest[:diagnosticDigestBytes])
	prefixLength := min(len(report), s.diagnostics.options.previewLimit())
	prefix := append([]byte(nil), report[:prefixLength]...)
	writer := s.diagnostics.options.Writer
	if writer == nil {
		return
	}
	line := fmt.Sprintf(
		"d200x outbound command=%s packet=%d/%d bytes=%d prefix=%s digest=%s\n",
		command,
		packetIndex+1,
		packetCount,
		len(report),
		hex.EncodeToString(prefix),
		hex.EncodeToString(shortDigest[:]),
	)
	writeBoundedDiagnostic(writer, []byte(line), s.diagnostics.options.lineLimit())
}

func (s *Session) logInputEvent(event InputEvent) {
	if s == nil || (s.diagnostics.options.Sink == nil && !s.diagnostics.verbose) {
		return
	}
	s.diagnosticMu.Lock()
	defer s.diagnosticMu.Unlock()
	digest := sha256.Sum256(event.RawPayload)
	var shortDigest [diagnosticDigestBytes]byte
	copy(shortDigest[:], digest[:diagnosticDigestBytes])
	if sink := s.diagnostics.options.Sink; sink != nil {
		sink.InputEvent(InputDiagnostic{
			WireIndex:     event.WireIndex,
			Marker:        event.Marker,
			Action:        event.Action,
			PayloadBytes:  len(event.RawPayload),
			PayloadDigest: shortDigest,
		})
	}
	if !s.diagnostics.verbose {
		return
	}
	writer := s.diagnostics.options.Writer
	if writer == nil {
		return
	}
	line := fmt.Sprintf(
		"d200x input wire-index=%d marker=0x%02x action=0x%02x payload-bytes=%d payload-digest=%s\n",
		event.WireIndex,
		byte(event.Marker),
		byte(event.Action),
		len(event.RawPayload),
		hex.EncodeToString(shortDigest[:]),
	)
	writeBoundedDiagnostic(writer, []byte(line), s.diagnostics.options.lineLimit())
}

func writeBoundedDiagnostic(writer io.Writer, line []byte, limit int) {
	if writer == nil || limit <= 0 {
		return
	}
	if len(line) > limit {
		line = line[:limit]
	}
	_, _ = writer.Write(line)
}
