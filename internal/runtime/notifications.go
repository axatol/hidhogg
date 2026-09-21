package runtime

import (
	"bytes"
	"context"
	"errors"
	"sync"
	"time"

	"hidhogg/internal/d200x"
	"hidhogg/internal/notification"
	"hidhogg/internal/profile"
)

const (
	notificationAdmissionCapacity = 8
	notificationOperationBudget   = 5 * time.Second
)

var (
	errNotificationPreparation      = errors.New("notification preparation failed")
	errNotificationSelectionExpired = errors.New("notification selection expired")
)

type notificationOverlay struct {
	NotificationID string
	Source         string
	Text           string
	PositionID     string
	Position       string
	Deadline       time.Time
}

type notificationSnapshot struct {
	profileID    string
	overlays     [d200x.DisplayPositionCount]*notificationOverlay
	renderedPage []byte
}

type NotificationInstance struct {
	ProfileID      string
	PositionID     string
	Position       string
	WireIndex      byte
	NotificationID string
	Source         string
	Text           string
	deadline       time.Time
}

type notificationRequestState struct {
	mu       sync.Mutex
	claimed  bool
	canceled bool
	boundary chan struct{}
}

func newNotificationRequestState() *notificationRequestState {
	return &notificationRequestState{boundary: make(chan struct{})}
}

func (state *notificationRequestState) claim(caller context.Context) bool {
	state.mu.Lock()
	defer state.mu.Unlock()
	if state.canceled || state.claimed {
		return false
	}
	if caller != nil && caller.Err() != nil {
		state.canceled = true
		close(state.boundary)
		return false
	}
	state.claimed = true
	close(state.boundary)
	return true
}

func (state *notificationRequestState) cancel() bool {
	state.mu.Lock()
	defer state.mu.Unlock()
	if state.claimed || state.canceled {
		return false
	}
	state.canceled = true
	close(state.boundary)
	return true
}

func (state *notificationRequestState) watch(ctx context.Context) {
	if ctx == nil {
		return
	}
	select {
	case <-ctx.Done():
		state.cancel()
	case <-state.boundary:
	}
}

type notificationRequest struct {
	ctx        context.Context
	caller     context.Context
	cancel     context.CancelFunc
	emit       *notification.EmitRequest
	identifier string
	clearID    string
	selection  *notificationSelection
	state      *notificationRequestState
	result     chan notificationResponse
}

type notificationResponse struct {
	emit      notification.EmitResult
	clear     notification.ClearResult
	dismissed bool
	err       error
}

func newNotificationSnapshot(profileID string, renderedPage []byte) notificationSnapshot {
	return notificationSnapshot{profileID: profileID, renderedPage: append([]byte(nil), renderedPage...)}
}

func (snapshot notificationSnapshot) clone() notificationSnapshot {
	clone := notificationSnapshot{profileID: snapshot.profileID, renderedPage: append([]byte(nil), snapshot.renderedPage...)}
	for index, overlay := range snapshot.overlays {
		if overlay == nil {
			continue
		}
		owned := *overlay
		clone.overlays[index] = &owned
	}
	return clone
}

func (snapshot notificationSnapshot) hasOverlays() bool {
	for _, overlay := range snapshot.overlays {
		if overlay != nil {
			return true
		}
	}
	return false
}

func (snapshot notificationSnapshot) earliestDeadline() (time.Time, bool) {
	var earliest time.Time
	for _, overlay := range snapshot.overlays {
		if overlay == nil || overlay.Deadline.IsZero() {
			continue
		}
		if earliest.IsZero() || overlay.Deadline.Before(earliest) {
			earliest = overlay.Deadline
		}
	}
	return earliest, !earliest.IsZero()
}

func (snapshot notificationSnapshot) at(wireIndex byte) (NotificationInstance, bool) {
	if int(wireIndex) >= len(snapshot.overlays) {
		return NotificationInstance{}, false
	}
	overlay := snapshot.overlays[wireIndex]
	if overlay == nil {
		return NotificationInstance{}, false
	}
	return NotificationInstance{
		ProfileID:      snapshot.profileID,
		PositionID:     overlay.PositionID,
		Position:       overlay.Position,
		WireIndex:      wireIndex,
		NotificationID: overlay.NotificationID,
		Source:         overlay.Source,
		Text:           overlay.Text,
		deadline:       overlay.Deadline,
	}, true
}

func (service *RuntimeProfileService) CurrentNotificationAt(wireIndex byte) (NotificationInstance, bool) {
	if service == nil {
		return NotificationInstance{}, false
	}
	snapshot := service.effective.Load()
	if snapshot == nil {
		return NotificationInstance{}, false
	}
	return snapshot.notifications.at(wireIndex)
}

func (service *RuntimeProfileService) CurrentNotifications() []NotificationInstance {
	if service == nil {
		return nil
	}
	snapshot := service.effective.Load()
	if snapshot == nil {
		return nil
	}
	instances := make([]NotificationInstance, 0, d200x.DisplayPositionCount)
	for wireIndex := range snapshot.notifications.overlays {
		if instance, ok := snapshot.notifications.at(byte(wireIndex)); ok {
			instances = append(instances, instance)
		}
	}
	return instances
}

func (service *RuntimeProfileService) EmitNotification(ctx context.Context, request notification.EmitRequest) (notification.EmitResult, error) {
	request = notification.CloneEmitRequest(request)
	if err := notification.ValidateEmit(request); err != nil {
		return notification.EmitResult{}, err
	}
	identifier, err := notification.NewNotificationID()
	if err != nil {
		return notification.EmitResult{}, errNotificationPreparation
	}
	response, err := service.enqueueNotification(ctx, notificationRequest{emit: &request, identifier: identifier, result: make(chan notificationResponse, 1)})
	if err != nil {
		return notification.EmitResult{}, err
	}
	response.emit.NotificationID = identifier
	return response.emit, nil
}

func (service *RuntimeProfileService) ClearNotification(ctx context.Context, identifier string) (notification.ClearResult, error) {
	if err := notification.ValidateNotificationID(identifier); err != nil {
		return notification.ClearResult{}, err
	}
	response, err := service.enqueueNotification(ctx, notificationRequest{clearID: identifier, result: make(chan notificationResponse, 1)})
	if err != nil {
		return notification.ClearResult{}, err
	}
	return response.clear, nil
}

func (service *RuntimeProfileService) dismissNotification(ctx context.Context, selection notificationSelection) (bool, error) {
	selection = selection.clone()
	response, err := service.enqueueNotification(ctx, notificationRequest{
		selection: &selection,
		result:    make(chan notificationResponse, 1),
	})
	if err != nil {
		return false, err
	}
	return response.dismissed, nil
}

func (service *RuntimeProfileService) enqueueNotification(ctx context.Context, request notificationRequest) (notificationResponse, error) {
	if service == nil {
		return notificationResponse{}, notification.ErrClosed
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if err := service.notificationAdmissionError(); err != nil {
		return notificationResponse{}, err
	}
	operationContext, cancel := context.WithTimeout(ctx, notificationOperationBudget)
	request.ctx = operationContext
	request.caller = ctx
	request.cancel = cancel
	request.state = newNotificationRequestState()
	if request.result == nil {
		request.result = make(chan notificationResponse, 1)
	}
	select {
	case <-ctx.Done():
		request.state.cancel()
		cancel()
		return notificationResponse{}, ctx.Err()
	case <-service.stop:
		request.state.cancel()
		cancel()
		return notificationResponse{}, service.notificationStopError()
	default:
	}
	service.mu.RLock()
	if err := service.notificationAdmissionErrorLocked(); err != nil {
		service.mu.RUnlock()
		request.state.cancel()
		cancel()
		return notificationResponse{}, err
	}
	select {
	case <-service.stop:
		service.mu.RUnlock()
		request.state.cancel()
		cancel()
		return notificationResponse{}, service.notificationStopError()
	case service.notifications <- request:
		service.mu.RUnlock()
	case <-ctx.Done():
		service.mu.RUnlock()
		request.state.cancel()
		cancel()
		return notificationResponse{}, ctx.Err()
	default:
		service.mu.RUnlock()
		request.state.cancel()
		cancel()
		return notificationResponse{}, notification.ErrBusy
	}
	go request.state.watch(ctx)
	select {
	case response := <-request.result:
		cancel()
		return response, response.err
	case <-ctx.Done():
		request.state.cancel()
		cancel()
		return notificationResponse{}, ctx.Err()
	case <-service.stop:
		request.state.cancel()
		cancel()
		return notificationResponse{}, service.notificationStopError()
	case <-operationContext.Done():
		request.state.cancel()
		return notificationResponse{}, operationContext.Err()
	}
}

func (service *RuntimeProfileService) notificationAdmissionError() error {
	if service == nil {
		return notification.ErrClosed
	}
	service.mu.RLock()
	defer service.mu.RUnlock()
	return service.notificationAdmissionErrorLocked()
}

func (service *RuntimeProfileService) notificationAdmissionErrorLocked() error {
	if service.uncertain {
		return notification.ErrUncertain
	}
	if service.closed || service.failed {
		return notification.ErrClosed
	}
	return nil
}

func (service *RuntimeProfileService) notificationStopError() error {
	if service == nil {
		return notification.ErrClosed
	}
	service.mu.RLock()
	defer service.mu.RUnlock()
	if service.uncertain {
		return notification.ErrUncertain
	}
	return notification.ErrClosed
}

func (service *RuntimeProfileService) closedOrUncertain() bool {
	if service == nil {
		return true
	}
	service.mu.RLock()
	defer service.mu.RUnlock()
	return service.closed || service.failed || service.uncertain
}

func (service *RuntimeProfileService) completeNotification(request notificationRequest) {
	defer func() {
		if request.cancel != nil {
			request.cancel()
		}
	}()
	response := notificationResponse{}
	if request.state == nil || !request.state.claim(request.caller) {
		if request.caller != nil {
			response.err = request.caller.Err()
		}
		if response.err == nil {
			response.err = request.ctx.Err()
		}
		if response.err == nil {
			response.err = notification.ErrClosed
		}
		completeNotificationRequest(request, response)
		return
	}
	if err := request.ctx.Err(); err != nil {
		response.err = err
		completeNotificationRequest(request, response)
		return
	}
	if request.emit != nil {
		response.emit, response.err = service.emitNotification(request.ctx, *request.emit, request.identifier)
	} else if request.selection != nil {
		response.dismissed, response.err = service.selectNotification(request.ctx, *request.selection)
	} else {
		response.clear, response.err = service.clearNotification(request.ctx, request.clearID)
	}
	completeNotificationRequest(request, response)
}

func completeNotificationRequest(request notificationRequest, response notificationResponse) {
	select {
	case request.result <- response:
	default:
	}
}

func (service *RuntimeProfileService) emitNotification(ctx context.Context, request notification.EmitRequest, identifier string) (notification.EmitResult, error) {
	snapshot, err := service.notificationSnapshotForWrite()
	if err != nil {
		return notification.EmitResult{}, err
	}
	prospective := snapshot.notifications.clone()
	matched := make([]byte, 0, d200x.DisplayPositionCount)
	for _, value := range snapshot.current.Values {
		spec, ok := d200x.LookupPosition(value.Position)
		if !ok || !containsNotificationSource(value.NotificationSources, request.Source) {
			continue
		}
		wireIndex := spec.WireIndex
		prospective.overlays[wireIndex] = &notificationOverlay{
			NotificationID: identifier,
			Source:         request.Source,
			Text:           request.Text,
			PositionID:     value.ID,
			Position:       value.Position,
		}
		matched = append(matched, wireIndex)
	}
	result := notification.EmitResult{NotificationID: identifier, MatchedCount: len(matched)}
	if len(matched) == 0 {
		return result, nil
	}
	update, err := buildNotificationUpdate(snapshot.current, prospective)
	if err != nil {
		return notification.EmitResult{}, errNotificationPreparation
	}
	wrote, err := service.sendNotificationUpdate(ctx, snapshot, update, func(archive []byte) {
		deadline := time.Time{}
		if request.TTLSeconds != nil {
			deadline = service.clock.Now().Add(time.Duration(*request.TTLSeconds) * time.Second)
		}
		for _, wireIndex := range matched {
			owned := *prospective.overlays[wireIndex]
			owned.Deadline = deadline
			prospective.overlays[wireIndex] = &owned
		}
		prospective.renderedPage = append([]byte(nil), archive...)
		prospective.profileID = snapshot.currentID
		service.effective.Store(snapshot.withNotifications(prospective))
	})
	if err != nil {
		return notification.EmitResult{}, err
	}
	_ = wrote
	return result, nil
}

func (service *RuntimeProfileService) clearNotification(ctx context.Context, identifier string) (notification.ClearResult, error) {
	snapshot, err := service.notificationSnapshotForWrite()
	if err != nil {
		return notification.ClearResult{}, err
	}
	prospective := snapshot.notifications.clone()
	cleared := 0
	for index, overlay := range prospective.overlays {
		if overlay == nil || overlay.NotificationID != identifier {
			continue
		}
		prospective.overlays[index] = nil
		cleared++
	}
	if cleared == 0 {
		return notification.ClearResult{}, nil
	}
	update, err := buildNotificationUpdate(snapshot.current, prospective)
	if err != nil {
		return notification.ClearResult{}, errNotificationPreparation
	}
	wrote, err := service.sendNotificationUpdate(ctx, snapshot, update, func(archive []byte) {
		prospective.renderedPage = append([]byte(nil), archive...)
		prospective.profileID = snapshot.currentID
		service.effective.Store(snapshot.withNotifications(prospective))
	})
	if err != nil {
		return notification.ClearResult{}, err
	}
	_ = wrote
	return notification.ClearResult{ClearedCount: cleared}, nil
}

func (service *RuntimeProfileService) selectNotification(ctx context.Context, selection notificationSelection) (bool, error) {
	if err := ctx.Err(); err != nil {
		return false, err
	}
	snapshot, err := service.notificationSnapshotForWrite()
	if err != nil {
		return false, err
	}
	if selection.profileID == "" || selection.profileID != snapshot.currentID ||
		!matchesProfileActionSnapshot(selection.snapshot, snapshot.currentID, snapshot.bindings) {
		return false, nil
	}
	currentBinding, hasBinding := actionBindingAt(profileActionSnapshot{
		profileID: snapshot.currentID,
		bindings:  snapshot.bindings,
	}, selection.position)
	if hasBinding != selection.hasBinding || (hasBinding && !equalProfileBinding(currentBinding, selection.binding)) {
		return false, nil
	}
	positions := eventPositionsForProfile(snapshot.current)
	position, ok := positions[selection.wireIndex]
	if !ok || position.id != selection.positionID || position.position != selection.position {
		return false, nil
	}
	if int(selection.wireIndex) >= len(snapshot.notifications.overlays) {
		return false, nil
	}
	overlay := snapshot.notifications.overlays[selection.wireIndex]
	if overlay == nil || overlay.NotificationID != selection.notificationID || overlay.PositionID != selection.positionID || overlay.Position != selection.position || !overlay.Deadline.Equal(selection.deadline) {
		return false, nil
	}
	if !overlay.Deadline.IsZero() && !service.clock.Now().Before(overlay.Deadline) {
		return false, nil
	}
	if err := ctx.Err(); err != nil {
		return false, err
	}
	prospective := snapshot.notifications.clone()
	prospective.overlays[selection.wireIndex] = nil
	update, err := buildNotificationUpdate(snapshot.current, prospective)
	if err != nil {
		return false, errNotificationPreparation
	}
	dismissed := false
	if _, err := service.sendNotificationUpdateGuarded(ctx, snapshot, update, func() error {
		if !selection.deadline.IsZero() && !service.clock.Now().Before(selection.deadline) {
			return errNotificationSelectionExpired
		}
		return nil
	}, func(archive []byte) {
		prospective.renderedPage = append([]byte(nil), archive...)
		prospective.profileID = snapshot.currentID
		service.effective.Store(snapshot.withNotifications(prospective))
		dismissed = true
	}); err != nil {
		if errors.Is(err, errNotificationSelectionExpired) {
			return false, nil
		}
		return false, err
	}
	return dismissed, nil
}

func (service *RuntimeProfileService) notificationSnapshotForWrite() (*effectiveSnapshot, error) {
	if err := service.notificationAdmissionError(); err != nil {
		return nil, err
	}
	snapshot := service.effective.Load()
	if snapshot == nil {
		return nil, notification.ErrClosed
	}
	return snapshot, nil
}

func (service *RuntimeProfileService) sendNotificationUpdate(ctx context.Context, snapshot *effectiveSnapshot, update d200x.LivePageUpdate, commit func([]byte)) (bool, error) {
	return service.sendNotificationUpdateGuarded(ctx, snapshot, update, nil, commit)
}

func (service *RuntimeProfileService) sendNotificationUpdateGuarded(ctx context.Context, snapshot *effectiveSnapshot, update d200x.LivePageUpdate, beforeWrite func() error, commit func([]byte)) (bool, error) {
	archive := update.Archive().Data
	if err := ctx.Err(); err != nil {
		return false, err
	}
	service.beginTransition(snapshot.currentID, snapshot.currentID)
	defer service.endTransition(snapshot.currentID, snapshot.currentID)
	if err := ctx.Err(); err != nil {
		return false, err
	}
	if beforeWrite != nil {
		if err := beforeWrite(); err != nil {
			return false, err
		}
	}
	wrote := !bytes.Equal(snapshot.notifications.renderedPage, archive)
	if wrote {
		if err := service.sender.SendLivePageUpdate(ctx, update); err != nil {
			service.markUncertain(err)
			return true, notification.ErrUncertain
		}
	} else if err := ctx.Err(); err != nil {
		return false, err
	}
	if commit != nil {
		commit(archive)
	}
	return wrote, nil
}

func buildNotificationUpdate(current profile.Profile, notifications notificationSnapshot) (d200x.LivePageUpdate, error) {
	composed := cloneRuntimeProfile(current)
	for index := range composed.Values {
		spec, ok := d200x.LookupPosition(composed.Values[index].Position)
		if !ok {
			continue
		}
		if overlay := notifications.overlays[spec.WireIndex]; overlay != nil {
			composed.Values[index].Label = overlay.Text
		}
	}
	page, err := pageForProfile(composed)
	if err != nil {
		return d200x.LivePageUpdate{}, err
	}
	return d200x.BuildLivePageUpdate(page)
}

func containsNotificationSource(sources []string, source string) bool {
	for _, candidate := range sources {
		if candidate == source {
			return true
		}
	}
	return false
}

func (service *RuntimeProfileService) notificationExpiryDue() bool {
	if service == nil || service.notificationAdmissionError() != nil {
		return false
	}
	snapshot := service.effective.Load()
	if snapshot == nil {
		return false
	}
	deadline, ok := snapshot.notifications.earliestDeadline()
	return ok && !service.clock.Now().Before(deadline)
}

func (service *RuntimeProfileService) rearmNotificationTimer(timer *Timer) {
	if timer == nil {
		return
	}
	stopTimer(*timer)
	*timer = nil
	if service == nil || service.notificationAdmissionError() != nil {
		return
	}
	snapshot := service.effective.Load()
	if snapshot == nil {
		return
	}
	deadline, ok := snapshot.notifications.earliestDeadline()
	if !ok {
		return
	}
	duration := deadline.Sub(service.clock.Now())
	if duration < 0 {
		duration = 0
	}
	*timer = service.clock.NewTimer(duration)
}

func (service *RuntimeProfileService) expireNotifications() {
	if service == nil || service.notificationAdmissionError() != nil {
		return
	}
	snapshot := service.effective.Load()
	if snapshot == nil {
		return
	}
	now := service.clock.Now()
	prospective := snapshot.notifications.clone()
	removed := false
	for index, overlay := range prospective.overlays {
		if overlay == nil || overlay.Deadline.IsZero() || now.Before(overlay.Deadline) {
			continue
		}
		prospective.overlays[index] = nil
		removed = true
	}
	if !removed {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), notificationOperationBudget)
	defer cancel()
	update, err := buildNotificationUpdate(snapshot.current, prospective)
	if err != nil {
		service.markInternal(errNotificationPreparation)
		return
	}
	if _, err := service.sendNotificationUpdate(ctx, snapshot, update, func(archive []byte) {
		prospective.renderedPage = append([]byte(nil), archive...)
		prospective.profileID = snapshot.currentID
		service.effective.Store(snapshot.withNotifications(prospective))
	}); err != nil {
		return
	}
}
