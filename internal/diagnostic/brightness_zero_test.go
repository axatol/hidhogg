package diagnostic

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"hidhogg/internal/d200x"
)

func TestBrightnessZeroMatrixTransitionsOnFirstEncoderRotation(t *testing.T) {
	records := brightnessZeroExpectedRecords(10)
	records = append(records, capturedInput{
		boundary: captureBoundary{sequence: 19},
		decoded:  true,
		event: d200x.InputEvent{
			WireIndex: 18,
			Marker:    d200x.InputMarkerEncoder,
			Action:    d200x.InputActionRotatedRight,
		},
	})

	status, transition := evaluateBrightnessZeroMatrix(records)
	if status != StatusPass {
		t.Fatalf("matrix status = %s, want %s", status, StatusPass)
	}
	if transition.sequence != 19 {
		t.Fatalf("transition boundary = %d, want 19", transition.sequence)
	}

	classifier := newBrightnessZeroMatrixClassifier()
	for _, record := range records {
		status, _, _ := classifier.classify(record)
		if status != StatusPass {
			t.Fatalf("record %d status = %s, want %s", record.boundary.sequence, status, StatusPass)
		}
	}
	if classifier.state != brightnessZeroStateEncoderObserved {
		t.Fatalf("matrix state = %d, want encoder-observed", classifier.state)
	}
	status, classification, detail := classifier.classify(capturedInput{
		boundary: captureBoundary{sequence: 20},
		decoded:  true,
		event: d200x.InputEvent{
			WireIndex: 17,
			Marker:    d200x.InputMarkerEncoder,
			Action:    d200x.InputActionPressed,
		},
	})
	if status != StatusClassFailure || classification != inputClassificationWrong {
		t.Fatalf("post-restoration input = %s/%s, want class-failure/wrong-input", status, classification)
	}
	if !strings.Contains(detail, "not zero-state evidence") {
		t.Fatalf("post-restoration detail = %q, want explicit zero-state exclusion", detail)
	}
}

func TestBrightnessZeroEncoderTransitionAllowlist(t *testing.T) {
	for wire := byte(17); wire <= 19; wire++ {
		for _, action := range []d200x.InputAction{d200x.InputActionRotatedLeft, d200x.InputActionRotatedRight} {
			t.Run(fmt.Sprintf("wire-%d-%s", wire, actionName(action)), func(t *testing.T) {
				records := brightnessZeroExpectedRecords(10)
				records = append(records, capturedInput{
					boundary: captureBoundary{sequence: 19},
					decoded:  true,
					event: d200x.InputEvent{
						WireIndex: wire,
						Marker:    d200x.InputMarkerEncoder,
						Action:    action,
					},
				})
				status, transition := evaluateBrightnessZeroMatrixWithAttestation(records, Brightness100Observed)
				if status != StatusPass || transition.sequence != 19 {
					t.Fatalf("matrix result = %s/%d, want pass/19", status, transition.sequence)
				}
			})
		}
	}
	for _, wire := range []byte{16, 20} {
		records := brightnessZeroExpectedRecords(10)
		records = append(records, capturedInput{
			boundary: captureBoundary{sequence: 19},
			decoded:  true,
			event:    d200x.InputEvent{WireIndex: wire, Marker: d200x.InputMarkerEncoder, Action: d200x.InputActionRotatedRight},
		})
		status, transition := evaluateBrightnessZeroMatrixWithAttestation(records, Brightness100Observed)
		if status != StatusClassFailure || transition.sequence != 0 {
			t.Fatalf("wire %d result = %s/%d, want class-failure/no transition", wire, status, transition.sequence)
		}
	}

	records := brightnessZeroExpectedRecords(10)
	rotation := capturedInput{
		boundary: captureBoundary{sequence: 19},
		decoded:  true,
		event:    d200x.InputEvent{WireIndex: 17, Marker: d200x.InputMarkerEncoder, Action: d200x.InputActionRotatedLeft},
	}
	records = append(records, rotation, capturedInput{
		boundary: captureBoundary{sequence: 20},
		decoded:  true,
		event:    d200x.InputEvent{WireIndex: 17, Marker: d200x.InputMarkerEncoder, Action: d200x.InputActionRotatedLeft},
	})
	status, transition := evaluateBrightnessZeroMatrixWithAttestation(records, Brightness100Observed)
	if status != StatusClassFailure || transition.sequence != rotation.boundary.sequence {
		t.Fatalf("duplicate rotation result = %s/%d, want class-failure/%d", status, transition.sequence, rotation.boundary.sequence)
	}
}

func TestBrightnessZeroMatrixRejectsMissingOrPrematureEncoderTransition(t *testing.T) {
	base := brightnessZeroExpectedRecords(10)
	tests := []struct {
		name    string
		records []capturedInput
	}{
		{
			name: "missing transition",
			records: append(append([]capturedInput(nil), base...), capturedInput{
				boundary: captureBoundary{sequence: 19},
				decoded:  true,
				event:    d200x.InputEvent{WireIndex: 17, Marker: d200x.InputMarkerEncoder, Action: d200x.InputActionPressed},
			}),
		},
		{
			name: "premature transition",
			records: append([]capturedInput{
				{boundary: captureBoundary{sequence: 11}, decoded: true, event: d200x.InputEvent{WireIndex: 17, Marker: d200x.InputMarkerEncoder, Action: d200x.InputActionRotatedLeft}},
			}, base...),
		},
		{
			name: "missing persistent input",
			records: append(append([]capturedInput(nil), base[:len(base)-1]...), capturedInput{
				boundary: captureBoundary{sequence: 19},
				decoded:  true,
				event:    d200x.InputEvent{WireIndex: 17, Marker: d200x.InputMarkerEncoder, Action: d200x.InputActionRotatedLeft},
			}),
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			status, transition := evaluateBrightnessZeroMatrix(test.records)
			if status != StatusClassFailure {
				t.Fatalf("matrix status = %s, want %s", status, StatusClassFailure)
			}
			if test.name == "premature transition" && transition.sequence != 11 {
				t.Fatalf("transition boundary = %d, want premature transition at 11", transition.sequence)
			}
			if test.name == "missing persistent input" && transition.sequence != 19 {
				t.Fatalf("transition boundary = %d, want transition at 19", transition.sequence)
			}
			if test.name == "missing transition" && transition.sequence != 0 {
				t.Fatalf("transition boundary = %d, want no accepted transition", transition.sequence)
			}
		})
	}
}

func TestBrightnessZeroObservationUsesRestorationPhaseAfterTransition(t *testing.T) {
	var output bytes.Buffer
	runner := &Runner{
		options:                   Options{Mode: ModeBrightnessZero},
		sink:                      observationSink{writer: &output, limit: 1024},
		brightnessZeroAttestation: Brightness100Observed,
	}
	boundaries := captureObservationBoundaries{
		ready:          captureBoundary{sequence: 1},
		baselineEnd:    captureBoundary{sequence: 3},
		zeroStart:      captureBoundary{sequence: 4},
		zeroEnd:        captureBoundary{sequence: 5},
		phaseEnd:       captureBoundary{sequence: 15},
		encoderRestore: captureBoundary{sequence: 14},
	}
	records := brightnessZeroExpectedRecords(5)
	records = append(records,
		capturedInput{boundary: captureBoundary{sequence: 14}, decoded: true, event: d200x.InputEvent{WireIndex: 18, Marker: d200x.InputMarkerEncoder, Action: d200x.InputActionRotatedLeft}},
		capturedInput{boundary: captureBoundary{sequence: 15}, decoded: true, event: d200x.InputEvent{WireIndex: 18, Marker: d200x.InputMarkerEncoder, Action: d200x.InputActionPressed}},
	)
	runner.observeBrightnessZeroCapturedInputs(records, boundaries)

	var transition Observation
	var postRestoration Observation
	for _, observation := range runner.sink.snapshot() {
		if observation.Sequence == 14 {
			transition = observation
		}
		if observation.Sequence == 15 {
			postRestoration = observation
		}
	}
	if transition.Phase != CapturePhaseRestoreOverlap || transition.Status != StatusPass {
		t.Fatalf("transition observation = %+v, want restoration phase/pass", transition)
	}
	if !strings.Contains(transition.Detail, "restored firmware brightness to 100") || !strings.Contains(transition.Detail, "not zero-state encoder evidence") {
		t.Fatalf("transition detail = %q, want restoration and zero-state exclusion", transition.Detail)
	}
	if postRestoration.Phase != CapturePhaseRestoreOverlap || postRestoration.Status != StatusClassFailure {
		t.Fatalf("post-restoration observation = %+v, want restoration phase/class-failure", postRestoration)
	}
}

func TestBrightnessZeroPostTransitionGapsAreNotInputEvidence(t *testing.T) {
	tests := []struct {
		name       string
		sequence   uint64
		wantPhase  CapturePhase
		wantStatus Status
	}{
		{name: "phase end to restore end", sequence: 16, wantPhase: CapturePhaseRestoreOverlap, wantStatus: StatusInvalidated},
		{name: "restore end to recovery ready", sequence: 18, wantPhase: CapturePhaseTrailing, wantStatus: StatusClassFailure},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			runner := &Runner{
				options:                   Options{Mode: ModeBrightnessZero},
				sink:                      observationSink{writer: &output, limit: 1024},
				brightnessZeroAttestation: Brightness100Observed,
			}
			boundaries := captureObservationBoundaries{
				ready:           captureBoundary{sequence: 1},
				baselineEnd:     captureBoundary{sequence: 3},
				zeroStart:       captureBoundary{sequence: 4},
				zeroEnd:         captureBoundary{sequence: 5},
				phaseEnd:        captureBoundary{sequence: 15},
				encoderRotation: captureBoundary{sequence: 14},
				restoreStart:    captureBoundary{sequence: 16},
				restoreEnd:      captureBoundary{sequence: 17},
				recoveryReady:   captureBoundary{sequence: 20},
				recoveryEnd:     captureBoundary{sequence: 22},
			}
			records := brightnessZeroExpectedRecords(5)
			records = append(records,
				capturedInput{boundary: captureBoundary{sequence: 14}, decoded: true, event: d200x.InputEvent{WireIndex: 18, Marker: d200x.InputMarkerEncoder, Action: d200x.InputActionRotatedRight}},
				capturedInput{boundary: captureBoundary{sequence: test.sequence}, decoded: true, event: d200x.InputEvent{WireIndex: 0, Marker: d200x.InputMarkerButton, Action: d200x.InputActionPressed}},
			)
			runner.observeBrightnessZeroCapturedInputs(records, boundaries)
			var found *Observation
			observations := runner.sink.snapshot()
			for index := range observations {
				observation := observations[index]
				if observation.Sequence == test.sequence {
					found = &observation
					break
				}
			}
			if found == nil {
				t.Fatalf("gap input sequence %d was omitted", test.sequence)
			}
			if found.Phase != test.wantPhase || found.Status != test.wantStatus {
				t.Fatalf("gap input = %+v, want phase/status %s/%s", *found, test.wantPhase, test.wantStatus)
			}
		})
	}
}

func brightnessZeroExpectedRecords(start uint64) []capturedInput {
	expected := brightnessZeroTrace()
	records := make([]capturedInput, 0, len(expected))
	for index, input := range expected {
		records = append(records, capturedInput{
			boundary: captureBoundary{sequence: start + uint64(index) + 1},
			decoded:  true,
			event: d200x.InputEvent{
				WireIndex: input.wire,
				Marker:    input.marker,
				Action:    input.action,
			},
		})
	}
	return records
}

func TestBrightnessZeroAttestationTokensAreClosed(t *testing.T) {
	for _, token := range []BrightnessZeroAttestation{
		Brightness100Observed,
		BrightnessNotObserved,
		BrightnessUncertain,
	} {
		for _, suffix := range []string{"\n", "\r\n"} {
			got, ok := ParseBrightnessZeroAttestation(string(token) + suffix)
			if !ok || got != token {
				t.Fatalf("attestation %q with suffix %q parsed as %q/%t", token, suffix, got, ok)
			}
		}
	}
	for _, line := range []string{
		"",
		"\n",
		" BRIGHTNESS_100_OBSERVED\n",
		"BRIGHTNESS_100_OBSERVED \n",
		"BRIGHTNESS_100_OBSERVED\nextra\n",
		"RESTORED\n",
	} {
		if _, ok := ParseBrightnessZeroAttestation(line); ok {
			t.Fatalf("malformed attestation %q was accepted", line)
		}
	}
}

func TestReadBrightnessZeroAttestationClassifiesAllOutcomes(t *testing.T) {
	tests := []struct {
		name          string
		input         string
		wantToken     BrightnessZeroAttestation
		wantStatus    Status
		wantDetail    string
		wantPrompting bool
	}{
		{name: "observed", input: string(Brightness100Observed) + "\n", wantToken: Brightness100Observed, wantStatus: StatusPass, wantDetail: brightnessZeroAttestationPositive, wantPrompting: true},
		{name: "not observed", input: string(BrightnessNotObserved) + "\n", wantToken: BrightnessNotObserved, wantStatus: StatusClassFailure, wantDetail: brightnessZeroAttestationNegative, wantPrompting: true},
		{name: "uncertain", input: string(BrightnessUncertain) + "\n", wantToken: BrightnessUncertain, wantStatus: StatusIndeterminate, wantDetail: brightnessZeroAttestationUncertain, wantPrompting: true},
		{name: "malformed", input: "RESTORED\n", wantStatus: StatusIndeterminate, wantDetail: brightnessZeroAttestationNotReceived, wantPrompting: true},
		{name: "eof", input: "", wantStatus: StatusIndeterminate, wantDetail: brightnessZeroAttestationNotReceived, wantPrompting: true},
		{name: "partial eof", input: string(Brightness100Observed), wantStatus: StatusIndeterminate, wantDetail: brightnessZeroAttestationNotReceived, wantPrompting: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var prompts bytes.Buffer
			runner := &Runner{
				options: Options{
					Mode:         ModeBrightnessZero,
					PromptWriter: &prompts,
					StageTimeout: time.Second,
				},
				reader: bufio.NewReader(strings.NewReader(test.input)),
			}
			gotToken, gotStatus, gotDetail := runner.readBrightnessZeroAttestation(nil)
			if gotToken != test.wantToken || gotStatus != test.wantStatus || gotDetail != test.wantDetail {
				t.Fatalf("attestation result = %q/%s/%q, want %q/%s/%q", gotToken, gotStatus, gotDetail, test.wantToken, test.wantStatus, test.wantDetail)
			}
			if test.wantPrompting && !strings.Contains(prompts.String(), "BRIGHTNESS_100_OBSERVED, NOT_OBSERVED, or UNCERTAIN") {
				t.Fatalf("prompt = %q, want closed token vocabulary", prompts.String())
			}
		})
	}
}

func TestBrightnessZeroAttestationGatesRestorationClassification(t *testing.T) {
	records := brightnessZeroExpectedRecords(10)
	records = append(records, capturedInput{
		boundary: captureBoundary{sequence: 19},
		decoded:  true,
		event: d200x.InputEvent{
			WireIndex: 18,
			Marker:    d200x.InputMarkerEncoder,
			Action:    d200x.InputActionRotatedRight,
		},
	})
	tests := []struct {
		attestation BrightnessZeroAttestation
		wantStatus  Status
	}{
		{attestation: Brightness100Observed, wantStatus: StatusPass},
		{attestation: BrightnessNotObserved, wantStatus: StatusClassFailure},
		{attestation: BrightnessUncertain, wantStatus: StatusIndeterminate},
		{attestation: "", wantStatus: StatusIndeterminate},
	}
	for _, test := range tests {
		t.Run(string(test.attestation), func(t *testing.T) {
			status, transition := evaluateBrightnessZeroMatrixWithAttestation(records, test.attestation)
			if status != test.wantStatus {
				t.Fatalf("matrix status = %s, want %s", status, test.wantStatus)
			}
			if transition.sequence != 19 {
				t.Fatalf("transition boundary = %d, want 19", transition.sequence)
			}
		})
	}
}

func TestBrightnessZeroAttestationDetailIsArchiveCompatible(t *testing.T) {
	encoded, err := json.Marshal(Observation{
		Event:  "diagnostic",
		Mode:   ModeBrightnessZero,
		Stage:  "brightness-zero-matrix",
		Status: StatusPass,
		Detail: brightnessZeroAttestationPositive,
	})
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &fields); err != nil {
		t.Fatal(err)
	}
	if _, ok := fields["attestation"]; ok {
		t.Fatalf("brightness-zero archive detail unexpectedly added attestation field: %s", encoded)
	}
	var detail string
	if err := json.Unmarshal(fields["detail"], &detail); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(detail, string(Brightness100Observed)) {
		t.Fatalf("archive detail = %q, want positive token", detail)
	}
}
