package diagnostic

import (
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/d200x"
)

func TestClosedDiagnosticModesAndWakeCandidates(t *testing.T) {
	for _, value := range []string{"brightness-zero", "firmware-wake"} {
		mode, err := ParseMode(value)
		if err != nil || !mode.Valid() {
			t.Fatalf("ParseMode(%q) = %q, %v", value, mode, err)
		}
	}
	if _, err := ParseMode("arbitrary-command"); !errors.Is(err, ErrInvalidMode) {
		t.Fatalf("unknown mode error = %v", err)
	}
	want := []WakeCandidate{WakeBrightness, WakeInputEnable, WakeUnlock, WakeCompletePageUpload}
	if got := WakeCandidates(); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("wake candidates = %v, want %v", got, want)
	}
	for _, candidate := range want {
		if parsed, err := ParseWakeCandidate(string(candidate)); err != nil || parsed != candidate {
			t.Fatalf("ParseWakeCandidate(%q) = %q, %v", candidate, parsed, err)
		}
	}
	if _, err := ParseWakeCandidate("device-information"); !errors.Is(err, ErrInvalidWakeCandidate) {
		t.Fatalf("unsafe wake candidate error = %v", err)
	}
}

func TestObservationSinkProducesBoundedValidJSONWithoutRawFields(t *testing.T) {
	var output bytes.Buffer
	sink := observationSink{writer: &output, limit: 64}
	if err := sink.observe(Observation{
		Event:     "diagnostic",
		Mode:      ModeFirmwareWake,
		Candidate: WakeCompletePageUpload,
		Stage:     strings.Repeat("stage", 100),
		Status:    StatusFail,
		Detail:    strings.Repeat("hidraw=/private/serial-secret", 100),
	}); err != nil {
		t.Fatal(err)
	}
	line := strings.TrimSpace(output.String())
	if len(line) > 64 {
		t.Fatalf("observation length = %d, want <= 64", len(line))
	}
	var decoded map[string]any
	if err := json.Unmarshal([]byte(line), &decoded); err != nil {
		t.Fatalf("bounded observation is not JSON: %v", err)
	}
	if strings.Contains(output.String(), "serial-secret") || strings.Contains(output.String(), "hidraw") {
		t.Fatalf("observation leaked raw identity: %q", output.String())
	}
}

func TestCapturedInputObservationsDistinguishBoundedFailureCauses(t *testing.T) {
	var output bytes.Buffer
	runner := &Runner{
		options: Options{Mode: ModeBrightnessZero},
		sink:    observationSink{writer: &output, limit: 1024},
	}
	boundaries := captureObservationBoundaries{
		ready:         captureBoundary{sequence: 1},
		baselineEnd:   captureBoundary{sequence: 5},
		zeroStart:     captureBoundary{sequence: 6},
		zeroEnd:       captureBoundary{sequence: 8},
		phaseEnd:      captureBoundary{sequence: 12},
		restoreStart:  captureBoundary{sequence: 13},
		restoreEnd:    captureBoundary{sequence: 15},
		recoveryReady: captureBoundary{sequence: 16},
		recoveryEnd:   captureBoundary{sequence: 19},
	}
	records := []capturedInput{
		{boundary: captureBoundary{sequence: 1}, decoded: true, event: d200x.InputEvent{WireIndex: 0, Marker: d200x.InputMarkerButton, Action: d200x.InputActionPressed}},
		{boundary: captureBoundary{sequence: 2}, decoded: true, event: d200x.InputEvent{WireIndex: 0, Marker: d200x.InputMarkerButton, Action: d200x.InputActionPressed}},
		{boundary: captureBoundary{sequence: 3}, decoded: true, event: d200x.InputEvent{WireIndex: 0, Marker: d200x.InputMarkerButton, Action: d200x.InputActionReleased}},
		{boundary: captureBoundary{sequence: 4}, decoded: true, event: d200x.InputEvent{WireIndex: 0, Marker: d200x.InputMarkerButton, Action: d200x.InputActionReleased}},
		{boundary: captureBoundary{sequence: 5}, decoded: true, event: d200x.InputEvent{WireIndex: 1, Marker: d200x.InputMarkerButton, Action: d200x.InputActionPressed}},
		{boundary: captureBoundary{sequence: 7}, decoded: true, event: d200x.InputEvent{WireIndex: 13, Marker: d200x.InputMarkerButton, Action: d200x.InputActionPressed}},
		{boundary: captureBoundary{sequence: 8}, malformed: true},
		{boundary: captureBoundary{sequence: 9}, decoded: true, event: d200x.InputEvent{WireIndex: 13, Marker: d200x.InputMarkerButton, Action: d200x.InputActionPressed}},
		{boundary: captureBoundary{sequence: 10}, decoded: true, event: d200x.InputEvent{WireIndex: 13, Marker: d200x.InputMarker(0x7f), Action: d200x.InputActionPressed}},
		{boundary: captureBoundary{sequence: 14}, decoded: true, event: d200x.InputEvent{WireIndex: 15, Marker: d200x.InputMarkerButton, Action: d200x.InputActionPressed}},
		{boundary: captureBoundary{sequence: 17}, decoded: true, event: d200x.InputEvent{WireIndex: 0, Marker: d200x.InputMarkerButton, Action: d200x.InputActionPressed}},
		{boundary: captureBoundary{sequence: 20}, decoded: true, event: d200x.InputEvent{WireIndex: 0, Marker: d200x.InputMarkerButton, Action: d200x.InputActionReleased}},
	}
	runner.observeCapturedInputs(records, boundaries)

	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != len(records) {
		t.Fatalf("observation count = %d, want %d", len(lines), len(records))
	}
	want := map[uint64]struct {
		phase          CapturePhase
		classification string
		status         Status
		decoded        bool
		malformed      bool
	}{
		1:  {CapturePhasePreReady, inputClassificationStale, StatusClassFailure, true, false},
		2:  {CapturePhaseBaseline, inputClassificationExpected, StatusPass, true, false},
		3:  {CapturePhaseBaseline, inputClassificationExpected, StatusPass, true, false},
		4:  {CapturePhaseBaseline, inputClassificationDuplicate, StatusClassFailure, true, false},
		5:  {CapturePhaseBaseline, inputClassificationWrong, StatusClassFailure, true, false},
		7:  {CapturePhaseZeroWriteOverlap, inputClassificationWriteOverlap, StatusInvalidated, true, false},
		8:  {CapturePhaseZeroWriteOverlap, inputClassificationMalformed, StatusInvalidated, false, true},
		9:  {CapturePhaseZeroState, inputClassificationExpected, StatusPass, true, false},
		10: {CapturePhaseZeroState, inputClassificationWrong, StatusClassFailure, true, false},
		14: {CapturePhaseRestoreOverlap, inputClassificationWriteOverlap, StatusInvalidated, true, false},
		17: {CapturePhaseRecovery, inputClassificationExpected, StatusPass, true, false},
		20: {CapturePhaseTrailing, inputClassificationTrailing, StatusClassFailure, true, false},
	}
	var previous uint64
	for _, line := range lines {
		var observation Observation
		if err := json.Unmarshal([]byte(line), &observation); err != nil {
			t.Fatalf("observation JSON = %v", err)
		}
		if observation.Event != "input" {
			t.Fatalf("observation event = %q, want input", observation.Event)
		}
		if observation.Sequence <= previous || observation.Boundary != observation.Sequence {
			t.Fatalf("observation sequence/boundary = %d/%d after %d", observation.Sequence, observation.Boundary, previous)
		}
		previous = observation.Sequence
		wantObservation, ok := want[observation.Sequence]
		if !ok {
			t.Fatalf("unexpected observation sequence = %d", observation.Sequence)
		}
		if observation.Phase != wantObservation.phase || observation.Classification != wantObservation.classification || observation.Status != wantObservation.status || observation.Decoded != wantObservation.decoded || observation.Malformed != wantObservation.malformed {
			t.Fatalf("observation %d = %+v, want phase=%s classification=%s status=%s decoded=%t malformed=%t", observation.Sequence, observation, wantObservation.phase, wantObservation.classification, wantObservation.status, wantObservation.decoded, wantObservation.malformed)
		}
		if strings.Contains(line, "payload") || strings.Contains(line, "serial") || strings.Contains(line, "hidraw") {
			t.Fatalf("observation contains a raw identity/payload marker: %q", line)
		}
	}
}

func TestInputObservationSinkPreservesMetadataWithinBound(t *testing.T) {
	var output bytes.Buffer
	sink := observationSink{writer: &output, limit: 256}
	if err := sink.observe(Observation{
		Event:          "input",
		Mode:           ModeBrightnessZero,
		Stage:          strings.Repeat("stage", 100),
		Status:         StatusClassFailure,
		Marker:         "button",
		Action:         "pressed",
		Sequence:       7,
		Phase:          CapturePhaseBaseline,
		Decoded:        true,
		Malformed:      false,
		Classification: inputClassificationWrong,
		Boundary:       7,
		Detail:         strings.Repeat("hidraw=/private/serial-secret payload=deadbeef ", 100),
	}); err != nil {
		t.Fatal(err)
	}
	line := strings.TrimSpace(output.String())
	if len(line) > 256 {
		t.Fatalf("observation length = %d, want <= 256", len(line))
	}
	var observation Observation
	if err := json.Unmarshal([]byte(line), &observation); err != nil {
		t.Fatalf("bounded input observation is not JSON: %v", err)
	}
	if observation.Event != "input" || observation.Sequence != 7 || observation.Phase != CapturePhaseBaseline || !observation.Decoded || observation.Malformed || observation.Classification != inputClassificationWrong {
		t.Fatalf("bounded input metadata = %+v", observation)
	}
	if strings.Contains(line, "serial-secret") || strings.Contains(line, "payload") || strings.Contains(line, "hidraw") {
		t.Fatalf("bounded input observation leaked raw data: %q", line)
	}
}

func TestConfirmationGatePerformsNoHIDCalls(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	factory := &diagnosticFactory{transport: newDiagnosticTransport()}
	runner, err := New(Options{
		Mode:       ModeBrightnessZero,
		ConfigPath: configurationPath,
		Factory:    factory,
		Confirm:    false,
		Reader:     io.NopCloser(strings.NewReader("\n\n\n\n")),
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := runner.Run(context.Background())
	if !errors.Is(err, ErrConfirmationRequired) {
		t.Fatalf("Run error = %v, want confirmation error", err)
	}
	if result.Status != StatusPartial {
		t.Fatalf("result status = %s, want %s", result.Status, StatusPartial)
	}
	encoded, marshalErr := json.Marshal(result)
	if marshalErr != nil {
		t.Fatal(marshalErr)
	}
	if strings.Contains(string(encoded), `"partial":`) {
		t.Fatalf("result retained removed partial boolean: %s", encoded)
	}
	if got := factory.calls(); len(got) != 0 {
		t.Fatalf("HID calls before confirmation = %v", got)
	}
}

func TestExactSelectionRefusesAmbiguousD200XCandidates(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	factory := &diagnosticFactory{
		transport: newDiagnosticTransport(),
		candidates: []d200x.Candidate{
			d200x.NewCandidate("/private/first", d200x.VendorID, d200x.ProductID, d200x.InterfaceNumber),
			d200x.NewCandidate("/private/second", d200x.VendorID, d200x.ProductID, d200x.InterfaceNumber),
		},
	}
	runner, err := New(Options{
		Mode:       ModeBrightnessZero,
		ConfigPath: configurationPath,
		Confirm:    true,
		Factory:    factory,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = runner.Run(context.Background())
	if err == nil {
		t.Fatal("ambiguous candidates were accepted")
	}
	if got := factory.calls(); fmt.Sprint(got) != "[enumerate]" {
		t.Fatalf("HID calls after ambiguous selection = %v", got)
	}
}

func TestBrightnessZeroMatrixWritesZeroThenConfiguredRestore(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	transport := newDiagnosticTransport()
	nowCalls := 0
	now := func() time.Time {
		nowCalls++
		switch nowCalls {
		case 1:
			queueInputPair(t, transport, 0, d200x.InputMarkerButton)
		case 5:
			queueBrightnessProbeEvents(t, transport)
		case 18:
			queueInputPair(t, transport, 0, d200x.InputMarkerButton)
		}
		return time.Unix(0, int64(nowCalls))
	}
	factory := &diagnosticFactory{transport: transport}
	var observations bytes.Buffer
	var prompts bytes.Buffer
	reader := &completionReader{transport: transport, target: 11}
	runner, err := New(Options{
		Mode:                ModeBrightnessZero,
		ConfigPath:          configurationPath,
		Confirm:             true,
		Factory:             factory,
		Reader:              reader,
		PromptWriter:        &prompts,
		ObservationWriter:   &observations,
		StageTimeout:        time.Second,
		MaxObservationBytes: 256,
		Now:                 now,
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := runner.Run(context.Background())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Status != StatusPass {
		t.Fatalf("result status = %s, want %s", result.Status, StatusPass)
	}
	commands, err := diagnosticCommands(transport.writesSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	want := []d200x.Command{
		d200x.CommandCompleteDisplayUpload,
		d200x.CommandBrightness,
		d200x.CommandUnlockScreen,
		d200x.CommandEnableInputStream,
		d200x.CommandBrightness,
		d200x.CommandBrightness,
	}
	if fmt.Sprint(commands) != fmt.Sprint(want) {
		t.Fatalf("commands = %v, want %v", commands, want)
	}
	brightnessPayloads, err := brightnessPayloads(transport.writesSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	if got, want := brightnessPayloads, [][]byte{[]byte("73"), []byte("0"), []byte("73")}; fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("brightness payloads = %q, want %q", got, want)
	}
	if transport.closeCountValue() != 1 {
		t.Fatalf("close count = %d, want 1", transport.closeCountValue())
	}
	wantStages := []string{
		"brightness-zero-baseline",
		"brightness-zero-write",
		"brightness-zero-attestation",
		"brightness-restore",
		"brightness-zero-matrix",
		"brightness-zero-recovery",
	}
	if got := matrixStages(result.Observations, wantStages); fmt.Sprint(got) != fmt.Sprint(wantStages) {
		t.Fatalf("brightness matrix stages = %v, want %v", got, wantStages)
	}
	for _, observation := range result.Observations {
		for _, stage := range wantStages {
			if observation.Stage == stage && observation.Status != StatusPass {
				t.Fatalf("input observation = %+v", observation)
			}
			if observation.Stage == "brightness-zero-attestation" && observation.BrightnessAttestation != Brightness100Observed {
				t.Fatalf("brightness attestation = %q, want %q", observation.BrightnessAttestation, Brightness100Observed)
			}
		}
	}
	for _, line := range strings.Split(strings.TrimSpace(observations.String()), "\n") {
		if len(line) > 256 {
			t.Fatalf("observation line length = %d", len(line))
		}
	}
	if reader.reads != 1 {
		t.Fatalf("operator completion reads = %d, want exactly one", reader.reads)
	}
	if lines := strings.Split(strings.TrimSpace(prompts.String()), "\n"); len(lines) != 4 {
		t.Fatalf("phase prompts = %q, want baseline, matrix, attestation, and recovery", prompts.String())
	}
	boundaries := make(map[string]uint64)
	for _, observation := range result.Observations {
		if observation.Boundary == 0 {
			continue
		}
		boundaries[observation.Stage] = observation.Boundary
	}
	orderedStages := []string{"brightness-zero-baseline", "brightness-zero-write", "brightness-zero-attestation", "brightness-restore", "brightness-zero-matrix", "brightness-zero-recovery"}
	for index := 1; index < len(orderedStages); index++ {
		if boundaries[orderedStages[index-1]] >= boundaries[orderedStages[index]] {
			t.Fatalf("boundaries are not monotonic by phase: %v", boundaries)
		}
	}
}

func TestBrightnessZeroLateInputBeforeCaptureShutdownInvalidatesResult(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	transport := newDiagnosticTransport()
	lateReports, err := d200x.EncodeFrame(d200x.NewFrame(d200x.CommandInputEvent, []byte{1, 0, byte(d200x.InputMarkerButton), byte(d200x.InputActionPressed)}))
	if err != nil {
		t.Fatal(err)
	}
	transport.postRecoveryReadAfter = 13
	transport.postRecoveryReport = lateReports[0]
	nowCalls := 0
	now := func() time.Time {
		nowCalls++
		switch nowCalls {
		case 1:
			queueInputPair(t, transport, 0, d200x.InputMarkerButton)
		case 5:
			queueBrightnessProbeEvents(t, transport)
		case 18:
			queueInputPair(t, transport, 0, d200x.InputMarkerButton)
		}
		return time.Unix(0, int64(nowCalls))
	}
	factory := &diagnosticFactory{transport: transport}
	reader := &completionReader{transport: transport, target: 11}
	runner, err := New(Options{
		Mode:         ModeBrightnessZero,
		ConfigPath:   configurationPath,
		Confirm:      true,
		Factory:      factory,
		Reader:       reader,
		StageTimeout: time.Second,
		Now:          now,
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := runner.Run(context.Background())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !transport.postRecoveryInjectedValue() {
		t.Fatal("late input was not injected while capture shutdown was pending")
	}
	if result.Status != StatusInvalidated {
		t.Fatalf("result status = %s, want %s", result.Status, StatusInvalidated)
	}
	var lateInput bool
	var matrixStage, recoveryStage Observation
	for _, observation := range result.Observations {
		if observation.Event == "input" && observation.Phase == CapturePhaseTrailing && observation.Status == StatusClassFailure {
			lateInput = true
		}
		if observation.Stage == "brightness-zero-matrix" {
			matrixStage = observation
		}
		if observation.Stage == "brightness-zero-recovery" {
			recoveryStage = observation
		}
	}
	if !lateInput {
		t.Fatal("late input was omitted or did not receive a non-pass trailing classification")
	}
	if matrixStage.Status != StatusInvalidated || recoveryStage.Status != StatusInvalidated {
		t.Fatalf("matrix/recovery stages = %s/%s, want invalidated/invalidated", matrixStage.Status, recoveryStage.Status)
	}
}

func TestContinuousTraceValidationRejectsMissingDuplicateReorderedMalformedAndUnexpected(t *testing.T) {
	exact := baselineTrace()
	valid := []capturedInput{
		{decoded: true, event: d200x.InputEvent{WireIndex: 0, Marker: d200x.InputMarkerButton, Action: d200x.InputActionPressed}},
		{decoded: true, event: d200x.InputEvent{WireIndex: 0, Marker: d200x.InputMarkerButton, Action: d200x.InputActionReleased}},
	}
	tests := map[string][]capturedInput{
		"missing":    valid[:1],
		"duplicate":  append(append([]capturedInput(nil), valid...), valid[1]),
		"reordered":  {valid[1], valid[0]},
		"malformed":  {valid[0], {malformed: true}},
		"unexpected": {valid[0], {decoded: false}},
	}
	if status := validateCapturedEvents(valid, exact); status != StatusPass {
		t.Fatalf("exact trace status = %s, want pass", status)
	}
	for name, records := range tests {
		t.Run(name, func(t *testing.T) {
			if status := validateCapturedEvents(records, exact); status != StatusClassFailure {
				t.Fatalf("trace status = %s, want class failure", status)
			}
		})
	}
}

func TestBoundaryPartitionIdentifiesEventsDuringWrites(t *testing.T) {
	records := []capturedInput{
		{boundary: captureBoundary{sequence: 2}, decoded: true},
		{boundary: captureBoundary{sequence: 4}, decoded: true},
		{boundary: captureBoundary{sequence: 6}, decoded: true},
	}
	if !recordsBetweenExist(records, captureBoundary{sequence: 3}, captureBoundary{sequence: 5}) {
		t.Fatal("event during write interval was not detected")
	}
	if recordsBetweenExist(records, captureBoundary{sequence: 4}, captureBoundary{sequence: 5}) {
		t.Fatal("event on the completed boundary leaked into the next interval")
	}
}

func TestFirmwareIdleBeforeBrightnessZeroInvalidatesWithoutWritingZero(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	transport := newDiagnosticTransport()
	queueInputPair(t, transport, 0, d200x.InputMarkerButton)
	staleCaptured := make(chan struct{})
	nowCalls := 0
	now := func() time.Time {
		nowCalls++
		if nowCalls == 2 {
			close(staleCaptured)
		}
		return time.Unix(0, int64(nowCalls))
	}
	var prompts bytes.Buffer
	runner, err := New(Options{
		Mode:         ModeBrightnessZero,
		ConfigPath:   configurationPath,
		Confirm:      true,
		Factory:      &diagnosticFactory{transport: transport},
		StageTimeout: 10 * time.Millisecond,
		PromptWriter: &promptAfterCaptureWriter{ready: staleCaptured, writer: &prompts},
		Now:          now,
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := runner.Run(context.Background())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Status != StatusClassFailure {
		t.Fatalf("result status = %s, want class-failure", result.Status)
	}
	commands, err := diagnosticCommands(transport.writesSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	if got := countCommand(commands, d200x.CommandBrightness); got != 1 {
		t.Fatalf("brightness attempts = %d, want startup only", got)
	}
}

func TestInputProbeConsumesPressReleaseBeforeNextStage(t *testing.T) {
	transport := newDiagnosticTransport()
	queueInputPair(t, transport, 0, d200x.InputMarkerButton)
	queueInputPair(t, transport, 13, d200x.InputMarkerButton)
	runner, session := newInputProbeRunner(t, transport, "\n\n")

	if status := runner.runInputProbe(context.Background(), session, brightnessZeroBeforeProbes()[0]); status != StatusPass {
		t.Fatalf("square pair status = %s, want %s", status, StatusPass)
	}
	if status := runner.runInputProbe(context.Background(), session, brightnessZeroBeforeProbes()[1]); status != StatusPass {
		t.Fatalf("wide pair status = %s, want %s", status, StatusPass)
	}
	transport.mu.Lock()
	remaining := len(transport.reads)
	transport.mu.Unlock()
	if remaining != 0 {
		t.Fatalf("input reports left after paired probes = %d, want 0", remaining)
	}
}

func TestInputProbeRejectsPairWithDifferentWireOrClassAndConsumesIt(t *testing.T) {
	transport := newDiagnosticTransport()
	queueInputEvent(t, transport, 0, d200x.InputMarkerButton, d200x.InputActionPressed)
	queueInputEvent(t, transport, 13, d200x.InputMarkerButton, d200x.InputActionReleased)
	queueInputPair(t, transport, 13, d200x.InputMarkerButton)
	runner, session := newInputProbeRunner(t, transport, "\n\n")

	if status := runner.runInputProbe(context.Background(), session, brightnessZeroBeforeProbes()[0]); status != StatusFail {
		t.Fatalf("mismatched pair status = %s, want %s", status, StatusFail)
	}
	if status := runner.runInputProbe(context.Background(), session, brightnessZeroBeforeProbes()[1]); status != StatusPass {
		t.Fatalf("following pair status = %s, want %s", status, StatusPass)
	}
}

func newInputProbeRunner(t *testing.T, transport *diagnosticTransport, input string) (*Runner, *d200x.Session) {
	t.Helper()
	factory := &diagnosticFactory{transport: transport}
	runner, err := New(Options{
		Mode:         ModeBrightnessZero,
		ConfigPath:   "/private/fake-diagnostic.toml",
		Confirm:      true,
		Factory:      factory,
		Reader:       io.NopCloser(strings.NewReader(input)),
		StageTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	session := d200x.NewSession(factory)
	candidate := d200x.NewCandidate("/private/fake-d200x", d200x.VendorID, d200x.ProductID, d200x.InterfaceNumber)
	if err := session.Open(context.Background(), candidate); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = session.Close() })
	return runner, session
}

func TestFirmwareWakeUploadUsesOnePrevalidatedCandidateFrameWithoutTrailingUnlock(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	transport := newDiagnosticTransport()
	transport.quietReadCount = 1
	queueInputPair(t, transport, 0, d200x.InputMarkerButton)
	queueInputPair(t, transport, 15, d200x.InputMarkerButton)
	queueInputEvent(t, transport, 17, d200x.InputMarkerEncoder, d200x.InputActionRotatedRight)
	factory := &diagnosticFactory{transport: transport}
	runner, err := New(Options{
		Mode:              ModeFirmwareWake,
		ConfigPath:        configurationPath,
		WakeCandidate:     WakeCompletePageUpload,
		Confirm:           true,
		Factory:           factory,
		Reader:            io.NopCloser(strings.NewReader("sleep\n\nrecovered\n\n\n\n")),
		StageTimeout:      10 * time.Millisecond,
		ObservationWriter: io.Discard,
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := runner.Run(context.Background())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Status != StatusPass {
		t.Fatalf("result status = %s, want %s", result.Status, StatusPass)
	}
	writes := transport.writesSnapshot()
	commands, err := diagnosticCommands(writes)
	if err != nil {
		t.Fatal(err)
	}
	want := []d200x.Command{
		d200x.CommandCompleteDisplayUpload,
		d200x.CommandBrightness,
		d200x.CommandUnlockScreen,
		d200x.CommandEnableInputStream,
		d200x.CommandCompleteDisplayUpload,
	}
	if fmt.Sprint(commands) != fmt.Sprint(want) {
		t.Fatalf("commands = %v, want %v", commands, want)
	}
	if commands[len(commands)-1] == d200x.CommandUnlockScreen {
		t.Fatal("upload candidate had a trailing unlock")
	}
	frames, err := decodedCommandFrames(writes)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(frames[0].Payload, frames[len(frames)-1].Payload) {
		t.Fatal("candidate upload payload differs from prevalidated startup page")
	}
	if transport.closeCountValue() != 1 {
		t.Fatalf("close count = %d, want 1", transport.closeCountValue())
	}
	wantStages := []string{
		"firmware-screensaver",
		"firmware-wake-before-square",
		"wake-candidate-write",
		"display-recovery",
		"firmware-wake-after-square",
		"firmware-wake-after-physical-button",
		"firmware-wake-after-encoder",
		"wake-result",
	}
	if got := matrixStages(result.Observations, wantStages); fmt.Sprint(got) != fmt.Sprint(wantStages) {
		t.Fatalf("firmware wake stages = %v, want %v", got, wantStages)
	}
}

func TestFirmwareWakeQuietPrecheckWithholdsCandidateAfterDecodedInput(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	transport := newDiagnosticTransport()
	queueInputEvent(t, transport, 0, d200x.InputMarkerButton, d200x.InputActionPressed)
	factory := &diagnosticFactory{transport: transport}
	runner, err := New(Options{
		Mode:          ModeFirmwareWake,
		ConfigPath:    configurationPath,
		WakeCandidate: WakeUnlock,
		Confirm:       true,
		Factory:       factory,
		Reader:        io.NopCloser(strings.NewReader("sleep\n\n")),
		StageTimeout:  10 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := runner.Run(context.Background())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Status != StatusFail {
		t.Fatalf("result status = %s, want %s", result.Status, StatusFail)
	}
	commands, err := diagnosticCommands(transport.writesSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	if got := countCommand(commands, d200x.CommandUnlockScreen); got != 1 {
		t.Fatalf("unlock command count = %d, want startup-only write", got)
	}
	foundPrecheckFailure := false
	for _, observation := range result.Observations {
		if observation.Stage == "firmware-wake-before-square" && observation.Status == StatusFail {
			foundPrecheckFailure = true
		}
	}
	if !foundPrecheckFailure {
		t.Fatal("decoded pre-attempt input was not recorded as a failure")
	}
	foundSelectedNotRun := false
	for _, observation := range result.Observations {
		if observation.Stage == "wake-candidate" && observation.Candidate == WakeUnlock && observation.Status == StatusNotRun {
			foundSelectedNotRun = true
			break
		}
	}
	if !foundSelectedNotRun {
		t.Fatal("selected wake candidate was not recorded as not-run after quiet precheck failure")
	}
}

func TestFirmwareWakeQuietPrecheckSkipMarksSelectedCandidateNotRun(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	transport := newDiagnosticTransport()
	factory := &diagnosticFactory{transport: transport}
	runner, err := New(Options{
		Mode:          ModeFirmwareWake,
		ConfigPath:    configurationPath,
		WakeCandidate: WakeUnlock,
		Confirm:       true,
		Factory:       factory,
		Reader:        io.NopCloser(strings.NewReader("sleep\nskip\n")),
		StageTimeout:  10 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := runner.Run(context.Background())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if result.Status != StatusPartial {
		t.Fatalf("result status = %s, want %s", result.Status, StatusPartial)
	}
	commands, err := diagnosticCommands(transport.writesSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	if got := countCommand(commands, d200x.CommandUnlockScreen); got != 1 {
		t.Fatalf("unlock command count = %d, want startup-only write", got)
	}
	for _, observation := range result.Observations {
		if observation.Stage == "wake-candidate" && observation.Candidate == WakeUnlock {
			if observation.Status != StatusNotRun {
				t.Fatalf("selected candidate observation = %+v, want not-run", observation)
			}
			return
		}
	}
	t.Fatal("selected wake candidate observation was missing")
}

func TestFirmwareWakeAllowlistMapsEachCandidateToOneFinalFrame(t *testing.T) {
	tests := []struct {
		candidate WakeCandidate
		command   d200x.Command
	}{
		{candidate: WakeBrightness, command: d200x.CommandBrightness},
		{candidate: WakeInputEnable, command: d200x.CommandEnableInputStream},
		{candidate: WakeUnlock, command: d200x.CommandUnlockScreen},
		{candidate: WakeCompletePageUpload, command: d200x.CommandCompleteDisplayUpload},
	}
	for _, test := range tests {
		t.Run(string(test.candidate), func(t *testing.T) {
			configurationPath := writeDiagnosticConfiguration(t, 73)
			transport := newDiagnosticTransport()
			transport.quietReadCount = 1
			queueInputPair(t, transport, 0, d200x.InputMarkerButton)
			queueInputEvent(t, transport, 15, d200x.InputMarkerButton, d200x.InputActionPressed)
			queueInputEvent(t, transport, 15, d200x.InputMarkerButton, d200x.InputActionReleased)
			queueInputEvent(t, transport, 17, d200x.InputMarkerEncoder, d200x.InputActionRotatedRight)
			factory := &diagnosticFactory{transport: transport}
			displayState := "recovered"
			if test.candidate == WakeInputEnable {
				displayState = "unchanged"
			}
			reader := io.NopCloser(strings.NewReader("sleep\n\n" + displayState + "\n\n\n\n"))
			runner, err := New(Options{
				Mode:          ModeFirmwareWake,
				ConfigPath:    configurationPath,
				WakeCandidate: test.candidate,
				Confirm:       true,
				Factory:       factory,
				Reader:        reader,
				StageTimeout:  10 * time.Millisecond,
			})
			if err != nil {
				t.Fatal(err)
			}
			result, err := runner.Run(context.Background())
			if err != nil || result.Status != StatusPass {
				t.Fatalf("Run result = %s, error = %v", result.Status, err)
			}
			if test.candidate == WakeInputEnable {
				foundUnchanged := false
				for _, observation := range result.Observations {
					if observation.Stage == "display-recovery" && observation.Display == DisplayUnchanged {
						foundUnchanged = true
						break
					}
				}
				if !foundUnchanged {
					t.Fatal("input-enable display state was not recorded as unchanged")
				}
			}
			commands, err := diagnosticCommands(transport.writesSnapshot())
			if err != nil {
				t.Fatal(err)
			}
			if got := commands[len(commands)-1]; got != test.command {
				t.Fatalf("final command = %s, want %s", got, test.command)
			}
		})
	}
}

func TestWakeCandidateConstructorsAreAllowlistedAndTyped(t *testing.T) {
	plan := devicePlan{pageFrame: d200x.NewFrame(d200x.CommandCompleteDisplayUpload, []byte("page")), brightness: 41}
	want := map[WakeCandidate]d200x.Command{
		WakeBrightness:         d200x.CommandBrightness,
		WakeInputEnable:        d200x.CommandEnableInputStream,
		WakeUnlock:             d200x.CommandUnlockScreen,
		WakeCompletePageUpload: d200x.CommandCompleteDisplayUpload,
	}
	for candidate, command := range want {
		frame, err := wakeFrame(candidate, plan)
		if err != nil || frame.Command != command {
			t.Fatalf("wakeFrame(%q) = %#v, %v; want %s", candidate, frame, err, command)
		}
	}
	if _, err := wakeFrame(WakeCandidate("lock-screen"), plan); !errors.Is(err, ErrInvalidWakeCandidate) {
		t.Fatalf("unsafe wakeFrame error = %v", err)
	}
}

func TestFirmwareWakeRunnerIsSingleUsePerFreshGeneration(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	factory := &diagnosticFactory{transport: newDiagnosticTransport()}
	runner, err := New(Options{
		Mode:          ModeFirmwareWake,
		ConfigPath:    configurationPath,
		WakeCandidate: WakeInputEnable,
		Confirm:       true,
		Factory:       factory,
		Reader:        io.NopCloser(strings.NewReader("")),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := runner.Run(context.Background()); err != nil {
		t.Fatalf("first generation run = %v", err)
	}
	if _, err := runner.Run(context.Background()); err == nil || !strings.Contains(err.Error(), "single-use") {
		t.Fatalf("second generation run error = %v", err)
	}
	if got := factory.calls(); fmt.Sprint(got) != "[enumerate open]" {
		t.Fatalf("device calls after second generation attempt = %v", got)
	}
}

func TestBrightnessZeroShortWriteIsIndeterminateAndNeverRetried(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	transport := newDiagnosticTransport()
	transport.shortCommand = d200x.CommandBrightness
	transport.shortCommandOccurrence = 2
	queueInputPair(t, transport, 0, d200x.InputMarkerButton)
	factory := &diagnosticFactory{transport: transport}
	runner, err := New(Options{
		Mode:         ModeBrightnessZero,
		ConfigPath:   configurationPath,
		Confirm:      true,
		Factory:      factory,
		Reader:       io.NopCloser(strings.NewReader("\n")),
		StageTimeout: time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := runner.Run(context.Background())
	if err == nil || result.Status != StatusIndeterminate {
		t.Fatalf("Run result = %s, error = %v; want indeterminate failure", result.Status, err)
	}
	commands, err := diagnosticCommands(transport.writesSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	if got := countCommand(commands, d200x.CommandBrightness); got != 2 {
		t.Fatalf("brightness command attempts = %d, want startup and one zero attempt", got)
	}
	if transport.closeCountValue() != 1 {
		t.Fatalf("close count = %d, want 1", transport.closeCountValue())
	}
}

func TestWakeCandidateFailedWriteIsIndeterminateAndNeverRetried(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	transport := newDiagnosticTransport()
	transport.quietReadCount = 1
	transport.failCommand = d200x.CommandUnlockScreen
	transport.failCommandOccurrence = 2
	factory := &diagnosticFactory{transport: transport}
	runner, err := New(Options{
		Mode:          ModeFirmwareWake,
		ConfigPath:    configurationPath,
		WakeCandidate: WakeUnlock,
		Confirm:       true,
		Factory:       factory,
		Reader:        io.NopCloser(strings.NewReader("sleep\n\n")),
		StageTimeout:  10 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := runner.Run(context.Background())
	if err == nil || result.Status != StatusIndeterminate {
		t.Fatalf("Run result = %s, error = %v; want indeterminate failure", result.Status, err)
	}
	commands, err := diagnosticCommands(transport.writesSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	if got := countCommand(commands, d200x.CommandUnlockScreen); got != 2 {
		t.Fatalf("unlock command attempts = %d, want startup and one candidate attempt", got)
	}
	if transport.closeCountValue() != 1 {
		t.Fatalf("close count = %d, want 1", transport.closeCountValue())
	}
}

func TestBrightnessZeroCancelledWriteIsIndeterminateAndNeverRetried(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	transport := newDiagnosticTransport()
	transport.cancelCommand = d200x.CommandBrightness
	transport.cancelCommandOccurrence = 2
	transport.cancelCommandStarted = make(chan struct{})
	queueInputPair(t, transport, 0, d200x.InputMarkerButton)
	factory := &diagnosticFactory{transport: transport}
	runner, err := New(Options{
		Mode:         ModeBrightnessZero,
		ConfigPath:   configurationPath,
		Confirm:      true,
		Factory:      factory,
		Reader:       io.NopCloser(strings.NewReader("\n")),
		StageTimeout: 10 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	type runResult struct {
		result Result
		err    error
	}
	runDone := make(chan runResult, 1)
	go func() {
		result, err := runner.Run(context.Background())
		runDone <- runResult{result: result, err: err}
	}()
	select {
	case <-transport.cancelCommandStarted:
	case <-time.After(2 * time.Second):
		t.Fatal("canceled brightness write did not start")
	}
	var run runResult
	select {
	case run = <-runDone:
	case <-time.After(2 * time.Second):
		t.Fatal("diagnostic did not stop after canceled brightness write")
	}
	result, err := run.result, run.err
	if err == nil || result.Status != StatusIndeterminate {
		t.Fatalf("Run result = %s, error = %v; want indeterminate failure", result.Status, err)
	}
	commands, err := diagnosticCommands(transport.writesSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	if got := countCommand(commands, d200x.CommandBrightness); got != 2 {
		t.Fatalf("brightness command attempts = %d, want startup and one canceled zero attempt", got)
	}
	if transport.closeCountValue() != 1 {
		t.Fatalf("close count = %d, want 1", transport.closeCountValue())
	}
}

func TestDiagnosticLineReadCancellationClosesBlockingReader(t *testing.T) {
	for _, test := range []struct {
		name string
		read func(*Runner, context.Context) (string, error)
	}{
		{name: "normal", read: (*Runner).readLine},
		{name: "strict", read: (*Runner).readLineStrict},
	} {
		t.Run(test.name, func(t *testing.T) {
			reader := newBlockingLineReader()
			runner := &Runner{
				reader:       bufio.NewReader(reader),
				readerCloser: reader,
			}
			ctx, cancel := context.WithCancel(context.Background())
			result := make(chan error, 1)
			go func() {
				_, err := test.read(runner, ctx)
				result <- err
			}()
			select {
			case <-reader.started:
			case <-time.After(2 * time.Second):
				t.Fatal("line read did not start")
			}
			cancel()
			select {
			case err := <-result:
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("line read error = %v, want cancellation", err)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("canceled line read did not return")
			}
			select {
			case <-reader.done:
			case <-time.After(2 * time.Second):
				t.Fatal("canceled line reader goroutine remained blocked")
			}
			if got := reader.closeCountValue(); got != 1 {
				t.Fatalf("reader close count = %d, want 1", got)
			}
		})
	}
}

func TestDiagnosticLineReadDeadlineAndCancellationJoinCloseExactlyOnce(t *testing.T) {
	tests := []struct {
		name       string
		wantErr    error
		triggerErr error
	}{
		{name: "cancellation", wantErr: context.Canceled, triggerErr: context.Canceled},
		{name: "deadline", wantErr: context.DeadlineExceeded, triggerErr: context.DeadlineExceeded},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reader := newBlockingLineReader()
			runner := &Runner{
				reader:       bufio.NewReader(reader),
				readerCloser: reader,
			}
			ctx := newSignaledDiagnosticContext()
			readDone := make(chan error, 1)
			go func() {
				_, err := runner.readLine(ctx)
				readDone <- err
			}()
			select {
			case <-reader.started:
			case <-time.After(2 * time.Second):
				t.Fatal("line read did not start")
			}
			ctx.signal(test.triggerErr)
			select {
			case err := <-readDone:
				if !errors.Is(err, test.wantErr) {
					t.Fatalf("line read error = %v, want %v", err, test.wantErr)
				}
			case <-time.After(2 * time.Second):
				t.Fatal("interrupted line read did not return")
			}
			select {
			case <-reader.done:
			default:
				t.Fatal("line read returned before the underlying read completed")
			}
			if got := reader.closeCountValue(); got != 1 {
				t.Fatalf("reader close count = %d, want 1", got)
			}
			runner.closeReader()
			runner.closeReader()
			if got := reader.closeCountValue(); got != 1 {
				t.Fatalf("reader close count after repeated close = %d, want 1", got)
			}
		})
	}
}

func TestDiagnosticLineReadPartialEOFModes(t *testing.T) {
	tests := []struct {
		name     string
		read     func(*Runner, context.Context) (string, error)
		wantLine string
		wantErr  error
	}{
		{name: "normal partial EOF", read: (*Runner).readLine, wantLine: "partial"},
		{name: "strict partial EOF", read: (*Runner).readLineStrict, wantLine: "partial", wantErr: io.EOF},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reader := io.NopCloser(strings.NewReader("partial"))
			runner := &Runner{reader: bufio.NewReader(reader), readerCloser: reader}
			line, err := test.read(runner, context.Background())
			if line != test.wantLine {
				t.Fatalf("line = %q, want %q", line, test.wantLine)
			}
			if !errors.Is(err, test.wantErr) {
				t.Fatalf("error = %v, want %v", err, test.wantErr)
			}
			runner.closeReader()
		})
	}
}

func TestDiagnosticNewNilReaderUsesEOFAndOwnedClose(t *testing.T) {
	runner, err := New(Options{
		Mode:       ModeBrightnessZero,
		ConfigPath: "/private/fake-diagnostic.toml",
	})
	if err != nil {
		t.Fatal(err)
	}
	if runner.readerCloser == nil {
		t.Fatal("nil Reader did not receive an owned closeable reader")
	}
	line, err := runner.readLine(context.Background())
	if line != "" || !errors.Is(err, io.EOF) {
		t.Fatalf("nil Reader line/error = %q/%v, want empty/EOF", line, err)
	}
	runner.closeReader()
}

func TestDiagnosticRunClosesOwnedReaderOnEveryExit(t *testing.T) {
	tests := []struct {
		name       string
		input      string
		configure  func(*testing.T, *countingReadCloser) Options
		cancelled  bool
		wantStatus Status
		wantErr    bool
	}{
		{
			name: "already canceled",
			configure: func(t *testing.T, reader *countingReadCloser) Options {
				t.Helper()
				return Options{
					Mode:       ModeBrightnessZero,
					ConfigPath: writeDiagnosticConfiguration(t, 73),
					Confirm:    true,
					Factory:    &diagnosticFactory{transport: newDiagnosticTransport()},
					Reader:     reader,
				}
			},
			cancelled:  true,
			wantStatus: StatusIndeterminate,
			wantErr:    true,
		},
		{
			name: "confirmation refusal",
			configure: func(t *testing.T, reader *countingReadCloser) Options {
				t.Helper()
				return Options{
					Mode:       ModeBrightnessZero,
					ConfigPath: writeDiagnosticConfiguration(t, 73),
					Factory:    &diagnosticFactory{transport: newDiagnosticTransport()},
					Reader:     reader,
				}
			},
			wantStatus: StatusPartial,
			wantErr:    true,
		},
		{
			name: "invalid configuration",
			configure: func(t *testing.T, reader *countingReadCloser) Options {
				t.Helper()
				path := filepath.Join(t.TempDir(), "invalid-config.toml")
				if err := os.WriteFile(path, []byte("schema_version = 3\n"), 0o600); err != nil {
					t.Fatal(err)
				}
				return Options{
					Mode:       ModeBrightnessZero,
					ConfigPath: path,
					Confirm:    true,
					Factory:    &diagnosticFactory{transport: newDiagnosticTransport()},
					Reader:     reader,
				}
			},
			wantStatus: StatusFail,
			wantErr:    true,
		},
		{
			name: "enumeration failure",
			configure: func(t *testing.T, reader *countingReadCloser) Options {
				t.Helper()
				return Options{
					Mode:       ModeBrightnessZero,
					ConfigPath: writeDiagnosticConfiguration(t, 73),
					Confirm:    true,
					Factory: &diagnosticFactory{
						transport:    newDiagnosticTransport(),
						enumerateErr: errors.New("enumeration failed"),
					},
					Reader: reader,
				}
			},
			wantStatus: StatusFail,
			wantErr:    true,
		},
		{
			name: "selection failure",
			configure: func(t *testing.T, reader *countingReadCloser) Options {
				t.Helper()
				return Options{
					Mode:       ModeBrightnessZero,
					ConfigPath: writeDiagnosticConfiguration(t, 73),
					Confirm:    true,
					Factory: &diagnosticFactory{
						transport:  newDiagnosticTransport(),
						candidates: []d200x.Candidate{},
					},
					Reader: reader,
				}
			},
			wantStatus: StatusFail,
			wantErr:    true,
		},
		{
			name: "session open failure",
			configure: func(t *testing.T, reader *countingReadCloser) Options {
				t.Helper()
				return Options{
					Mode:       ModeBrightnessZero,
					ConfigPath: writeDiagnosticConfiguration(t, 73),
					Confirm:    true,
					Factory: &diagnosticFactory{
						transport: newDiagnosticTransport(),
						openErr:   errors.New("open failed"),
					},
					Reader: reader,
				}
			},
			wantStatus: StatusFail,
			wantErr:    true,
		},
		{
			name:  "ordinary success",
			input: "sleep\n\nunchanged\n\n\n\n",
			configure: func(t *testing.T, reader *countingReadCloser) Options {
				t.Helper()
				transport := newDiagnosticTransport()
				transport.quietReadCount = 1
				queueInputPair(t, transport, 0, d200x.InputMarkerButton)
				queueInputEvent(t, transport, 15, d200x.InputMarkerButton, d200x.InputActionPressed)
				queueInputEvent(t, transport, 15, d200x.InputMarkerButton, d200x.InputActionReleased)
				queueInputEvent(t, transport, 17, d200x.InputMarkerEncoder, d200x.InputActionRotatedRight)
				return Options{
					Mode:          ModeFirmwareWake,
					ConfigPath:    writeDiagnosticConfiguration(t, 73),
					WakeCandidate: WakeInputEnable,
					Confirm:       true,
					Factory:       &diagnosticFactory{transport: transport},
					Reader:        reader,
					StageTimeout:  10 * time.Millisecond,
				}
			},
			wantStatus: StatusPass,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reader := newCountingReadCloser(test.input)
			options := test.configure(t, reader)
			runner, err := New(options)
			if err != nil {
				t.Fatal(err)
			}
			ctx := context.Background()
			if test.cancelled {
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				cancel()
			}
			result, runErr := runner.Run(ctx)
			if result.Status != test.wantStatus {
				t.Fatalf("result status = %s, want %s", result.Status, test.wantStatus)
			}
			if (runErr != nil) != test.wantErr {
				t.Fatalf("Run error = %v, want error=%t", runErr, test.wantErr)
			}
			if got := reader.closeCountValue(); got != 1 {
				t.Fatalf("reader close count = %d, want exactly one", got)
			}
		})
	}
}

func TestDiagnosticRunClosesReaderAfterLaterCancellationOrDeadline(t *testing.T) {
	for _, test := range []struct {
		name       string
		triggerErr error
	}{
		{name: "cancellation", triggerErr: context.Canceled},
		{name: "deadline", triggerErr: context.DeadlineExceeded},
	} {
		t.Run(test.name, func(t *testing.T) {
			reader := newBlockingLineReader()
			factory := &diagnosticFactory{transport: newDiagnosticTransport()}
			runner, err := New(Options{
				Mode:          ModeFirmwareWake,
				ConfigPath:    writeDiagnosticConfiguration(t, 73),
				WakeCandidate: WakeInputEnable,
				Confirm:       true,
				Factory:       factory,
				Reader:        reader,
				StageTimeout:  time.Second,
			})
			if err != nil {
				t.Fatal(err)
			}
			ctx := newSignaledDiagnosticContext()
			runDone := make(chan error, 1)
			go func() {
				_, runErr := runner.Run(ctx)
				runDone <- runErr
			}()
			select {
			case <-reader.started:
			case <-time.After(2 * time.Second):
				t.Fatal("later diagnostic read did not start")
			}
			ctx.signal(test.triggerErr)
			select {
			case runErr := <-runDone:
				if runErr == nil {
					t.Fatal("later diagnostic cancellation returned nil")
				}
			case <-time.After(2 * time.Second):
				t.Fatal("later diagnostic cancellation did not return")
			}
			select {
			case <-reader.done:
			default:
				t.Fatal("Run returned before the later read completed")
			}
			if got := reader.closeCountValue(); got != 1 {
				t.Fatalf("reader close count = %d, want exactly one", got)
			}
		})
	}
}

func TestDiagnosticBuildPlanUsesConfiguredDefaultProfileWhenNotFirst(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	plan, err := buildPlan(configurationPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(plan.page.Positions) == 0 {
		t.Fatal("configured default page has no positions")
	}
	if plan.page.Positions[0].ID != "0_0" || plan.page.Positions[0].Label != "Default tile 0" {
		t.Fatalf("diagnostic default first position = %#v, want configured default profile", plan.page.Positions[0])
	}
}

func TestBrightnessZeroFailedZeroAndRestoreOutcomesNeverRetry(t *testing.T) {
	tests := []struct {
		name          string
		wantAttempts  int
		configureFail func(*diagnosticTransport)
	}{
		{
			name:         "zero-failed",
			wantAttempts: 2,
			configureFail: func(transport *diagnosticTransport) {
				transport.failCommand = d200x.CommandBrightness
				transport.failCommandOccurrence = 2
			},
		},
		{
			name:         "restore-short",
			wantAttempts: 3,
			configureFail: func(transport *diagnosticTransport) {
				transport.shortCommand = d200x.CommandBrightness
				transport.shortCommandOccurrence = 3
			},
		},
		{
			name:         "restore-canceled",
			wantAttempts: 3,
			configureFail: func(transport *diagnosticTransport) {
				transport.cancelCommand = d200x.CommandBrightness
				transport.cancelCommandOccurrence = 3
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			configurationPath := writeDiagnosticConfiguration(t, 73)
			transport := newDiagnosticTransport()
			test.configureFail(transport)
			queueInputPair(t, transport, 0, d200x.InputMarkerButton)
			runner, err := New(Options{
				Mode:         ModeBrightnessZero,
				ConfigPath:   configurationPath,
				Confirm:      true,
				Factory:      &diagnosticFactory{transport: transport},
				Reader:       io.NopCloser(strings.NewReader("\n")),
				StageTimeout: 10 * time.Millisecond,
			})
			if err != nil {
				t.Fatal(err)
			}
			result, err := runner.Run(context.Background())
			if err == nil || result.Status != StatusIndeterminate {
				t.Fatalf("Run result = %s, error = %v; want indeterminate", result.Status, err)
			}
			commands, decodeErr := diagnosticCommands(transport.writesSnapshot())
			if decodeErr != nil {
				t.Fatal(decodeErr)
			}
			if got := countCommand(commands, d200x.CommandBrightness); got != test.wantAttempts {
				t.Fatalf("brightness attempts = %d, want %d", got, test.wantAttempts)
			}
		})
	}
}

func TestBrightnessZeroObservationFailureStillRestoresExactlyOnce(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	transport := newDiagnosticTransport()
	queueInputPair(t, transport, 0, d200x.InputMarkerButton)
	factory := &diagnosticFactory{transport: transport}
	writer := &stageFailingWriter{stage: "brightness-zero-write"}
	runner, err := New(Options{
		Mode:              ModeBrightnessZero,
		ConfigPath:        configurationPath,
		Confirm:           true,
		Factory:           factory,
		Reader:            io.NopCloser(strings.NewReader("\n")),
		ObservationWriter: writer,
		StageTimeout:      10 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := runner.Run(context.Background())
	if err == nil || result.Status != StatusIndeterminate {
		t.Fatalf("Run result = %s, error = %v; want indeterminate observation failure", result.Status, err)
	}
	commands, err := diagnosticCommands(transport.writesSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	if got := countCommand(commands, d200x.CommandBrightness); got != 3 {
		t.Fatalf("brightness command attempts = %d, want startup, zero, and one restore", got)
	}
	if transport.closeCountValue() != 1 {
		t.Fatalf("close count = %d, want 1", transport.closeCountValue())
	}
}

func TestBrightnessZeroObservationAndRestoreFailuresRemainRepresented(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	transport := newDiagnosticTransport()
	transport.failCommand = d200x.CommandBrightness
	transport.failCommandOccurrence = 3
	queueInputPair(t, transport, 0, d200x.InputMarkerButton)
	factory := &diagnosticFactory{transport: transport}
	writer := &stageFailingWriter{stage: "brightness-zero-write"}
	runner, err := New(Options{
		Mode:              ModeBrightnessZero,
		ConfigPath:        configurationPath,
		Confirm:           true,
		Factory:           factory,
		Reader:            io.NopCloser(strings.NewReader("\n")),
		ObservationWriter: writer,
		StageTimeout:      10 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	result, err := runner.Run(context.Background())
	if err == nil || result.Status != StatusIndeterminate {
		t.Fatalf("Run result = %s, error = %v; want indeterminate restore failure", result.Status, err)
	}
	if !strings.Contains(err.Error(), "write diagnostic observation failed") {
		t.Fatalf("error = %q, missing original observation failure", err)
	}
	if !strings.Contains(err.Error(), "restore configured brightness failed") {
		t.Fatalf("error = %q, missing restore failure", err)
	}
	commands, err := diagnosticCommands(transport.writesSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	if got := countCommand(commands, d200x.CommandBrightness); got != 3 {
		t.Fatalf("brightness command attempts = %d, want startup, zero, and one restore", got)
	}
	if transport.closeCountValue() != 1 {
		t.Fatalf("close count = %d, want 1", transport.closeCountValue())
	}
}

func TestFirmwareWakeCompletePageUploadFailuresDoNotRetryMultiReportCandidate(t *testing.T) {
	tests := []struct {
		name string
		set  func(*diagnosticTransport, int)
	}{
		{
			name: "failed",
			set: func(transport *diagnosticTransport, occurrence int) {
				transport.failWriteOccurrence = occurrence
			},
		},
		{
			name: "short",
			set: func(transport *diagnosticTransport, occurrence int) {
				transport.shortWriteOccurrence = occurrence
			},
		},
		{
			name: "canceled",
			set: func(transport *diagnosticTransport, occurrence int) {
				transport.cancelWriteOccurrence = occurrence
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			configurationPath := writeDiagnosticConfiguration(t, 73)
			plan, err := buildPlan(configurationPath)
			if err != nil {
				t.Fatal(err)
			}
			pageReports, err := d200x.EncodeFrame(plan.pageFrame)
			if err != nil {
				t.Fatal(err)
			}
			if len(pageReports) < 2 {
				t.Fatalf("configured page upload uses %d report(s), want a multi-report frame", len(pageReports))
			}
			transport := newDiagnosticTransport()
			test.set(transport, len(pageReports)+5)
			factory := &diagnosticFactory{transport: transport}
			runner, err := New(Options{
				Mode:          ModeFirmwareWake,
				ConfigPath:    configurationPath,
				WakeCandidate: WakeCompletePageUpload,
				Confirm:       true,
				Factory:       factory,
				Reader:        io.NopCloser(strings.NewReader("sleep\n\n")),
				StageTimeout:  10 * time.Millisecond,
			})
			if err != nil {
				t.Fatal(err)
			}
			result, err := runner.Run(context.Background())
			if err == nil || result.Status != StatusIndeterminate {
				t.Fatalf("Run result = %s, error = %v; want indeterminate candidate failure", result.Status, err)
			}
			writes := transport.writesSnapshot()
			commands := reportCommands(writes)
			if got := countCommand(commands, d200x.CommandCompleteDisplayUpload); got != 2 {
				t.Fatalf("complete-page-upload frame attempts = %d, want startup and one candidate frame", got)
			}
			if got := len(writes); got != len(pageReports)+5 {
				t.Fatalf("total report attempts = %d, want startup reports, three startup primitives, and two candidate reports", got)
			}
			if transport.closeCountValue() != 1 {
				t.Fatalf("close count = %d, want 1", transport.closeCountValue())
			}
		})
	}
}

func TestDiagnosticErrorsAreRedactedAndConfigValidationPrecedesEnumeration(t *testing.T) {
	configurationPath := writeDiagnosticConfiguration(t, 73)
	factory := &diagnosticFactory{transport: newDiagnosticTransport(), enumerateErr: errors.New("hidraw=/private/serial-secret")}
	var observations bytes.Buffer
	runner, err := New(Options{
		Mode:              ModeFirmwareWake,
		ConfigPath:        configurationPath,
		WakeCandidate:     WakeBrightness,
		Confirm:           true,
		Factory:           factory,
		ObservationWriter: &observations,
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = runner.Run(context.Background())
	if err == nil || strings.Contains(err.Error(), "serial-secret") || strings.Contains(err.Error(), configurationPath) {
		t.Fatalf("unsanitized diagnostic error = %v", err)
	}
	if got := factory.calls(); fmt.Sprint(got) != "[enumerate]" {
		t.Fatalf("HID calls after redacted enumeration error = %v", got)
	}
	if strings.Contains(observations.String(), "serial-secret") || strings.Contains(observations.String(), configurationPath) {
		t.Fatalf("observation leaked private identity: %q", observations.String())
	}

	invalidPath := filepath.Join(t.TempDir(), "invalid-config.toml")
	if err := os.WriteFile(invalidPath, []byte("schema_version = 3\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	invalidFactory := &diagnosticFactory{transport: newDiagnosticTransport()}
	invalidRunner, err := New(Options{
		Mode:       ModeBrightnessZero,
		ConfigPath: invalidPath,
		Confirm:    true,
		Factory:    invalidFactory,
		Reader:     io.NopCloser(strings.NewReader("")),
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := invalidRunner.Run(context.Background()); err == nil {
		t.Fatal("invalid configuration was accepted")
	}
	if got := invalidFactory.calls(); len(got) != 0 {
		t.Fatalf("HID calls after invalid config = %v", got)
	}
}

func writeDiagnosticConfiguration(t *testing.T, brightness int) string {
	t.Helper()
	var builder strings.Builder
	fmt.Fprintf(&builder, "schema_version = 4\nadapter = \"ulanzi.d200x\"\nbrightness = %d\ndefault_profile_id = \"default\"\n\n", brightness)
	for _, profileID := range []string{"alternate", "default"} {
		fmt.Fprintf(&builder, "[profiles.%q]\nlabel = \"%s\"\n\n", profileID, profileID)
		profileLabel := "Default"
		if profileID == "alternate" {
			profileLabel = "Alternate"
		}
		for index, spec := range d200x.SupportedPositions() {
			fmt.Fprintf(&builder, "[profiles.%q.positions.%q]\nlabel = \"%s tile %d\"\nbackground = \"#102030\"\n\n", profileID, spec.Name, profileLabel, index)
		}
	}
	path := filepath.Join(t.TempDir(), "diagnostic.toml")
	if err := os.WriteFile(path, []byte(builder.String()), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

type blockingLineReader struct {
	started      chan struct{}
	done         chan struct{}
	release      chan struct{}
	closeOnce    sync.Once
	startOnce    sync.Once
	closeCountMu sync.Mutex
	closeCount   int
}

type countingReadCloser struct {
	mu         sync.Mutex
	reader     *strings.Reader
	closeCount int
}

func newCountingReadCloser(input string) *countingReadCloser {
	return &countingReadCloser{reader: strings.NewReader(input)}
}

func (reader *countingReadCloser) Read(buffer []byte) (int, error) {
	reader.mu.Lock()
	defer reader.mu.Unlock()
	return reader.reader.Read(buffer)
}

func (reader *countingReadCloser) Close() error {
	reader.mu.Lock()
	defer reader.mu.Unlock()
	reader.closeCount++
	return nil
}

func (reader *countingReadCloser) closeCountValue() int {
	reader.mu.Lock()
	defer reader.mu.Unlock()
	return reader.closeCount
}

func newBlockingLineReader() *blockingLineReader {
	return &blockingLineReader{
		started: make(chan struct{}),
		done:    make(chan struct{}),
		release: make(chan struct{}),
	}
}

func (reader *blockingLineReader) Read([]byte) (int, error) {
	reader.startOnce.Do(func() { close(reader.started) })
	defer close(reader.done)
	<-reader.release
	return 0, io.ErrClosedPipe
}

func (reader *blockingLineReader) Close() error {
	reader.closeCountMu.Lock()
	reader.closeCount++
	reader.closeCountMu.Unlock()
	reader.closeOnce.Do(func() { close(reader.release) })
	return nil
}

func (reader *blockingLineReader) closeCountValue() int {
	reader.closeCountMu.Lock()
	defer reader.closeCountMu.Unlock()
	return reader.closeCount
}

type signaledDiagnosticContext struct {
	context.Context
	done       chan struct{}
	errMu      sync.Mutex
	err        error
	signalOnce sync.Once
}

func newSignaledDiagnosticContext() *signaledDiagnosticContext {
	return &signaledDiagnosticContext{
		Context: context.Background(),
		done:    make(chan struct{}),
	}
}

func (ctx *signaledDiagnosticContext) Deadline() (time.Time, bool) {
	return time.Time{}, true
}

func (ctx *signaledDiagnosticContext) Done() <-chan struct{} {
	return ctx.done
}

func (ctx *signaledDiagnosticContext) Err() error {
	ctx.errMu.Lock()
	defer ctx.errMu.Unlock()
	return ctx.err
}

func (ctx *signaledDiagnosticContext) signal(err error) {
	ctx.errMu.Lock()
	ctx.err = err
	ctx.errMu.Unlock()
	ctx.signalOnce.Do(func() { close(ctx.done) })
}

func queueInputEvent(t *testing.T, transport *diagnosticTransport, wireIndex byte, marker d200x.InputMarker, action d200x.InputAction) {
	t.Helper()
	reports, err := d200x.EncodeFrame(d200x.NewFrame(d200x.CommandInputEvent, []byte{1, wireIndex, byte(marker), byte(action)}))
	if err != nil {
		t.Fatal(err)
	}
	transport.mu.Lock()
	transport.reads = append(transport.reads, reports...)
	transport.mu.Unlock()
	select {
	case transport.readNotify <- struct{}{}:
	default:
	}
}

func queueInputPair(t *testing.T, transport *diagnosticTransport, wireIndex byte, marker d200x.InputMarker) {
	t.Helper()
	queueInputEvent(t, transport, wireIndex, marker, d200x.InputActionPressed)
	queueInputEvent(t, transport, wireIndex, marker, d200x.InputActionReleased)
}

func queueBrightnessProbeEvents(t *testing.T, transport *diagnosticTransport) {
	queueInputPair(t, transport, 13, d200x.InputMarkerButton)
	queueInputPair(t, transport, 15, d200x.InputMarkerButton)
	queueInputPair(t, transport, 16, d200x.InputMarkerButton)
	queueInputPair(t, transport, 0, d200x.InputMarkerButton)
	queueInputEvent(t, transport, 18, d200x.InputMarkerEncoder, d200x.InputActionRotatedRight)
}

type completionReader struct {
	transport *diagnosticTransport
	target    int
	line      string
	used      bool
	reads     int
}

type promptAfterCaptureWriter struct {
	ready  <-chan struct{}
	writer io.Writer
}

func (writer *promptAfterCaptureWriter) Write(buffer []byte) (int, error) {
	select {
	case <-writer.ready:
	case <-time.After(time.Second):
		return 0, errors.New("timed out waiting for stale capture")
	}
	return writer.writer.Write(buffer)
}

func (reader *completionReader) Read(buffer []byte) (int, error) {
	reader.reads++
	if reader.used {
		return 0, io.EOF
	}
	reader.used = true
	reader.transport.waitForReads(reader.target)
	line := reader.line
	if line == "" {
		line = string(Brightness100Observed) + "\n"
	}
	return copy(buffer, line), nil
}

func (reader *completionReader) Close() error {
	return nil
}

func matrixStages(observations []Observation, wanted []string) []string {
	wantedSet := make(map[string]struct{}, len(wanted))
	for _, stage := range wanted {
		wantedSet[stage] = struct{}{}
	}
	got := make([]string, 0, len(wanted))
	for _, observation := range observations {
		if _, ok := wantedSet[observation.Stage]; ok {
			got = append(got, observation.Stage)
		}
	}
	return got
}

type diagnosticFactory struct {
	mu           sync.Mutex
	transport    *diagnosticTransport
	enumerateErr error
	openErr      error
	candidates   []d200x.Candidate
	opened       bool
	called       []string
}

func (factory *diagnosticFactory) Enumerate(context.Context) ([]d200x.Candidate, error) {
	factory.mu.Lock()
	factory.called = append(factory.called, "enumerate")
	factory.mu.Unlock()
	if factory.enumerateErr != nil {
		return nil, factory.enumerateErr
	}
	if factory.candidates != nil {
		return append([]d200x.Candidate(nil), factory.candidates...), nil
	}
	return []d200x.Candidate{d200x.NewCandidate("/private/fake-d200x", d200x.VendorID, d200x.ProductID, d200x.InterfaceNumber)}, nil
}

func (factory *diagnosticFactory) Open(context.Context, d200x.Candidate) (d200x.Transport, error) {
	factory.mu.Lock()
	factory.called = append(factory.called, "open")
	factory.opened = true
	transport := factory.transport
	openErr := factory.openErr
	factory.mu.Unlock()
	if openErr != nil {
		return nil, openErr
	}
	return transport, nil
}

func (factory *diagnosticFactory) calls() []string {
	factory.mu.Lock()
	defer factory.mu.Unlock()
	return append([]string(nil), factory.called...)
}

type diagnosticTransport struct {
	mu                      sync.Mutex
	writes                  [][]byte
	reads                   [][]byte
	readNotify              chan struct{}
	readProgress            chan struct{}
	readsReturned           int
	quietReadCount          int
	closeCount              int
	writeOccurrences        int
	commandOccurrences      map[d200x.Command]int
	failCommand             d200x.Command
	failCommandOccurrence   int
	shortCommand            d200x.Command
	shortCommandOccurrence  int
	cancelCommand           d200x.Command
	cancelCommandOccurrence int
	cancelCommandStarted    chan struct{}
	cancelCommandOnce       sync.Once
	failWriteOccurrence     int
	shortWriteOccurrence    int
	cancelWriteOccurrence   int
	postRecoveryReadAfter   int
	postRecoveryReport      []byte
	postRecoveryInjected    bool
}

func newDiagnosticTransport() *diagnosticTransport {
	return &diagnosticTransport{
		commandOccurrences: make(map[d200x.Command]int),
		readNotify:         make(chan struct{}, 1),
		readProgress:       make(chan struct{}, 1),
	}
}

func (transport *diagnosticTransport) Read(ctx context.Context, report []byte) (int, error) {
	for {
		transport.mu.Lock()
		if transport.postRecoveryReadAfter > 0 &&
			transport.readsReturned >= transport.postRecoveryReadAfter &&
			!transport.postRecoveryInjected && len(transport.reads) == 0 {
			lateReport := append([]byte(nil), transport.postRecoveryReport...)
			transport.postRecoveryInjected = true
			transport.mu.Unlock()
			<-ctx.Done()
			if len(lateReport) > len(report) {
				return 0, io.ErrShortBuffer
			}
			return copy(report, lateReport), nil
		}
		if transport.quietReadCount > 0 {
			transport.quietReadCount--
			transport.mu.Unlock()
			<-ctx.Done()
			return 0, ctx.Err()
		}
		if len(transport.reads) > 0 {
			queued := transport.reads[0]
			transport.reads = transport.reads[1:]
			transport.readsReturned++
			transport.mu.Unlock()
			select {
			case transport.readProgress <- struct{}{}:
			default:
			}
			if len(queued) > len(report) {
				return 0, io.ErrShortBuffer
			}
			return copy(report, queued), nil
		}
		transport.mu.Unlock()
		select {
		case <-ctx.Done():
			return 0, ctx.Err()
		case <-transport.readNotify:
		}
	}
}

func (transport *diagnosticTransport) waitForReads(count int) {
	for {
		transport.mu.Lock()
		complete := transport.readsReturned >= count
		transport.mu.Unlock()
		if complete {
			return
		}
		<-transport.readProgress
	}
}

func (transport *diagnosticTransport) Write(ctx context.Context, report []byte) (int, error) {
	transport.mu.Lock()
	transport.writes = append(transport.writes, append([]byte(nil), report...))
	transport.writeOccurrences++
	writeOccurrence := transport.writeOccurrences
	command := reportCommand(report)
	if writeOccurrence == transport.failWriteOccurrence {
		transport.mu.Unlock()
		return 0, errors.New("hidraw=/private/serial-secret")
	}
	if writeOccurrence == transport.cancelWriteOccurrence {
		transport.mu.Unlock()
		return 0, context.Canceled
	}
	if writeOccurrence == transport.shortWriteOccurrence {
		transport.mu.Unlock()
		return len(report) - 1, nil
	}
	if command != 0 {
		transport.commandOccurrences[command]++
		occurrence := transport.commandOccurrences[command]
		if command == transport.failCommand && occurrence == transport.failCommandOccurrence {
			transport.mu.Unlock()
			return 0, errors.New("hidraw=/private/serial-secret")
		}
		if command == transport.cancelCommand && occurrence == transport.cancelCommandOccurrence {
			cancelStarted := transport.cancelCommandStarted
			transport.mu.Unlock()
			if cancelStarted != nil {
				transport.cancelCommandOnce.Do(func() { close(cancelStarted) })
			}
			return 0, context.Canceled
		}
		if command == transport.shortCommand && occurrence == transport.shortCommandOccurrence {
			transport.mu.Unlock()
			return len(report) - 1, nil
		}
	}
	transport.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return 0, err
	}
	return len(report), nil
}

func (transport *diagnosticTransport) Close() error {
	transport.mu.Lock()
	transport.closeCount++
	transport.mu.Unlock()
	return nil
}

func (transport *diagnosticTransport) writesSnapshot() [][]byte {
	transport.mu.Lock()
	defer transport.mu.Unlock()
	writes := make([][]byte, len(transport.writes))
	for index := range transport.writes {
		writes[index] = append([]byte(nil), transport.writes[index]...)
	}
	return writes
}

func (transport *diagnosticTransport) closeCountValue() int {
	transport.mu.Lock()
	defer transport.mu.Unlock()
	return transport.closeCount
}

func (transport *diagnosticTransport) postRecoveryInjectedValue() bool {
	transport.mu.Lock()
	defer transport.mu.Unlock()
	return transport.postRecoveryInjected
}

func reportCommand(report []byte) d200x.Command {
	packet, err := d200x.NormalizeReport(report)
	if err != nil || len(packet) < d200x.FrameHeaderSize || packet[0] != 0x7c || packet[1] != 0x7c {
		return 0
	}
	return d200x.Command(binary.BigEndian.Uint16(packet[2:4]))
}

func diagnosticCommands(reports [][]byte) ([]d200x.Command, error) {
	frames, err := decodedCommandFrames(reports)
	if err != nil {
		return nil, err
	}
	commands := make([]d200x.Command, len(frames))
	for index, frame := range frames {
		commands[index] = frame.Command
	}
	return commands, nil
}

func decodedCommandFrames(reports [][]byte) ([]d200x.Frame, error) {
	frames := make([]d200x.Frame, 0)
	for offset := 0; offset < len(reports); {
		packet, err := d200x.NormalizeReport(reports[offset])
		if err != nil {
			return nil, err
		}
		declared := int(binary.LittleEndian.Uint32(packet[4:8]))
		packetCount := 1
		if declared > d200x.FirstPayloadCapacity {
			packetCount += (declared - d200x.FirstPayloadCapacity + d200x.ProtocolPacketSize - 1) / d200x.ProtocolPacketSize
		}
		if offset+packetCount > len(reports) {
			return nil, fmt.Errorf("frame extends beyond writes")
		}
		frame, err := d200x.DecodeFrame(reports[offset : offset+packetCount])
		if err != nil {
			return nil, err
		}
		frames = append(frames, frame)
		offset += packetCount
	}
	return frames, nil
}

func brightnessPayloads(reports [][]byte) ([][]byte, error) {
	frames, err := decodedCommandFrames(reports)
	if err != nil {
		return nil, err
	}
	payloads := make([][]byte, 0)
	for _, frame := range frames {
		if frame.Command == d200x.CommandBrightness {
			payloads = append(payloads, frame.PayloadCopy())
		}
	}
	return payloads, nil
}

func countCommand(commands []d200x.Command, want d200x.Command) int {
	count := 0
	for _, command := range commands {
		if command == want {
			count++
		}
	}
	return count
}

func reportCommands(reports [][]byte) []d200x.Command {
	commands := make([]d200x.Command, len(reports))
	for index, report := range reports {
		commands[index] = reportCommand(report)
	}
	return commands
}

type stageFailingWriter struct {
	stage  string
	failed bool
}

func (writer *stageFailingWriter) Write(data []byte) (int, error) {
	if !writer.failed && bytes.Contains(data, []byte(`"stage":"`+writer.stage+`"`)) {
		writer.failed = true
		return 0, errors.New("observation writer failed")
	}
	return len(data), nil
}

var _ d200x.TransportFactory = (*diagnosticFactory)(nil)
var _ d200x.Transport = (*diagnosticTransport)(nil)
