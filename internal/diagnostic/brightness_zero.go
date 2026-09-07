package diagnostic

import (
	"context"
	"sort"
	"strings"
	"time"

	"hidhogg/internal/d200x"
)

type brightnessZeroMatrixState uint8

const (
	brightnessZeroStatePersisting brightnessZeroMatrixState = iota
	brightnessZeroStateEncoderObserved
	brightnessZeroStateRestoredByEncoder
)

const (
	brightnessZeroAttestationStage       = "brightness-zero-attestation"
	brightnessZeroEncoderRotationDetail  = "encoder rotation was observed; owner attestation is required before firmware restoration is classified"
	brightnessZeroRestorationDetail      = "encoder rotation restored firmware brightness to 100; this transition is not zero-state encoder evidence"
	brightnessZeroPostRestorationDetail  = "input arrived after the encoder rotation transition; it is not zero-state evidence"
	brightnessZeroAttestationPrompt      = "immediately after the single encoder rotation, type exactly one token and press Enter: BRIGHTNESS_100_OBSERVED, NOT_OBSERVED, or UNCERTAIN; do not perform any further input"
	brightnessZeroAttestationPositive    = "attestation=BRIGHTNESS_100_OBSERVED; firmware brightness restoration confirmed"
	brightnessZeroAttestationNegative    = "attestation=NOT_OBSERVED; firmware brightness restoration not confirmed"
	brightnessZeroAttestationUncertain   = "attestation=UNCERTAIN; firmware brightness restoration indeterminate"
	brightnessZeroAttestationNotReceived = "attestation missing or not an exact allowlisted token"
)

type BrightnessZeroAttestation string

const (
	Brightness100Observed BrightnessZeroAttestation = "BRIGHTNESS_100_OBSERVED"
	BrightnessNotObserved BrightnessZeroAttestation = "NOT_OBSERVED"
	BrightnessUncertain   BrightnessZeroAttestation = "UNCERTAIN"
)

func ParseBrightnessZeroAttestation(line string) (BrightnessZeroAttestation, bool) {
	line = strings.TrimSuffix(line, "\n")
	line = strings.TrimSuffix(line, "\r")
	attestation := BrightnessZeroAttestation(line)
	switch attestation {
	case Brightness100Observed, BrightnessNotObserved, BrightnessUncertain:
		return attestation, true
	default:
		return "", false
	}
}

func (attestation BrightnessZeroAttestation) status() Status {
	switch attestation {
	case Brightness100Observed:
		return StatusPass
	case BrightnessNotObserved:
		return StatusClassFailure
	default:
		return StatusIndeterminate
	}
}

func (attestation BrightnessZeroAttestation) detail() string {
	switch attestation {
	case Brightness100Observed:
		return brightnessZeroAttestationPositive
	case BrightnessNotObserved:
		return brightnessZeroAttestationNegative
	case BrightnessUncertain:
		return brightnessZeroAttestationUncertain
	default:
		return brightnessZeroAttestationNotReceived
	}
}

func (runner *Runner) readBrightnessZeroAttestation(ctx context.Context) (BrightnessZeroAttestation, Status, string) {
	if err := runner.prompt(brightnessZeroAttestationPrompt); err != nil {
		return "", StatusIndeterminate, brightnessZeroAttestationNotReceived
	}
	if ctx == nil {
		ctx = context.Background()
	}
	attestationContext, cancel := context.WithTimeout(ctx, runner.options.StageTimeout)
	defer cancel()
	line, err := runner.readLineStrict(attestationContext)
	if err != nil {
		return "", StatusIndeterminate, brightnessZeroAttestationNotReceived
	}
	attestation, ok := ParseBrightnessZeroAttestation(line)
	if !ok {
		return "", StatusIndeterminate, brightnessZeroAttestationNotReceived
	}
	return attestation, attestation.status(), attestation.detail()
}

func (runner *Runner) readLineStrict(ctx context.Context) (string, error) {
	return runner.readLineContext(ctx, false)
}

func brightnessZeroTrace() []expectedInput {
	return []expectedInput{
		{wire: 13, marker: d200x.InputMarkerButton, action: d200x.InputActionPressed},
		{wire: 13, marker: d200x.InputMarkerButton, action: d200x.InputActionReleased},
		{wire: 15, marker: d200x.InputMarkerButton, action: d200x.InputActionPressed},
		{wire: 15, marker: d200x.InputMarkerButton, action: d200x.InputActionReleased},
		{wire: 16, marker: d200x.InputMarkerButton, action: d200x.InputActionPressed},
		{wire: 16, marker: d200x.InputMarkerButton, action: d200x.InputActionReleased},
		{wire: 0, marker: d200x.InputMarkerButton, action: d200x.InputActionPressed},
		{wire: 0, marker: d200x.InputMarkerButton, action: d200x.InputActionReleased},
	}
}

func brightnessZeroMatrixEventCount() int {
	return len(brightnessZeroTrace()) + 1
}

func isBrightnessZeroEncoderRestoration(event d200x.InputEvent) bool {
	return event.Marker == d200x.InputMarkerEncoder &&
		event.WireIndex >= 17 && event.WireIndex <= 19 &&
		(event.Action == d200x.InputActionRotatedLeft || event.Action == d200x.InputActionRotatedRight)
}

type brightnessZeroMatrixClassifier struct {
	expected           []expectedInput
	state              brightnessZeroMatrixState
	cursor             int
	failed             bool
	transitionBoundary captureBoundary
}

func newBrightnessZeroMatrixClassifier() *brightnessZeroMatrixClassifier {
	return &brightnessZeroMatrixClassifier{expected: brightnessZeroTrace(), state: brightnessZeroStatePersisting}
}

func (classifier *brightnessZeroMatrixClassifier) classify(record capturedInput) (Status, string, string) {
	if record.malformed {
		classifier.failed = true
		return StatusClassFailure, inputClassificationMalformed, "malformed input was captured while classifying the brightness-zero matrix"
	}
	if !record.decoded {
		return StatusPass, inputClassificationNonInput, "non-input frame was captured"
	}
	if !record.event.Marker.IsKnown() || !record.event.Action.IsKnown() {
		classifier.failed = true
		return StatusClassFailure, inputClassificationWrong, "input marker or action was unknown"
	}
	if classifier.state == brightnessZeroStateRestoredByEncoder {
		classifier.failed = true
		return StatusClassFailure, inputClassificationWrong, brightnessZeroPostRestorationDetail
	}
	if classifier.state == brightnessZeroStateEncoderObserved {
		classifier.failed = true
		return StatusClassFailure, inputClassificationWrong, brightnessZeroPostRestorationDetail
	}
	if isBrightnessZeroEncoderRestoration(record.event) {
		classifier.state = brightnessZeroStateEncoderObserved
		classifier.transitionBoundary = record.boundary
		if classifier.cursor != len(classifier.expected) {
			classifier.failed = true
			return StatusClassFailure, inputClassificationExpected, "encoder rotation was observed before all zero-persistent inputs were captured; this transition is not zero-state encoder evidence"
		}
		return StatusPass, inputClassificationExpected, brightnessZeroEncoderRotationDetail
	}
	if classifier.cursor < len(classifier.expected) &&
		expectedInputMatches(record.event, classifier.expected[classifier.cursor]) {
		classifier.cursor++
		return StatusPass, inputClassificationExpected, "expected input was captured while brightness remained zero"
	}
	if classifier.cursor > 0 {
		for _, prior := range classifier.expected[:classifier.cursor] {
			if expectedInputMatches(record.event, prior) {
				classifier.failed = true
				return StatusClassFailure, inputClassificationDuplicate, "duplicate input was captured while classifying the brightness-zero matrix"
			}
		}
	}
	classifier.failed = true
	return StatusClassFailure, inputClassificationWrong, "unexpected input was captured before the encoder restoration transition"
}

func (classifier *brightnessZeroMatrixClassifier) result() (Status, captureBoundary) {
	if classifier.failed || classifier.cursor != len(classifier.expected) ||
		(classifier.state != brightnessZeroStateEncoderObserved && classifier.state != brightnessZeroStateRestoredByEncoder) {
		return StatusClassFailure, classifier.transitionBoundary
	}
	return StatusPass, classifier.transitionBoundary
}

func (classifier *brightnessZeroMatrixClassifier) attestedResult(attestation BrightnessZeroAttestation) (Status, captureBoundary) {
	status, boundary := classifier.result()
	if status != StatusPass {
		return status, boundary
	}
	if attestation == Brightness100Observed {
		classifier.state = brightnessZeroStateRestoredByEncoder
		return StatusPass, boundary
	}
	if attestation == BrightnessNotObserved {
		classifier.failed = true
		return StatusClassFailure, boundary
	}
	return StatusIndeterminate, boundary
}

func evaluateBrightnessZeroMatrix(records []capturedInput) (Status, captureBoundary) {
	classifier := newBrightnessZeroMatrixClassifier()
	for _, record := range records {
		classifier.classify(record)
	}
	return classifier.result()
}

func evaluateBrightnessZeroMatrixWithAttestation(records []capturedInput, attestation BrightnessZeroAttestation) (Status, captureBoundary) {
	classifier := newBrightnessZeroMatrixClassifier()
	for _, record := range records {
		classifier.classify(record)
	}
	return classifier.attestedResult(attestation)
}

func brightnessZeroEncoderRotationBoundary(records []capturedInput, after captureBoundary) captureBoundary {
	for _, record := range records {
		if record.boundary.sequence <= after.sequence || !record.decoded || !isBrightnessZeroEncoderRestoration(record.event) {
			continue
		}
		return record.boundary
	}
	return captureBoundary{}
}

func (capture *continuousCapture) waitForBrightnessZeroEncoderRotation(ctx context.Context, after captureBoundary, timeout time.Duration) (captureBoundary, Status) {
	waitContext, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	for {
		if boundary := brightnessZeroEncoderRotationBoundary(capture.snapshot(), after); boundary.sequence > 0 {
			return boundary, StatusPass
		}
		capture.mu.Lock()
		terminal := capture.terminalErr != nil
		stopped := capture.stopped
		health := capture.health
		capture.mu.Unlock()
		if terminal || stopped {
			if ctx.Err() != nil || terminal || health != captureHealthy {
				return captureBoundary{}, StatusIndeterminate
			}
			return captureBoundary{}, StatusClassFailure
		}
		select {
		case <-waitContext.Done():
			if ctx.Err() != nil || capture.healthState() != captureHealthy {
				return captureBoundary{}, StatusIndeterminate
			}
			return captureBoundary{}, StatusClassFailure
		case <-capture.notify:
		}
	}
}

func (boundaries captureObservationBoundaries) inBrightnessZeroMatrix(sequence uint64) bool {
	return boundaries.zeroEnd.sequence > 0 && boundaries.phaseEnd.sequence > boundaries.zeroEnd.sequence &&
		sequence > boundaries.zeroEnd.sequence && sequence <= boundaries.phaseEnd.sequence
}

func (runner *Runner) observeBrightnessZeroCapturedInputs(records []capturedInput, boundaries captureObservationBoundaries) {
	if boundaries.encoderRotation.sequence == 0 {
		_, boundaries.encoderRotation = evaluateBrightnessZeroMatrix(recordsBetween(records, boundaries.zeroEnd, boundaries.phaseEnd))
	}
	ordered := append([]capturedInput(nil), records...)
	sort.SliceStable(ordered, func(left, right int) bool {
		return ordered[left].boundary.sequence < ordered[right].boundary.sequence
	})
	classifier := newBrightnessZeroMatrixClassifier()
	cursors := make(map[CapturePhase]int)
	for _, record := range ordered {
		phase := boundaries.phase(record.boundary.sequence)
		var status Status
		var classification string
		var detail string
		if boundaries.inBrightnessZeroMatrix(record.boundary.sequence) {
			status, classification, detail = classifier.classify(record)
			if classification == inputClassificationExpected && isBrightnessZeroEncoderRestoration(record.event) {
				status, detail = runner.brightnessZeroAttestationOutcome()
			}
		} else {
			cursor := cursors[phase]
			expected := captureExpectedTrace(phase)
			status, classification, detail = classifyCapturedInput(record, phase, expected, &cursor)
			cursors[phase] = cursor
		}
		observation := Observation{
			Event:          "input",
			Mode:           runner.options.Mode,
			Candidate:      runner.options.WakeCandidate,
			Stage:          "captured-input",
			Status:         status,
			InputClass:     classifyInput(record.event),
			Marker:         markerName(record.event.Marker),
			Action:         actionName(record.event.Action),
			Detail:         detail,
			Sequence:       record.boundary.sequence,
			Phase:          phase,
			Decoded:        record.decoded,
			Malformed:      record.malformed,
			Classification: classification,
			Boundary:       record.boundary.sequence,
		}
		if record.decoded {
			wireIndex := int(record.event.WireIndex)
			observation.WireIndex = &wireIndex
		}
		runner.observe(observation)
	}
}

func (runner *Runner) brightnessZeroAttestationOutcome() (Status, string) {
	switch runner.brightnessZeroAttestation {
	case Brightness100Observed:
		return StatusPass, brightnessZeroRestorationDetail
	case BrightnessNotObserved:
		return StatusClassFailure, brightnessZeroAttestationNegative + "; this transition is not zero-state encoder evidence"
	case BrightnessUncertain:
		return StatusIndeterminate, brightnessZeroAttestationUncertain + "; this transition is not zero-state encoder evidence"
	default:
		return StatusIndeterminate, brightnessZeroAttestationNotReceived + "; this transition is not zero-state encoder evidence"
	}
}
