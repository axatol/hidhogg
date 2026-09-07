package runtime

import (
	"context"
	"errors"

	"hidhogg/internal/d200x"
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
}

type profileActionController struct {
	service    ProfileService
	positions  func() map[byte]eventPosition
	transition *profileTransitionGate
	candidate  *profileActionCandidate
}

type profileActionSnapshotProvider interface {
	currentActionSnapshot() profileActionSnapshot
}

type profileActionActivator interface {
	activateProfileForAction(context.Context, profileActionSnapshot, string) (ActivationResult, error)
}

func newProfileActionController(service ProfileService, positions func() map[byte]eventPosition) *profileActionController {
	if service == nil {
		return nil
	}
	controller := &profileActionController{service: service, positions: positions}
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
	snapshot  profileActionSnapshot
	profileID string
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
			snapshot:  candidate.snapshot,
			profileID: candidate.binding.Action.ProfileID,
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
	var err error
	if activator, ok := controller.service.(profileActionActivator); ok {
		_, err = activator.activateProfileForAction(ctx, activation.snapshot, activation.profileID)
	} else {
		_, err = controller.service.ActivateProfile(ctx, activation.profileID)
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
	return ok && binding == candidate.binding
}

func actionBindingAt(snapshot profileActionSnapshot, position string) (profile.Binding, bool) {
	var binding profile.Binding
	found := false
	for _, current := range snapshot.bindings {
		if current.Position != position {
			continue
		}
		if found || current.Action.Type != profile.ActivateProfileType || current.Action.Gesture != profile.PressGesture {
			return profile.Binding{}, false
		}
		binding = current
		found = true
	}
	return binding, found
}

func isOrdinaryPressOrRelease(event d200x.InputEvent) bool {
	if event.Marker != d200x.InputMarkerButton && event.Marker != d200x.InputMarkerEncoder {
		return false
	}
	return event.Action == d200x.InputActionPressed || event.Action == d200x.InputActionReleased
}
