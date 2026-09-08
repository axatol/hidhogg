package runtime

import (
	"context"
	"errors"
	"slices"
	"time"

	"hidhogg/internal/d200x"
	"hidhogg/internal/execution"
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

type profileActionCandidate struct {
	wireIndex byte
	marker    d200x.InputMarker
	snapshot  profileActionSnapshot
	binding   profile.Binding
	position  eventPosition
}

type profileActionController struct {
	service    ProfileService
	executor   executionSubmitter
	positions  func() map[byte]eventPosition
	transition *profileTransitionGate
	candidate  *profileActionCandidate
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

func newProfileActionController(service ProfileService, positions func() map[byte]eventPosition, executors ...executionSubmitter) *profileActionController {
	if service == nil {
		return nil
	}
	controller := &profileActionController{service: service, positions: positions}
	if len(executors) > 0 {
		controller.executor = executors[0]
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
	controller.candidate = nil
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
	snapshot   profileActionSnapshot
	binding    profile.Binding
	positionID string
}

func (controller *profileActionController) observeState(event d200x.InputEvent) *profileActionActivation {
	if controller == nil {
		return nil
	}
	if controller.transition != nil && controller.transition.active {
		controller.reset()
		return nil
	}
	if !isOrdinaryPressOrRelease(event) {
		controller.reset()
		return nil
	}

	position, ok := controller.positionFor(event.WireIndex)
	if !ok {
		controller.reset()
		return nil
	}

	snapshot := controller.currentSnapshot()
	switch event.Action {
	case d200x.InputActionPressed:
		binding, ok := actionBindingAt(snapshot, position.position)
		if !ok {
			controller.reset()
			return nil
		}
		if controller.candidate != nil &&
			controller.candidate.wireIndex == event.WireIndex &&
			controller.candidate.marker == event.Marker {
			controller.reset()
			return nil
		}
		controller.candidate = &profileActionCandidate{
			wireIndex: event.WireIndex,
			marker:    event.Marker,
			snapshot:  snapshot.clone(),
			binding:   binding,
			position:  position,
		}
		return nil
	case d200x.InputActionReleased:
		candidate := controller.candidate
		controller.reset()
		if candidate == nil || candidate.wireIndex != event.WireIndex || candidate.marker != event.Marker {
			return nil
		}
		if !candidate.matches(snapshot, position) {
			return nil
		}
		return &profileActionActivation{
			snapshot:   candidate.snapshot,
			binding:    candidate.binding,
			positionID: candidate.position.id,
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

func (controller *profileActionController) activate(ctx context.Context, activation *profileActionActivation) error {
	if controller == nil || controller.service == nil || activation == nil {
		return nil
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
	if snapshot.profileID != candidate.snapshot.profileID || position.position != candidate.binding.Position {
		return false
	}
	binding, ok := actionBindingAt(snapshot, position.position)
	return ok && equalProfileBinding(binding, candidate.binding)
}

func actionBindingAt(snapshot profileActionSnapshot, position string) (profile.Binding, bool) {
	var binding profile.Binding
	found := false
	for _, current := range snapshot.bindings {
		if current.Position != position {
			continue
		}
		if found || current.Action.Gesture != profile.PressGesture ||
			(current.Action.Type != profile.ActivateProfileType && current.Action.Type != profile.ExecuteActionType) {
			return profile.Binding{}, false
		}
		binding = current
		found = true
	}
	return binding, found
}

func equalProfileBinding(left, right profile.Binding) bool {
	return left.Position == right.Position &&
		left.Action.Type == right.Action.Type &&
		left.Action.Gesture == right.Action.Gesture &&
		left.Action.ProfileID == right.Action.ProfileID &&
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
