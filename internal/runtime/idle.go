package runtime

import (
	"context"
	"errors"
	"io"
	"sync"
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
	displayAwake  bool
	suppressedKey *suppressionKey
	lastActivity  time.Time
	idleDeadline  time.Time
	keepaliveAt   time.Time
}

type idlePolicyController struct {
	clock             Clock
	sender            frameSender
	plan              devicePlan
	startupAt         time.Time
	input             <-chan inputObservation
	stdout            io.Writer
	actions           *profileActionController
	transition        *profileTransitionGate
	settings          <-chan idleSettingsRequest
	hostState         <-chan hostDisplayStateRequest
	wakeSender        hostDisplayWakeSender
	wakeSource        hostDisplayWakeSource
	hostManaged       bool
	hostPending       bool
	pendingAwake      bool
	hostOffPending    func() bool
	hostWriteBoundary func() (bool, func())
	state             idlePolicyState
}

type idleSettingsRequest struct {
	ctx      context.Context
	settings reloadSettings
	result   chan idleSettingsResponse
	state    *idleSettingsRequestState
}

type idleSettingsRequestState struct {
	mu      sync.Mutex
	claimed bool
	aborted bool
}

func (state *idleSettingsRequestState) claim() bool {
	state.mu.Lock()
	defer state.mu.Unlock()
	if state.aborted {
		return false
	}
	state.claimed = true
	return true
}

func (state *idleSettingsRequestState) abort() bool {
	state.mu.Lock()
	defer state.mu.Unlock()
	if state.claimed {
		return false
	}
	state.aborted = true
	return true
}

type idleSettingsResponse struct {
	result idleSettingsApplyResult
	err    error
}

type idleSettingsBridge struct {
	mu         sync.Mutex
	requests   chan idleSettingsRequest
	active     bool
	closed     bool
	activeDone chan struct{}
}

func newIdleSettingsBridge() *idleSettingsBridge {
	return &idleSettingsBridge{requests: make(chan idleSettingsRequest)}
}

func (bridge *idleSettingsBridge) activate() {
	if bridge == nil {
		return
	}
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if bridge.closed || bridge.active {
		return
	}
	bridge.active = true
	bridge.activeDone = make(chan struct{})
}

func (bridge *idleSettingsBridge) deactivate() {
	if bridge == nil {
		return
	}
	bridge.mu.Lock()
	defer bridge.mu.Unlock()
	if !bridge.active {
		return
	}
	bridge.active = false
	close(bridge.activeDone)
	bridge.activeDone = nil
}

func (bridge *idleSettingsBridge) close() {
	if bridge == nil {
		return
	}
	bridge.mu.Lock()
	bridge.closed = true
	if bridge.active {
		bridge.active = false
		close(bridge.activeDone)
		bridge.activeDone = nil
	}
	bridge.mu.Unlock()
}

func (bridge *idleSettingsBridge) ApplySettings(ctx context.Context, settings reloadSettings) (idleSettingsApplyResult, error) {
	if bridge == nil {
		return idleSettingsApplyResult{}, ErrReloadSettingsPending
	}
	if ctx == nil {
		ctx = context.Background()
	}
	bridge.mu.Lock()
	if bridge.closed || !bridge.active {
		bridge.mu.Unlock()
		return idleSettingsApplyResult{}, ErrReloadSettingsPending
	}
	done := bridge.activeDone
	bridge.mu.Unlock()
	request := idleSettingsRequest{
		ctx:      ctx,
		settings: settings,
		result:   make(chan idleSettingsResponse, 1),
		state:    &idleSettingsRequestState{},
	}
	select {
	case <-ctx.Done():
		return idleSettingsApplyResult{}, ctx.Err()
	case <-done:
		return idleSettingsApplyResult{}, ErrReloadSettingsPending
	case bridge.requests <- request:
	}
	select {
	case response := <-request.result:
		return response.result, response.err
	case <-done:
		if request.state.abort() {
			return idleSettingsApplyResult{}, ErrReloadSettingsPending
		}
		response := <-request.result
		return response.result, response.err
	}
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
	settingsChannels ...<-chan idleSettingsRequest,
) error {
	var settings <-chan idleSettingsRequest
	if len(settingsChannels) > 0 {
		settings = settingsChannels[0]
	}
	return runIdlePolicyWithHostDisplay(ctx, clock, sender, plan, startupAt, input, stdout, actionService, executor, settings, nil, nil, nil, nil, nil)
}

func runIdlePolicyWithHostDisplay(
	ctx context.Context,
	clock Clock,
	sender frameSender,
	plan devicePlan,
	startupAt time.Time,
	input <-chan inputObservation,
	stdout io.Writer,
	actionService ProfileService,
	executor executionSubmitter,
	settings <-chan idleSettingsRequest,
	hostState <-chan hostDisplayStateRequest,
	wakeSender hostDisplayWakeSender,
	wakeSource hostDisplayWakeSource,
	hostOffPending func() bool,
	hostWriteBoundary func() (bool, func()),
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
		clock:             clock,
		sender:            sender,
		plan:              plan,
		startupAt:         startupAt,
		input:             input,
		stdout:            stdout,
		actions:           newProfileActionController(actionService, plan.eventPositions, executor),
		settings:          settings,
		hostState:         hostState,
		wakeSender:        wakeSender,
		wakeSource:        wakeSource,
		hostOffPending:    hostOffPending,
		hostWriteBoundary: hostWriteBoundary,
		hostManaged:       hostState != nil,
		state: idlePolicyState{
			displayAwake: true,
			lastActivity: startupAt,
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
	var pendingHostState *hostDisplayStateRequest
	defer func() {
		stopTimer(keepaliveTimer)
		stopTimer(idleTimer)
		if pendingHostState != nil {
			pendingHostState.result <- hostDisplayStateResponse{err: errHostDisplayStatePending}
		}
	}()

	for {
		if err := ctx.Err(); err != nil {
			return nil
		}
		if pendingHostState != nil {
			var deferred bool
			var err error
			idleTimer, deferred, err = controller.handleHostStateRequest(ctx, *pendingHostState, idleTimer)
			if !deferred {
				pendingHostState = nil
				controller.hostPending = false
			}
			if err != nil {
				return err
			}
			if !deferred {
				continue
			}
		}
		hostState := controller.hostState
		if pendingHostState != nil {
			hostState = nil
		}
		select {
		case request := <-hostState:
			pendingHostState = controller.acceptHostStateRequest(request)
			continue
		case request := <-controller.settings:
			var err error
			idleTimer, err = controller.handleSettingsRequest(ctx, request, idleTimer)
			if err != nil {
				return err
			}
			continue
		default:
		}
		if transitionDone, active := controller.transitionState(); active {
			select {
			case <-ctx.Done():
				return nil
			case <-transitionDone:
			case request := <-controller.settings:
				var err error
				idleTimer, err = controller.handleSettingsRequest(ctx, request, idleTimer)
				if err != nil {
					return err
				}
			case request := <-hostState:
				pendingHostState = controller.acceptHostStateRequest(request)
			case observation, ok := <-controller.input:
				if !ok {
					return nil
				}
				var err error
				idleTimer, err = controller.handleInputAndSyncTimer(ctx, observation, idleTimer)
				if err != nil {
					return err
				}
			}
			continue
		}
		now := controller.clock.Now()
		if !now.Before(controller.state.keepaliveAt) {
			stopTimer(keepaliveTimer)
			written, err := controller.tryKeepalive(ctx)
			if err != nil {
				return err
			}
			if !written {
				keepaliveTimer = controller.armTimer(controller.state.keepaliveAt)
				continue
			}
			controller.state.keepaliveAt = advanceSchedule(controller.state.keepaliveAt, controller.clock.Now())
			keepaliveTimer = controller.armTimer(controller.state.keepaliveAt)
			continue
		}

		if !controller.state.dimmed && !controller.state.idleDeadline.IsZero() && !now.Before(controller.state.idleDeadline) {
			observation, open, ready := receiveReady(controller.input)
			if !ready {
				stopTimer(idleTimer)
				written, err := controller.tryDim(ctx)
				if err != nil {
					return err
				}
				if !written {
					idleTimer = controller.armTimer(controller.state.idleDeadline)
					continue
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
			written, err := controller.tryDim(ctx)
			if err != nil {
				return err
			}
			if !written {
				idleTimer = controller.armTimer(controller.state.idleDeadline)
				continue
			}
			idleTimer = nil
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
		case request := <-controller.settings:
			var err error
			idleTimer, err = controller.handleSettingsRequest(ctx, request, idleTimer)
			if err != nil {
				return err
			}
		case request := <-hostState:
			pendingHostState = controller.acceptHostStateRequest(request)
		case <-keepaliveTimer.C():
			stopTimer(keepaliveTimer)
			keepaliveTimer = controller.armTimer(controller.state.keepaliveAt)
		case <-timerChannel(idleTimer):
			stopTimer(idleTimer)
			idleTimer = controller.armTimer(controller.state.idleDeadline)
		}
	}
}

func (controller *idlePolicyController) transitionState() (<-chan struct{}, bool) {
	if controller == nil || controller.transition == nil {
		return nil, false
	}
	controller.transition.mu.RLock()
	defer controller.transition.mu.RUnlock()
	return controller.transition.activeDone, controller.transition.active
}

func (controller *idlePolicyController) displayIsAwake() bool {
	return controller != nil && (!controller.hostManaged || controller.state.displayAwake)
}

func (controller *idlePolicyController) acceptHostStateRequest(request hostDisplayStateRequest) *hostDisplayStateRequest {
	if request.state != nil && !request.state.claim() {
		request.result <- hostDisplayStateResponse{err: errHostDisplayStatePending}
		return nil
	}
	controller.hostPending = true
	controller.pendingAwake = request.displayAwake
	return &request
}

func (controller *idlePolicyController) handleSettingsRequest(_ context.Context, request idleSettingsRequest, timer Timer) (Timer, error) {
	if request.state != nil && !request.state.claim() {
		request.result <- idleSettingsResponse{err: ErrReloadSettingsPending}
		return timer, nil
	}
	result, err := controller.applySettings(request.ctx, request.settings)
	request.result <- idleSettingsResponse{result: result, err: err}
	if err != nil {
		if result.writeAttempted {
			return timer, err
		}
		return timer, nil
	}
	stopTimer(timer)
	if controller.state.dimmed || controller.state.idleDeadline.IsZero() {
		return nil, nil
	}
	return controller.armTimer(controller.state.idleDeadline), nil
}

func (controller *idlePolicyController) handleHostStateRequest(_ context.Context, request hostDisplayStateRequest, timer Timer) (Timer, bool, error) {
	if controller.transition != nil {
		controller.transition.mu.RLock()
		if controller.transition.active {
			controller.transition.mu.RUnlock()
			return timer, true, nil
		}
		defer controller.transition.mu.RUnlock()
	}
	if request.state != nil && !request.state.claim() {
		request.result <- hostDisplayStateResponse{err: errHostDisplayStatePending}
		return timer, false, nil
	}
	result, writeAttempted, err := controller.applyHostDisplayState(request.ctx, request.displayAwake)
	request.result <- hostDisplayStateResponse{result: result, err: err}
	if err != nil {
		if writeAttempted {
			return timer, false, err
		}
		return timer, false, nil
	}
	stopTimer(timer)
	if !controller.displayIsAwake() || controller.state.dimmed || controller.state.idleDeadline.IsZero() {
		return nil, false, nil
	}
	return controller.armTimer(controller.state.idleDeadline), false, nil
}

func (controller *idlePolicyController) applyHostDisplayState(ctx context.Context, displayAwake bool) (hostDisplayStateResult, bool, error) {
	result := hostDisplayStateResult{displayAwake: displayAwake}
	if !controller.hostManaged {
		controller.hostManaged = true
		controller.state.displayAwake = true
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return result, false, err
	}
	if controller.state.displayAwake == displayAwake {
		return result, false, nil
	}
	if !displayAwake {
		if err := controller.sender.SendFrame(ctx, d200x.BrightnessFrame(0)); err != nil {
			return result, true, sanitizeFailure("write D200X host display sleep brightness", err)
		}
		controller.state.displayAwake = false
		controller.state.dimmed = true
		controller.state.idleDeadline = time.Time{}
		controller.state.suppressedKey = nil
		controller.actions.reset()
		result.changed = true
		return result, true, nil
	}
	if controller.wakeSender == nil || controller.wakeSource == nil {
		return result, false, errors.New("runtime host display wake path is unavailable")
	}
	update, brightness, err := controller.wakeSource.hostDisplayWakeState()
	if err != nil {
		return result, false, sanitizeFailure("prepare D200X host display wake", err)
	}
	if err := controller.wakeSender.SendStartupPageUpdate(ctx, update, brightness); err != nil {
		return result, true, sanitizeFailure("write D200X host display wake", err)
	}
	completedAt := controller.clock.Now()
	controller.plan.brightness = brightness
	controller.state.displayAwake = true
	controller.state.dimmed = false
	controller.state.lastActivity = completedAt
	controller.state.idleDeadline = idleDeadline(completedAt, controller.plan.idleTimeout)
	controller.state.suppressedKey = nil
	controller.actions.reset()
	result.changed = true
	return result, true, nil
}

func (controller *idlePolicyController) applySettings(ctx context.Context, settings reloadSettings) (idleSettingsApplyResult, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return idleSettingsApplyResult{}, err
	}
	bridgeOffPending := false
	if controller.hostWriteBoundary != nil {
		var unlock func()
		bridgeOffPending, unlock = controller.hostWriteBoundary()
		defer unlock()
	} else if controller.hostOffPending != nil {
		bridgeOffPending = controller.hostOffPending()
	}
	if !controller.displayIsAwake() || controller.hostSleepPending(bridgeOffPending) {
		controller.plan.brightness = settings.brightness
		controller.plan.idleTimeout = settings.idleTimeout
		controller.state.idleDeadline = time.Time{}
		return idleSettingsApplyResult{}, nil
	}
	now := controller.clock.Now()
	deadline := idleDeadline(controller.state.lastActivity, settings.idleTimeout)
	restore := controller.state.dimmed && settings.idleTimeout <= 0
	dim := !controller.state.dimmed && !deadline.IsZero() && !now.Before(deadline)
	writeBrightness := -1
	switch {
	case restore:
		writeBrightness = settings.brightness
	case dim:
		writeBrightness = 0
	case !controller.state.dimmed && settings.brightness != controller.plan.brightness:
		writeBrightness = settings.brightness
	}
	result := idleSettingsApplyResult{writeAttempted: writeBrightness >= 0}
	if writeBrightness >= 0 {
		if err := controller.sender.SendFrame(ctx, d200x.BrightnessFrame(writeBrightness)); err != nil {
			return result, sanitizeFailure("write D200X reload brightness", err)
		}
	}
	controller.plan.brightness = settings.brightness
	controller.plan.idleTimeout = settings.idleTimeout
	controller.state.idleDeadline = deadline
	if restore {
		controller.state.dimmed = false
		controller.state.suppressedKey = nil
		controller.actions.reset()
	}
	if dim {
		controller.state.dimmed = true
		controller.actions.reset()
	}
	return result, nil
}

func (controller *idlePolicyController) hostSleepPending(bridgeOffPending bool) bool {
	if controller == nil {
		return false
	}
	if controller.hostPending && !controller.pendingAwake {
		return true
	}
	return bridgeOffPending
}

func (controller *idlePolicyController) armTimer(deadline time.Time) Timer {
	duration := deadline.Sub(controller.clock.Now())
	if duration < 0 {
		duration = 0
	}
	return controller.clock.NewTimer(duration)
}

func (controller *idlePolicyController) keepalive(ctx context.Context) error {
	_, err := controller.tryKeepalive(ctx)
	return err
}

func (controller *idlePolicyController) tryKeepalive(ctx context.Context) (bool, error) {
	if controller.transition != nil {
		controller.transition.mu.RLock()
		defer controller.transition.mu.RUnlock()
		if controller.transition.active {
			return false, nil
		}
	}
	if err := controller.sender.SendFrame(ctx, d200x.EnableInputStreamFrame()); err != nil {
		if ctx.Err() != nil || errors.Is(err, context.Canceled) {
			return true, nil
		}
		return true, sanitizeFailure("write D200X keepalive", err)
	}
	return true, nil
}

func (controller *idlePolicyController) dim(ctx context.Context) error {
	_, err := controller.tryDim(ctx)
	return err
}

func (controller *idlePolicyController) tryDim(ctx context.Context) (bool, error) {
	if controller.state.dimmed || !controller.displayIsAwake() {
		return true, nil
	}
	if controller.transition != nil {
		controller.transition.mu.RLock()
		defer controller.transition.mu.RUnlock()
		if controller.transition.active {
			return false, nil
		}
	}
	if err := controller.sender.SendFrame(ctx, d200x.BrightnessFrame(0)); err != nil {
		if ctx.Err() != nil || errors.Is(err, context.Canceled) {
			return true, nil
		}
		return true, sanitizeFailure("write D200X idle brightness", err)
	}
	controller.state.dimmed = true
	controller.actions.reset()
	return true, nil
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
	controller.state.lastActivity = completedAt
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
		controller.actions.consumePhysical(observation.event)
		controller.actions.reset()
		controller.state.suppressedKey = nil
		return nil, nil
	}
	event := observation.event
	if !controller.displayIsAwake() {
		controller.actions.consumePhysical(event)
		controller.actions.reset()
		controller.state.suppressedKey = nil
		if event.Marker == d200x.InputMarkerEncoder && (event.Action == d200x.InputActionRotatedLeft || event.Action == d200x.InputActionRotatedRight) {
			if err := controller.sender.SendFrame(ctx, d200x.BrightnessFrame(0)); err != nil {
				return nil, sanitizeFailure("reassert D200X host display sleep brightness", err)
			}
		}
		return nil, nil
	}
	known := isKnownGesture(event)
	if controller.state.dimmed {
		controller.actions.consumePhysical(event)
		controller.actions.reset()
		if !known {
			return nil, controller.emit(event)
		}
		return nil, controller.restore(ctx, event)
	}

	if controller.state.suppressedKey != nil {
		if matchingSuppressedRelease(event, *controller.state.suppressedKey) {
			controller.actions.consumePhysical(event)
			controller.state.suppressedKey = nil
			controller.actions.reset()
			return nil, nil
		}
		if matchingSuppressedPress(event, *controller.state.suppressedKey) {
			controller.actions.consumePhysical(event)
			return nil, nil
		}
	}
	if err := controller.emit(event); err != nil {
		return nil, err
	}
	activation := controller.actions.observeState(event)
	if known {
		controller.state.lastActivity = observation.observedAt
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
		generation, active := transition.snapshot()
		observation := inputObservation{
			event:                event,
			observedAt:           r.clock.Now(),
			transitionGeneration: generation,
			transitionTagged:     transition != nil,
			transitionSuppressed: active,
		}
		select {
		case output <- observation:
		case <-ctx.Done():
			return nil
		}
	}
}
