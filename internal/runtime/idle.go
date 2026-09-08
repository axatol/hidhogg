package runtime

import (
	"context"
	"errors"
	"io"
	"time"

	"hidhogg/internal/d200x"
)

const keepaliveInterval = 50 * time.Second

// Clock and Timer isolate policy scheduling from wall-clock time. The runtime
// uses the standard monotonic clock in production; tests can drive timers and
// observations without waiting for real time.
type Clock interface {
	Now() time.Time
	NewTimer(time.Duration) Timer
}

type Timer interface {
	C() <-chan time.Time
	Stop() bool
}

type realClock struct{}

func (realClock) Now() time.Time {
	return time.Now()
}

func (realClock) NewTimer(duration time.Duration) Timer {
	return realTimer{timer: time.NewTimer(duration)}
}

type realTimer struct {
	timer *time.Timer
}

func (timer realTimer) C() <-chan time.Time {
	if timer.timer == nil {
		return nil
	}
	return timer.timer.C
}

func (timer realTimer) Stop() bool {
	if timer.timer == nil {
		return false
	}
	return timer.timer.Stop()
}

type inputObservation struct {
	event                d200x.InputEvent
	observedAt           time.Time
	transitionGeneration uint64
	transitionTagged     bool
	transitionSuppressed bool
}

type frameSender interface {
	SendFrame(context.Context, d200x.Frame) error
}

type suppressionKey struct {
	marker    d200x.InputMarker
	wireIndex byte
}

type idlePolicyState struct {
	dimmed        bool
	suppressedKey *suppressionKey
	idleDeadline  time.Time
	keepaliveAt   time.Time
}

type idlePolicyController struct {
	clock      Clock
	sender     frameSender
	plan       devicePlan
	startupAt  time.Time
	input      <-chan inputObservation
	stdout     io.Writer
	actions    *profileActionController
	transition *profileTransitionGate
	state      idlePolicyState
}

func runIdlePolicy(
	ctx context.Context,
	clock Clock,
	sender frameSender,
	plan devicePlan,
	startupAt time.Time,
	input <-chan inputObservation,
	stdout io.Writer,
	actionServices ...ProfileService,
) error {
	var actionService ProfileService
	if len(actionServices) > 0 {
		actionService = actionServices[0]
	}
	return runIdlePolicyWithExecutor(ctx, clock, sender, plan, startupAt, input, stdout, actionService, nil)
}

func runIdlePolicyWithExecutor(
	ctx context.Context,
	clock Clock,
	sender frameSender,
	plan devicePlan,
	startupAt time.Time,
	input <-chan inputObservation,
	stdout io.Writer,
	actionService ProfileService,
	executor executionSubmitter,
) error {
	if ctx == nil {
		ctx = context.Background()
	}
	if clock == nil {
		clock = realClock{}
	}
	if sender == nil {
		return errors.New("runtime has no active D200X device")
	}
	if stdout == nil {
		return errors.New("runtime output writer is nil")
	}
	if startupAt.IsZero() {
		startupAt = clock.Now()
	}
	controller := &idlePolicyController{
		clock:     clock,
		sender:    sender,
		plan:      plan,
		startupAt: startupAt,
		input:     input,
		stdout:    stdout,
		actions:   newProfileActionController(actionService, plan.eventPositions, executor),
		state: idlePolicyState{
			idleDeadline: idleDeadline(startupAt, plan.idleTimeout),
			keepaliveAt:  startupAt.Add(keepaliveInterval),
		},
	}
	if source, ok := actionService.(profileTransitionSource); ok {
		controller.transition = source.profileTransitionGate()
	}
	controller.state.keepaliveAt = firstScheduleDeadline(controller.state.keepaliveAt, clock.Now())
	return controller.run(ctx)
}

func idleDeadline(start time.Time, timeout time.Duration) time.Time {
	if timeout <= 0 {
		return time.Time{}
	}
	return start.Add(timeout)
}

func (controller *idlePolicyController) run(ctx context.Context) error {
	keepaliveTimer := controller.armTimer(controller.state.keepaliveAt)
	var idleTimer Timer
	if !controller.state.idleDeadline.IsZero() {
		idleTimer = controller.armTimer(controller.state.idleDeadline)
	}
	defer func() {
		stopTimer(keepaliveTimer)
		stopTimer(idleTimer)
	}()

	for {
		if err := ctx.Err(); err != nil {
			return nil
		}
		now := controller.clock.Now()
		if !now.Before(controller.state.keepaliveAt) {
			stopTimer(keepaliveTimer)
			if err := controller.keepalive(ctx); err != nil {
				return err
			}
			controller.state.keepaliveAt = advanceSchedule(controller.state.keepaliveAt, controller.clock.Now())
			keepaliveTimer = controller.armTimer(controller.state.keepaliveAt)
			continue
		}

		if !controller.state.dimmed && !controller.state.idleDeadline.IsZero() && !now.Before(controller.state.idleDeadline) {
			observation, open, ready := receiveReady(controller.input)
			if !ready {
				stopTimer(idleTimer)
				if err := controller.dim(ctx); err != nil {
					return err
				}
				idleTimer = nil
				continue
			}
			if !open {
				return nil
			}
			if observation.observedAt.Before(controller.state.idleDeadline) || observation.observedAt.Equal(controller.state.idleDeadline) {
				var err error
				idleTimer, err = controller.handleInputAndSyncTimer(ctx, observation, idleTimer)
				if err != nil {
					return err
				}
				continue
			}
			stopTimer(idleTimer)
			if err := controller.dim(ctx); err != nil {
				return err
			}
			idleTimer = nil
			var err error
			idleTimer, err = controller.handleInputAndSyncTimer(ctx, observation, idleTimer)
			if err != nil {
				return err
			}
			continue
		}

		select {
		case <-ctx.Done():
			return nil
		case observation, ok := <-controller.input:
			if !ok {
				return nil
			}
			var err error
			idleTimer, err = controller.handleInputAndSyncTimer(ctx, observation, idleTimer)
			if err != nil {
				return err
			}
		case <-keepaliveTimer.C():
			stopTimer(keepaliveTimer)
			keepaliveTimer = controller.armTimer(controller.state.keepaliveAt)
		case <-timerChannel(idleTimer):
			stopTimer(idleTimer)
			idleTimer = controller.armTimer(controller.state.idleDeadline)
		}
	}
}

func (controller *idlePolicyController) armTimer(deadline time.Time) Timer {
	duration := deadline.Sub(controller.clock.Now())
	if duration < 0 {
		duration = 0
	}
	return controller.clock.NewTimer(duration)
}

func (controller *idlePolicyController) keepalive(ctx context.Context) error {
	if err := controller.sender.SendFrame(ctx, d200x.EnableInputStreamFrame()); err != nil {
		if ctx.Err() != nil || errors.Is(err, context.Canceled) {
			return nil
		}
		return sanitizeFailure("write D200X keepalive", err)
	}
	return nil
}

func (controller *idlePolicyController) dim(ctx context.Context) error {
	if controller.state.dimmed {
		return nil
	}
	if controller.transition != nil {
		if err := controller.transition.waitInactive(ctx); err != nil {
			if ctx != nil && ctx.Err() != nil {
				return nil
			}
			return err
		}
		controller.transition.mu.RLock()
		defer controller.transition.mu.RUnlock()
	}
	if err := controller.sender.SendFrame(ctx, d200x.BrightnessFrame(0)); err != nil {
		if ctx.Err() != nil || errors.Is(err, context.Canceled) {
			return nil
		}
		return sanitizeFailure("write D200X idle brightness", err)
	}
	controller.state.dimmed = true
	controller.actions.reset()
	return nil
}

func (controller *idlePolicyController) restore(ctx context.Context, event d200x.InputEvent) error {
	if err := controller.sender.SendFrame(ctx, d200x.BrightnessFrame(controller.plan.brightness)); err != nil {
		if ctx.Err() != nil || errors.Is(err, context.Canceled) {
			return nil
		}
		return sanitizeFailure("write D200X restore brightness", err)
	}
	completedAt := controller.clock.Now()
	controller.state.dimmed = false
	controller.state.idleDeadline = idleDeadline(completedAt, controller.plan.idleTimeout)
	controller.state.suppressedKey = nil
	controller.actions.reset()
	if isPressGesture(event) {
		controller.state.suppressedKey = &suppressionKey{marker: event.Marker, wireIndex: event.WireIndex}
	}
	return nil
}

func (controller *idlePolicyController) handleInput(ctx context.Context, observation inputObservation) error {
	if controller.transition != nil {
		controller.transition.mu.RLock()
	}
	activation, err := controller.handleInputState(ctx, observation)
	if controller.transition != nil {
		controller.transition.mu.RUnlock()
	}
	if err != nil {
		return err
	}
	return controller.actions.activate(ctx, activation)
}

func (controller *idlePolicyController) handleInputState(ctx context.Context, observation inputObservation) (*profileActionActivation, error) {
	if !controller.allowsObservation(observation) {
		controller.actions.reset()
		controller.state.suppressedKey = nil
		return nil, nil
	}
	event := observation.event
	known := isKnownGesture(event)
	if controller.state.dimmed {
		controller.actions.reset()
		if !known {
			return nil, controller.emit(event)
		}
		return nil, controller.restore(ctx, event)
	}

	if controller.state.suppressedKey != nil {
		if matchingSuppressedRelease(event, *controller.state.suppressedKey) {
			controller.state.suppressedKey = nil
			controller.actions.reset()
			return nil, nil
		}
		if matchingSuppressedPress(event, *controller.state.suppressedKey) {
			controller.state.suppressedKey = nil
			controller.actions.reset()
		}
	}
	if err := controller.emit(event); err != nil {
		return nil, err
	}
	activation := controller.actions.observeState(event)
	if known {
		controller.state.idleDeadline = idleDeadline(observation.observedAt, controller.plan.idleTimeout)
	}
	return activation, nil
}

func (controller *idlePolicyController) allowsObservation(observation inputObservation) bool {
	if controller == nil {
		return false
	}
	if observation.transitionTagged && observation.transitionSuppressed {
		return false
	}
	if controller.transition == nil || !observation.transitionTagged {
		return controller.transition == nil || !controller.transition.active
	}
	return !controller.transition.active && observation.transitionGeneration == controller.transition.generation
}

func (controller *idlePolicyController) handleInputAndSyncTimer(ctx context.Context, observation inputObservation, timer Timer) (Timer, error) {
	previousDeadline := controller.state.idleDeadline
	if err := controller.handleInput(ctx, observation); err != nil {
		return timer, err
	}
	if previousDeadline == controller.state.idleDeadline {
		return timer, nil
	}
	stopTimer(timer)
	if controller.state.dimmed || controller.state.idleDeadline.IsZero() {
		return nil, nil
	}
	return controller.armTimer(controller.state.idleDeadline), nil
}

func (controller *idlePolicyController) emit(event d200x.InputEvent) error {
	return writeInputEvent(controller.stdout, controller.plan, event)
}

func isKnownGesture(event d200x.InputEvent) bool {
	switch event.Marker {
	case d200x.InputMarkerButton, d200x.InputMarkerEncoder:
		if event.Action == d200x.InputActionPressed || event.Action == d200x.InputActionReleased {
			return true
		}
		if event.Marker == d200x.InputMarkerEncoder {
			return event.Action == d200x.InputActionRotatedLeft || event.Action == d200x.InputActionRotatedRight
		}
		return false
	default:
		return false
	}
}

func isPressGesture(event d200x.InputEvent) bool {
	return (event.Marker == d200x.InputMarkerButton || event.Marker == d200x.InputMarkerEncoder) &&
		event.Action == d200x.InputActionPressed
}

func matchingSuppressedRelease(event d200x.InputEvent, key suppressionKey) bool {
	return event.Marker == key.marker &&
		event.Action == d200x.InputActionReleased &&
		event.WireIndex == key.wireIndex
}

func matchingSuppressedPress(event d200x.InputEvent, key suppressionKey) bool {
	return event.Marker == key.marker &&
		event.Action == d200x.InputActionPressed &&
		event.WireIndex == key.wireIndex
}

func receiveReady(input <-chan inputObservation) (inputObservation, bool, bool) {
	select {
	case observation, ok := <-input:
		return observation, ok, true
	default:
		return inputObservation{}, false, false
	}
}

func advanceSchedule(previous, now time.Time) time.Time {
	next := previous.Add(keepaliveInterval)
	if next.After(now) {
		return next
	}
	missed := now.Sub(next)/keepaliveInterval + 1
	return next.Add(missed * keepaliveInterval)
}

func firstScheduleDeadline(scheduled, now time.Time) time.Time {
	if scheduled.Before(now) {
		return advanceSchedule(scheduled.Add(-keepaliveInterval), now)
	}
	return scheduled
}

func timerChannel(timer Timer) <-chan time.Time {
	if timer == nil {
		return nil
	}
	return timer.C()
}

func stopTimer(timer Timer) {
	if timer == nil {
		return
	}
	timer.Stop()
	select {
	case <-timer.C():
	default:
	}
}

func (r *Runtime) readInputObservations(ctx context.Context, output chan<- inputObservation) error {
	r.mu.Lock()
	session := r.session
	r.mu.Unlock()
	if session == nil {
		close(output)
		return errors.New("runtime has no active D200X device")
	}
	defer close(output)
	for {
		transition := r.profileTransitionGate()
		beforeGeneration, beforeActive := transition.snapshot()
		event, ok, err := session.ReadInput(ctx)
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, context.Canceled) {
				return nil
			}
			if isRecoverableInputError(err) {
				continue
			}
			return sanitizeFailure("read D200X input", err)
		}
		if !ok {
			continue
		}
		afterGeneration, afterActive := transition.snapshot()
		observation := inputObservation{
			event:                event,
			observedAt:           r.clock.Now(),
			transitionGeneration: afterGeneration,
			transitionTagged:     transition != nil,
			transitionSuppressed: beforeActive || afterActive || beforeGeneration != afterGeneration,
		}
		select {
		case output <- observation:
		case <-ctx.Done():
			return nil
		}
	}
}
