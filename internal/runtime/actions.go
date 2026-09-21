package runtime

import (
	"context"
	"errors"
	"slices"
	"time"

	"hidhogg/internal/d200x"
	"hidhogg/internal/execution"
	"hidhogg/internal/nativeinput"
	"hidhogg/internal/notification"
	"hidhogg/internal/profile"
)

var errProfileActionBindingChanged = errors.New("profile action binding changed")

type profileActionSnapshot struct {
	profileID string
	bindings  []profile.Binding
}

func (snapshot profileActionSnapshot) clone() profileActionSnapshot {
	return profileActionSnapshot{
		profileID: snapshot.profileID,
		bindings:  cloneRuntimeBindings(snapshot.bindings),
	}
}

type notificationSelection struct {
	notificationID string
	wireIndex      byte
	profileID      string
	positionID     string
	position       string
	deadline       time.Time
	snapshot       profileActionSnapshot
	binding        profile.Binding
	hasBinding     bool
}

func (selection notificationSelection) clone() notificationSelection {
	selection.snapshot = selection.snapshot.clone()
	selection.binding.Action.Arguments = slices.Clone(selection.binding.Action.Arguments)
	return selection
}

type profileActionCandidate struct {
	wireIndex    byte
	marker       d200x.InputMarker
	snapshot     profileActionSnapshot
	binding      profile.Binding
	hasBinding   bool
	position     eventPosition
	notification *notificationSelection
}

type profileActionKey struct {
	marker    d200x.InputMarker
	wireIndex byte
}

type profileActionController struct {
	service    ProfileService
	executor   executionSubmitter
	native     nativeWorker
	positions  func() map[byte]eventPosition
	transition *profileTransitionGate
	held       map[profileActionKey]struct{}
	pending    map[profileActionKey]*profileActionCandidate
}

type executionSubmitter interface {
	Submit(execution.Request) (execution.Record, error)
}

type profileActionSnapshotProvider interface {
	currentActionSnapshot() profileActionSnapshot
}

type profileActionActivator interface {
	activateProfileForAction(context.Context, profileActionSnapshot, string) (ActivationResult, error)
}

type profileNotificationDismissal interface {
	dismissNotification(context.Context, notificationSelection) (bool, error)
}

func newProfileActionController(service ProfileService, positions func() map[byte]eventPosition, executors ...executionSubmitter) *profileActionController {
	if service == nil {
		return nil
	}
	controller := &profileActionController{service: service, positions: positions}
	if len(executors) > 0 {
		controller.executor = executors[0]
		if provider, ok := executors[0].(interface{ nativeInputSubmitter() nativeWorker }); ok {
			controller.native = provider.nativeInputSubmitter()
		}
	}
	if source, ok := service.(profileTransitionSource); ok {
		controller.transition = source.profileTransitionGate()
		controller.transition.registerReset(controller.reset)
	}
	return controller
}

func (controller *profileActionController) reset() {
	if controller == nil {
		return
	}
	controller.ensureState()
	clear(controller.pending)
}

func (controller *profileActionController) ensureState() {
	if controller == nil {
		return
	}
	if controller.held == nil {
		controller.held = make(map[profileActionKey]struct{})
	}
	if controller.pending == nil {
		controller.pending = make(map[profileActionKey]*profileActionCandidate)
	}
}

// consumePhysical records a down or up without evaluating the configured
// action. Idle wake and transition-suppressed events use this to keep the
// physical latch aligned while deliberately discarding actions.
func (controller *profileActionController) consumePhysical(event d200x.InputEvent) {
	if controller == nil {
		return
	}
	key, ok := profileActionKeyFor(event)
	if !ok {
		return
	}
	controller.ensureState()
	switch event.Action {
	case d200x.InputActionPressed:
		controller.held[key] = struct{}{}
	case d200x.InputActionReleased:
		delete(controller.held, key)
		delete(controller.pending, key)
	}
}

func (controller *profileActionController) observe(ctx context.Context, event d200x.InputEvent) error {
	if controller == nil {
		return nil
	}
	if controller.transition != nil {
		if err := controller.transition.waitInactive(ctx); err != nil {
			return err
		}
	}
	if controller.transition != nil {
		controller.transition.mu.RLock()
	}
	activation := controller.observeState(event)
	if controller.transition != nil {
		controller.transition.mu.RUnlock()
	}
	return controller.activate(ctx, activation)
}

type profileActionActivation struct {
	snapshot     profileActionSnapshot
	binding      profile.Binding
	hasBinding   bool
	positionID   string
	notification *notificationSelection
}

func (controller *profileActionController) observeState(event d200x.InputEvent) *profileActionActivation {
	if controller == nil {
		return nil
	}
	controller.ensureState()
	if controller.transition != nil && controller.transition.active {
		controller.consumePhysical(event)
		controller.reset()
		return nil
	}
	if !isOrdinaryPressOrRelease(event) {
		controller.reset()
		return nil
	}

	key := profileActionKey{marker: event.Marker, wireIndex: event.WireIndex}
	switch event.Action {
	case d200x.InputActionPressed:
		if _, held := controller.held[key]; held {
			return nil
		}
		controller.held[key] = struct{}{}
		position, ok := controller.positionFor(event.WireIndex)
		if !ok {
			return nil
		}
		snapshot := controller.currentSnapshot()
		binding, hasBinding := actionBindingAt(snapshot, position.position)
		selection := controller.notificationSelectionAt(event.WireIndex, snapshot, position, binding, hasBinding)
		if !hasBinding && selection == nil {
			return nil
		}
		candidate := &profileActionCandidate{
			wireIndex:    event.WireIndex,
			marker:       event.Marker,
			snapshot:     snapshot.clone(),
			binding:      binding,
			hasBinding:   hasBinding,
			position:     position,
			notification: selection,
		}
		switch effectiveActionGesture(binding.Action.Gesture) {
		case profile.PressGesture:
			if !hasBinding {
				return nil
			}
			return &profileActionActivation{
				snapshot:     candidate.snapshot,
				binding:      candidate.binding,
				hasBinding:   candidate.hasBinding,
				positionID:   candidate.position.id,
				notification: cloneNotificationSelection(candidate.notification),
			}
		case profile.ReleaseGesture:
			controller.pending[key] = candidate
		}
		return nil
	case d200x.InputActionReleased:
		_, held := controller.held[key]
		delete(controller.held, key)
		candidate := controller.pending[key]
		delete(controller.pending, key)
		if !held || candidate == nil {
			return nil
		}
		position, ok := controller.positionFor(event.WireIndex)
		if !ok {
			return nil
		}
		snapshot := controller.currentSnapshot()
		if !candidate.matches(snapshot, position) {
			return nil
		}
		return &profileActionActivation{
			snapshot:     candidate.snapshot,
			binding:      candidate.binding,
			hasBinding:   candidate.hasBinding,
			positionID:   candidate.position.id,
			notification: cloneNotificationSelection(candidate.notification),
		}
	default:
		controller.reset()
		return nil
	}
}

func (controller *profileActionController) positionFor(wireIndex byte) (eventPosition, bool) {
	if controller == nil || controller.positions == nil {
		return eventPosition{}, false
	}
	position, ok := controller.positions()[wireIndex]
	return position, ok
}

func (controller *profileActionController) currentSnapshot() profileActionSnapshot {
	if controller == nil || controller.service == nil {
		return profileActionSnapshot{}
	}
	if provider, ok := controller.service.(profileActionSnapshotProvider); ok {
		return provider.currentActionSnapshot()
	}
	profileID, ok := controller.service.CurrentProfileID()
	if !ok {
		return profileActionSnapshot{}
	}
	return profileActionSnapshot{profileID: profileID, bindings: controller.service.CurrentBindings()}
}

func (controller *profileActionController) notificationSelectionAt(wireIndex byte, snapshot profileActionSnapshot, position eventPosition, binding profile.Binding, hasBinding bool) *notificationSelection {
	provider, ok := controller.service.(interface {
		CurrentNotificationAt(byte) (NotificationInstance, bool)
	})
	if !ok {
		return nil
	}
	instance, ok := provider.CurrentNotificationAt(wireIndex)
	if !ok || instance.ProfileID != snapshot.profileID || instance.PositionID != position.id || instance.Position != position.position {
		return nil
	}
	selection := &notificationSelection{
		notificationID: instance.NotificationID,
		wireIndex:      wireIndex,
		profileID:      instance.ProfileID,
		positionID:     instance.PositionID,
		position:       instance.Position,
		deadline:       instance.deadline,
		snapshot:       snapshot.clone(),
		binding:        binding,
		hasBinding:     hasBinding,
	}
	return selection
}

func cloneNotificationSelection(selection *notificationSelection) *notificationSelection {
	if selection == nil {
		return nil
	}
	owned := selection.clone()
	return &owned
}

func (controller *profileActionController) activate(ctx context.Context, activation *profileActionActivation) error {
	if controller == nil || controller.service == nil || activation == nil {
		return nil
	}
	if activation.notification != nil {
		dismissal, ok := controller.service.(profileNotificationDismissal)
		if !ok {
			return nil
		}
		dismissed, err := dismissal.dismissNotification(ctx, *activation.notification)
		if err != nil {
			if errors.Is(err, notification.ErrBusy) || errors.Is(err, notification.ErrClosed) || errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				return nil
			}
			return err
		}
		if !dismissed {
			return nil
		}
	}
	if !activation.hasActionBinding() {
		return nil
	}
	if activation.binding.Action.Type == profile.TypeTextActionType || activation.binding.Action.Type == profile.KeyPressActionType {
		if controller.native == nil {
			return nil
		}
		action := activation.binding.Action
		_, err := controller.native.Submit(nativeinput.Request{ProfileID: activation.snapshot.profileID, PositionID: activation.positionID, Text: action.Text, Key: action.Key})
		if errors.Is(err, nativeinput.ErrClosed) && ctx != nil && ctx.Err() != nil {
			return nil
		}
		return err
	}
	if activation.binding.Action.Type == profile.ExecuteActionType {
		if controller.executor == nil {
			return nil
		}
		action := activation.binding.Action
		_, err := controller.executor.Submit(execution.Request{
			ProfileID:  activation.snapshot.profileID,
			PositionID: activation.positionID,
			Executable: action.Executable,
			Arguments:  slices.Clone(action.Arguments),
			Timeout:    time.Duration(action.TimeoutSeconds) * time.Second,
		})
		if errors.Is(err, execution.ErrClosed) && ctx != nil && ctx.Err() != nil {
			return nil
		}
		return err
	}
	var err error
	if activator, ok := controller.service.(profileActionActivator); ok {
		_, err = activator.activateProfileForAction(ctx, activation.snapshot, activation.binding.Action.ProfileID)
	} else {
		_, err = controller.service.ActivateProfile(ctx, activation.binding.Action.ProfileID)
	}
	if errors.Is(err, errProfileActionBindingChanged) {
		return nil
	}
	if errors.Is(err, context.Canceled) && ctx != nil && ctx.Err() != nil {
		return nil
	}
	return err
}

func (candidate profileActionCandidate) matches(snapshot profileActionSnapshot, position eventPosition) bool {
	if snapshot.profileID != candidate.snapshot.profileID || position.id != candidate.position.id || position.position != candidate.position.position {
		return false
	}
	if !candidate.hasActionBinding() {
		_, ok := actionBindingAt(snapshot, position.position)
		return !ok
	}
	binding, ok := actionBindingAt(snapshot, position.position)
	return ok && equalProfileBinding(binding, candidate.binding)
}

func (candidate profileActionCandidate) hasActionBinding() bool {
	return candidate.hasBinding || candidate.binding.Action.Type != ""
}

func (activation profileActionActivation) hasActionBinding() bool {
	return activation.hasBinding || activation.binding.Action.Type != ""
}

func actionBindingAt(snapshot profileActionSnapshot, position string) (profile.Binding, bool) {
	var binding profile.Binding
	found := false
	for _, current := range snapshot.bindings {
		if current.Position != position {
			continue
		}
		if found || !isSupportedAction(current.Action) {
			return profile.Binding{}, false
		}
		binding = current
		found = true
	}
	return binding, found
}

func isSupportedAction(action profile.Action) bool {
	if action.Type != profile.ActivateProfileType && action.Type != profile.ExecuteActionType && action.Type != profile.TypeTextActionType && action.Type != profile.KeyPressActionType {
		return false
	}
	gesture := effectiveActionGesture(action.Gesture)
	return gesture == profile.PressGesture || gesture == profile.ReleaseGesture
}

func effectiveActionGesture(gesture string) string {
	if gesture == "" {
		return profile.DefaultGesture
	}
	return gesture
}

func profileActionKeyFor(event d200x.InputEvent) (profileActionKey, bool) {
	if !isOrdinaryPressOrRelease(event) {
		return profileActionKey{}, false
	}
	return profileActionKey{marker: event.Marker, wireIndex: event.WireIndex}, true
}

func equalProfileBinding(left, right profile.Binding) bool {
	return left.Position == right.Position &&
		left.Action.Type == right.Action.Type &&
		effectiveActionGesture(left.Action.Gesture) == effectiveActionGesture(right.Action.Gesture) &&
		left.Action.ProfileID == right.Action.ProfileID &&
		left.Action.Text == right.Action.Text &&
		left.Action.Key == right.Action.Key &&
		left.Action.Executable == right.Action.Executable &&
		slices.Equal(left.Action.Arguments, right.Action.Arguments) &&
		left.Action.TimeoutSeconds == right.Action.TimeoutSeconds
}

func isOrdinaryPressOrRelease(event d200x.InputEvent) bool {
	if event.Marker != d200x.InputMarkerButton && event.Marker != d200x.InputMarkerEncoder {
		return false
	}
	return event.Action == d200x.InputActionPressed || event.Action == d200x.InputActionReleased
}
