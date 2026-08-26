package d200x

import (
	"bytes"
	"encoding/binary"
	"errors"
	"testing"
)

func TestEncodeDecodeFrameBoundariesAndReportNormalization(t *testing.T) {
	for _, payloadLength := range []int{0, 1, FirstPayloadCapacity, FirstPayloadCapacity + 1, 2041} {
		payload := make([]byte, payloadLength)
		for index := range payload {
			payload[index] = byte(index*31 + 7)
		}
		frame := NewFrame(CommandCompleteDisplayUpload, payload)
		reports, err := EncodeFrame(frame)
		if err != nil {
			t.Fatalf("EncodeFrame(%d): %v", payloadLength, err)
		}
		wantReports := 1
		if payloadLength > FirstPayloadCapacity {
			wantReports += (payloadLength - FirstPayloadCapacity + ProtocolPacketSize - 1) / ProtocolPacketSize
		}
		if len(reports) != wantReports {
			t.Fatalf("payload %d: got %d reports, want %d", payloadLength, len(reports), wantReports)
		}
		for index, report := range reports {
			if len(report) != TransportReportSize {
				t.Fatalf("report %d length = %d, want %d", index, len(report), TransportReportSize)
			}
			if report[0] != ReportIdentifier {
				t.Fatalf("report %d ID = %#x, want %#x", index, report[0], ReportIdentifier)
			}
		}
		decoded, err := DecodeFrame(reports)
		if err != nil {
			t.Fatalf("DecodeFrame(%d): %v", payloadLength, err)
		}
		if decoded.Command != frame.Command || !bytes.Equal(decoded.Payload, payload) {
			t.Fatalf("payload %d did not round trip", payloadLength)
		}

		protocolPacket, err := NormalizeReport(reports[0][1:])
		if err != nil {
			t.Fatalf("NormalizeReport(protocol packet): %v", err)
		}
		if !bytes.Equal(protocolPacket, reports[0][1:]) {
			t.Fatal("protocol packet normalization changed bytes")
		}
	}
}

func TestNormalizeReportRejectsInvalidLengthAndReportID(t *testing.T) {
	if _, err := NormalizeReport(make([]byte, ProtocolPacketSize-1)); !hasProtocolKind(err, ErrorInvalidReportLength) {
		t.Fatalf("short report error = %v", err)
	}
	if _, err := NormalizeReport(make([]byte, ProtocolPacketSize-1)); !hasProtocolKind(err, ErrorInvalidReportLength) {
		t.Fatalf("invalid HID report error = %v", err)
	}
	unsupported := make([]byte, TransportReportSize)
	unsupported[0] = 1
	if _, err := NormalizeReport(unsupported); !hasProtocolKind(err, ErrorUnsupportedReportID) {
		t.Fatalf("unsupported report ID error = %v", err)
	}
}

func TestEncodeFrameUsesProtocolEndianAndZeroPadding(t *testing.T) {
	payload := bytes.Repeat([]byte{0xa5}, 17)
	reports, err := EncodeFrame(NewFrame(CommandBrightness, payload))
	if err != nil {
		t.Fatal(err)
	}
	packet := reports[0][1:]
	if got := binary.BigEndian.Uint16(packet[2:4]); got != uint16(CommandBrightness) {
		t.Fatalf("command header = %#x, want %#x", got, CommandBrightness)
	}
	if got := binary.LittleEndian.Uint32(packet[4:8]); got != uint32(len(payload)) {
		t.Fatalf("length header = %d, want %d", got, len(payload))
	}
	if !bytes.Equal(packet[FrameHeaderSize:FrameHeaderSize+len(payload)], payload) || !bytes.Equal(packet[FrameHeaderSize+len(payload):], make([]byte, ProtocolPacketSize-FrameHeaderSize-len(payload))) {
		t.Fatal("unused first-packet bytes were not zero padded")
	}

	continuationPayload := bytes.Repeat([]byte{0x5a}, FirstPayloadCapacity+1)
	reports, err = EncodeFrame(NewFrame(CommandCompleteDisplayUpload, continuationPayload))
	if err != nil {
		t.Fatal(err)
	}
	if len(reports) != 2 || reports[1][1] != continuationPayload[FirstPayloadCapacity] || !bytes.Equal(reports[1][2:], make([]byte, ProtocolPacketSize-1)) {
		t.Fatal("continuation packet was not zero padded")
	}
}

func TestFrameAssemblerRejectsMalformedOrTruncatedInput(t *testing.T) {
	frame := NewFrame(CommandCompleteDisplayUpload, bytes.Repeat([]byte{0xa5}, 2041))
	reports, err := EncodeFrame(frame)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeFrame(reports[:len(reports)-1]); !hasProtocolKind(err, ErrorTruncatedPayload) {
		t.Fatalf("truncated frame error = %v", err)
	}
	if _, err := DecodeFrame(append(append([][]byte(nil), reports...), make([]byte, TransportReportSize))); !hasProtocolKind(err, ErrorUnexpectedContinuation) {
		t.Fatalf("extra continuation error = %v", err)
	}

	badMagic := append([]byte(nil), reports[0]...)
	badMagic[1] = 0
	if _, err := NewFrameAssembler(badMagic); !hasProtocolKind(err, ErrorInvalidFrameMagic) {
		t.Fatalf("bad magic error = %v", err)
	}

	badContinuation := reports[1][:ProtocolPacketSize-1]
	assembler, err := NewFrameAssembler(reports[0])
	if err != nil {
		t.Fatal(err)
	}
	if err := assembler.Append(badContinuation); !hasProtocolKind(err, ErrorInvalidReportLength) {
		t.Fatalf("bad continuation error = %v", err)
	}

	zeroFrameReports, err := EncodeFrame(NewFrame(CommandBrightness, nil))
	if err != nil {
		t.Fatal(err)
	}
	zeroAssembler, err := NewFrameAssembler(zeroFrameReports[0])
	if err != nil {
		t.Fatal(err)
	}
	if err := zeroAssembler.Append(make([]byte, TransportReportSize)); !hasProtocolKind(err, ErrorUnexpectedContinuation) {
		t.Fatalf("continuation after complete error = %v", err)
	}
}

func TestFrameLimitsAreEnforced(t *testing.T) {
	tooLarge := make([]byte, MaxPayloadLength+1)
	if _, err := EncodeFrame(NewFrame(CommandCompleteDisplayUpload, tooLarge)); !hasProtocolKind(err, ErrorPayloadTooLarge) {
		t.Fatalf("oversize encode error = %v", err)
	}
	if _, err := CompleteDisplayUploadFrame(tooLarge); !hasProtocolKind(err, ErrorPayloadTooLarge) {
		t.Fatalf("oversize upload frame error = %v", err)
	}

	first := make([]byte, TransportReportSize)
	first[0] = ReportIdentifier
	packet := first[1:]
	packet[0] = 0x7c
	packet[1] = 0x7c
	binary.BigEndian.PutUint16(packet[2:4], uint16(CommandCompleteDisplayUpload))
	binary.LittleEndian.PutUint32(packet[4:8], uint32(MaxPayloadLength+1))
	if _, err := NewFrameAssembler(first); !hasProtocolKind(err, ErrorPayloadTooLarge) {
		t.Fatalf("oversize declared frame error = %v", err)
	}
}

func TestInputDecodingPreservesWireValuesAndMalformedInputIsSafe(t *testing.T) {
	payload := []byte{0xa7, 13, 0xf2, 0xf3, 0x44}
	event, ok, err := DecodeInput(NewFrame(CommandInputEvent, payload))
	if err != nil || !ok {
		t.Fatalf("DecodeInput unknown values: event=%+v ok=%t err=%v", event, ok, err)
	}
	if event.DeviceState != payload[0] || event.WireIndex != payload[1] || byte(event.Marker) != payload[2] || byte(event.Action) != payload[3] || !bytes.Equal(event.RawPayload, payload) {
		t.Fatalf("decoded event lost wire values: %+v", event)
	}
	if event.Marker.IsKnown() || event.Action.IsKnown() {
		t.Fatal("unknown marker/action was reported as known")
	}

	for _, length := range []int{0, 3} {
		_, ok, err := DecodeInput(NewFrame(CommandInputEvent, make([]byte, length)))
		if !ok || !hasProtocolKind(err, ErrorMalformedInputPayload) {
			t.Fatalf("malformed input length %d: ok=%t err=%v", length, ok, err)
		}
		var protocolErr *ProtocolError
		if !errors.As(err, &protocolErr) || protocolErr.Expected != 4 {
			t.Fatalf("malformed input length %d expected bytes = %d", length, protocolErr.Expected)
		}
	}
	if _, ok, err := DecodeInput(NewFrame(CommandBrightness, nil)); ok || err != nil {
		t.Fatalf("non-input frame: ok=%t err=%v", ok, err)
	}
}

func TestBrightnessFrameClampsOnlyAtPrimitiveBoundary(t *testing.T) {
	if got := BrightnessFrame(-20).Payload; string(got) != "0" {
		t.Fatalf("negative brightness payload = %q", got)
	}
	if got := BrightnessFrame(120).Payload; string(got) != "100" {
		t.Fatalf("high brightness payload = %q", got)
	}
	if got := BrightnessFrame(37).Payload; string(got) != "37" {
		t.Fatalf("normal brightness payload = %q", got)
	}
}

func hasProtocolKind(err error, kind ProtocolErrorKind) bool {
	var protocolError *ProtocolError
	return errors.As(err, &protocolError) && protocolError.Kind == kind
}
