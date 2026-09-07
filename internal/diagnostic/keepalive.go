package diagnostic

import (
	"context"
	"errors"
	"time"

	"hidhogg/internal/d200x"
)

const (
	EndpointCloseTolerance     = 250 * time.Millisecond
	KeepaliveBoundaryTolerance = 250 * time.Millisecond

	maximumKeepaliveBoundaries = 48
	maximumKeepaliveDuration   = 60 * time.Minute
	keepaliveK150Interval      = 50 * time.Second
	keepaliveK150Duration      = 200 * time.Second

	keepaliveStartStage      = "keepalive-prevention-start"
	keepaliveBoundaryStage   = "keepalive-prevention-boundary"
	keepaliveScheduleStage   = "keepalive-prevention-schedule"
	keepaliveCueStage        = "keepalive-prevention-endpoint-cue"
	keepaliveFinalStage      = "keepalive-prevention-final-verification"
	keepaliveResultStage     = "keepalive-prevention-result"
	keepaliveInputStage      = "keepalive-prevention-input"
	keepaliveInputClass      = "observed"
	keepaliveInputMalformed  = "malformed"
	keepaliveInputNonInput   = "non-input"
	keepaliveInputUnexpected = "unexpected"
	keepaliveInputPreCue     = "pre-cue"
	keepaliveInputPostWindow = "post-window"
	keepaliveHealthStage     = "keepalive-prevention-capture-health"
)

const (
	keepaliveTimingContractK150V1 = "k1-50-v1"
	KeepaliveTimingContractK150V1 = keepaliveTimingContractK150V1
)

const keepaliveInputPreCueDetail = "pre-cue observation retained outside endpoint classification"

// KeepaliveClock supplies monotonic scheduling points for the diagnostic. A
// wait reports its actual wake time. Waking before the requested deadline or
// at or after the next interval boundary invalidates the run; wake jitter
// within those two boundaries is accepted.
type KeepaliveClock interface {
	Now() time.Time
	WaitUntil(context.Context, time.Time) (time.Time, error)
}

func keepaliveTimingContractForSchedule(interval, duration time.Duration) string {
	if interval == keepaliveK150Interval && duration == keepaliveK150Duration {
		return keepaliveTimingContractK150V1
	}
	return ""
}

type keepaliveBoundaryTiming struct {
	scheduleStart   time.Time
	planned         time.Time
	wake            time.Time
	writeStart      time.Time
	writeCompletion time.Time
}

func keepaliveBoundaryTimingValid(timing keepaliveBoundaryTiming) bool {
	if timing.scheduleStart.IsZero() || timing.planned.IsZero() || timing.wake.IsZero() ||
		timing.writeStart.IsZero() || timing.writeCompletion.IsZero() {
		return false
	}
	latest := timing.planned.Add(KeepaliveBoundaryTolerance)
	return !timing.planned.Before(timing.scheduleStart) &&
		!timing.wake.Before(timing.planned) &&
		!timing.writeStart.Before(timing.wake) &&
		!timing.writeCompletion.Before(timing.writeStart) &&
		!timing.writeCompletion.After(latest)
}

func keepaliveScheduleBoundaries(interval, duration time.Duration) (int64, error) {
	if interval <= 0 {
		return 0, ErrInvalidKeepaliveInterval
	}
	if duration <= 0 {
		return 0, ErrInvalidKeepaliveDuration
	}
	if duration > maximumKeepaliveDuration {
		return 0, ErrKeepaliveDurationTooLong
	}
	if duration%4 != 0 || interval != duration/4 {
		return 0, ErrKeepaliveScheduleMismatch
	}
	boundaries := int64(duration / interval)
	if boundaries == 0 {
		return 0, ErrKeepaliveScheduleEmpty
	}
	if boundaries > maximumKeepaliveBoundaries {
		return 0, ErrKeepaliveScheduleTooLong
	}
	return boundaries, nil
}

// ValidateKeepaliveSchedule checks the closed K1 duration contract without
// constructing a runner or touching a transport.
func ValidateKeepaliveSchedule(interval, duration time.Duration) error {
	_, err := keepaliveScheduleBoundaries(interval, duration)
	return err
}

type wallKeepaliveClock struct{}

func (wallKeepaliveClock) Now() time.Time {
	return time.Now()
}

func (wallKeepaliveClock) WaitUntil(ctx context.Context, deadline time.Time) (time.Time, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	delay := time.Until(deadline)
	if delay <= 0 {
		if err := ctx.Err(); err != nil {
			return time.Time{}, err
		}
		return time.Now(), nil
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return time.Time{}, ctx.Err()
	case <-timer.C:
		return time.Now(), nil
	}
}

func (runner *Runner) runKeepalivePrevention(ctx context.Context, session *d200x.Session) (runErr error) {
	clock := runner.options.KeepaliveClock
	if clock == nil {
		clock = wallKeepaliveClock{}
	}
	start := clock.Now()
	if start.IsZero() {
		if err := runner.recordKeepaliveStages(
			keepaliveStageObservation{keepaliveScheduleStage, StatusIndeterminate, "monotonic scheduler did not provide a start time", 0},
			keepaliveStageObservation{keepaliveFinalStage, StatusNotRun, "final input verification was not reached", 0},
			keepaliveStageObservation{keepaliveResultStage, StatusIndeterminate, "keepalive schedule could not start", 0},
		); err != nil {
			return safeOperationError("write diagnostic observation", err)
		}
		return errors.New("keepalive schedule could not start")
	}
	prospectiveTiming := runner.options.KeepaliveTimingContract == keepaliveTimingContractK150V1
	var lastBoundaryCompletion time.Time

	capture := newContinuousCapture(clock.Now)
	idleStart := capture.markSequenceBoundary()
	var idleEnd captureBoundary
	var cueStart captureBoundary
	captureContext, stopCaptureContext := context.WithCancel(ctx)
	go capture.run(captureContext, session)
	captureStopped := false
	var captureStop captureBoundary
	inputsObserved := false
	var captured []capturedInput
	stopCapture := func() {
		if captureStopped {
			return
		}
		stopCaptureContext()
		<-capture.done
		captured = capture.snapshot()
		captureStop = capture.stopBoundary()
		captureStopped = true
	}
	defer func() {
		stopCapture()
		if idleEnd.sequence == 0 {
			idleEnd = capture.markSequenceBoundary()
		}
		if inputsObserved {
			return
		}
		if err := runner.observeKeepaliveInputs(captured, idleStart, idleEnd, cueStart, start, time.Time{}); err != nil && runErr == nil {
			runErr = safeOperationError("write diagnostic observation", err)
		}
	}()
	invalidateIdleInput := func(boundary uint64) error {
		if err := runner.recordKeepaliveStages(
			keepaliveStageObservation{keepaliveScheduleStage, StatusInvalidated, "inbound frame invalidated the idle interval", boundary},
			keepaliveStageObservation{keepaliveFinalStage, StatusNotRun, "final input verification was withheld after idle activity", boundary},
			keepaliveStageObservation{keepaliveResultStage, StatusInvalidated, "keepalive prevention requires a frame-free idle interval", boundary},
		); err != nil {
			return safeOperationError("write diagnostic observation", err)
		}
		runner.addCritical(StatusInvalidated)
		stopCapture()
		idleEnd = capture.markSequenceBoundary()
		if err := runner.observeKeepaliveInputs(captured, idleStart, idleEnd, cueStart, start, time.Time{}); err != nil {
			inputsObserved = true
			return safeOperationError("write diagnostic observation", err)
		}
		inputsObserved = true
		return nil
	}
	checkedHealth := func(checkpoint string, boundary uint64) captureHealth {
		health := capture.healthState()
		if runner.keepaliveHealthTest != nil {
			return runner.keepaliveHealthTest(checkpoint, boundary, health)
		}
		return health
	}
	stopForCaptureHealth := func(boundary uint64, health captureHealth) error {
		stopCapture()
		idleEnd = capture.markSequenceBoundary()
		if err := runner.observeKeepaliveHealth(StatusIndeterminate, health, boundary); err != nil {
			return safeOperationError("write diagnostic observation", err)
		}
		if err := runner.recordKeepaliveStages(
			keepaliveStageObservation{keepaliveScheduleStage, StatusIndeterminate, "input capture became unhealthy; no further experimental action was attempted", boundary},
			keepaliveStageObservation{keepaliveFinalStage, StatusNotRun, "final input verification was withheld after capture failure", boundary},
			keepaliveStageObservation{keepaliveResultStage, StatusIndeterminate, "capture health did not satisfy the closed protocol", boundary},
		); err != nil {
			return safeOperationError("write diagnostic observation", err)
		}
		runner.addCritical(StatusIndeterminate)
		if err := runner.observeKeepaliveInputs(captured, idleStart, idleEnd, cueStart, start, time.Time{}); err != nil {
			inputsObserved = true
			return safeOperationError("write diagnostic observation", err)
		}
		inputsObserved = true
		return nil
	}

	if err := runner.observe(Observation{
		Event:  "diagnostic",
		Mode:   runner.options.Mode,
		Stage:  keepaliveStartStage,
		Status: StatusPass,
		Detail: "one HID session started with a monotonic keepalive schedule",
	}); err != nil {
		return safeOperationError("write diagnostic observation", err)
	}
	runner.addCritical(StatusPass)

	boundaryCount := runner.keepaliveBoundaries
	for boundary := int64(1); boundary <= boundaryCount; boundary++ {
		deadline := start.Add(time.Duration(boundary) * runner.options.KeepaliveInterval)
		wake, err := clock.WaitUntil(ctx, deadline)
		if err != nil {
			status := StatusIndeterminate
			if ctx.Err() == nil {
				status = StatusInvalidated
			}
			if observationErr := runner.recordKeepaliveStages(
				keepaliveStageObservation{keepaliveScheduleStage, status, "scheduled boundary did not complete", uint64(boundary)},
				keepaliveStageObservation{keepaliveFinalStage, StatusNotRun, "final input verification was not reached", uint64(boundary)},
				keepaliveStageObservation{keepaliveResultStage, status, "keepalive schedule stopped before completion", uint64(boundary)},
			); observationErr != nil {
				return safeOperationError("write diagnostic observation", observationErr)
			}
			runner.addCritical(status)
			if ctx.Err() != nil {
				return safeOperationError("run keepalive-prevention diagnostic", ctx.Err())
			}
			return nil
		}
		nextDeadline := start.Add(time.Duration(boundary+1) * runner.options.KeepaliveInterval)
		missedBoundary := wake.Before(deadline) || !wake.Before(nextDeadline)
		boundaryTiming := keepaliveBoundaryTiming{
			scheduleStart: start,
			planned:       deadline,
			wake:          wake,
		}
		if prospectiveTiming {
			if !keepaliveBoundaryWakeTimingValid(boundaryTiming) {
				return runner.recordKeepaliveTimingInvalidation(uint64(boundary), boundaryTiming, "boundary timing was early, late, or inconsistent")
			}
		} else if missedBoundary {
			if err := runner.recordKeepaliveStages(
				keepaliveStageObservation{keepaliveBoundaryStage, StatusInvalidated, "scheduled boundary was missed; no catch-up write was attempted", uint64(boundary)},
				keepaliveStageObservation{keepaliveScheduleStage, StatusInvalidated, "keepalive schedule was invalidated at or beyond the next boundary", uint64(boundary)},
				keepaliveStageObservation{keepaliveFinalStage, StatusNotRun, "final input verification was not reached", uint64(boundary)},
				keepaliveStageObservation{keepaliveResultStage, StatusInvalidated, "keepalive schedule stopped without retry or catch-up", uint64(boundary)},
			); err != nil {
				return safeOperationError("write diagnostic observation", err)
			}
			runner.addCritical(StatusInvalidated)
			return nil
		}
		inspectionEnd := capture.markSequenceBoundary()
		if recordsBetweenExist(capture.snapshot(), idleStart, inspectionEnd) {
			return invalidateIdleInput(uint64(boundary - 1))
		}
		preWriteHealth := checkedHealth("before-write", uint64(boundary))
		if preWriteHealth != captureHealthy {
			return stopForCaptureHealth(uint64(boundary-1), preWriteHealth)
		}
		if prospectiveTiming {
			boundaryTiming.writeStart = clock.Now()
			if !keepaliveBoundaryWriteStartTimingValid(boundaryTiming) {
				return runner.recordKeepaliveTimingInvalidation(uint64(boundary), boundaryTiming, "write invocation start was early, late, or inconsistent")
			}
		}
		if err := session.SendFrame(ctx, d200x.EnableInputStreamFrame()); err != nil {
			if prospectiveTiming {
				if observationErr := runner.observeKeepaliveBoundary(StatusIndeterminate, "enable-input-stream write was failed, short, or uncertain; no retry was attempted", uint64(boundary), boundaryTiming); observationErr != nil {
					return safeOperationError("write diagnostic observation", observationErr)
				}
				if observationErr := runner.recordKeepaliveStages(
					keepaliveStageObservation{keepaliveScheduleStage, StatusIndeterminate, "keepalive schedule stopped after one invalidated write", uint64(boundary)},
					keepaliveStageObservation{keepaliveFinalStage, StatusNotRun, "final input verification was not reached", uint64(boundary)},
					keepaliveStageObservation{keepaliveResultStage, StatusIndeterminate, "keepalive schedule stopped after one invalidated write", uint64(boundary)},
				); observationErr != nil {
					return safeOperationError("write diagnostic observation", observationErr)
				}
			} else if observationErr := runner.recordKeepaliveStages(
				keepaliveStageObservation{keepaliveBoundaryStage, StatusIndeterminate, "enable-input-stream write was failed, short, or uncertain; no retry was attempted", uint64(boundary)},
				keepaliveStageObservation{keepaliveScheduleStage, StatusIndeterminate, "keepalive schedule stopped after one invalidated write", uint64(boundary)},
				keepaliveStageObservation{keepaliveFinalStage, StatusNotRun, "final input verification was not reached", uint64(boundary)},
				keepaliveStageObservation{keepaliveResultStage, StatusIndeterminate, "keepalive schedule stopped after one invalidated write", uint64(boundary)},
			); observationErr != nil {
				return safeOperationError("write diagnostic observation", observationErr)
			}
			runner.addCritical(StatusIndeterminate)
			return safeOperationError("write keepalive input-enable frame", err)
		}
		if prospectiveTiming {
			boundaryTiming.writeCompletion = clock.Now()
		}
		postWriteHealth := checkedHealth("after-write", uint64(boundary))
		if postWriteHealth != captureHealthy {
			return stopForCaptureHealth(uint64(boundary), postWriteHealth)
		}
		if prospectiveTiming && !keepaliveBoundaryTimingValid(boundaryTiming) {
			return runner.recordKeepaliveTimingInvalidation(uint64(boundary), boundaryTiming, "boundary timing was reordered, late, or affected by a clock anomaly")
		}
		if err := runner.observeKeepaliveBoundary(StatusPass, "one enable-input-stream frame sent at the scheduled boundary", uint64(boundary), boundaryTiming); err != nil {
			return safeOperationError("write diagnostic observation", err)
		}
		runner.addCritical(StatusPass)
		if prospectiveTiming {
			lastBoundaryCompletion = boundaryTiming.writeCompletion
		}
	}

	idleEnd = capture.markBoundary()
	if recordsBetweenExist(capture.snapshot(), idleStart, idleEnd) {
		return invalidateIdleInput(uint64(boundaryCount))
	}
	if err := runner.recordKeepaliveStage(keepaliveScheduleStage, StatusPass, "duration completed after all scheduled input-enable boundaries exactly once", uint64(boundaryCount)); err != nil {
		return safeOperationError("write diagnostic observation", err)
	}
	runner.addCritical(StatusPass)
	preCueHealth := checkedHealth("before-cue", uint64(boundaryCount))
	if preCueHealth != captureHealthy {
		return stopForCaptureHealth(uint64(boundaryCount), preCueHealth)
	}
	if err := runner.observeKeepaliveHealth(StatusPass, captureHealthy, uint64(boundaryCount)); err != nil {
		return safeOperationError("write diagnostic observation", err)
	}
	preCueHealth = checkedHealth("before-cue-commit", uint64(boundaryCount))
	if preCueHealth != captureHealthy {
		return stopForCaptureHealth(uint64(boundaryCount), preCueHealth)
	}

	cueStart = capture.markBoundary()
	if prospectiveTiming && (lastBoundaryCompletion.IsZero() || cueStart.moment.IsZero() || cueStart.moment.Before(lastBoundaryCompletion)) {
		if err := runner.recordKeepaliveStages(
			keepaliveStageObservation{keepaliveFinalStage, StatusNotRun, "endpoint cue was withheld because the fourth write completed after the fresh cue boundary", uint64(boundaryCount)},
			keepaliveStageObservation{keepaliveResultStage, StatusInvalidated, "fourth write completion did not precede the fresh endpoint cue boundary", uint64(boundaryCount)},
		); err != nil {
			return safeOperationError("write diagnostic observation", err)
		}
		runner.addCritical(StatusInvalidated)
		return nil
	}
	cueErr := RunEndpointCue(ctx, runner.options.EndpointCue)
	cueCompletion := capture.markBoundary()
	cueDuration, cueTimingOK := elapsedDuration(cueStart.moment, cueCompletion.moment)
	if cueErr != nil || !cueTimingOK || cueDuration < 0 || cueDuration > EndpointCueTimeout {
		stopCapture()
		if err := runner.observeKeepaliveCue(StatusInvalidated, start, cueStart, cueCompletion); err != nil {
			return safeOperationError("write diagnostic observation", err)
		}
		if err := runner.observeKeepaliveInputs(captured, idleStart, idleEnd, cueStart, start, time.Time{}); err != nil {
			inputsObserved = true
			return safeOperationError("write diagnostic observation", err)
		}
		inputsObserved = true
		if err := runner.recordKeepaliveStages(
			keepaliveStageObservation{keepaliveFinalStage, StatusNotRun, "endpoint capture window was not opened", uint64(boundaryCount)},
			keepaliveStageObservation{keepaliveResultStage, StatusInvalidated, "endpoint cue did not complete within the fixed limit", uint64(boundaryCount)},
		); err != nil {
			return safeOperationError("write diagnostic observation", err)
		}
		runner.addCritical(StatusInvalidated)
		if ctx.Err() != nil {
			return safeOperationError("run keepalive endpoint cue", ctx.Err())
		}
		return nil
	}

	plannedClose := cueCompletion.moment.Add(EndpointCaptureWindow)
	actualWake, waitErr := clock.WaitUntil(ctx, plannedClose)
	stopCapture()
	captureHealth := capture.healthState()
	captureFailed := captureHealth != captureHealthy
	if captureFailed {
		if err := runner.observeKeepaliveHealth(StatusIndeterminate, captureHealth, uint64(boundaryCount)); err != nil {
			return safeOperationError("write diagnostic observation", err)
		}
	}
	timingValid := waitErr == nil && validateEndpointCloseTiming(plannedClose, actualWake, captureStop.moment)

	var attestation EndpointAttestation
	attestationOK := false
	var attestationErr error
	if timingValid && ctx.Err() == nil {
		if err := runner.prompt("enter exactly ACTIVE_AT_CUE, SCREENSAVER_AT_CUE, or UNCERTAIN"); err != nil {
			attestationErr = err
		} else {
			var attestationLine string
			attestationLine, attestationErr = runner.readLine(ctx)
			attestation, attestationOK = ParseEndpointAttestation(attestationLine)
		}
	} else if ctx.Err() != nil {
		attestationErr = ctx.Err()
	}

	if err := runner.observeKeepaliveCue(StatusPass, start, cueStart, cueCompletion); err != nil {
		return safeOperationError("write diagnostic observation", err)
	}
	if err := runner.observeKeepaliveInputs(captured, idleStart, idleEnd, cueStart, start, plannedClose); err != nil {
		inputsObserved = true
		return safeOperationError("write diagnostic observation", err)
	}
	inputsObserved = true
	windowRecords := recordsWithinLogicalWindow(recordsBetween(captured, cueStart, captureStop), cueStart.moment, plannedClose)
	finalStatus := classifyKeepaliveEndpoint(timingValid, !captureFailed, attestation, attestationErr == nil && attestationOK, windowRecords, cueStart.moment, plannedClose)
	if runner.keepaliveCommitTest != nil {
		runner.keepaliveCommitTest("before-endpoint")
	}
	commitCancellation := ctx.Err()
	if commitCancellation != nil && finalStatus == StatusPass {
		finalStatus = StatusIndeterminate
	}
	finalDetail := "active-at-cue attestation and one canonical 0_0 pair were verified in the endpoint window"
	switch finalStatus {
	case StatusInvalidated:
		finalDetail = "endpoint timing did not satisfy the planned-close tolerance"
	case StatusIndeterminate:
		finalDetail = "endpoint capture health or visual attestation was indeterminate"
	case StatusClassFailure:
		finalDetail = "endpoint attestation or timed canonical input did not satisfy the closed protocol"
	}
	if err := runner.observeKeepaliveEndpoint(finalStatus, finalDetail, attestation, start, cueStart, cueCompletion, plannedClose, actualWake, captureStop, uint64(boundaryCount)); err != nil {
		return safeOperationError("write diagnostic observation", err)
	}
	if runner.keepaliveCommitTest != nil {
		runner.keepaliveCommitTest("between-endpoint-result")
	}
	if err := ctx.Err(); err != nil {
		commitCancellation = err
		if finalStatus == StatusPass {
			finalStatus = StatusIndeterminate
		}
	}
	if err := runner.recordKeepaliveStage(keepaliveResultStage, finalStatus, "keepalive prevention requires the coupled visual and canonical-input endpoint", uint64(boundaryCount)); err != nil {
		return safeOperationError("write diagnostic observation", err)
	}
	runner.addCritical(finalStatus)
	if runner.keepaliveCommitTest != nil {
		runner.keepaliveCommitTest("after-result")
	}
	if commitCancellation != nil {
		return safeOperationError("run keepalive endpoint window", commitCancellation)
	}
	return nil
}

func (runner *Runner) observeKeepaliveBoundary(status Status, detail string, boundary uint64, timingValues ...keepaliveBoundaryTiming) error {
	var timing keepaliveBoundaryTiming
	if len(timingValues) > 0 {
		timing = timingValues[0]
	}
	observation := Observation{
		Event:    "diagnostic",
		Mode:     runner.options.Mode,
		Stage:    keepaliveBoundaryStage,
		Status:   status,
		Command:  d200x.CommandEnableInputStream.String(),
		Detail:   detail,
		Boundary: boundary,
	}
	if timingContract := runner.options.KeepaliveTimingContract; timingContract != "" {
		observation.TimingContract = timingContract
		observation.PlannedBoundaryElapsedNS = elapsedNanoseconds(timing.scheduleStart, timing.planned)
		observation.ActualTimerWakeNS = elapsedNanoseconds(timing.scheduleStart, timing.wake)
		observation.WriteStartElapsedNS = elapsedNanoseconds(timing.scheduleStart, timing.writeStart)
		observation.WriteCompletionElapsedNS = elapsedNanoseconds(timing.scheduleStart, timing.writeCompletion)
	}
	return runner.observe(observation)
}

func (runner *Runner) observeKeepaliveHealth(status Status, health captureHealth, boundary uint64) error {
	return runner.observe(Observation{
		Event:          "diagnostic",
		Mode:           runner.options.Mode,
		Stage:          keepaliveHealthStage,
		Status:         status,
		Detail:         "capture health checked without retaining transport or device identity",
		Classification: string(health),
		Boundary:       boundary,
	})
}

func (runner *Runner) recordKeepaliveStage(stage string, status Status, detail string, boundary uint64) error {
	return runner.observe(Observation{
		Event:    "diagnostic",
		Mode:     runner.options.Mode,
		Stage:    stage,
		Status:   status,
		Detail:   detail,
		Boundary: boundary,
	})
}

type keepaliveStageObservation struct {
	stage    string
	status   Status
	detail   string
	boundary uint64
}

func (runner *Runner) recordKeepaliveStages(observations ...keepaliveStageObservation) error {
	for _, observation := range observations {
		if err := runner.recordKeepaliveStage(observation.stage, observation.status, observation.detail, observation.boundary); err != nil {
			return err
		}
	}
	return nil
}

func keepaliveBoundaryWakeTimingValid(timing keepaliveBoundaryTiming) bool {
	if timing.scheduleStart.IsZero() || timing.planned.IsZero() || timing.wake.IsZero() {
		return false
	}
	latest := timing.planned.Add(KeepaliveBoundaryTolerance)
	return !timing.planned.Before(timing.scheduleStart) &&
		!timing.wake.Before(timing.planned) &&
		!timing.wake.After(latest)
}

func keepaliveBoundaryWriteStartTimingValid(timing keepaliveBoundaryTiming) bool {
	if !keepaliveBoundaryWakeTimingValid(timing) || timing.writeStart.IsZero() {
		return false
	}
	latest := timing.planned.Add(KeepaliveBoundaryTolerance)
	return !timing.writeStart.Before(timing.wake) && !timing.writeStart.After(latest)
}

func (runner *Runner) recordKeepaliveTimingInvalidation(boundary uint64, timing keepaliveBoundaryTiming, detail string) error {
	if err := runner.observeKeepaliveBoundary(StatusInvalidated, detail, boundary, timing); err != nil {
		return safeOperationError("write diagnostic observation", err)
	}
	if err := runner.recordKeepaliveStages(
		keepaliveStageObservation{keepaliveScheduleStage, StatusInvalidated, "keepalive schedule stopped after invalid boundary timing", boundary},
		keepaliveStageObservation{keepaliveFinalStage, StatusNotRun, "final input verification was not reached", boundary},
		keepaliveStageObservation{keepaliveResultStage, StatusInvalidated, "keepalive schedule stopped without retry or catch-up", boundary},
	); err != nil {
		return safeOperationError("write diagnostic observation", err)
	}
	runner.addCritical(StatusInvalidated)
	return nil
}

func validateKeepaliveFinal(records []capturedInput) Status {
	expected := baselineTrace()
	if len(records) != len(expected) {
		return StatusClassFailure
	}
	for index, record := range records {
		if record.malformed || !record.decoded || !record.event.Marker.IsKnown() || !record.event.Action.IsKnown() {
			return StatusClassFailure
		}
		want := expected[index]
		if record.event.WireIndex != want.wire || record.event.Marker != want.marker || record.event.Action != want.action {
			return StatusClassFailure
		}
	}
	return StatusPass
}

func validateKeepaliveEndpoint(records []capturedInput, windowStart, windowClose time.Time) Status {
	if validateKeepaliveFinal(records) != StatusPass {
		return StatusClassFailure
	}
	for _, record := range records {
		if record.boundary.moment.IsZero() || record.boundary.moment.Before(windowStart) || record.boundary.moment.After(windowClose) {
			return StatusClassFailure
		}
	}
	return StatusPass
}

func recordsWithinLogicalWindow(records []capturedInput, windowStart, plannedClose time.Time) []capturedInput {
	windowRecords := make([]capturedInput, 0, len(records))
	for _, record := range records {
		if record.boundary.moment.Before(windowStart) || record.boundary.moment.After(plannedClose) {
			continue
		}
		windowRecords = append(windowRecords, record)
	}
	return windowRecords
}

func validateEndpointCloseTiming(plannedClose, actualWake, actualStop time.Time) bool {
	if plannedClose.IsZero() || actualWake.IsZero() || actualStop.IsZero() {
		return false
	}
	latest := plannedClose.Add(EndpointCloseTolerance)
	return !actualWake.Before(plannedClose) && !actualWake.After(latest) &&
		!actualStop.Before(actualWake) && !actualStop.After(latest)
}

func classifyKeepaliveEndpoint(timingValid, captureHealthy bool, attestation EndpointAttestation, attestationValid bool, records []capturedInput, windowStart, plannedClose time.Time) Status {
	if !timingValid {
		return StatusInvalidated
	}
	if !captureHealthy || !attestationValid || attestation == EndpointUncertain {
		return StatusIndeterminate
	}
	if attestation == EndpointScreensaverAtCue {
		return StatusClassFailure
	}
	if attestation == EndpointActiveAtCue && validateKeepaliveEndpoint(records, windowStart, plannedClose) == StatusPass {
		return StatusPass
	}
	return StatusClassFailure
}

func elapsedDuration(start, end time.Time) (time.Duration, bool) {
	if start.IsZero() || end.IsZero() || end.Before(start) {
		return 0, false
	}
	return end.Sub(start), true
}

func elapsedNanoseconds(start, end time.Time) int64 {
	elapsed, ok := elapsedDuration(start, end)
	if !ok {
		return 0
	}
	return int64(elapsed)
}

func (runner *Runner) observeKeepaliveCue(status Status, scheduleStart time.Time, cueStart, cueCompletion captureBoundary) error {
	return runner.observe(Observation{
		Event:                  "diagnostic",
		Mode:                   runner.options.Mode,
		Stage:                  keepaliveCueStage,
		Status:                 status,
		Detail:                 "fixed local endpoint cue executed once without a shell",
		Boundary:               uint64(runner.keepaliveBoundaries),
		CueStartElapsedNS:      elapsedNanoseconds(scheduleStart, cueStart.moment),
		CueCompletionElapsedNS: elapsedNanoseconds(scheduleStart, cueCompletion.moment),
		CueDurationNS:          elapsedNanoseconds(cueStart.moment, cueCompletion.moment),
	})
}

func (runner *Runner) observeKeepaliveEndpoint(status Status, detail string, attestation EndpointAttestation, scheduleStart time.Time, cueStart, cueCompletion captureBoundary, plannedClose, actualWake time.Time, captureStop captureBoundary, boundary uint64) error {
	return runner.observe(Observation{
		Event:                  "diagnostic",
		Mode:                   runner.options.Mode,
		Stage:                  keepaliveFinalStage,
		Status:                 status,
		Detail:                 detail,
		Boundary:               boundary,
		Attestation:            attestation,
		WindowStartElapsedNS:   elapsedNanoseconds(scheduleStart, cueStart.moment),
		PlannedCloseElapsedNS:  elapsedNanoseconds(scheduleStart, plannedClose),
		ActualTimerWakeNS:      elapsedNanoseconds(scheduleStart, actualWake),
		ActualCaptureStopNS:    elapsedNanoseconds(scheduleStart, captureStop.moment),
		WindowDurationNS:       elapsedNanoseconds(cueStart.moment, plannedClose),
		CueCompletionElapsedNS: elapsedNanoseconds(scheduleStart, cueCompletion.moment),
	})
}

func (runner *Runner) observeKeepaliveInputs(records []capturedInput, idleStart, idleEnd, cueStart captureBoundary, scheduleStart, plannedClose time.Time) error {
	for _, record := range records {
		status := StatusPass
		classification := keepaliveInputClass
		detail := "bounded input observation retained"
		if record.malformed {
			status = StatusClassFailure
			classification = keepaliveInputMalformed
			detail = "malformed input observation retained without raw payload"
		} else if !record.decoded {
			classification = keepaliveInputNonInput
			detail = "non-input frame observation retained without raw payload"
		} else if !record.event.Marker.IsKnown() || !record.event.Action.IsKnown() {
			status = StatusClassFailure
			classification = keepaliveInputUnexpected
			detail = "unknown input observation retained without raw payload"
		}
		if record.boundary.sequence > idleStart.sequence && record.boundary.sequence <= idleEnd.sequence {
			status = StatusInvalidated
			detail = "inbound frame invalidated the frame-free idle interval"
		} else if record.boundary.sequence > idleEnd.sequence && record.boundary.sequence <= cueStart.sequence {
			status = StatusPass
			classification = keepaliveInputPreCue
			detail = keepaliveInputPreCueDetail
		} else if !plannedClose.IsZero() && record.boundary.moment.After(plannedClose) {
			status = StatusPass
			classification = keepaliveInputPostWindow
			detail = "post-window observation retained outside endpoint classification"
		}
		observation := Observation{
			Event:          "input",
			Mode:           runner.options.Mode,
			Stage:          keepaliveInputStage,
			Status:         status,
			InputClass:     classifyInput(record.event),
			Marker:         markerName(record.event.Marker),
			Action:         actionName(record.event.Action),
			Detail:         detail,
			Sequence:       record.boundary.sequence,
			Decoded:        record.decoded,
			Malformed:      record.malformed,
			Classification: classification,
			Boundary:       record.boundary.sequence,
			InputElapsedNS: elapsedNanoseconds(scheduleStart, record.boundary.moment),
		}
		if !record.decoded || record.malformed {
			observation.Marker = "unknown"
			observation.Action = "unknown"
		}
		if record.decoded && !record.malformed {
			wireIndex := int(record.event.WireIndex)
			observation.WireIndex = &wireIndex
		}
		if err := runner.observeKeepaliveBounded(observation); err != nil {
			return err
		}
	}
	return nil
}

func (runner *Runner) observeKeepaliveBounded(observation Observation) error {
	// Keep space for the final verification and result records even when a
	// short interval produces many bounded input observations.
	if len(runner.sink.items) >= maximumObservationCount-2 {
		return errors.New("required keepalive observation capacity exhausted")
	}
	return runner.observe(observation)
}
