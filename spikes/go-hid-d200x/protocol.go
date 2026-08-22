package d200x

import (
	"encoding/binary"
	"fmt"
)

const (
	VendorID        uint16 = 0x2207
	ProductID       uint16 = 0x0019
	InterfaceNumber int    = 0
	TargetUsagePage uint16 = 0x000c
	TargetUsage     uint16 = 0x0001

	ReportIdentifier     byte = 0
	ProtocolPacketSize        = 1024
	TransportReportSize       = ProtocolPacketSize + 1
	FrameHeaderSize           = 8
	FirstPayloadCapacity      = ProtocolPacketSize - FrameHeaderSize
	MaxPayloadLength          = 16 * 1024 * 1024
)

type ProtocolErrorKind string

const (
	ErrorInvalidReportLength      ProtocolErrorKind = "invalid-report-length"
	ErrorUnsupportedReportID      ProtocolErrorKind = "unsupported-report-id"
	ErrorInvalidFrameMagic        ProtocolErrorKind = "invalid-frame-magic"
	ErrorPayloadTooLarge          ProtocolErrorKind = "payload-too-large"
	ErrorTruncatedPayload         ProtocolErrorKind = "truncated-payload"
	ErrorUnexpectedContinuation   ProtocolErrorKind = "unexpected-continuation"
	ErrorAmbiguousDeviceSelection ProtocolErrorKind = "ambiguous-device-selection"
	ErrorNoMatchingDevice         ProtocolErrorKind = "no-matching-device"
	ErrorIneligibleDevice         ProtocolErrorKind = "ineligible-device"
	ErrorMalformedInputPayload    ProtocolErrorKind = "malformed-input-payload"
	ErrorTransportShortWrite      ProtocolErrorKind = "transport-short-write"
	ErrorUnsafeOutboundCommand    ProtocolErrorKind = "unsafe-outbound-command"
	ErrorSessionClosed            ProtocolErrorKind = "session-closed"
	ErrorNoActiveTransport        ProtocolErrorKind = "no-active-transport"
)

// ProtocolError retains bounded diagnostic values without retaining device identity.
type ProtocolError struct {
	Kind     ProtocolErrorKind
	Actual   int
	Expected int
	ReportID byte
	Magic    [2]byte
	Declared uint32
	Limit    int
	Received int
	Command  Command
	Count    int
}

func (e *ProtocolError) Error() string {
	switch e.Kind {
	case ErrorInvalidReportLength:
		return fmt.Sprintf("invalid report length: got %d, want %d or %d", e.Actual, ProtocolPacketSize, TransportReportSize)
	case ErrorUnsupportedReportID:
		return fmt.Sprintf("unsupported report ID: 0x%02x", e.ReportID)
	case ErrorInvalidFrameMagic:
		return fmt.Sprintf("invalid frame magic: 0x%02x%02x", e.Magic[0], e.Magic[1])
	case ErrorPayloadTooLarge:
		return fmt.Sprintf("declared payload length %d exceeds limit %d", e.Declared, e.Limit)
	case ErrorTruncatedPayload:
		return fmt.Sprintf("truncated payload: received %d of %d bytes", e.Received, e.Expected)
	case ErrorUnexpectedContinuation:
		return "unexpected continuation packet"
	case ErrorAmbiguousDeviceSelection:
		return fmt.Sprintf("refusing to choose between %d matching interface-0 devices", e.Count)
	case ErrorNoMatchingDevice:
		return "no matching D200X interface-0 device"
	case ErrorIneligibleDevice:
		return "refusing to open a nonmatching HID device"
	case ErrorMalformedInputPayload:
		return fmt.Sprintf("malformed input payload: got %d bytes, want at least 4", e.Actual)
	case ErrorTransportShortWrite:
		return fmt.Sprintf("short HID write: wrote %d of %d bytes", e.Actual, e.Expected)
	case ErrorUnsafeOutboundCommand:
		return fmt.Sprintf("refusing unsafe outbound command %s", e.Command)
	case ErrorSessionClosed:
		return "HID session is closed"
	case ErrorNoActiveTransport:
		return "HID session has no active transport"
	default:
		return string(e.Kind)
	}
}

type Command uint16

const (
	CommandCompleteDisplayUpload Command = 0x0001
	CommandEnableInputStream     Command = 0x0002
	CommandObservedHostLock      Command = 0x0004
	CommandSmallWindowRefresh    Command = 0x0006
	CommandBrightness            Command = 0x000A
	CommandLabelStyle            Command = 0x000B
	CommandPartialDisplayUpload  Command = 0x000D
	CommandLockScreen            Command = 0x000F
	CommandUnlockScreen          Command = 0x0010
	CommandInputEvent            Command = 0x0101
	CommandAcknowledgement       Command = 0x010B
	CommandDeviceInformation     Command = 0x0303
)

func (c Command) String() string {
	switch c {
	case CommandCompleteDisplayUpload:
		return "complete-display-upload"
	case CommandEnableInputStream:
		return "enable-input-stream"
	case CommandObservedHostLock:
		return "observed-host-lock"
	case CommandSmallWindowRefresh:
		return "small-window-refresh"
	case CommandBrightness:
		return "brightness"
	case CommandLabelStyle:
		return "label-style"
	case CommandPartialDisplayUpload:
		return "partial-display-upload"
	case CommandLockScreen:
		return "lock-screen"
	case CommandUnlockScreen:
		return "unlock-screen"
	case CommandInputEvent:
		return "input-event"
	case CommandAcknowledgement:
		return "acknowledgement"
	case CommandDeviceInformation:
		return "device-information"
	default:
		return fmt.Sprintf("unknown-0x%04x", uint16(c))
	}
}

func (c Command) IsKnown() bool {
	switch c {
	case CommandCompleteDisplayUpload,
		CommandEnableInputStream,
		CommandObservedHostLock,
		CommandSmallWindowRefresh,
		CommandBrightness,
		CommandLabelStyle,
		CommandPartialDisplayUpload,
		CommandLockScreen,
		CommandUnlockScreen,
		CommandInputEvent,
		CommandAcknowledgement,
		CommandDeviceInformation:
		return true
	default:
		return false
	}
}

func (c Command) IsSafeOutbound() bool {
	switch c {
	case CommandCompleteDisplayUpload,
		CommandEnableInputStream,
		CommandBrightness,
		CommandUnlockScreen:
		return true
	default:
		return false
	}
}

type Frame struct {
	Command Command
	Payload []byte
}

// NewFrame constructs an in-memory protocol value. Session.SendFrame applies
// the physical outbound allowlist before any HID report can be written.
func NewFrame(command Command, payload []byte) Frame {
	return Frame{Command: command, Payload: append([]byte(nil), payload...)}
}

func (f Frame) PayloadCopy() []byte {
	return append([]byte(nil), f.Payload...)
}

// NormalizeReport converts either a protocol packet or a HID report with a
// leading report ID into one protocol packet. D200X uses report ID zero.
func NormalizeReport(report []byte) ([]byte, error) {
	switch len(report) {
	case ProtocolPacketSize:
		return append([]byte(nil), report...), nil
	case TransportReportSize:
		if report[0] != ReportIdentifier {
			return nil, &ProtocolError{Kind: ErrorUnsupportedReportID, ReportID: report[0]}
		}
		return append([]byte(nil), report[1:]...), nil
	default:
		return nil, &ProtocolError{
			Kind:     ErrorInvalidReportLength,
			Actual:   len(report),
			Expected: ProtocolPacketSize,
		}
	}
}

// EncodeFrame packetizes one D200X frame into HID output reports. Every
// returned report begins with report ID zero and is exactly 1025 bytes.
func EncodeFrame(frame Frame) ([][]byte, error) {
	if len(frame.Payload) > MaxPayloadLength {
		return nil, &ProtocolError{
			Kind:     ErrorPayloadTooLarge,
			Declared: uint32(len(frame.Payload)),
			Limit:    MaxPayloadLength,
		}
	}

	protocolPackets := make([][]byte, 0, 1+(len(frame.Payload)/ProtocolPacketSize))
	first := make([]byte, ProtocolPacketSize)
	first[0] = 0x7c
	first[1] = 0x7c
	binary.BigEndian.PutUint16(first[2:4], uint16(frame.Command))
	binary.LittleEndian.PutUint32(first[4:8], uint32(len(frame.Payload)))
	firstPayloadLength := min(len(frame.Payload), FirstPayloadCapacity)
	copy(first[FrameHeaderSize:], frame.Payload[:firstPayloadLength])
	protocolPackets = append(protocolPackets, first)

	for offset := firstPayloadLength; offset < len(frame.Payload); offset += ProtocolPacketSize {
		packet := make([]byte, ProtocolPacketSize)
		end := min(offset+ProtocolPacketSize, len(frame.Payload))
		copy(packet, frame.Payload[offset:end])
		protocolPackets = append(protocolPackets, packet)
	}

	reports := make([][]byte, len(protocolPackets))
	for index, packet := range protocolPackets {
		report := make([]byte, TransportReportSize)
		copy(report[1:], packet)
		reports[index] = report
	}
	return reports, nil
}

type FrameAssembler struct {
	command  Command
	declared uint32
	payload  []byte
}

func NewFrameAssembler(firstReport []byte) (*FrameAssembler, error) {
	packet, err := NormalizeReport(firstReport)
	if err != nil {
		return nil, err
	}
	if packet[0] != 0x7c || packet[1] != 0x7c {
		return nil, &ProtocolError{
			Kind:  ErrorInvalidFrameMagic,
			Magic: [2]byte{packet[0], packet[1]},
		}
	}

	declared := binary.LittleEndian.Uint32(packet[4:8])
	if declared > MaxPayloadLength {
		return nil, &ProtocolError{
			Kind:     ErrorPayloadTooLarge,
			Declared: declared,
			Limit:    MaxPayloadLength,
		}
	}
	firstPayloadLength := min(int(declared), FirstPayloadCapacity)
	return &FrameAssembler{
		command:  Command(binary.BigEndian.Uint16(packet[2:4])),
		declared: declared,
		payload:  append([]byte(nil), packet[FrameHeaderSize:FrameHeaderSize+firstPayloadLength]...),
	}, nil
}

func (a *FrameAssembler) Complete() bool {
	return a != nil && len(a.payload) == int(a.declared)
}

func (a *FrameAssembler) ReceivedPayloadLength() int {
	if a == nil {
		return 0
	}
	return len(a.payload)
}

func (a *FrameAssembler) ExpectedPayloadLength() int {
	if a == nil {
		return 0
	}
	return int(a.declared)
}

func (a *FrameAssembler) Append(continuationReport []byte) error {
	if a == nil {
		return &ProtocolError{Kind: ErrorUnexpectedContinuation}
	}
	if a.Complete() {
		return &ProtocolError{Kind: ErrorUnexpectedContinuation, Command: a.command}
	}
	packet, err := NormalizeReport(continuationReport)
	if err != nil {
		return err
	}
	remaining := int(a.declared) - len(a.payload)
	copyLength := min(remaining, ProtocolPacketSize)
	a.payload = append(a.payload, packet[:copyLength]...)
	return nil
}

func (a *FrameAssembler) Frame() (Frame, error) {
	if a == nil {
		return Frame{}, &ProtocolError{Kind: ErrorUnexpectedContinuation}
	}
	if !a.Complete() {
		return Frame{}, &ProtocolError{
			Kind:     ErrorTruncatedPayload,
			Expected: int(a.declared),
			Received: len(a.payload),
			Command:  a.command,
		}
	}
	return NewFrame(a.command, a.payload), nil
}

func DecodeFrame(reports [][]byte) (Frame, error) {
	if len(reports) == 0 {
		return Frame{}, &ProtocolError{Kind: ErrorTruncatedPayload, Expected: 1}
	}
	assembler, err := NewFrameAssembler(reports[0])
	if err != nil {
		return Frame{}, err
	}
	for _, report := range reports[1:] {
		if err := assembler.Append(report); err != nil {
			return Frame{}, err
		}
	}
	return assembler.Frame()
}

func EnableInputStreamFrame() Frame {
	return NewFrame(CommandEnableInputStream, nil)
}

func ClampBrightness(percentage int) int {
	return min(max(percentage, 0), 100)
}

func BrightnessFrame(percentage int) Frame {
	return NewFrame(CommandBrightness, []byte(fmt.Sprintf("%d", ClampBrightness(percentage))))
}

func UnlockScreenFrame() Frame {
	return NewFrame(CommandUnlockScreen, nil)
}

func CompleteDisplayUploadFrame(payload []byte) (Frame, error) {
	if len(payload) > MaxPayloadLength {
		return Frame{}, &ProtocolError{
			Kind:     ErrorPayloadTooLarge,
			Declared: uint32(len(payload)),
			Limit:    MaxPayloadLength,
		}
	}
	return NewFrame(CommandCompleteDisplayUpload, payload), nil
}

type InputMarker byte

const (
	InputMarkerButton  InputMarker = 0x01
	InputMarkerEncoder InputMarker = 0x02
)

func (m InputMarker) IsKnown() bool {
	return m == InputMarkerButton || m == InputMarkerEncoder
}

type InputAction byte

const (
	InputActionReleased     InputAction = 0x00
	InputActionPressed      InputAction = 0x01
	InputActionRotatedLeft  InputAction = 0x02
	InputActionRotatedRight InputAction = 0x03
)

func (a InputAction) IsKnown() bool {
	return a <= InputActionRotatedRight
}

type InputEvent struct {
	DeviceState byte
	WireIndex   byte
	Marker      InputMarker
	Action      InputAction
	RawPayload  []byte
}

func DecodeInput(frame Frame) (InputEvent, bool, error) {
	if frame.Command != CommandInputEvent {
		return InputEvent{}, false, nil
	}
	if len(frame.Payload) < 4 {
		return InputEvent{}, true, &ProtocolError{
			Kind:   ErrorMalformedInputPayload,
			Actual: len(frame.Payload),
		}
	}
	return InputEvent{
		DeviceState: frame.Payload[0],
		WireIndex:   frame.Payload[1],
		Marker:      InputMarker(frame.Payload[2]),
		Action:      InputAction(frame.Payload[3]),
		RawPayload:  append([]byte(nil), frame.Payload...),
	}, true, nil
}

func min(left, right int) int {
	if left < right {
		return left
	}
	return right
}

func max(left, right int) int {
	if left > right {
		return left
	}
	return right
}
