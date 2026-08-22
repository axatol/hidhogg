package d200x

import (
	"bytes"
	"encoding/binary"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/go-ctap/hid"
)

func TestNormalizeReportAcceptsProtocolAndReportIDForms(t *testing.T) {
	packet := make([]byte, ProtocolPacketSize)
	for index := range packet {
		packet[index] = byte(index % 251)
	}

	gotPacket, err := NormalizeReport(packet)
	if err != nil {
		t.Fatalf("normalize protocol packet: %v", err)
	}
	if !reflect.DeepEqual(gotPacket, packet) {
		t.Fatalf("normalized packet changed: got first bytes %v", gotPacket[:4])
	}

	transportReport := append([]byte{ReportIdentifier}, packet...)
	gotTransport, err := NormalizeReport(transportReport)
	if err != nil {
		t.Fatalf("normalize transport report: %v", err)
	}
	if !reflect.DeepEqual(gotTransport, packet) {
		t.Fatalf("report ID normalization changed packet")
	}
}

func TestNormalizeReportRejectsWrongLengthAndNonzeroReportID(t *testing.T) {
	for _, length := range []int{0, 1, ProtocolPacketSize - 1, TransportReportSize + 1} {
		_, err := NormalizeReport(make([]byte, length))
		var protocolErr *ProtocolError
		if !errors.As(err, &protocolErr) || protocolErr.Kind != ErrorInvalidReportLength || protocolErr.Actual != length {
			t.Fatalf("length %d error = %#v", length, err)
		}
	}

	report := make([]byte, TransportReportSize)
	report[0] = 7
	_, err := NormalizeReport(report)
	var protocolErr *ProtocolError
	if !errors.As(err, &protocolErr) || protocolErr.Kind != ErrorUnsupportedReportID || protocolErr.ReportID != 7 {
		t.Fatalf("nonzero report ID error = %#v", err)
	}
}

func TestFrameEncodingRoundTripsPayloadBoundaries(t *testing.T) {
	for _, payloadLength := range []int{0, 17, FirstPayloadCapacity, FirstPayloadCapacity + 1, 2_041} {
		payload := syntheticPayload(payloadLength)
		reports, err := EncodeFrame(NewFrame(CommandCompleteDisplayUpload, payload))
		if err != nil {
			t.Fatalf("encode payload length %d: %v", payloadLength, err)
		}
		for index, report := range reports {
			if len(report) != TransportReportSize {
				t.Fatalf("payload length %d report %d length = %d", payloadLength, index, len(report))
			}
			if report[0] != ReportIdentifier {
				t.Fatalf("payload length %d report %d ID = %d", payloadLength, index, report[0])
			}
		}
		if got, err := DecodeFrame(reports); err != nil || !bytes.Equal(got.Payload, payload) || got.Command != CommandCompleteDisplayUpload {
			t.Fatalf("payload length %d round trip = frame %#v, error %v", payloadLength, got, err)
		}
	}
}

func TestFrameEncoding1017BytePayloadUsesZeroPaddedContinuation(t *testing.T) {
	payload := syntheticPayload(FirstPayloadCapacity + 1)
	reports, err := EncodeFrame(NewFrame(CommandCompleteDisplayUpload, payload))
	if err != nil {
		t.Fatal(err)
	}
	if len(reports) != 2 {
		t.Fatalf("1017-byte payload reports = %d, want 2", len(reports))
	}
	first, err := NormalizeReport(reports[0])
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(first[FrameHeaderSize:], payload[:FirstPayloadCapacity]) {
		t.Fatal("first packet payload boundary changed")
	}
	continuation, err := NormalizeReport(reports[1])
	if err != nil {
		t.Fatal(err)
	}
	if continuation[0] != payload[FirstPayloadCapacity] {
		t.Fatalf("continuation byte = 0x%02x, want 0x%02x", continuation[0], payload[FirstPayloadCapacity])
	}
	if !bytes.Equal(continuation[1:], make([]byte, ProtocolPacketSize-1)) {
		t.Fatal("continuation packet was not zero padded")
	}
}

func TestFrameEncodingZeroPadsUnusedFirstPacketBytes(t *testing.T) {
	payload := syntheticPayload(17)
	reports, err := EncodeFrame(NewFrame(CommandBrightness, payload))
	if err != nil {
		t.Fatal(err)
	}
	packet, err := NormalizeReport(reports[0])
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(packet[FrameHeaderSize:FrameHeaderSize+len(payload)], payload) {
		t.Fatal("first packet payload changed")
	}
	if !bytes.Equal(packet[FrameHeaderSize+len(payload):], make([]byte, ProtocolPacketSize-FrameHeaderSize-len(payload))) {
		t.Fatal("unused first packet bytes were not zero padded")
	}
}

func TestFrameEncodingUsesBigEndianCommandAndLittleEndianLength(t *testing.T) {
	payload := []byte{0xA5, 0x00, 0x7C}
	reports, err := EncodeFrame(NewFrame(CommandBrightness, payload))
	if err != nil {
		t.Fatal(err)
	}
	packet := reports[0][1:]
	if got := binary.BigEndian.Uint16(packet[2:4]); got != uint16(CommandBrightness) {
		t.Fatalf("command header = 0x%04x", got)
	}
	if got := binary.LittleEndian.Uint32(packet[4:8]); got != uint32(len(payload)) {
		t.Fatalf("length header = %d", got)
	}
}

func TestFrameAssemblerRejectsTruncationAndOverLimit(t *testing.T) {
	payload := syntheticPayload(2_041)
	reports, err := EncodeFrame(NewFrame(CommandCompleteDisplayUpload, payload))
	if err != nil {
		t.Fatal(err)
	}
	assembler, err := NewFrameAssembler(reports[0])
	if err != nil {
		t.Fatal(err)
	}
	if err := assembler.Append(reports[1]); err != nil {
		t.Fatal(err)
	}
	_, err = assembler.Frame()
	var protocolErr *ProtocolError
	if !errors.As(err, &protocolErr) || protocolErr.Kind != ErrorTruncatedPayload || protocolErr.Expected != len(payload) || protocolErr.Received != 2_040 {
		t.Fatalf("truncation error = %#v", err)
	}

	first := make([]byte, ProtocolPacketSize)
	first[0] = 0x7C
	first[1] = 0x7C
	binary.BigEndian.PutUint16(first[2:4], uint16(CommandCompleteDisplayUpload))
	binary.LittleEndian.PutUint32(first[4:8], uint32(MaxPayloadLength+1))
	_, err = NewFrameAssembler(first)
	if !errors.As(err, &protocolErr) || protocolErr.Kind != ErrorPayloadTooLarge || protocolErr.Declared != MaxPayloadLength+1 {
		t.Fatalf("over-limit error = %#v", err)
	}
}

func TestFrameAssemblerRejectsContinuationAfterCompletion(t *testing.T) {
	assembler, err := NewFrameAssembler(mustFirstPacket(CommandEnableInputStream, nil))
	if err != nil {
		t.Fatal(err)
	}
	if !assembler.Complete() {
		t.Fatal("empty frame should be complete")
	}
	err = assembler.Append(make([]byte, ProtocolPacketSize))
	var protocolErr *ProtocolError
	if !errors.As(err, &protocolErr) || protocolErr.Kind != ErrorUnexpectedContinuation {
		t.Fatalf("unexpected continuation error = %#v", err)
	}
}

func TestUnknownCommandAndInputValuesRemainLossless(t *testing.T) {
	unknownFrame := NewFrame(Command(0xBEEF), []byte{0x7C, 0, 0xFF})
	if unknownFrame.Command.IsKnown() || unknownFrame.Command.String() != "unknown-0xbeef" {
		t.Fatalf("unknown command was coerced: %#v", unknownFrame.Command)
	}

	payload := []byte{9, 200, 0xFE, 0xFF, 0x7C, 0}
	event, ok, err := DecodeInput(NewFrame(CommandInputEvent, payload))
	if err != nil || !ok {
		t.Fatalf("decode unknown input: event=%#v ok=%v err=%v", event, ok, err)
	}
	if event.Marker.IsKnown() || event.Action.IsKnown() || !reflect.DeepEqual(event.RawPayload, payload) {
		t.Fatalf("unknown input was not lossless: %#v", event)
	}

	_, ok, err = DecodeInput(unknownFrame)
	if err != nil || ok {
		t.Fatalf("non-input frame result: ok=%v err=%v", ok, err)
	}
}

func TestInputMatrixAndShortPayloadValidation(t *testing.T) {
	for _, action := range []InputAction{InputActionReleased, InputActionPressed, InputActionRotatedLeft, InputActionRotatedRight} {
		event, ok, err := DecodeInput(NewFrame(CommandInputEvent, []byte{1, 17, byte(InputMarkerEncoder), byte(action), 0xA5}))
		if err != nil || !ok || event.Action != action || event.Marker != InputMarkerEncoder {
			t.Fatalf("action 0x%02x decode = %#v, ok=%v, error=%v", action, event, ok, err)
		}
	}
	for length := 0; length < 4; length++ {
		_, ok, err := DecodeInput(NewFrame(CommandInputEvent, make([]byte, length)))
		var protocolErr *ProtocolError
		if !ok || !errors.As(err, &protocolErr) || protocolErr.Kind != ErrorMalformedInputPayload || protocolErr.Actual != length {
			t.Fatalf("short input length %d = ok=%v error=%#v", length, ok, err)
		}
	}
}

func TestCommandConstructorsBoundBrightnessAndExposeSafeDiagnostics(t *testing.T) {
	for percentage, want := range map[int]string{-20: "0", 0: "0", 80: "80", 100: "100", 140: "100"} {
		frame := BrightnessFrame(percentage)
		if frame.Command != CommandBrightness || string(frame.Payload) != want {
			t.Fatalf("brightness %d = %#v", percentage, frame)
		}
	}
	if frame := EnableInputStreamFrame(); frame.Command != CommandEnableInputStream || len(frame.Payload) != 0 {
		t.Fatalf("input stream frame = %#v", frame)
	}
	diagnosticFrame, err := DiagnosticDisplayFrame()
	if err != nil || diagnosticFrame.Command != CommandCompleteDisplayUpload || len(diagnosticFrame.Payload) == 0 {
		t.Fatalf("diagnostic display frame = %#v, error=%v", diagnosticFrame, err)
	}
	if frame := UnlockScreenFrame(); frame.Command != CommandUnlockScreen || len(frame.Payload) != 0 {
		t.Fatalf("unlock frame = %#v", frame)
	}
}

func TestSelectionRefusesZeroOrMultipleCandidates(t *testing.T) {
	if _, err := SelectSingle(nil); !hasProtocolKind(err, ErrorNoMatchingDevice) {
		t.Fatalf("empty selection error = %v", err)
	}
	candidate := NewCandidate("opaque-path", VendorID, ProductID, InterfaceNumber)
	if selected, err := SelectSingle([]Candidate{candidate}); err != nil || selected != candidate {
		t.Fatalf("single selection = %#v, error=%v", selected, err)
	}
	if _, err := SelectSingle([]Candidate{candidate, candidate}); !hasProtocolKind(err, ErrorAmbiguousDeviceSelection) {
		t.Fatalf("ambiguous selection error = %v", err)
	}
	if _, err := SelectSingle([]Candidate{NewCandidate("keyboard", VendorID, ProductID, 1)}); !hasProtocolKind(err, ErrorIneligibleDevice) {
		t.Fatalf("nonmatching selection error = %v", err)
	}
}

func TestCandidateFromDeviceInfoNeverRetainsSerialNumber(t *testing.T) {
	info := &hid.DeviceInfo{
		Path:           "opaque-path",
		VendorID:       VendorID,
		ProductID:      ProductID,
		InterfaceNbr:   InterfaceNumber,
		UsagePage:      TargetUsagePage,
		Usage:          TargetUsage,
		InstanceID:     "opaque-instance-a",
		ParentDeviceID: "opaque-parent-a",
		ProductStr:     "D200X",
		SerialNbr:      "must-not-be-copied",
	}
	candidate, ok := CandidateFromDeviceInfo(info)
	if !ok || candidate.Product != "D200X" || candidate.path != info.Path || candidate.UsagePage != TargetUsagePage || candidate.Usage != TargetUsage {
		t.Fatalf("candidate = %#v, ok=%v", candidate, ok)
	}
	if candidate.InstanceHash == "none" || candidate.ParentHash == "none" || candidate.PathHash == "none" {
		t.Fatalf("candidate hashes = %#v", candidate)
	}
	if strings.Contains(candidate.Summary(), info.Path) || strings.Contains(candidate.Summary(), info.InstanceID) || strings.Contains(candidate.Summary(), info.ParentDeviceID) || strings.Contains(candidate.Summary(), info.SerialNbr) {
		t.Fatalf("candidate summary exposed opaque identity: %s", candidate.Summary())
	}
}

func TestCandidateDiagnosticsDifferentiateOpaqueCollectionsWithoutRawIdentifiers(t *testing.T) {
	base := hid.DeviceInfo{
		Path:           "opaque-path-a",
		VendorID:       VendorID,
		ProductID:      ProductID,
		InterfaceNbr:   InterfaceNumber,
		UsagePage:      TargetUsagePage,
		Usage:          TargetUsage,
		InstanceID:     "opaque-instance-a",
		ParentDeviceID: "opaque-parent-a",
	}
	other := base
	other.Path = "opaque-path-b"
	other.InstanceID = "opaque-instance-b"
	candidateA, ok := CandidateFromDeviceInfo(&base)
	if !ok {
		t.Fatal("base candidate rejected")
	}
	candidateB, ok := CandidateFromDeviceInfo(&other)
	if !ok {
		t.Fatal("other candidate rejected")
	}
	if candidateA.UsagePage != candidateB.UsagePage || candidateA.Usage != candidateB.Usage {
		t.Fatalf("usage diagnostics changed unexpectedly: %#v %#v", candidateA, candidateB)
	}
	if candidateA.InstanceHash == candidateB.InstanceHash || candidateA.PathHash == candidateB.PathHash {
		t.Fatalf("opaque identity hashes did not differentiate candidates: %#v %#v", candidateA, candidateB)
	}
	if strings.Contains(candidateA.Summary(), base.Path) || strings.Contains(candidateB.Summary(), other.Path) {
		t.Fatal("raw path exposed in candidate summary")
	}
}

func TestCandidateFromDeviceInfoRejectsEveryNonmatchingIdentity(t *testing.T) {
	base := &hid.DeviceInfo{
		Path:         "opaque-path",
		VendorID:     VendorID,
		ProductID:    ProductID,
		InterfaceNbr: InterfaceNumber,
		UsagePage:    TargetUsagePage,
		Usage:        TargetUsage,
	}
	for name, mutate := range map[string]func(*hid.DeviceInfo){
		"nil":        nil,
		"vendor":     func(info *hid.DeviceInfo) { info.VendorID++ },
		"product":    func(info *hid.DeviceInfo) { info.ProductID++ },
		"interface":  func(info *hid.DeviceInfo) { info.InterfaceNbr = 1 },
		"usage-page": func(info *hid.DeviceInfo) { info.UsagePage = 0x0001 },
		"usage":      func(info *hid.DeviceInfo) { info.Usage = 0x0006 },
		"path":       func(info *hid.DeviceInfo) { info.Path = "" },
	} {
		var info *hid.DeviceInfo
		if mutate == nil {
			info = nil
		} else {
			copy := *base
			mutate(&copy)
			info = &copy
		}
		if _, ok := CandidateFromDeviceInfo(info); ok {
			t.Fatalf("%s identity was accepted", name)
		}
	}
}

func TestCandidateFromDeviceInfoRejectsObservedKeyboardCollection(t *testing.T) {
	info := &hid.DeviceInfo{
		Path:         "keyboard-collection",
		VendorID:     VendorID,
		ProductID:    ProductID,
		InterfaceNbr: InterfaceNumber,
		UsagePage:    0x0001,
		Usage:        0x0006,
	}
	if _, ok := CandidateFromDeviceInfo(info); ok {
		t.Fatal("generic-desktop keyboard collection was accepted as D200X control collection")
	}
}

func syntheticPayload(length int) []byte {
	payload := make([]byte, length)
	for index := range payload {
		payload[index] = byte(index % 251)
	}
	return payload
}

func mustFirstPacket(command Command, payload []byte) []byte {
	reports, err := EncodeFrame(NewFrame(command, payload))
	if err != nil {
		panic(err)
	}
	return reports[0]
}

func hasProtocolKind(err error, kind ProtocolErrorKind) bool {
	var protocolErr *ProtocolError
	return errors.As(err, &protocolErr) && protocolErr.Kind == kind
}
