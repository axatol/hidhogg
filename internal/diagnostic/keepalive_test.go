package diagnostic

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/d200x"
)

func TestKeepaliveScheduleUsesAbsoluteBoundariesThroughDuration(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	wantDeadlines := []time.Time{
		start.Add(time.Second),
		start.Add(2 * time.Second),
		start.Add(3 * time.Second),
		start.Add(4 * time.Second),
	}
	clock := &scriptedKeepaliveClock{
		start: start,
		wakes: append([]time.Time(nil), wantDeadlines...),
	}
	transport := newDiagnosticTransport()
	reader := &finalPairReader{testing: t, transport: transport, expectedWrites: 4}
	runner, session := newKeepaliveTestRunner(t, transport, reader, clock, time.Second, 4*time.Second)

	if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
		t.Fatal(err)
	}

	if len(clock.deadlines) != len(wantDeadlines)+1 {
		t.Fatalf("wait count = %d, want %d", len(clock.deadlines), len(wantDeadlines)+1)
	}
	for index := range wantDeadlines {
		if !clock.deadlines[index].Equal(wantDeadlines[index]) {
			t.Fatalf("deadline %d = %s, want %s", index, clock.deadlines[index], wantDeadlines[index])
		}
	}
	commands, err := diagnosticCommands(transport.writesSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	if len(commands) != 4 {
		t.Fatalf("experimental writes = %d, want 4", len(commands))
	}
	for _, command := range commands {
		if command != d200x.CommandEnableInputStream {
			t.Fatalf("experimental command = %s, want %s", command, d200x.CommandEnableInputStream)
		}
	}
	if !hasKeepaliveObservation(runner.sink.snapshot(), keepaliveFinalStage, StatusPass, 4) {
		t.Fatalf("final observations = %+v", runner.sink.snapshot())
	}
}

func TestKeepaliveRunReusesOneNormalStartupSession(t *testing.T) {
	const scheduledBoundaries = 4

	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	clock := &scriptedKeepaliveClock{
		start: start,
		wakes: []time.Time{
			start.Add(time.Second),
			start.Add(2 * time.Second),
			start.Add(3 * time.Second),
			start.Add(4 * time.Second),
		},
	}
	transport := newDiagnosticTransport()
	reader := &finalPairReader{testing: t, transport: transport, expectedInputEnables: 5}
	factory := &diagnosticFactory{transport: transport}
	var observationOutput bytes.Buffer
	runner, err := New(Options{
		Mode:              ModeKeepalivePrevention,
		ConfigPath:        writeDiagnosticConfiguration(t, 73),
		Confirm:           true,
		Factory:           factory,
		Reader:            reader,
		StageTimeout:      time.Second,
		KeepaliveInterval: time.Second,
		KeepaliveDuration: 4 * time.Second,
		KeepaliveClock:    clock,
		EndpointCue:       testEndpointCue(clock, reader),
		ObservationWriter: &observationOutput,
	})
	if err != nil {
		t.Fatal(err)
	}

	result, err := runner.Run(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if result.Status != StatusPass {
		t.Fatalf("result status = %s, want %s", result.Status, StatusPass)
	}
	if got := factory.calls(); len(got) != 2 || got[0] != "enumerate" || got[1] != "open" {
		t.Fatalf("factory calls = %v, want one enumerate/open", got)
	}
	commands, err := diagnosticCommands(transport.writesSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	if got := countCommand(commands, d200x.CommandEnableInputStream); got != 5 {
		t.Fatalf("input-enable commands = %d, want one startup plus four scheduled", got)
	}
	if len(commands) < 4 {
		t.Fatalf("commands = %v", commands)
	}
	for _, command := range commands[len(commands)-4:] {
		if command != d200x.CommandEnableInputStream {
			t.Fatalf("post-startup command = %s, want only input-enable", command)
		}
	}

	lines := strings.Split(strings.TrimSpace(observationOutput.String()), "\n")
	if got, want := len(lines), scheduledBoundaries+9; got != want {
		t.Fatalf("observation count = %d, want %d; output=%q", got, want, observationOutput.String())
	}
	observations := make([]Observation, len(lines))
	for index, line := range lines {
		if err := json.Unmarshal([]byte(line), &observations[index]); err != nil {
			t.Fatalf("observation %d is invalid JSON: %v", index, err)
		}
		if observations[index].Mode != ModeKeepalivePrevention || observations[index].Status != StatusPass {
			t.Fatalf("observation %d = %+v, want keepalive-prevention/pass", index, observations[index])
		}
	}
	wantStages := []string{
		"normal-startup",
		keepaliveStartStage,
		keepaliveBoundaryStage,
		keepaliveBoundaryStage,
		keepaliveBoundaryStage,
		keepaliveBoundaryStage,
		keepaliveScheduleStage,
		keepaliveHealthStage,
		keepaliveCueStage,
		keepaliveInputStage,
		keepaliveInputStage,
		keepaliveFinalStage,
		keepaliveResultStage,
	}
	for index, wantStage := range wantStages {
		if observations[index].Stage != wantStage {
			t.Fatalf("observation %d stage = %q, want %q", index, observations[index].Stage, wantStage)
		}
	}
	for boundary := 1; boundary <= scheduledBoundaries; boundary++ {
		observation := observations[boundary+1]
		if observation.Event != "diagnostic" || observation.Command != d200x.CommandEnableInputStream.String() || observation.Boundary != uint64(boundary) {
			t.Fatalf("scheduled observation %d = %+v", boundary, observation)
		}
	}
	for _, index := range []int{scheduledBoundaries + 2, scheduledBoundaries + 3, scheduledBoundaries + 4, scheduledBoundaries + 7, scheduledBoundaries + 8} {
		if observations[index].Boundary != scheduledBoundaries {
			t.Fatalf("terminal observation %d boundary = %d, want %d", index, observations[index].Boundary, scheduledBoundaries)
		}
	}
	pressed := observations[scheduledBoundaries+5]
	released := observations[scheduledBoundaries+6]
	for index, observation := range []Observation{pressed, released} {
		if observation.Event != "input" || observation.InputClass != InputSquare || observation.WireIndex == nil || *observation.WireIndex != 0 || observation.Marker != "button" || !observation.Decoded || observation.Malformed || observation.Classification != keepaliveInputClass {
			t.Fatalf("final input observation %d = %+v", index, observation)
		}
	}
	if pressed.Action != "pressed" || released.Action != "released" {
		t.Fatalf("final actions = %q/%q, want pressed/released", pressed.Action, released.Action)
	}
	if released.Sequence != pressed.Sequence+1 || pressed.Boundary != pressed.Sequence || released.Boundary != released.Sequence {
		t.Fatalf("final input sequence/boundaries = %d/%d and %d/%d", pressed.Sequence, pressed.Boundary, released.Sequence, released.Boundary)
	}
	healthObservation := observations[scheduledBoundaries+3]
	if healthObservation.Classification != string(captureHealthy) {
		t.Fatalf("capture health observation = %+v", healthObservation)
	}
	cueObservation := observations[scheduledBoundaries+4]
	if cueObservation.CueStartElapsedNS != int64(4*time.Second) || cueObservation.CueCompletionElapsedNS != int64(4500*time.Millisecond) || cueObservation.CueDurationNS != int64(500*time.Millisecond) {
		t.Fatalf("cue timing = %+v", cueObservation)
	}
	endpointObservation := observations[scheduledBoundaries+7]
	if endpointObservation.Attestation != EndpointActiveAtCue || endpointObservation.WindowStartElapsedNS != int64(4*time.Second) || endpointObservation.PlannedCloseElapsedNS != int64(9500*time.Millisecond) || endpointObservation.ActualTimerWakeNS != int64(9500*time.Millisecond) || endpointObservation.ActualCaptureStopNS != int64(9500*time.Millisecond) || endpointObservation.WindowDurationNS != int64(5500*time.Millisecond) {
		t.Fatalf("endpoint observation = %+v", endpointObservation)
	}
	if pressed.InputElapsedNS <= cueObservation.CueStartElapsedNS || pressed.InputElapsedNS > endpointObservation.PlannedCloseElapsedNS || released.InputElapsedNS > endpointObservation.PlannedCloseElapsedNS {
		t.Fatalf("input elapsed = %d/%d", pressed.InputElapsedNS, released.InputElapsedNS)
	}
	if reader.attestationReads != 1 {
		t.Fatalf("attestation reads = %d, want 1", reader.attestationReads)
	}
}

func TestKeepaliveEndpointRequiresActiveAttestation(t *testing.T) {
	for _, attestation := range []EndpointAttestation{EndpointScreensaverAtCue, EndpointUncertain} {
		t.Run(string(attestation), func(t *testing.T) {
			wantStatus := StatusClassFailure
			if attestation == EndpointUncertain {
				wantStatus = StatusIndeterminate
			}
			start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
			clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{
				start.Add(time.Second), start.Add(2 * time.Second), start.Add(3 * time.Second), start.Add(4 * time.Second),
			}}
			transport := newDiagnosticTransport()
			reader := &finalPairReader{testing: t, transport: transport, expectedWrites: 4, attestation: attestation}
			runner, session := newKeepaliveTestRunner(t, transport, reader, clock, time.Second, 4*time.Second)

			if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
				t.Fatal(err)
			}
			if !hasKeepaliveObservation(runner.sink.snapshot(), keepaliveFinalStage, wantStatus, 4) {
				t.Fatalf("observations = %+v", runner.sink.snapshot())
			}
		})
	}
}

func TestKeepaliveEndpointCueOverrunInvalidatesWithoutRetry(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{
		start.Add(time.Second), start.Add(2 * time.Second), start.Add(3 * time.Second), start.Add(4 * time.Second),
	}}
	transport := newDiagnosticTransport()
	runner, session := newKeepaliveTestRunner(t, transport, io.NopCloser(strings.NewReader("")), clock, time.Second, 4*time.Second)
	cueRuns := 0
	runner.options.EndpointCue = EndpointCueFunc(func(context.Context) error {
		cueRuns++
		clock.advance(EndpointCueTimeout + time.Nanosecond)
		return nil
	})

	if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	if cueRuns != 1 {
		t.Fatalf("cue runs = %d, want 1", cueRuns)
	}
	if got := len(transport.writesSnapshot()); got != 4 {
		t.Fatalf("experimental writes = %d, want 4", got)
	}
	if !hasKeepaliveObservation(runner.sink.snapshot(), keepaliveCueStage, StatusInvalidated, 4) {
		t.Fatalf("observations = %+v", runner.sink.snapshot())
	}
}

func TestKeepaliveZeroDurationCueIsArchivedAndAccepted(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	var output bytes.Buffer
	runner := &Runner{options: Options{Mode: ModeKeepalivePrevention}, sink: observationSink{writer: &output, limit: maximumObservationBytes}}
	if err := runner.observeKeepaliveCue(StatusPass, start, captureBoundary{moment: start.Add(time.Second)}, captureBoundary{moment: start.Add(time.Second)}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(output.String(), `"cue_duration_ns":0`) {
		t.Fatalf("zero cue duration was not archived: %q", output.String())
	}
}

func TestInvalidEndpointTimingSkipsAttestation(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{
		start.Add(time.Second), start.Add(2 * time.Second), start.Add(3 * time.Second), start.Add(4 * time.Second),
	}}
	transport := newDiagnosticTransport()
	reader := &finalPairReader{testing: t, transport: transport, expectedWrites: 4}
	runner, session := newKeepaliveTestRunner(t, transport, reader, clock, time.Second, 4*time.Second)
	runner.options.EndpointCue = EndpointCueFunc(func(context.Context) error {
		clock.advance(time.Second)
		clock.appendWake(clock.Now().Add(EndpointCaptureWindow + EndpointCloseTolerance + time.Nanosecond))
		return nil
	})

	if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	if reader.attestationReads != 0 {
		t.Fatalf("attestation reads = %d, want 0", reader.attestationReads)
	}
	if !hasKeepaliveObservation(runner.sink.snapshot(), keepaliveFinalStage, StatusInvalidated, 4) {
		t.Fatalf("observations = %+v", runner.sink.snapshot())
	}
}

func TestKeepaliveEndpointUsesFreshCueBoundaryAfterIdleEnd(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{
		start.Add(time.Second), start.Add(2 * time.Second), start.Add(3 * time.Second), start.Add(4 * time.Second),
	}}
	transport := newDiagnosticTransport()
	reader := &finalPairReader{testing: t, transport: transport, expectedWrites: 4}
	runner, session := newKeepaliveTestRunner(t, transport, reader, clock, time.Second, 4*time.Second)
	runner.keepaliveHealthTest = func(checkpoint string, boundary uint64, health captureHealth) captureHealth {
		if checkpoint != "before-cue-commit" || boundary != 4 {
			return health
		}
		clock.advance(10 * time.Millisecond)
		captured := make(chan struct{}, 1)
		clock.mu.Lock()
		clock.nowSignal = captured
		clock.mu.Unlock()
		queueInboundFrame(t, transport, d200x.NewFrame(d200x.CommandInputEvent, []byte{1, 13, byte(d200x.InputMarkerButton), byte(d200x.InputActionPressed)}))
		<-captured
		clock.mu.Lock()
		clock.nowSignal = nil
		clock.mu.Unlock()
		clock.advance(time.Nanosecond)
		return health
	}

	if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	observations := runner.sink.snapshot()
	if !hasKeepaliveObservation(observations, keepaliveFinalStage, StatusPass, 4) ||
		!hasKeepaliveObservation(observations, keepaliveResultStage, StatusPass, 4) {
		t.Fatalf("endpoint observations = %+v", observations)
	}

	var cue Observation
	var gap Observation
	var canonical Observation
	for _, observation := range observations {
		if observation.Stage == keepaliveCueStage && observation.Status == StatusPass {
			cue = observation
		}
		if observation.Event != "input" || observation.WireIndex == nil {
			continue
		}
		if *observation.WireIndex == 13 && observation.Action == "pressed" {
			gap = observation
		}
		if *observation.WireIndex == 0 && observation.Action == "pressed" {
			canonical = observation
		}
	}
	if gap.Sequence == 0 || canonical.Sequence == 0 || gap.Sequence >= canonical.Sequence {
		t.Fatalf("gap/canonical sequence = %d/%d, want gap before canonical", gap.Sequence, canonical.Sequence)
	}
	if gap.Status != StatusPass || gap.Classification != keepaliveInputPreCue || gap.Detail != keepaliveInputPreCueDetail {
		t.Fatalf("gap observation = %+v, want archived pre-cue pass", gap)
	}
	if gap.InputElapsedNS >= canonical.InputElapsedNS {
		t.Fatalf("pre-cue elapsed = %d, canonical elapsed = %d", gap.InputElapsedNS, canonical.InputElapsedNS)
	}
	wantCueStart := int64(4*time.Second + 10*time.Millisecond + time.Nanosecond)
	if cue.CueStartElapsedNS != wantCueStart || cue.CueCompletionElapsedNS != wantCueStart+int64(500*time.Millisecond) || cue.CueDurationNS != int64(500*time.Millisecond) {
		t.Fatalf("cue timing = %+v, want fresh cue boundary at %d ns", cue, wantCueStart)
	}
	if gap.InputElapsedNS >= cue.CueStartElapsedNS {
		t.Fatalf("pre-cue elapsed = %d, cue start elapsed = %d", gap.InputElapsedNS, cue.CueStartElapsedNS)
	}
	if canonical.Classification != keepaliveInputClass || canonical.InputElapsedNS < cue.CueStartElapsedNS {
		t.Fatalf("canonical observation = %+v, want observed input at or after cue start", canonical)
	}
	if reader.attestationReads != 1 {
		t.Fatalf("attestation reads = %d, want 1", reader.attestationReads)
	}
}

func TestKeepalivePreCueInputSchemasAreArchivedAsPass(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	records := []capturedInput{
		{
			boundary: captureBoundary{sequence: 5, moment: start.Add(time.Second)},
			event:    d200x.InputEvent{WireIndex: 7, Marker: d200x.InputMarkerButton, Action: d200x.InputActionPressed},
			decoded:  true,
		},
		{
			boundary: captureBoundary{sequence: 6, moment: start.Add(2 * time.Second)},
			event:    d200x.InputEvent{WireIndex: 200, Marker: d200x.InputMarker(0x7f), Action: d200x.InputAction(0x7f)},
			decoded:  true,
		},
		{boundary: captureBoundary{sequence: 7, moment: start.Add(3 * time.Second)}},
		{boundary: captureBoundary{sequence: 8, moment: start.Add(4 * time.Second)}, malformed: true},
	}
	runner := &Runner{options: Options{Mode: ModeKeepalivePrevention}, sink: observationSink{writer: io.Discard, limit: maximumObservationBytes}}
	idleEnd := captureBoundary{sequence: 4, moment: start}
	cueStart := captureBoundary{sequence: 9, moment: start.Add(5 * time.Second)}
	if err := runner.observeKeepaliveInputs(records, captureBoundary{sequence: 0}, idleEnd, cueStart, start, cueStart.moment.Add(5*time.Second)); err != nil {
		t.Fatal(err)
	}
	observations := runner.sink.snapshot()
	if len(observations) != len(records) {
		t.Fatalf("observations = %d, want %d", len(observations), len(records))
	}
	for index, observation := range observations {
		if observation.Status != StatusPass || observation.Classification != keepaliveInputPreCue || observation.Detail != keepaliveInputPreCueDetail {
			t.Fatalf("pre-cue observation %d = %+v", index, observation)
		}
		if observation.InputElapsedNS <= 0 || observation.InputElapsedNS >= int64(5*time.Second) {
			t.Fatalf("pre-cue elapsed %d = %d, want positive and before cue start", index, observation.InputElapsedNS)
		}
	}
	if observations[0].WireIndex == nil || *observations[0].WireIndex != 7 || observations[0].Marker != "button" || observations[0].Action != "pressed" || !observations[0].Decoded || observations[0].Malformed {
		t.Fatalf("decoded-known pre-cue observation = %+v", observations[0])
	}
	if observations[1].WireIndex == nil || *observations[1].WireIndex != 200 || observations[1].Marker != "unknown" || observations[1].Action != "unknown" || !observations[1].Decoded || observations[1].Malformed {
		t.Fatalf("decoded-unknown pre-cue observation = %+v", observations[1])
	}
	for index, observation := range observations[2:] {
		if observation.WireIndex != nil || observation.InputClass != "" || observation.Marker != "unknown" || observation.Action != "unknown" || observation.Decoded {
			t.Fatalf("non-decoded pre-cue observation %d = %+v", index+2, observation)
		}
	}
	if !observations[3].Malformed {
		t.Fatalf("malformed pre-cue observation = %+v", observations[3])
	}
}

func TestKeepaliveEndpointCaptureFailuresAreIndeterminate(t *testing.T) {
	tests := []struct {
		name          string
		failureHealth captureHealth
	}{
		{name: "terminal error", failureHealth: captureTerminalError},
		{name: "capacity exhausted", failureHealth: captureCapacityExhausted},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
			clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{
				start.Add(time.Second), start.Add(2 * time.Second), start.Add(3 * time.Second), start.Add(4 * time.Second),
			}}
			transport := newDiagnosticTransport()
			var reader io.ReadCloser
			var attestationReads func() int
			if test.failureHealth == captureTerminalError {
				reader = &finalPairReader{testing: t, transport: transport, expectedWrites: 4}
				attestationReads = func() int { return reader.(*finalPairReader).attestationReads }
			} else {
				frames := make([]d200x.Frame, maximumCapturedInputCount-2)
				for index := range frames {
					frames[index] = d200x.BrightnessFrame(index % 100)
				}
				capacityReader := &finalFramesReader{testing: t, transport: transport, frames: frames}
				reader = capacityReader
				attestationReads = func() int { return capacityReader.attestationReads }
			}

			var captureTransport d200x.Transport = transport
			var terminalTransport *endpointCaptureFailureTransport
			if test.failureHealth == captureTerminalError {
				terminalTransport = newEndpointCaptureFailureTransport(transport)
				captureTransport = terminalTransport
			}
			runner, session := newKeepaliveTestRunnerWithTransport(t, captureTransport, reader, clock, time.Second, 4*time.Second)
			cueRuns := 0
			runner.options.EndpointCue = EndpointCueFunc(func(ctx context.Context) error {
				cueRuns++
				clock.advance(500 * time.Millisecond)
				windowClose := clock.Now().Add(EndpointCaptureWindow)
				if terminalTransport != nil {
					clock.appendWakeHook(windowClose, func() {
						failEndpointCapture(t, clock, terminalTransport, transport)
					})
					return nil
				}
				return testEndpointCue(clock, reader).Cue(ctx)
			})

			if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
				t.Fatal(err)
			}
			if cueRuns != 1 || attestationReads() != 1 {
				t.Fatalf("cue runs/attestation reads = %d/%d, want 1/1", cueRuns, attestationReads())
			}
			observations := runner.sink.snapshot()
			if !hasKeepaliveObservation(observations, keepaliveHealthStage, StatusIndeterminate, 4) ||
				!hasKeepaliveObservation(observations, keepaliveFinalStage, StatusIndeterminate, 4) ||
				!hasKeepaliveObservation(observations, keepaliveResultStage, StatusIndeterminate, 4) {
				t.Fatalf("capture failure observations = %+v", observations)
			}
			for _, observation := range observations {
				if (observation.Stage == keepaliveFinalStage || observation.Stage == keepaliveResultStage) &&
					(observation.Status == StatusPass || observation.Status == StatusClassFailure) {
					t.Fatalf("capture failure committed endpoint outcome = %+v", observation)
				}
			}
		})
	}
}

func TestKeepaliveEndpointTimingInvalidationPrecedesCaptureFailure(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{
		start.Add(time.Second), start.Add(2 * time.Second), start.Add(3 * time.Second), start.Add(4 * time.Second),
	}}
	transport := newDiagnosticTransport()
	terminalTransport := newEndpointCaptureFailureTransport(transport)
	reader := &finalPairReader{testing: t, transport: transport, expectedWrites: 4}
	runner, session := newKeepaliveTestRunnerWithTransport(t, terminalTransport, reader, clock, time.Second, 4*time.Second)
	runner.options.EndpointCue = EndpointCueFunc(func(context.Context) error {
		clock.advance(500 * time.Millisecond)
		windowClose := clock.Now().Add(EndpointCaptureWindow + EndpointCloseTolerance + time.Nanosecond)
		clock.appendWakeHook(windowClose, func() {
			failEndpointCapture(t, clock, terminalTransport, transport)
		})
		return nil
	})

	if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	if reader.attestationReads != 0 {
		t.Fatalf("attestation reads = %d, want 0", reader.attestationReads)
	}
	observations := runner.sink.snapshot()
	if !hasKeepaliveObservation(observations, keepaliveHealthStage, StatusIndeterminate, 4) ||
		!hasKeepaliveObservation(observations, keepaliveFinalStage, StatusInvalidated, 4) ||
		!hasKeepaliveObservation(observations, keepaliveResultStage, StatusInvalidated, 4) {
		t.Fatalf("timing/capture observations = %+v", observations)
	}
}

func TestCancellationDuringAttestationCannotCommitPass(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{
		start.Add(time.Second), start.Add(2 * time.Second), start.Add(3 * time.Second), start.Add(4 * time.Second),
	}}
	transport := newDiagnosticTransport()
	ctx, cancel := context.WithCancel(context.Background())
	reader := &finalPairReader{testing: t, transport: transport, expectedWrites: 4, onAttestationRead: cancel}
	runner, session := newKeepaliveTestRunner(t, transport, reader, clock, time.Second, 4*time.Second)

	err := runner.runKeepalivePrevention(ctx, session)
	if err == nil || !strings.Contains(err.Error(), "canceled") {
		t.Fatalf("cancellation error = %v", err)
	}
	if hasKeepaliveObservation(runner.sink.snapshot(), keepaliveFinalStage, StatusPass, 4) ||
		hasKeepaliveObservation(runner.sink.snapshot(), keepaliveResultStage, StatusPass, 4) {
		t.Fatalf("cancellation committed pass: %+v", runner.sink.snapshot())
	}
}

func TestEndpointResultCommitCancellationBoundaries(t *testing.T) {
	tests := []struct {
		name               string
		cancelAt           string
		wantEndpointStatus Status
		wantResultStatus   Status
		wantError          bool
	}{
		{name: "before endpoint", cancelAt: "before-endpoint", wantEndpointStatus: StatusIndeterminate, wantResultStatus: StatusIndeterminate, wantError: true},
		{name: "between endpoint and result", cancelAt: "between-endpoint-result", wantEndpointStatus: StatusPass, wantResultStatus: StatusIndeterminate, wantError: true},
		{name: "after both commits", cancelAt: "after-result", wantEndpointStatus: StatusPass, wantResultStatus: StatusPass},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
			clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{
				start.Add(time.Second), start.Add(2 * time.Second), start.Add(3 * time.Second), start.Add(4 * time.Second),
			}}
			transport := newDiagnosticTransport()
			reader := &finalPairReader{testing: t, transport: transport, expectedWrites: 4}
			runner, session := newKeepaliveTestRunner(t, transport, reader, clock, time.Second, 4*time.Second)
			ctx, cancel := context.WithCancel(context.Background())
			runner.keepaliveCommitTest = func(checkpoint string) {
				if checkpoint == test.cancelAt {
					cancel()
				}
			}

			err := runner.runKeepalivePrevention(ctx, session)
			if (err != nil) != test.wantError {
				t.Fatalf("error = %v, want_error=%t", err, test.wantError)
			}
			observations := runner.sink.snapshot()
			if !hasKeepaliveObservation(observations, keepaliveFinalStage, test.wantEndpointStatus, 4) ||
				!hasKeepaliveObservation(observations, keepaliveResultStage, test.wantResultStatus, 4) {
				t.Fatalf("commit observations = %+v", observations)
			}
		})
	}
}

func TestRequiredKeepaliveObservationWriterFailuresAreIndeterminate(t *testing.T) {
	tests := []struct {
		stage              string
		failWrite          int
		experimentalWrites int
		cueRuns            int
	}{
		{stage: "start", failWrite: 2, experimentalWrites: 0},
		{stage: "boundary", failWrite: 3, experimentalWrites: 1},
		{stage: "health", failWrite: 8, experimentalWrites: 4},
		{stage: "cue", failWrite: 9, experimentalWrites: 4, cueRuns: 1},
		{stage: "input", failWrite: 10, experimentalWrites: 4, cueRuns: 1},
		{stage: "endpoint", failWrite: 12, experimentalWrites: 4, cueRuns: 1},
		{stage: "result", failWrite: 13, experimentalWrites: 4, cueRuns: 1},
	}
	for _, test := range tests {
		t.Run(test.stage, func(t *testing.T) {
			start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
			clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{
				start.Add(time.Second), start.Add(2 * time.Second), start.Add(3 * time.Second), start.Add(4 * time.Second),
			}}
			transport := newDiagnosticTransport()
			reader := &finalPairReader{testing: t, transport: transport, expectedInputEnables: 5}
			factory := &diagnosticFactory{transport: transport}
			writer := &failAtObservationWriter{failAt: test.failWrite}
			cueRuns := 0
			runner, err := New(Options{
				Mode: ModeKeepalivePrevention, ConfigPath: writeDiagnosticConfiguration(t, 73), Confirm: true,
				Factory: factory, Reader: reader, StageTimeout: time.Second, KeepaliveInterval: time.Second,
				KeepaliveDuration: 4 * time.Second, KeepaliveClock: clock, ObservationWriter: writer,
				EndpointCue: EndpointCueFunc(func(ctx context.Context) error {
					cueRuns++
					return testEndpointCue(clock, reader).Cue(ctx)
				}),
			})
			if err != nil {
				t.Fatal(err)
			}
			result, runErr := runner.Run(context.Background())
			if runErr == nil || result.Status == StatusPass {
				t.Fatalf("result=%s error=%v", result.Status, runErr)
			}
			commands, err := diagnosticCommands(transport.writesSnapshot())
			if err != nil {
				t.Fatal(err)
			}
			if got := countCommand(commands, d200x.CommandEnableInputStream) - 1; got != test.experimentalWrites || cueRuns != test.cueRuns {
				t.Fatalf("experimental_writes=%d want=%d cue_runs=%d want=%d", got, test.experimentalWrites, cueRuns, test.cueRuns)
			}
		})
	}
}

func TestBoundedKeepaliveObservationCapacityFailsClosed(t *testing.T) {
	runner := &Runner{sink: observationSink{writer: io.Discard, limit: maximumObservationBytes, items: make([]Observation, maximumObservationCount-2)}}
	if err := runner.observeKeepaliveBounded(Observation{Event: "input"}); err == nil {
		t.Fatal("bounded keepalive observation capacity returned nil")
	}
}

func TestRequiredKeepaliveObservationFailureStopsBeforeExperimentalWrite(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{start.Add(time.Second)}}
	transport := newDiagnosticTransport()
	runner, session := newKeepaliveTestRunner(t, transport, io.NopCloser(strings.NewReader("")), clock, time.Second, 4*time.Second)
	runner.sink.writer = failingObservationWriter{}

	if err := runner.runKeepalivePrevention(context.Background(), session); err == nil {
		t.Fatal("required observation failure returned nil")
	}
	if got := len(transport.writesSnapshot()); got != 0 {
		t.Fatalf("experimental writes = %d, want 0", got)
	}
}

func TestEndpointCloseTimingTolerance(t *testing.T) {
	planned := time.Date(2026, time.August, 31, 0, 0, 5, 0, time.UTC)
	tests := []struct {
		name string
		wake time.Time
		stop time.Time
		want bool
	}{
		{name: "zero lateness", wake: planned, stop: planned, want: true},
		{name: "maximum lateness", wake: planned.Add(EndpointCloseTolerance), stop: planned.Add(EndpointCloseTolerance), want: true},
		{name: "timer one nanosecond over", wake: planned.Add(EndpointCloseTolerance + time.Nanosecond), stop: planned, want: false},
		{name: "stop one nanosecond over", wake: planned, stop: planned.Add(EndpointCloseTolerance + time.Nanosecond), want: false},
		{name: "early timer", wake: planned.Add(-time.Nanosecond), stop: planned, want: false},
		{name: "early stop", wake: planned, stop: planned.Add(-time.Nanosecond), want: false},
		{name: "stop before timer wake", wake: planned.Add(time.Nanosecond), stop: planned, want: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := validateEndpointCloseTiming(planned, test.wake, test.stop); got != test.want {
				t.Fatalf("timing validity = %t, want %t", got, test.want)
			}
		})
	}
}

func TestKeepaliveLogicalWindowBoundsAndPostWindowArchival(t *testing.T) {
	cueStart := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	plannedClose := cueStart.Add(EndpointCaptureWindow)
	records := []capturedInput{
		keepaliveCapturedInput(1, cueStart, 0, d200x.InputActionPressed),
		keepaliveCapturedInput(2, plannedClose, 0, d200x.InputActionReleased),
		keepaliveCapturedInput(3, plannedClose.Add(time.Nanosecond), 13, d200x.InputActionPressed),
	}
	windowRecords := recordsWithinLogicalWindow(records, cueStart, plannedClose)
	if got := validateKeepaliveEndpoint(windowRecords, cueStart, plannedClose); got != StatusPass {
		t.Fatalf("inclusive logical window status = %s", got)
	}
	if got := len(windowRecords); got != 2 {
		t.Fatalf("window records = %d, want 2", got)
	}

	runner := &Runner{options: Options{Mode: ModeKeepalivePrevention}, sink: observationSink{writer: io.Discard, limit: maximumObservationBytes}}
	if err := runner.observeKeepaliveInputs(records, captureBoundary{}, captureBoundary{}, captureBoundary{}, cueStart.Add(-time.Second), plannedClose); err != nil {
		t.Fatal(err)
	}
	observations := runner.sink.snapshot()
	if got := observations[2].Classification; got != keepaliveInputPostWindow || observations[2].Status != StatusPass {
		t.Fatalf("post-window observation = %+v", observations[2])
	}
}

func TestKeepaliveEndpointOutcomeTable(t *testing.T) {
	cueStart := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	plannedClose := cueStart.Add(EndpointCaptureWindow)
	canonical := []capturedInput{
		keepaliveCapturedInput(1, cueStart, 0, d200x.InputActionPressed),
		keepaliveCapturedInput(2, plannedClose, 0, d200x.InputActionReleased),
	}
	wrong := append([]capturedInput(nil), canonical...)
	wrong[1] = keepaliveCapturedInput(2, plannedClose, 13, d200x.InputActionReleased)
	reversed := []capturedInput{canonical[1], canonical[0]}
	duplicate := append(append([]capturedInput(nil), canonical...), canonical[1])
	malformed := append([]capturedInput(nil), canonical...)
	malformed[0].malformed = true
	nonInput := append([]capturedInput(nil), canonical...)
	nonInput[0].decoded = false

	tests := []struct {
		name             string
		timingValid      bool
		captureHealthy   bool
		attestation      EndpointAttestation
		attestationValid bool
		records          []capturedInput
		want             Status
	}{
		{name: "active canonical", timingValid: true, captureHealthy: true, attestation: EndpointActiveAtCue, attestationValid: true, records: canonical, want: StatusPass},
		{name: "active missing", timingValid: true, captureHealthy: true, attestation: EndpointActiveAtCue, attestationValid: true, want: StatusClassFailure},
		{name: "active wrong", timingValid: true, captureHealthy: true, attestation: EndpointActiveAtCue, attestationValid: true, records: wrong, want: StatusClassFailure},
		{name: "active reversed", timingValid: true, captureHealthy: true, attestation: EndpointActiveAtCue, attestationValid: true, records: reversed, want: StatusClassFailure},
		{name: "active duplicate", timingValid: true, captureHealthy: true, attestation: EndpointActiveAtCue, attestationValid: true, records: duplicate, want: StatusClassFailure},
		{name: "active malformed", timingValid: true, captureHealthy: true, attestation: EndpointActiveAtCue, attestationValid: true, records: malformed, want: StatusClassFailure},
		{name: "active non-input", timingValid: true, captureHealthy: true, attestation: EndpointActiveAtCue, attestationValid: true, records: nonInput, want: StatusClassFailure},
		{name: "screensaver with input", timingValid: true, captureHealthy: true, attestation: EndpointScreensaverAtCue, attestationValid: true, records: canonical, want: StatusClassFailure},
		{name: "screensaver without input", timingValid: true, captureHealthy: true, attestation: EndpointScreensaverAtCue, attestationValid: true, want: StatusClassFailure},
		{name: "uncertain", timingValid: true, captureHealthy: true, attestation: EndpointUncertain, attestationValid: true, records: canonical, want: StatusIndeterminate},
		{name: "missing attestation", timingValid: true, captureHealthy: true, records: canonical, want: StatusIndeterminate},
		{name: "capture failure", timingValid: true, captureHealthy: false, attestation: EndpointActiveAtCue, attestationValid: true, records: canonical, want: StatusIndeterminate},
		{name: "timing precedence", timingValid: false, captureHealthy: false, attestation: EndpointUncertain, records: wrong, want: StatusInvalidated},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := classifyKeepaliveEndpoint(test.timingValid, test.captureHealthy, test.attestation, test.attestationValid, test.records, cueStart, plannedClose)
			if got != test.want {
				t.Fatalf("endpoint status = %s, want %s", got, test.want)
			}
		})
	}
}

func TestContinuousCaptureTerminalAndExhaustionAreFailures(t *testing.T) {
	for _, capture := range []*continuousCapture{
		{terminalErr: errors.New("terminal read failure"), health: captureTerminalError},
		{health: captureCapacityExhausted},
	} {
		if !capture.terminalFailure() {
			t.Fatal("capture health accepted a terminal failure")
		}
	}
}

func TestCaptureHealthStopsWritesAndCueAtEverySchedulerCheckpoint(t *testing.T) {
	tests := []struct {
		name           string
		checkpoint     string
		boundary       uint64
		expectedWrites int
		failureHealth  captureHealth
	}{
		{name: "before boundary one", checkpoint: "before-write", boundary: 1, expectedWrites: 0, failureHealth: captureTerminalError},
		{name: "before boundary two", checkpoint: "before-write", boundary: 2, expectedWrites: 1},
		{name: "before boundary three", checkpoint: "before-write", boundary: 3, expectedWrites: 2},
		{name: "before boundary four", checkpoint: "before-write", boundary: 4, expectedWrites: 3},
		{name: "after boundary one", checkpoint: "after-write", boundary: 1, expectedWrites: 1},
		{name: "capacity after boundary two", checkpoint: "after-write", boundary: 2, expectedWrites: 2, failureHealth: captureCapacityExhausted},
		{name: "after boundary four", checkpoint: "after-write", boundary: 4, expectedWrites: 4},
		{name: "between fourth write and cue", checkpoint: "before-cue", boundary: 4, expectedWrites: 4},
		{name: "post-health-observation cue race", checkpoint: "before-cue-commit", boundary: 4, expectedWrites: 4},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			failureHealth := test.failureHealth
			if failureHealth == "" {
				failureHealth = captureTerminalError
			}
			start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
			clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{
				start.Add(time.Second), start.Add(2 * time.Second), start.Add(3 * time.Second), start.Add(4 * time.Second),
			}}
			transport := newDiagnosticTransport()
			runner, session := newKeepaliveTestRunner(t, transport, io.NopCloser(strings.NewReader("")), clock, time.Second, 4*time.Second)
			cueRuns := 0
			runner.options.EndpointCue = EndpointCueFunc(func(context.Context) error {
				cueRuns++
				return nil
			})
			runner.keepaliveHealthTest = func(checkpoint string, boundary uint64, health captureHealth) captureHealth {
				if checkpoint == test.checkpoint && boundary == test.boundary {
					return failureHealth
				}
				return health
			}

			if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
				t.Fatal(err)
			}
			if got := len(transport.writesSnapshot()); got != test.expectedWrites || cueRuns != 0 {
				t.Fatalf("writes=%d want=%d cue_runs=%d", got, test.expectedWrites, cueRuns)
			}
			observations := runner.sink.snapshot()
			if !hasKeepaliveObservation(observations, keepaliveScheduleStage, StatusIndeterminate, uint64(test.expectedWrites)) ||
				!hasKeepaliveObservation(observations, keepaliveFinalStage, StatusNotRun, uint64(test.expectedWrites)) ||
				!hasKeepaliveObservation(observations, keepaliveResultStage, StatusIndeterminate, uint64(test.expectedWrites)) {
				t.Fatalf("terminal observations = %+v", observations)
			}
			foundHealth := false
			for _, observation := range observations {
				if observation.Stage == keepaliveHealthStage && observation.Status == StatusIndeterminate && observation.Classification == string(failureHealth) {
					foundHealth = true
				}
			}
			if !foundHealth {
				t.Fatalf("redacted health observation missing: %+v", observations)
			}
		})
	}
}

func keepaliveCapturedInput(sequence uint64, moment time.Time, wire byte, action d200x.InputAction) capturedInput {
	return capturedInput{
		boundary: captureBoundary{sequence: sequence, moment: moment},
		event: d200x.InputEvent{
			WireIndex: wire,
			Marker:    d200x.InputMarkerButton,
			Action:    action,
		},
		decoded: true,
	}
}

func TestKeepaliveScheduleAllowsSubIntervalJitter(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	clock := &scriptedKeepaliveClock{
		start: start,
		wakes: []time.Time{
			start.Add(1500 * time.Millisecond),
			start.Add(2500 * time.Millisecond),
			start.Add(3500 * time.Millisecond),
			start.Add(4500 * time.Millisecond),
		},
	}
	transport := newDiagnosticTransport()
	reader := &finalPairReader{testing: t, transport: transport, expectedWrites: 4}
	runner, session := newKeepaliveTestRunner(t, transport, reader, clock, time.Second, 4*time.Second)

	if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	if got := len(transport.writesSnapshot()); got != 4 {
		t.Fatalf("experimental writes = %d, want 4", got)
	}
}

func TestKeepaliveScheduleUsesFourBoundariesForTheClosedDuration(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	clock := &scriptedKeepaliveClock{
		start: start,
		wakes: []time.Time{
			start.Add(time.Second),
			start.Add(2 * time.Second),
			start.Add(3 * time.Second),
			start.Add(4 * time.Second),
		},
	}
	transport := newDiagnosticTransport()
	reader := &finalPairReader{testing: t, transport: transport, expectedWrites: 4}
	runner, session := newKeepaliveTestRunner(t, transport, reader, clock, time.Second, 4*time.Second)

	if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	wantDeadlines := []time.Time{
		start.Add(time.Second),
		start.Add(2 * time.Second),
		start.Add(3 * time.Second),
		start.Add(4 * time.Second),
	}
	if len(clock.deadlines) != len(wantDeadlines)+1 {
		t.Fatalf("wait count = %d, want %d", len(clock.deadlines), len(wantDeadlines)+1)
	}
	for index := range wantDeadlines {
		if !clock.deadlines[index].Equal(wantDeadlines[index]) {
			t.Fatalf("deadline %d = %s, want %s", index, clock.deadlines[index], wantDeadlines[index])
		}
	}
	if got := len(transport.writesSnapshot()); got != 4 {
		t.Fatalf("experimental writes = %d, want 4", got)
	}
}

func TestKeepaliveScheduleInvalidatesAtNextBoundaryWithoutCatchUp(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	clock := &scriptedKeepaliveClock{
		start: start,
		wakes: []time.Time{start.Add(2 * time.Second)},
	}
	transport := newDiagnosticTransport()
	runner, session := newKeepaliveTestRunner(t, transport, io.NopCloser(strings.NewReader("")), clock, time.Second, 4*time.Second)

	if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	if got := len(transport.writesSnapshot()); got != 0 {
		t.Fatalf("writes after late resumption = %d, want 0", got)
	}
	if !hasKeepaliveObservation(runner.sink.snapshot(), keepaliveBoundaryStage, StatusInvalidated, 1) {
		t.Fatalf("late observations = %+v", runner.sink.snapshot())
	}
}

func TestKeepaliveScheduleCancellationWritesNothing(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	clock := &scriptedKeepaliveClock{start: start}
	transport := newDiagnosticTransport()
	runner, session := newKeepaliveTestRunner(t, transport, io.NopCloser(strings.NewReader("")), clock, time.Second, 4*time.Second)

	err := runner.runKeepalivePrevention(ctx, session)
	if err == nil || !strings.Contains(err.Error(), "canceled") {
		t.Fatalf("cancellation error = %v", err)
	}
	if got := len(transport.writesSnapshot()); got != 0 {
		t.Fatalf("writes after cancellation = %d, want 0", got)
	}
	if !hasKeepaliveObservation(runner.sink.snapshot(), keepaliveScheduleStage, StatusIndeterminate, 1) {
		t.Fatalf("cancellation observations = %+v", runner.sink.snapshot())
	}
}

func TestKeepaliveWriteFailureIsNotRetried(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	clock := &scriptedKeepaliveClock{
		start: start,
		wakes: []time.Time{start.Add(time.Second), start.Add(2 * time.Second)},
	}
	transport := newDiagnosticTransport()
	transport.failCommand = d200x.CommandEnableInputStream
	transport.failCommandOccurrence = 1
	runner, session := newKeepaliveTestRunner(t, transport, io.NopCloser(strings.NewReader("")), clock, time.Second, 4*time.Second)

	if err := runner.runKeepalivePrevention(context.Background(), session); err == nil {
		t.Fatal("failed write returned no error")
	}
	if got := len(transport.writesSnapshot()); got != 1 {
		t.Fatalf("write attempts = %d, want 1", got)
	}
	if got := len(clock.deadlines); got != 1 {
		t.Fatalf("wait attempts = %d, want 1", got)
	}
}

func TestKeepaliveIdleInboundFramesInvalidateBeforeAnotherWrite(t *testing.T) {
	tests := []struct {
		name           string
		frame          d200x.Frame
		classification string
	}{
		{
			name:           "decoded input",
			frame:          d200x.NewFrame(d200x.CommandInputEvent, []byte{1, 7, byte(d200x.InputMarkerButton), byte(d200x.InputActionPressed)}),
			classification: keepaliveInputClass,
		},
		{
			name:           "non-input frame",
			frame:          d200x.BrightnessFrame(50),
			classification: keepaliveInputNonInput,
		},
		{
			name:           "malformed input",
			frame:          d200x.NewFrame(d200x.CommandInputEvent, nil),
			classification: keepaliveInputMalformed,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
			baseTransport := newDiagnosticTransport()
			readReturned := make(chan struct{})
			allowReadReturn := make(chan struct{})
			transport := &synchronizedReadTransport{
				diagnosticTransport: baseTransport,
				readReturned:        readReturned,
				allowReadReturn:     allowReadReturn,
			}
			captured := make(chan struct{})
			var clock *scriptedKeepaliveClock
			clock = &scriptedKeepaliveClock{
				start: start,
				wakes: []time.Time{start.Add(time.Second), start.Add(2 * time.Second)},
				hooks: []func(){func() {
					queueInboundFrame(t, baseTransport, test.frame)
					<-readReturned
					clock.mu.Lock()
					clock.nowSignal = captured
					clock.mu.Unlock()
					close(allowReadReturn)
					<-captured
					clock.mu.Lock()
					clock.nowSignal = nil
					clock.mu.Unlock()
				}},
			}
			factory := &directTransportFactory{transport: transport}
			runner, err := New(Options{
				Mode:              ModeKeepalivePrevention,
				ConfigPath:        "/private/fake-diagnostic.toml",
				Confirm:           true,
				Factory:           factory,
				Reader:            io.NopCloser(strings.NewReader("")),
				StageTimeout:      time.Second,
				KeepaliveInterval: time.Second,
				KeepaliveDuration: 4 * time.Second,
				KeepaliveClock:    clock,
				EndpointCue: EndpointCueFunc(func(context.Context) error {
					t.Fatal("endpoint cue must not run after idle invalidation")
					return nil
				}),
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

			if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
				t.Fatal(err)
			}
			if got := len(baseTransport.writesSnapshot()); got != 0 {
				t.Fatalf("experimental writes after early idle activity = %d, want 0", got)
			}
			if got := len(clock.deadlines); got != 1 {
				t.Fatalf("scheduled waits after early idle activity = %d, want 1", got)
			}
			observations := runner.sink.snapshot()
			if !hasKeepaliveObservation(observations, keepaliveScheduleStage, StatusInvalidated, 0) ||
				!hasKeepaliveObservation(observations, keepaliveFinalStage, StatusNotRun, 0) {
				t.Fatalf("idle invalidation observations = %+v", observations)
			}
			foundInput := false
			for _, observation := range observations {
				if observation.Event != "input" {
					continue
				}
				foundInput = true
				if observation.Status != StatusInvalidated || observation.Classification != test.classification {
					t.Fatalf("idle input observation = %+v", observation)
				}
			}
			if !foundInput {
				t.Fatalf("idle input observation missing: %+v", observations)
			}
		})
	}
}

func TestKeepaliveFinalValidationIncludesPromptGapFrames(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{
		start.Add(time.Second),
		start.Add(2 * time.Second),
		start.Add(3 * time.Second),
		start.Add(4 * time.Second),
	}}
	transport := newDiagnosticTransport()
	reader := &finalFramesReader{
		testing:   t,
		transport: transport,
		frames:    []d200x.Frame{d200x.BrightnessFrame(50)},
	}
	runner, session := newKeepaliveTestRunner(t, transport, reader, clock, time.Second, 4*time.Second)

	if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	if !hasKeepaliveObservation(runner.sink.snapshot(), keepaliveFinalStage, StatusClassFailure, 4) {
		t.Fatalf("final observations = %+v", runner.sink.snapshot())
	}
}

func TestKeepaliveScheduleContract(t *testing.T) {
	tests := []struct {
		name     string
		interval time.Duration
		duration time.Duration
		wantErr  error
	}{
		{name: "sixty minutes accepted", interval: 15 * time.Minute, duration: 60 * time.Minute},
		{name: "duration over sixty minutes", interval: 15 * time.Minute, duration: 60*time.Minute + time.Nanosecond, wantErr: ErrKeepaliveDurationTooLong},
		{name: "ratio mismatch", interval: time.Second, duration: 5 * time.Second, wantErr: ErrKeepaliveScheduleMismatch},
		{name: "duration not divisible by four", interval: time.Nanosecond, duration: 5 * time.Nanosecond, wantErr: ErrKeepaliveScheduleMismatch},
		{name: "overflow-safe interval mismatch", interval: time.Duration(1 << 62), duration: 60 * time.Minute, wantErr: ErrKeepaliveScheduleMismatch},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			err := ValidateKeepaliveSchedule(test.interval, test.duration)
			if test.wantErr == nil {
				if err != nil {
					t.Fatalf("validation error = %v", err)
				}
				return
			}
			if !errors.Is(err, test.wantErr) {
				t.Fatalf("validation error = %v, want %v", err, test.wantErr)
			}
		})
	}
}

func TestKeepaliveTimingContractSelection(t *testing.T) {
	base := Options{
		Mode:              ModeKeepalivePrevention,
		ConfigPath:        "/private/fake-diagnostic.toml",
		KeepaliveInterval: 50 * time.Second,
		KeepaliveDuration: 200 * time.Second,
	}
	runner, err := New(base)
	if err != nil {
		t.Fatal(err)
	}
	if runner.options.KeepaliveTimingContract != KeepaliveTimingContractK150V1 {
		t.Fatalf("timing contract = %q, want %q", runner.options.KeepaliveTimingContract, KeepaliveTimingContractK150V1)
	}

	legacy := base
	legacy.KeepaliveInterval = 15 * time.Minute
	legacy.KeepaliveDuration = 60 * time.Minute
	legacyRunner, err := New(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if legacyRunner.options.KeepaliveTimingContract != "" {
		t.Fatalf("legacy timing contract = %q, want absent", legacyRunner.options.KeepaliveTimingContract)
	}

	unknown := base
	unknown.KeepaliveTimingContract = "unknown"
	if _, err := New(unknown); !errors.Is(err, ErrInvalidKeepaliveTimingContract) {
		t.Fatalf("unknown timing contract error = %v", err)
	}
	mismatched := base
	mismatched.KeepaliveInterval = time.Second
	mismatched.KeepaliveDuration = 4 * time.Second
	mismatched.KeepaliveTimingContract = KeepaliveTimingContractK150V1
	if _, err := New(mismatched); !errors.Is(err, ErrKeepaliveTimingContractMismatch) {
		t.Fatalf("mismatched timing contract error = %v", err)
	}
}

func TestK150BoundaryTimingIsSerializedAndBounded(t *testing.T) {
	tests := []struct {
		name          string
		completionLag time.Duration
		wantStatus    Status
		wantCueRuns   int
		wantWrites    int
	}{
		{name: "zero lateness", wantStatus: StatusPass, wantCueRuns: 1, wantWrites: 4},
		{name: "inclusive tolerance", completionLag: KeepaliveBoundaryTolerance, wantStatus: StatusPass, wantCueRuns: 1, wantWrites: 4},
		{name: "one nanosecond over", completionLag: KeepaliveBoundaryTolerance + time.Nanosecond, wantStatus: StatusInvalidated, wantCueRuns: 0, wantWrites: 4},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
			clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{
				start.Add(50 * time.Second),
				start.Add(100 * time.Second),
				start.Add(150 * time.Second),
				start.Add(200 * time.Second),
			}}
			baseTransport := newDiagnosticTransport()
			transport := &keepaliveCompletionTimingTransport{
				diagnosticTransport: baseTransport,
				clock:               clock,
				completionLags:      []time.Duration{0, 0, 0, test.completionLag},
			}
			reader := &finalPairReader{testing: t, transport: baseTransport, expectedWrites: 4}
			runner, session := newKeepaliveTestRunnerWithTransport(t, transport, reader, clock, 50*time.Second, 200*time.Second)
			var output bytes.Buffer
			runner.sink.writer = &output
			cueRuns := 0
			runner.options.EndpointCue = EndpointCueFunc(func(ctx context.Context) error {
				cueRuns++
				return testEndpointCue(clock, reader).Cue(ctx)
			})

			if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
				t.Fatal(err)
			}
			if got := len(baseTransport.writesSnapshot()); got != test.wantWrites {
				t.Fatalf("writes = %d, want %d", got, test.wantWrites)
			}
			if cueRuns != test.wantCueRuns {
				t.Fatalf("cue runs = %d, want %d", cueRuns, test.wantCueRuns)
			}
			observations := runner.sink.snapshot()
			if !hasKeepaliveObservation(observations, keepaliveBoundaryStage, test.wantStatus, 4) {
				t.Fatalf("boundary observations = %+v", observations)
			}
			for boundary := uint64(1); boundary <= 4; boundary++ {
				var observation Observation
				for _, candidate := range observations {
					if candidate.Stage == keepaliveBoundaryStage && candidate.Boundary == boundary {
						observation = candidate
						break
					}
				}
				if observation.Status != test.wantStatus {
					continue
				}
				planned := int64(boundary) * int64(50*time.Second)
				wantCompletion := planned
				if boundary == 4 {
					wantCompletion += int64(test.completionLag)
				}
				if observation.TimingContract != KeepaliveTimingContractK150V1 ||
					observation.PlannedBoundaryElapsedNS != planned ||
					observation.ActualTimerWakeNS != planned ||
					observation.WriteStartElapsedNS != planned ||
					observation.WriteCompletionElapsedNS != wantCompletion {
					t.Fatalf("boundary %d timing = %+v, want planned=%d completion=%d", boundary, observation, planned, wantCompletion)
				}
			}

			lines := strings.Split(strings.TrimSpace(output.String()), "\n")
			for _, line := range lines {
				var fields map[string]json.RawMessage
				if err := json.Unmarshal([]byte(line), &fields); err != nil {
					t.Fatal(err)
				}
				stage := string(fields["stage"])
				if stage != `"keepalive-prevention-boundary"` {
					continue
				}
				wantKeys := []string{
					"event", "mode", "stage", "status", "command", "detail", "boundary", "timing_contract",
					"planned_boundary_elapsed_ns", "actual_timer_wake_elapsed_ns", "write_start_elapsed_ns", "write_completion_elapsed_ns",
				}
				if len(fields) != len(wantKeys) {
					t.Fatalf("serialized boundary keys = %v, want exactly %v", fields, wantKeys)
				}
				for _, key := range wantKeys {
					if _, ok := fields[key]; !ok {
						t.Fatalf("serialized boundary omitted %q: %v", key, fields)
					}
				}
				if test.wantStatus == StatusInvalidated && fields["write_completion_elapsed_ns"] == nil {
					t.Fatal("late completion invalidation omitted an observed completion")
				}
			}
		})
	}
}

func TestK150TimingAnomaliesStopWithoutLaterAction(t *testing.T) {
	tests := []struct {
		name string
		wake time.Time
		hook func(*scriptedKeepaliveClock)
	}{
		{name: "early wake"},
		{name: "missing wake"},
		{name: "write starts before wake"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
			wake := start.Add(50 * time.Second)
			switch test.name {
			case "early wake":
				wake = wake.Add(-time.Nanosecond)
			case "missing wake":
				wake = time.Time{}
			case "write starts before wake":
				test.hook = func(clock *scriptedKeepaliveClock) { clock.advance(-time.Nanosecond) }
			}
			clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{wake}}
			if test.hook != nil {
				clock.hooks = []func(){func() { test.hook(clock) }}
			}
			transport := newDiagnosticTransport()
			runner, session := newKeepaliveTestRunner(t, transport, io.NopCloser(strings.NewReader("")), clock, 50*time.Second, 200*time.Second)
			cueRuns := 0
			runner.options.EndpointCue = EndpointCueFunc(func(context.Context) error {
				cueRuns++
				t.Fatal("endpoint cue ran after timing invalidation")
				return nil
			})

			if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
				t.Fatal(err)
			}
			if got := len(transport.writesSnapshot()); got != 0 {
				t.Fatalf("writes after timing invalidation = %d, want 0", got)
			}
			if len(clock.deadlines) != 1 || cueRuns != 0 {
				t.Fatalf("waits=%d cue_runs=%d, want one wait and no cue", len(clock.deadlines), cueRuns)
			}
			if !hasKeepaliveObservation(runner.sink.snapshot(), keepaliveBoundaryStage, StatusInvalidated, 1) ||
				!hasKeepaliveObservation(runner.sink.snapshot(), keepaliveResultStage, StatusInvalidated, 1) {
				t.Fatalf("timing invalidation observations = %+v", runner.sink.snapshot())
			}
		})
	}
}

func TestK150WriteFailureOmitsCompletionAndStops(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{start.Add(50 * time.Second)}}
	transport := newDiagnosticTransport()
	transport.failCommand = d200x.CommandEnableInputStream
	transport.failCommandOccurrence = 1
	runner, session := newKeepaliveTestRunner(t, transport, io.NopCloser(strings.NewReader("")), clock, 50*time.Second, 200*time.Second)
	var output bytes.Buffer
	runner.sink.writer = &output
	runner.options.EndpointCue = EndpointCueFunc(func(context.Context) error {
		t.Fatal("endpoint cue ran after write failure")
		return nil
	})

	if err := runner.runKeepalivePrevention(context.Background(), session); err == nil {
		t.Fatal("write failure returned nil")
	}
	if got := len(transport.writesSnapshot()); got != 1 {
		t.Fatalf("write attempts = %d, want 1", got)
	}
	var boundary Observation
	for _, observation := range runner.sink.snapshot() {
		if observation.Stage == keepaliveBoundaryStage {
			boundary = observation
			break
		}
	}
	if boundary.Status != StatusIndeterminate || boundary.WriteCompletionElapsedNS != 0 {
		t.Fatalf("failed boundary observation = %+v", boundary)
	}
	for _, line := range strings.Split(strings.TrimSpace(output.String()), "\n") {
		var fields map[string]json.RawMessage
		if err := json.Unmarshal([]byte(line), &fields); err != nil {
			t.Fatal(err)
		}
		if string(fields["stage"]) == `"keepalive-prevention-boundary"` {
			if _, ok := fields["write_completion_elapsed_ns"]; ok {
				t.Fatalf("failed boundary serialized completion: %v", fields)
			}
			return
		}
	}
	t.Fatal("failed boundary observation was not serialized")
}

func TestK150FourthCompletionMustPrecedeFreshCueBoundary(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	clock := &scriptedKeepaliveClock{start: start, wakes: []time.Time{
		start.Add(50 * time.Second), start.Add(100 * time.Second), start.Add(150 * time.Second), start.Add(200 * time.Second),
	}}
	transport := newDiagnosticTransport()
	runner, session := newKeepaliveTestRunner(t, transport, io.NopCloser(strings.NewReader("")), clock, 50*time.Second, 200*time.Second)
	cueRuns := 0
	runner.options.EndpointCue = EndpointCueFunc(func(context.Context) error {
		cueRuns++
		t.Fatal("endpoint cue ran after fourth completion ordering failure")
		return nil
	})
	runner.keepaliveHealthTest = func(checkpoint string, boundary uint64, health captureHealth) captureHealth {
		if checkpoint == "before-cue-commit" && boundary == 4 {
			clock.advance(-time.Nanosecond)
		}
		return health
	}

	if err := runner.runKeepalivePrevention(context.Background(), session); err != nil {
		t.Fatal(err)
	}
	if got := len(transport.writesSnapshot()); got != 4 {
		t.Fatalf("writes = %d, want 4", got)
	}
	if cueRuns != 0 {
		t.Fatalf("cue runs = %d, want 0", cueRuns)
	}
	if !hasKeepaliveObservation(runner.sink.snapshot(), keepaliveFinalStage, StatusNotRun, 4) ||
		!hasKeepaliveObservation(runner.sink.snapshot(), keepaliveResultStage, StatusInvalidated, 4) {
		t.Fatalf("fresh cue ordering observations = %+v", runner.sink.snapshot())
	}
}

func TestK150TimingEvidenceFailsClosedAtOutputLimit(t *testing.T) {
	start := time.Date(2026, time.August, 31, 0, 0, 0, 0, time.UTC)
	var output bytes.Buffer
	runner := &Runner{
		options: Options{Mode: ModeKeepalivePrevention, KeepaliveTimingContract: KeepaliveTimingContractK150V1},
		sink:    observationSink{writer: &output, limit: 200},
	}
	timing := keepaliveBoundaryTiming{
		scheduleStart:   start,
		planned:         start.Add(50 * time.Second),
		wake:            start.Add(50 * time.Second),
		writeStart:      start.Add(50 * time.Second),
		writeCompletion: start.Add(50 * time.Second),
	}
	if err := runner.observeKeepaliveBoundary(StatusPass, "boundary", 1, timing); err == nil {
		t.Fatal("oversized timing observation returned nil")
	}
	if output.Len() != 0 || len(runner.sink.items) != 0 {
		t.Fatalf("oversized timing observation was retained in bounded form: output=%q items=%d", output.String(), len(runner.sink.items))
	}
}

func TestKeepaliveArgumentsArePositiveAndModeScoped(t *testing.T) {
	base := Options{Mode: ModeKeepalivePrevention, ConfigPath: "/private/fake-diagnostic.toml"}
	if _, err := New(base); !errors.Is(err, ErrInvalidKeepaliveInterval) {
		t.Fatalf("missing interval error = %v", err)
	}
	base.KeepaliveInterval = time.Second
	if _, err := New(base); !errors.Is(err, ErrInvalidKeepaliveDuration) {
		t.Fatalf("missing duration error = %v", err)
	}
	base.KeepaliveDuration = 500 * time.Millisecond
	if _, err := New(base); !errors.Is(err, ErrKeepaliveScheduleMismatch) {
		t.Fatalf("ratio mismatch error = %v", err)
	}
	base.Mode = ModeBrightnessZero
	base.KeepaliveDuration = time.Second
	if _, err := New(base); !errors.Is(err, ErrKeepaliveArgumentsOnly) {
		t.Fatalf("mis-scoped argument error = %v", err)
	}
}

func newKeepaliveTestRunner(t *testing.T, transport *diagnosticTransport, reader io.ReadCloser, clock *scriptedKeepaliveClock, interval, duration time.Duration) (*Runner, *d200x.Session) {
	t.Helper()
	factory := &diagnosticFactory{transport: transport}
	runner, err := New(Options{
		Mode:              ModeKeepalivePrevention,
		ConfigPath:        "/private/fake-diagnostic.toml",
		Confirm:           true,
		Factory:           factory,
		Reader:            reader,
		StageTimeout:      time.Second,
		KeepaliveInterval: interval,
		KeepaliveDuration: duration,
		KeepaliveClock:    clock,
		EndpointCue:       testEndpointCue(clock, reader),
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

func newKeepaliveTestRunnerWithTransport(t *testing.T, transport d200x.Transport, reader io.ReadCloser, clock *scriptedKeepaliveClock, interval, duration time.Duration) (*Runner, *d200x.Session) {
	t.Helper()
	factory := &directTransportFactory{transport: transport}
	runner, err := New(Options{
		Mode:              ModeKeepalivePrevention,
		ConfigPath:        "/private/fake-diagnostic.toml",
		Confirm:           true,
		Factory:           factory,
		Reader:            reader,
		StageTimeout:      time.Second,
		KeepaliveInterval: interval,
		KeepaliveDuration: duration,
		KeepaliveClock:    clock,
		EndpointCue:       testEndpointCue(clock, reader),
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

func hasKeepaliveObservation(observations []Observation, stage string, status Status, boundary uint64) bool {
	for _, observation := range observations {
		if observation.Stage == stage && observation.Status == status && observation.Boundary == boundary {
			return true
		}
	}
	return false
}

type scriptedKeepaliveClock struct {
	mu        sync.Mutex
	start     time.Time
	current   time.Time
	wakes     []time.Time
	hooks     []func()
	deadlines []time.Time
	nowSignal chan struct{}
}

func (clock *scriptedKeepaliveClock) Now() time.Time {
	clock.mu.Lock()
	if clock.current.IsZero() {
		clock.current = clock.start
	}
	current := clock.current
	signal := clock.nowSignal
	clock.mu.Unlock()
	if signal != nil {
		signal <- struct{}{}
	}
	return current
}

func (clock *scriptedKeepaliveClock) WaitUntil(ctx context.Context, deadline time.Time) (time.Time, error) {
	clock.mu.Lock()
	clock.deadlines = append(clock.deadlines, deadline)
	if err := ctx.Err(); err != nil {
		clock.mu.Unlock()
		return time.Time{}, err
	}
	if len(clock.wakes) == 0 {
		clock.mu.Unlock()
		return time.Time{}, errors.New("no scripted wake")
	}
	wake := clock.wakes[0]
	clock.wakes = clock.wakes[1:]
	clock.current = wake
	var hook func()
	if len(clock.hooks) > 0 {
		hook = clock.hooks[0]
		clock.hooks = clock.hooks[1:]
	}
	clock.mu.Unlock()
	if hook != nil {
		hook()
	}
	return wake, nil
}

func (clock *scriptedKeepaliveClock) advance(duration time.Duration) {
	clock.mu.Lock()
	if clock.current.IsZero() {
		clock.current = clock.start
	}
	clock.current = clock.current.Add(duration)
	clock.mu.Unlock()
}

func (clock *scriptedKeepaliveClock) appendWake(wake time.Time) {
	clock.mu.Lock()
	clock.wakes = append(clock.wakes, wake)
	clock.mu.Unlock()
}

func (clock *scriptedKeepaliveClock) appendWakeHook(wake time.Time, hook func()) {
	clock.mu.Lock()
	clock.wakes = append(clock.wakes, wake)
	clock.hooks = append(clock.hooks, hook)
	clock.mu.Unlock()
}

type directTransportFactory struct {
	transport d200x.Transport
}

type keepaliveCompletionTimingTransport struct {
	*diagnosticTransport
	clock          *scriptedKeepaliveClock
	completionLags []time.Duration
	mu             sync.Mutex
	writeCount     int
}

func (transport *keepaliveCompletionTimingTransport) Write(ctx context.Context, report []byte) (int, error) {
	n, err := transport.diagnosticTransport.Write(ctx, report)
	if err != nil {
		return n, err
	}
	transport.mu.Lock()
	index := transport.writeCount
	transport.writeCount++
	var lag time.Duration
	if index < len(transport.completionLags) {
		lag = transport.completionLags[index]
	}
	transport.mu.Unlock()
	transport.clock.advance(lag)
	return n, nil
}

func (factory *directTransportFactory) Enumerate(context.Context) ([]d200x.Candidate, error) {
	return nil, errors.New("enumeration is not expected")
}

func (factory *directTransportFactory) Open(context.Context, d200x.Candidate) (d200x.Transport, error) {
	return factory.transport, nil
}

type synchronizedReadTransport struct {
	*diagnosticTransport
	readReturned    chan struct{}
	allowReadReturn chan struct{}
	once            sync.Once
}

func (transport *synchronizedReadTransport) Read(ctx context.Context, report []byte) (int, error) {
	n, err := transport.diagnosticTransport.Read(ctx, report)
	transport.once.Do(func() {
		close(transport.readReturned)
		<-transport.allowReadReturn
	})
	return n, err
}

func queueInboundFrame(t *testing.T, transport *diagnosticTransport, frame d200x.Frame) {
	t.Helper()
	reports, err := d200x.EncodeFrame(frame)
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

type finalPairReader struct {
	testing              *testing.T
	transport            *diagnosticTransport
	expectedWrites       int
	expectedInputEnables int
	attestation          EndpointAttestation
	attestationReads     int
	onAttestationRead    func()
	once                 sync.Once
}

type failingObservationWriter struct{}

func (failingObservationWriter) Write([]byte) (int, error) {
	return 0, errors.New("observation write failed")
}

type failAtObservationWriter struct {
	writes int
	failAt int
}

func (writer *failAtObservationWriter) Write(payload []byte) (int, error) {
	writer.writes++
	if writer.writes >= writer.failAt {
		return 0, errors.New("observation write failed")
	}
	return len(payload), nil
}

type finalFramesReader struct {
	testing          *testing.T
	transport        *diagnosticTransport
	frames           []d200x.Frame
	attestationReads int
	once             sync.Once
}

func (reader *finalFramesReader) Read(buffer []byte) (int, error) {
	reader.attestationReads++
	return copy(buffer, string(EndpointActiveAtCue)+"\n"), nil
}

func (reader *finalFramesReader) Close() error {
	return nil
}

func (reader *finalPairReader) Read(buffer []byte) (int, error) {
	reader.attestationReads++
	if reader.onAttestationRead != nil {
		reader.onAttestationRead()
	}
	attestation := reader.attestation
	if attestation == "" {
		attestation = EndpointActiveAtCue
	}
	return copy(buffer, string(attestation)+"\n"), nil
}

func (reader *finalPairReader) Close() error {
	return nil
}

func (reader *finalFramesReader) queueEndpointInput() {
	reader.once.Do(func() {
		for _, frame := range reader.frames {
			queueInboundFrame(reader.testing, reader.transport, frame)
		}
		queueInputPair(reader.testing, reader.transport, 0, d200x.InputMarkerButton)
	})
}

func (reader *finalFramesReader) endpointInputCount() int {
	return len(reader.frames) + 2
}

func (reader *finalPairReader) queueEndpointInput() {
	reader.once.Do(func() {
		writes := reader.transport.writesSnapshot()
		if reader.expectedInputEnables > 0 {
			commands, err := diagnosticCommands(writes)
			if err != nil {
				reader.testing.Fatal(err)
			}
			if got := countCommand(commands, d200x.CommandEnableInputStream); got != reader.expectedInputEnables {
				reader.testing.Fatalf("input-enable writes before endpoint = %d, want %d", got, reader.expectedInputEnables)
			}
		} else if got := len(writes); got != reader.expectedWrites {
			reader.testing.Fatalf("writes before endpoint = %d, want %d", got, reader.expectedWrites)
		}
		queueInputPair(reader.testing, reader.transport, 0, d200x.InputMarkerButton)
	})
}

func (*finalPairReader) endpointInputCount() int {
	return 2
}

type endpointCaptureFailureTransport struct {
	*diagnosticTransport
	failure chan struct{}
	once    sync.Once
}

func newEndpointCaptureFailureTransport(transport *diagnosticTransport) *endpointCaptureFailureTransport {
	return &endpointCaptureFailureTransport{diagnosticTransport: transport, failure: make(chan struct{})}
}

func (transport *endpointCaptureFailureTransport) activate() {
	transport.once.Do(func() { close(transport.failure) })
}

func (transport *endpointCaptureFailureTransport) failed() bool {
	select {
	case <-transport.failure:
		return true
	default:
		return false
	}
}

func failEndpointCapture(t *testing.T, clock *scriptedKeepaliveClock, transport *endpointCaptureFailureTransport, baseTransport *diagnosticTransport) {
	t.Helper()
	processed := make(chan struct{}, 1)
	clock.mu.Lock()
	clock.nowSignal = processed
	clock.mu.Unlock()
	transport.activate()
	queueInboundFrame(t, baseTransport, d200x.BrightnessFrame(50))
	<-processed
	clock.mu.Lock()
	clock.nowSignal = nil
	clock.mu.Unlock()
}

func (transport *endpointCaptureFailureTransport) Read(ctx context.Context, report []byte) (int, error) {
	if transport.failed() {
		return 0, errors.New("endpoint capture terminal failure")
	}
	n, err := transport.diagnosticTransport.Read(ctx, report)
	if transport.failed() {
		return 0, errors.New("endpoint capture terminal failure")
	}
	return n, err
}

func testEndpointCue(clock *scriptedKeepaliveClock, reader io.Reader) EndpointCue {
	return EndpointCueFunc(func(context.Context) error {
		clock.advance(500 * time.Millisecond)
		windowClose := clock.Now().Add(EndpointCaptureWindow)
		queuer, ok := reader.(interface {
			queueEndpointInput()
			endpointInputCount() int
		})
		if !ok {
			clock.appendWake(windowClose)
			return nil
		}
		clock.appendWakeHook(windowClose, func() {
			signals := make(chan struct{}, queuer.endpointInputCount())
			clock.mu.Lock()
			clock.nowSignal = signals
			clock.mu.Unlock()
			queuer.queueEndpointInput()
			for index := 0; index < queuer.endpointInputCount(); index++ {
				<-signals
			}
			clock.mu.Lock()
			clock.nowSignal = nil
			clock.mu.Unlock()
		})
		return nil
	})
}
