package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	d200x "hidhogg/spikes/go-hid-d200x"
)

type probeTransport struct {
	writes    [][]byte
	reads     [][]byte
	writeN    int
	writeErr  error
	failOn    d200x.Command
	failErr   error
	failShort bool
	readReady chan struct{}
	readOnce  sync.Once
}

func (transport *probeTransport) Read(ctx context.Context, destination []byte) (int, error) {
	if len(transport.reads) == 0 {
		transport.readOnce.Do(func() {
			if transport.readReady != nil {
				close(transport.readReady)
			}
		})
		<-ctx.Done()
		return 0, ctx.Err()
	}
	report := transport.reads[0]
	transport.reads = transport.reads[1:]
	return copy(destination, report), nil
}

func (transport *probeTransport) Write(_ context.Context, report []byte) (int, error) {
	transport.writes = append(transport.writes, append([]byte(nil), report...))
	if transport.failOn != 0 && probeReportCommand(report) == transport.failOn {
		if transport.failShort {
			return len(report) - 1, nil
		}
		if transport.failErr != nil {
			return 0, transport.failErr
		}
		return 0, errors.New("injected write failure")
	}
	if transport.writeErr != nil {
		return 0, transport.writeErr
	}
	if transport.writeN != 0 {
		return transport.writeN, nil
	}
	return len(report), nil
}

func (*probeTransport) Close() error { return nil }

type probeFactory struct {
	candidates     []d200x.Candidate
	transport      *probeTransport
	enumerateCalls int
	openCalls      int
	enumerateErr   error
	openErr        error
}

func (factory *probeFactory) Enumerate(context.Context) ([]d200x.Candidate, error) {
	factory.enumerateCalls++
	if factory.enumerateErr != nil {
		return nil, factory.enumerateErr
	}
	return factory.candidates, nil
}

func (factory *probeFactory) Open(context.Context, d200x.Candidate) (d200x.Transport, error) {
	factory.openCalls++
	if factory.openErr != nil {
		return nil, factory.openErr
	}
	return factory.transport, nil
}

func newProbeFactory() *probeFactory {
	return &probeFactory{
		candidates: []d200x.Candidate{d200x.NewCandidate("opaque", d200x.VendorID, d200x.ProductID, d200x.InterfaceNumber)},
		transport:  &probeTransport{},
	}
}

func probeReportCommand(report []byte) d200x.Command {
	packet, err := d200x.NormalizeReport(report)
	if err != nil || len(packet) < d200x.FrameHeaderSize || packet[0] != 0x7c || packet[1] != 0x7c {
		return 0
	}
	return d200x.Command(binary.BigEndian.Uint16(packet[2:4]))
}

func writtenFrameStartCommands(reports [][]byte) []d200x.Command {
	commands := make([]d200x.Command, 0, len(reports))
	for _, report := range reports {
		if command := probeReportCommand(report); command != 0 {
			commands = append(commands, command)
		}
	}
	return commands
}

func decodeWrittenFrames(reports [][]byte) ([]d200x.Frame, error) {
	frames := make([]d200x.Frame, 0)
	for index := 0; index < len(reports); {
		assembler, err := d200x.NewFrameAssembler(reports[index])
		if err != nil {
			return nil, err
		}
		index++
		for !assembler.Complete() {
			if index >= len(reports) {
				return nil, errors.New("incomplete written frame")
			}
			if err := assembler.Append(reports[index]); err != nil {
				return nil, err
			}
			index++
		}
		frame, err := assembler.Frame()
		if err != nil {
			return nil, err
		}
		frames = append(frames, frame)
	}
	return frames, nil
}

func TestActionDefinitionsMapAllKnownSymbolsExactly(t *testing.T) {
	want := map[string]d200x.Command{
		"complete-display-upload": 0x0001,
		"enable-input-stream":     0x0002,
		"observed-host-lock":      0x0004,
		"small-window-refresh":    0x0006,
		"brightness":              0x000a,
		"label-style":             0x000b,
		"partial-display-upload":  0x000d,
		"lock-screen":             0x000f,
		"unlock-screen":           0x0010,
		"input-event":             0x0101,
		"acknowledgement":         0x010b,
		"device-information":      0x0303,
	}
	if len(actionDefinitions) != len(want) {
		t.Fatalf("action count = %d, want %d", len(actionDefinitions), len(want))
	}
	for _, definition := range actionDefinitions {
		if wantCommand, ok := want[definition.name]; !ok || definition.command != wantCommand {
			t.Fatalf("mapping %q = 0x%04x", definition.name, uint16(definition.command))
		}
	}
}

func TestRunRejectsZeroActivityAndMixedModesBeforeEnumeration(t *testing.T) {
	requests := [][]string{
		nil,
		{"--parameters", "diagnostic"},
		{"--action", "brightness", "--parameters", "1", "--listen", "--duration", "1s"},
		{"--listen", "--duration", "0s"},
		{"--listen", "--duration", "-1s"},
		{"--duration", "1s"},
		{"--action", "lock-screen", "--duration", "1s"},
		{"--action", "unknown"},
		{"--action", "unlock-screen", "unexpected"},
		{"--confirm"},
	}
	for _, request := range requests {
		factory := newProbeFactory()
		var stdout, stderr bytes.Buffer
		if code := run(request, factory, &stdout, &stderr); code != 2 {
			t.Fatalf("request %v code = %d, stderr=%q", request, code, stderr.String())
		}
		if factory.enumerateCalls != 0 || factory.openCalls != 0 || len(factory.transport.writes) != 0 {
			t.Fatalf("request %v touched HID", request)
		}
	}
}

func TestHelpDescribesLiveBulkPresetAndObservation(t *testing.T) {
	factory := newProbeFactory()
	var stdout, stderr bytes.Buffer
	if code := run([]string{"--help"}, factory, &stdout, &stderr); code != 2 {
		t.Fatalf("help code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	output := stdout.String() + stderr.String()
	for _, want := range []string{
		"live-bulk",
		"0x0001",
		"bulk redraw",
		"host write success",
		"startup-sequence",
		"unlock-screen",
		"complete-display-upload",
		"brightness",
		"enable-input-stream",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("help missing %q: %q", want, output)
		}
	}
	if factory.enumerateCalls != 0 || factory.openCalls != 0 || len(factory.transport.writes) != 0 {
		t.Fatalf("help touched HID: enumerate=%d open=%d writes=%d", factory.enumerateCalls, factory.openCalls, len(factory.transport.writes))
	}
}

func TestBrightnessRequiresCanonicalDecimal(t *testing.T) {
	for _, parameter := range []string{"", "00", "01", "+1", "-0", " 1", "1 ", "101", "-1", "1.0"} {
		factory := newProbeFactory()
		var stdout, stderr bytes.Buffer
		args := []string{"--action", "brightness", "--parameters", parameter}
		if code := run(args, factory, &stdout, &stderr); code != 2 {
			t.Fatalf("parameter %q code = %d", parameter, code)
		}
		if factory.enumerateCalls != 0 {
			t.Fatalf("parameter %q enumerated", parameter)
		}
	}
	for _, parameter := range []string{"0", "1", "99", "100"} {
		frame, err := buildActionFrame("brightness", optionalString{present: true, value: parameter})
		if err != nil || string(frame.Payload) != parameter {
			t.Fatalf("parameter %q frame=%#v err=%v", parameter, frame, err)
		}
	}
}

func TestStartupSequenceRequiresCanonicalBrightnessBeforeEnumeration(t *testing.T) {
	for _, parameter := range []string{"", "00", "01", "+1", "-0", " 1", "1 ", "101", "-1", "1.0"} {
		factory := newProbeFactory()
		var stdout, stderr bytes.Buffer
		args := []string{"--action", startupSequenceAction, "--parameters", parameter}
		if code := run(args, factory, &stdout, &stderr); code != 2 {
			t.Fatalf("parameter %q code = %d, stderr=%q", parameter, code, stderr.String())
		}
		if factory.enumerateCalls != 0 || factory.openCalls != 0 || len(factory.transport.writes) != 0 {
			t.Fatalf("parameter %q touched HID: enumerate=%d open=%d writes=%d", parameter, factory.enumerateCalls, factory.openCalls, len(factory.transport.writes))
		}
		if !strings.Contains(stderr.String(), "canonical decimal") {
			t.Fatalf("parameter %q error=%q", parameter, stderr.String())
		}
	}
}

func TestStartupSequenceAcceptsCanonicalBounds(t *testing.T) {
	for _, parameter := range []string{"0", "100"} {
		factory := newProbeFactory()
		var stdout, stderr bytes.Buffer
		args := []string{"--action", startupSequenceAction, "--parameters", parameter}
		if code := run(args, factory, &stdout, &stderr); code != 0 {
			t.Fatalf("parameter %q code=%d stderr=%q", parameter, code, stderr.String())
		}
		frames, err := decodeWrittenFrames(factory.transport.writes)
		if err != nil {
			t.Fatalf("parameter %q decode frames: %v", parameter, err)
		}
		if len(frames) != 4 || frames[2].Command != d200x.CommandBrightness || string(frames[2].Payload) != parameter {
			t.Fatalf("parameter %q frames=%#v", parameter, frames)
		}
	}
}

func TestStartupSequenceSendsExactFramesInOneSession(t *testing.T) {
	factory := newProbeFactory()
	var stdout, stderr bytes.Buffer
	if code := run([]string{"--action", startupSequenceAction, "--parameters", "80"}, factory, &stdout, &stderr); code != 0 {
		t.Fatalf("code=%d stderr=%q", code, stderr.String())
	}
	if factory.enumerateCalls != 1 || factory.openCalls != 1 {
		t.Fatalf("enumerate=%d open=%d", factory.enumerateCalls, factory.openCalls)
	}
	frames, err := decodeWrittenFrames(factory.transport.writes)
	if err != nil {
		t.Fatalf("decode startup frames: %v", err)
	}
	wantCommands := []d200x.Command{
		d200x.CommandUnlockScreen,
		d200x.CommandCompleteDisplayUpload,
		d200x.CommandBrightness,
		d200x.CommandEnableInputStream,
	}
	if len(frames) != len(wantCommands) {
		t.Fatalf("frame count=%d, want %d", len(frames), len(wantCommands))
	}
	for index, command := range wantCommands {
		if frames[index].Command != command {
			t.Fatalf("frame %d command=%s, want %s", index, frames[index].Command, command)
		}
	}
	wantLiveBulk, err := d200x.LiveBulkDisplayFrame()
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(frames[1].Payload, wantLiveBulk.Payload) {
		t.Fatal("startup upload differs from existing content-addressed live-bulk archive")
	}
	if string(frames[2].Payload) != "80" {
		t.Fatalf("brightness payload=%q", frames[2].Payload)
	}
	for _, commandName := range []string{"unlock-screen", "complete-display-upload", "brightness", "enable-input-stream"} {
		if !strings.Contains(stdout.String(), "startup-sequence completed "+commandName) {
			t.Fatalf("output missing completed %s: %q", commandName, stdout.String())
		}
	}
	if strings.Contains(stdout.String()+stderr.String(), "opaque") ||
		strings.Contains(stdout.String()+stderr.String(), "serial") ||
		strings.Contains(stdout.String()+stderr.String(), "path") ||
		strings.Contains(stdout.String()+stderr.String(), "payload") ||
		strings.Contains(stdout.String()+stderr.String(), "archive") {
		t.Fatalf("startup output exposed unsafe detail: stdout=%q stderr=%q", stdout.String(), stderr.String())
	}
}

func TestParameterRulesAndPayloads(t *testing.T) {
	diagnostic, err := buildActionFrame("complete-display-upload", optionalString{present: true, value: "diagnostic"})
	if err != nil || diagnostic.Command != d200x.CommandCompleteDisplayUpload || len(diagnostic.Payload) == 0 || len(diagnostic.Payload) > d200x.MaxPayloadLength {
		t.Fatalf("diagnostic frame=%#v err=%v", diagnostic, err)
	}
	wantDiagnostic, err := d200x.DiagnosticDisplayFrame()
	if err != nil || !bytes.Equal(diagnostic.Payload, wantDiagnostic.Payload) {
		t.Fatalf("diagnostic upload did not preserve the existing archive exactly: %v", err)
	}
	liveBulk, err := buildActionFrame("complete-display-upload", optionalString{present: true, value: d200x.LiveBulkDisplayPreset})
	if err != nil || liveBulk.Command != d200x.CommandCompleteDisplayUpload || len(liveBulk.Payload) == 0 || len(liveBulk.Payload) > d200x.MaxPayloadLength {
		t.Fatalf("live bulk frame=%#v err=%v", liveBulk, err)
	}
	wantLiveBulk, err := d200x.LiveBulkDisplayFrame()
	if err != nil || !bytes.Equal(liveBulk.Payload, wantLiveBulk.Payload) {
		t.Fatalf("live bulk upload did not preserve its archive exactly: %v", err)
	}
	for _, parameter := range []optionalString{{}, {present: true, value: ""}, {present: true, value: "archive.zip"}} {
		if _, err := buildActionFrame("complete-display-upload", parameter); err == nil {
			t.Fatalf("upload accepted parameter %#v", parameter)
		}
	}
	if _, err := buildActionFrame("complete-display-upload", optionalString{present: true, value: "unknown"}); err == nil {
		t.Fatal("upload accepted unknown preset")
	}
	for _, definition := range actionDefinitions {
		if definition.command == d200x.CommandBrightness || definition.command == d200x.CommandCompleteDisplayUpload || definition.command == d200x.CommandPartialDisplayUpload {
			continue
		}
		frame, err := buildActionFrame(definition.name, optionalString{})
		if err != nil || len(frame.Payload) != 0 {
			t.Fatalf("action %s frame=%#v err=%v", definition.name, frame, err)
		}
		if _, err := buildActionFrame(definition.name, optionalString{present: true}); err == nil {
			t.Fatalf("action %s accepted parameters", definition.name)
		}
	}
}

func TestLiveBulkPresetSendsExactlyOneCompleteUpload(t *testing.T) {
	factory := newProbeFactory()
	var stdout, stderr bytes.Buffer
	args := []string{"--action", "complete-display-upload", "--parameters", d200x.LiveBulkDisplayPreset}
	if code := run(args, factory, &stdout, &stderr); code != 0 {
		t.Fatalf("code=%d stderr=%q", code, stderr.String())
	}
	if factory.enumerateCalls != 1 || factory.openCalls != 1 {
		t.Fatalf("enumerate=%d open=%d", factory.enumerateCalls, factory.openCalls)
	}
	frame, err := d200x.DecodeFrame(factory.transport.writes)
	if err != nil || frame.Command != d200x.CommandCompleteDisplayUpload || len(frame.Payload) == 0 {
		t.Fatalf("live bulk decoded frame=%#v err=%v", frame, err)
	}
	if strings.Contains(stdout.String(), "brightness") || strings.Contains(stdout.String(), "unlock") || strings.Contains(stdout.String(), "input-enable") {
		t.Fatalf("live bulk output implies auxiliary command: %q", stdout.String())
	}
	if !strings.Contains(stdout.String(), "0x0001") || !strings.Contains(stdout.String(), "write completed") {
		t.Fatalf("live bulk output=%q", stdout.String())
	}
}

func TestEveryActionOpensOnceAndSendsOneLogicalFrame(t *testing.T) {
	for _, definition := range actionDefinitions {
		factory := newProbeFactory()
		args := []string{"--action", definition.name}
		if definition.command == d200x.CommandBrightness {
			args = append(args, "--parameters", "80")
		}
		if definition.command == d200x.CommandCompleteDisplayUpload {
			args = append(args, "--parameters", "diagnostic")
		}
		if definition.command == d200x.CommandPartialDisplayUpload {
			args = append(args, "--parameters", "square-a")
		}
		var stdout, stderr bytes.Buffer
		if code := run(args, factory, &stdout, &stderr); code != 0 {
			t.Fatalf("action %s code=%d stderr=%q", definition.name, code, stderr.String())
		}
		if factory.enumerateCalls != 1 || factory.openCalls != 1 {
			t.Fatalf("action %s enumerate=%d open=%d", definition.name, factory.enumerateCalls, factory.openCalls)
		}
		frame, err := d200x.DecodeFrame(factory.transport.writes)
		if err != nil || frame.Command != definition.command {
			t.Fatalf("action %s decoded=%#v err=%v", definition.name, frame, err)
		}
		if definition.command == d200x.CommandCompleteDisplayUpload && strings.Contains(stdout.String(), "unlock") {
			t.Fatalf("upload output implies unlock: %q", stdout.String())
		}
		if !strings.Contains(stdout.String(), "write completed") || strings.Contains(stdout.String(), "accepted") {
			t.Fatalf("action %s output=%q", definition.name, stdout.String())
		}
	}
}

func TestFailedAndShortWritesAreNotRetried(t *testing.T) {
	for _, transport := range []*probeTransport{
		{writeErr: errors.New("write failed")},
		{writeN: d200x.TransportReportSize - 1},
	} {
		factory := newProbeFactory()
		factory.transport = transport
		var stdout, stderr bytes.Buffer
		if code := run([]string{"--action", "lock-screen"}, factory, &stdout, &stderr); code != 1 {
			t.Fatalf("code=%d stderr=%q", code, stderr.String())
		}
		if len(transport.writes) != 1 {
			t.Fatalf("failed write attempts = %d", len(transport.writes))
		}
	}
}

func TestStartupSequenceStopsAtFirstOrdinaryWriteFailure(t *testing.T) {
	wantCommands := []d200x.Command{
		d200x.CommandUnlockScreen,
		d200x.CommandCompleteDisplayUpload,
		d200x.CommandBrightness,
		d200x.CommandEnableInputStream,
	}
	for failureIndex, command := range wantCommands {
		factory := newProbeFactory()
		factory.transport.failOn = command
		factory.transport.failErr = errors.New("injected-write-secret")
		var stdout, stderr bytes.Buffer
		if code := run([]string{"--action", startupSequenceAction, "--parameters", "50"}, factory, &stdout, &stderr); code != 1 {
			t.Fatalf("failure at %s code=%d stdout=%q stderr=%q", command, code, stdout.String(), stderr.String())
		}
		written := writtenFrameStartCommands(factory.transport.writes)
		if len(written) != failureIndex+1 {
			t.Fatalf("failure at %s wrote command starts=%v, want prefix length %d", command, written, failureIndex+1)
		}
		for index, writtenCommand := range written {
			if writtenCommand != wantCommands[index] {
				t.Fatalf("failure at %s command %d=%s, want %s", command, index, writtenCommand, wantCommands[index])
			}
		}
		if !strings.Contains(stderr.String(), "startup-sequence step "+command.String()+" failed") ||
			!strings.Contains(stderr.String(), "frame write failed") ||
			strings.Contains(stderr.String(), "injected-write-secret") {
			t.Fatalf("failure at %s unsafe error=%q", command, stderr.String())
		}
		if strings.Contains(stdout.String(), "completed "+command.String()) {
			t.Fatalf("failed command reported completed: %q", stdout.String())
		}
		for _, laterCommand := range wantCommands[failureIndex+1:] {
			if strings.Contains(stdout.String(), "completed "+laterCommand.String()) || strings.Contains(stderr.String(), "step "+laterCommand.String()) {
				t.Fatalf("failure at %s continued to %s: stdout=%q stderr=%q", command, laterCommand, stdout.String(), stderr.String())
			}
		}
	}
}

func TestStartupSequenceStopsAtFirstShortWrite(t *testing.T) {
	wantCommands := []d200x.Command{
		d200x.CommandUnlockScreen,
		d200x.CommandCompleteDisplayUpload,
		d200x.CommandBrightness,
		d200x.CommandEnableInputStream,
	}
	for failureIndex, command := range wantCommands {
		factory := newProbeFactory()
		factory.transport.failOn = command
		factory.transport.failShort = true
		var stdout, stderr bytes.Buffer
		if code := run([]string{"--action", startupSequenceAction, "--parameters", "50"}, factory, &stdout, &stderr); code != 1 {
			t.Fatalf("short failure at %s code=%d stdout=%q stderr=%q", command, code, stdout.String(), stderr.String())
		}
		written := writtenFrameStartCommands(factory.transport.writes)
		if len(written) != failureIndex+1 {
			t.Fatalf("short failure at %s wrote command starts=%v, want prefix length %d", command, written, failureIndex+1)
		}
		if !strings.Contains(stderr.String(), "startup-sequence step "+command.String()+" failed") ||
			!strings.Contains(stderr.String(), "short write") || strings.Contains(stderr.String(), "payload") {
			t.Fatalf("short failure at %s error=%q", command, stderr.String())
		}
		for _, laterCommand := range wantCommands[failureIndex+1:] {
			if strings.Contains(stdout.String(), "completed "+laterCommand.String()) || strings.Contains(stderr.String(), "step "+laterCommand.String()) {
				t.Fatalf("short failure at %s continued to %s: stdout=%q stderr=%q", command, laterCommand, stdout.String(), stderr.String())
			}
		}
	}
}

func TestStartupSequenceSelectionAndOpenFailuresAreSafe(t *testing.T) {
	tests := []struct {
		name             string
		configure        func(*probeFactory)
		wantEnumerations int
		wantOpens        int
		wantError        string
	}{
		{
			name:             "selection",
			configure:        func(factory *probeFactory) { factory.candidates = nil },
			wantEnumerations: 1,
			wantOpens:        0,
			wantError:        "startup-sequence device selection failed",
		},
		{
			name:             "open",
			configure:        func(factory *probeFactory) { factory.openErr = errors.New("open-device-secret") },
			wantEnumerations: 1,
			wantOpens:        1,
			wantError:        "startup-sequence device open failed",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			factory := newProbeFactory()
			test.configure(factory)
			var stdout, stderr bytes.Buffer
			if code := run([]string{"--action", startupSequenceAction, "--parameters", "50"}, factory, &stdout, &stderr); code != 1 {
				t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
			}
			if factory.enumerateCalls != test.wantEnumerations || factory.openCalls != test.wantOpens || len(factory.transport.writes) != 0 {
				t.Fatalf("enumerate=%d open=%d writes=%d", factory.enumerateCalls, factory.openCalls, len(factory.transport.writes))
			}
			if !strings.Contains(stderr.String(), test.wantError) || strings.Contains(stderr.String(), "secret") || strings.Contains(stderr.String(), "opaque") {
				t.Fatalf("unsafe error=%q", stderr.String())
			}
		})
	}
}

func TestPassiveListenSendsNothingAndLogsCompleteFramesWithRedaction(t *testing.T) {
	inputPayload := []byte{7, 9, 2, 1, 0xaa}
	inputReports, err := d200x.EncodeFrame(d200x.NewFrame(d200x.CommandInputEvent, inputPayload))
	if err != nil {
		t.Fatal(err)
	}
	otherReports, err := d200x.EncodeFrame(d200x.NewFrame(d200x.CommandAcknowledgement, []byte("raw-secret-payload")))
	if err != nil {
		t.Fatal(err)
	}
	factory := newProbeFactory()
	factory.transport.reads = append(inputReports, otherReports...)
	var stdout, stderr bytes.Buffer
	if code := run([]string{"--listen", "--duration", "1ms"}, factory, &stdout, &stderr); code != 0 {
		t.Fatalf("code=%d stderr=%q", code, stderr.String())
	}
	output := stdout.String()
	for _, want := range []string{"zero frames", "command=input-event", "input-index=9", "command=acknowledgement", "sha256="} {
		if !strings.Contains(output, want) {
			t.Fatalf("output missing %q: %q", want, output)
		}
	}
	for _, forbidden := range []string{"raw-secret-payload", "opaque", "serial", "path"} {
		if strings.Contains(output+stderr.String(), forbidden) {
			t.Fatalf("listen exposed %q: %q", forbidden, output+stderr.String())
		}
	}
	if len(factory.transport.writes) != 0 {
		t.Fatalf("passive listen writes = %d", len(factory.transport.writes))
	}
}

func TestPassiveListenFailsOnPartialFrameTimeout(t *testing.T) {
	payload := make([]byte, d200x.FirstPayloadCapacity+1)
	reports, err := d200x.EncodeFrame(d200x.NewFrame(d200x.CommandDeviceInformation, payload))
	if err != nil {
		t.Fatal(err)
	}
	factory := newProbeFactory()
	factory.transport.reads = reports[:1]
	var stdout, stderr bytes.Buffer
	if code := run([]string{"--listen", "--duration", "1ms"}, factory, &stdout, &stderr); code != 1 {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if !strings.Contains(stderr.String(), "partial frame") || len(factory.transport.writes) != 0 {
		t.Fatalf("stdout=%q stderr=%q writes=%d", stdout.String(), stderr.String(), len(factory.transport.writes))
	}
}

func TestIndefiniteListenStopsOnInjectedSignalAtFrameBoundary(t *testing.T) {
	reports, err := d200x.EncodeFrame(d200x.NewFrame(d200x.CommandAcknowledgement, []byte("bounded-secret")))
	if err != nil {
		t.Fatal(err)
	}
	factory := newProbeFactory()
	factory.transport.reads = reports
	factory.transport.readReady = make(chan struct{})
	listenContext, signalCancel := cancellableSignalContext()
	var stdout, stderr bytes.Buffer
	result := make(chan int, 1)
	go func() {
		result <- runWithSignalContext([]string{"--listen"}, factory, &stdout, &stderr, listenContext)
	}()
	select {
	case <-factory.transport.readReady:
	case <-time.After(time.Second):
		t.Fatal("listen did not reach a blocking read")
	}
	signalCancel()
	select {
	case code := <-result:
		if code != 0 {
			t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
		}
	case <-time.After(time.Second):
		t.Fatal("listen did not stop after injected signal")
	}
	if !strings.Contains(stdout.String(), "command=acknowledgement") || !strings.Contains(stdout.String(), "stopped by signal") {
		t.Fatalf("stdout=%q", stdout.String())
	}
	if strings.Contains(stdout.String(), "duration elapsed") || len(factory.transport.writes) != 0 {
		t.Fatalf("stdout=%q writes=%d", stdout.String(), len(factory.transport.writes))
	}
}

func TestIndefiniteListenSignalWithPartialFrameFails(t *testing.T) {
	payload := make([]byte, d200x.FirstPayloadCapacity+1)
	reports, err := d200x.EncodeFrame(d200x.NewFrame(d200x.CommandDeviceInformation, payload))
	if err != nil {
		t.Fatal(err)
	}
	factory := newProbeFactory()
	factory.transport.reads = reports[:1]
	factory.transport.readReady = make(chan struct{})
	listenContext, signalCancel := cancellableSignalContext()
	var stdout, stderr bytes.Buffer
	result := make(chan int, 1)
	go func() {
		result <- runWithSignalContext([]string{"--listen"}, factory, &stdout, &stderr, listenContext)
	}()
	select {
	case <-factory.transport.readReady:
	case <-time.After(time.Second):
		t.Fatal("listen did not reach a blocking read")
	}
	signalCancel()
	select {
	case code := <-result:
		if code != 1 {
			t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
		}
	case <-time.After(time.Second):
		t.Fatal("listen did not stop after injected signal")
	}
	if !strings.Contains(stderr.String(), "partial frame") || len(factory.transport.writes) != 0 {
		t.Fatalf("stdout=%q stderr=%q writes=%d", stdout.String(), stderr.String(), len(factory.transport.writes))
	}
}

func cancellableSignalContext() (listenSignalContext, context.CancelFunc) {
	var cancel context.CancelFunc
	return func(parent context.Context) (context.Context, context.CancelFunc) {
			ctx, contextCancel := context.WithCancel(parent)
			cancel = contextCancel
			return ctx, contextCancel
		}, func() {
			cancel()
		}
}
