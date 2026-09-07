package runtime

import (
	"context"
	"errors"
	"fmt"
	"io"
	"sync"

	"hidhogg/internal/d200x"
	"hidhogg/internal/profile"
)

const (
	profileActivationCapacity = 8
	// ProfileActivationCapacity is the maximum number of queued activation
	// requests behind the one request currently being processed.
	ProfileActivationCapacity = profileActivationCapacity
)

var (
	ErrUnknownProfile        = errors.New("unknown profile")
	ErrProfileStateUncertain = errors.New("profile state is uncertain")
	ErrProfileServiceClosed  = errors.New("profile service is closed")
)

// ErrUnknownProfileID is an explicit alias for callers that distinguish an
// identifier lookup failure from other activation failures.
var ErrUnknownProfileID = ErrUnknownProfile

// ErrRuntimeUncertain identifies a device state that can no longer be
// represented as one of the committed profiles.
var ErrRuntimeUncertain = ErrProfileStateUncertain

// ProfileService is the narrow runtime boundary consumed by future IPC and
// input-action callers. Profile values and bindings returned by the service
// are independent copies owned by the caller.
type ProfileService interface {
	ListProfiles() []profile.Profile
	CurrentProfile() (profile.Profile, bool)
	CurrentProfileID() (string, bool)
	CurrentBindings() []profile.Binding
	ActivateProfile(context.Context, string) (ActivationResult, error)
}

// ActivationResult reports the committed profile after an activation request.
// A current-profile request succeeds as an idempotent no-op with Changed=false.
type ActivationResult struct {
	ProfileID string `json:"profile_id"`
	Changed   bool   `json:"changed"`
}

// PageSender is the startup device operation. Profile activation uses the
// separate typed live-update sender so it cannot accidentally repeat startup's
// complete-page sequence.
type PageSender interface {
	SendPage(context.Context, d200x.Page, int) error
}

// LivePageSender emits one prebuilt, typed full-page update. A profile
// transition owns the prebuild boundary and invokes this method once; the
// concrete D200X session serializes all reports for that one frame.
type LivePageSender interface {
	SendLivePageUpdate(context.Context, d200x.LivePageUpdate) error
}

// ProfileServiceOptions supplies validated catalog state and the single typed
// live-page sender used by RuntimeProfileService. Terminal is called once
// after a live display transition fails and the service has entered the
// uncertain state. Cancel, when supplied, is invoked after Terminal to stop
// the caller's runtime context.
type ProfileServiceOptions struct {
	Catalog          profile.Catalog
	Sender           LivePageSender
	InitialProfileID string
	Terminal         func(error)
	Cancel           context.CancelFunc
	Verbose          bool
	Logger           io.Writer
}

// RuntimeProfileService owns the committed profile and serializes full-page
// live redraw activation requests through a bounded coordinator. Each redraw
// is one logical frame encoded into multiple transport reports; device-side
// physical atomicity is not proven. Failed writes are terminal, and callers
// may invoke the service concurrently.
type RuntimeProfileService struct {
	catalog    profile.Catalog
	sender     LivePageSender
	terminal   func(error)
	cancel     context.CancelFunc
	verbose    bool
	logger     io.Writer
	logMu      sync.Mutex
	requests   chan profileActivationRequest
	stop       chan struct{}
	workerDone chan struct{}
	transition *profileTransitionGate

	mu             sync.RWMutex
	closed         bool
	uncertain      bool
	current        profile.Profile
	currentID      string
	currentBinding []profile.Binding

	closeOnce sync.Once
}

type profileActivationRequest struct {
	ctx       context.Context
	profileID string
	expected  *profileActionSnapshot
	result    chan profileActivationResponse
}

type profileActivationResponse struct {
	result ActivationResult
	err    error
}

// NewProfileService constructs a profile service with the configured default
// profile committed. It starts no HID operation and validates all constructor
// inputs before starting the coordinator.
func NewProfileService(options ProfileServiceOptions) (*RuntimeProfileService, error) {
	if options.Sender == nil {
		return nil, errors.New("profile service sender is nil")
	}
	initialID := options.InitialProfileID
	if initialID == "" {
		initialID = options.Catalog.DefaultProfileID()
	}
	initial, ok := options.Catalog.Lookup(initialID)
	if !ok {
		return nil, fmt.Errorf("profile service initial profile %q does not resolve", initialID)
	}
	service := &RuntimeProfileService{
		catalog:        options.Catalog,
		sender:         options.Sender,
		terminal:       options.Terminal,
		cancel:         options.Cancel,
		verbose:        options.Verbose && options.Logger != nil,
		logger:         options.Logger,
		requests:       make(chan profileActivationRequest, profileActivationCapacity),
		stop:           make(chan struct{}),
		workerDone:     make(chan struct{}),
		transition:     &profileTransitionGate{},
		current:        initial,
		currentID:      initial.ID,
		currentBinding: initial.Bindings(),
	}
	go service.runCoordinator()
	return service, nil
}

// NewRuntimeProfileService is a descriptive constructor alias.
func NewRuntimeProfileService(options ProfileServiceOptions) (*RuntimeProfileService, error) {
	return NewProfileService(options)
}

// ListProfiles returns profiles in the configured order.
func (service *RuntimeProfileService) ListProfiles() []profile.Profile {
	if service == nil {
		return nil
	}
	return service.catalog.Profiles()
}

// Profiles is an explicit alias for ListProfiles.
func (service *RuntimeProfileService) Profiles() []profile.Profile {
	return service.ListProfiles()
}

// CurrentProfile returns the last successfully committed profile. The bool
// reports whether a profile is available; it remains true when the device is
// uncertain because the last committed profile is still retained for status.
func (service *RuntimeProfileService) CurrentProfile() (profile.Profile, bool) {
	if service == nil {
		return profile.Profile{}, false
	}
	service.mu.RLock()
	defer service.mu.RUnlock()
	if service.currentID == "" {
		return profile.Profile{}, false
	}
	return cloneRuntimeProfile(service.current), true
}

// CurrentProfileID returns the last successfully committed profile ID.
func (service *RuntimeProfileService) CurrentProfileID() (string, bool) {
	if service == nil {
		return "", false
	}
	service.mu.RLock()
	defer service.mu.RUnlock()
	return service.currentID, service.currentID != ""
}

// CurrentBindings returns the action bindings of the last successfully
// committed profile.
func (service *RuntimeProfileService) CurrentBindings() []profile.Binding {
	if service == nil {
		return nil
	}
	service.mu.RLock()
	defer service.mu.RUnlock()
	return cloneRuntimeBindings(service.currentBinding)
}

func (service *RuntimeProfileService) currentActionSnapshot() profileActionSnapshot {
	if service == nil {
		return profileActionSnapshot{}
	}
	service.mu.RLock()
	defer service.mu.RUnlock()
	return profileActionSnapshot{
		profileID: service.currentID,
		bindings:  cloneRuntimeBindings(service.currentBinding),
	}
}

// CurrentEventPositions returns the committed display-position map used by
// the input and idle policy paths. It is evaluated on every observation so a
// successful activation becomes visible without restarting the policy.
func (service *RuntimeProfileService) CurrentEventPositions() map[byte]eventPosition {
	if service == nil {
		return nil
	}
	service.mu.RLock()
	defer service.mu.RUnlock()
	return eventPositionsForProfile(service.current)
}

// Uncertain reports whether a live update write failed after activation began.
func (service *RuntimeProfileService) Uncertain() bool {
	if service == nil {
		return true
	}
	service.mu.RLock()
	defer service.mu.RUnlock()
	return service.uncertain
}

// ActivateProfile enqueues one request on the bounded coordinator. A caller
// waits for its result or cancellation; queued cancellation is observed by
// the coordinator before any live batch is prepared or sent.
func (service *RuntimeProfileService) ActivateProfile(ctx context.Context, profileID string) (ActivationResult, error) {
	return service.enqueueActivation(ctx, profileID, nil)
}

func (service *RuntimeProfileService) activateProfileForAction(ctx context.Context, expected profileActionSnapshot, profileID string) (ActivationResult, error) {
	expected = expected.clone()
	return service.enqueueActivation(ctx, profileID, &expected)
}

func (service *RuntimeProfileService) enqueueActivation(ctx context.Context, profileID string, expected *profileActionSnapshot) (ActivationResult, error) {
	if service == nil {
		return ActivationResult{}, ErrProfileServiceClosed
	}
	if ctx == nil {
		ctx = context.Background()
	}
	request := profileActivationRequest{
		ctx:       ctx,
		profileID: profileID,
		expected:  expected,
		result:    make(chan profileActivationResponse, 1),
	}
	select {
	case <-ctx.Done():
		return ActivationResult{}, ctx.Err()
	case <-service.stop:
		return ActivationResult{}, service.closedError()
	case service.requests <- request:
	}
	select {
	case response := <-request.result:
		return response.result, response.err
	case <-ctx.Done():
		return ActivationResult{}, ctx.Err()
	case <-service.stop:
		return ActivationResult{}, service.closedError()
	}
}

// Close stops the coordinator after completing at most the request already
// being processed. Queued requests are completed with ErrProfileServiceClosed
// and no further live display transition can begin.
func (service *RuntimeProfileService) Close() error {
	if service == nil {
		return nil
	}
	service.closeOnce.Do(func() {
		service.mu.Lock()
		service.closed = true
		service.mu.Unlock()
		close(service.stop)
		service.drainQueuedRequests()
		<-service.workerDone
	})
	return nil
}

func (service *RuntimeProfileService) runCoordinator() {
	defer close(service.workerDone)
	for {
		select {
		case request := <-service.requests:
			service.completeRequest(request)
		case <-service.stop:
			service.drainQueuedRequests()
			return
		}
	}
}

func (service *RuntimeProfileService) drainQueuedRequests() {
	err := service.closedError()
	for {
		select {
		case request := <-service.requests:
			completeProfileRequest(request, profileActivationResponse{err: err})
		default:
			return
		}
	}
}

func (service *RuntimeProfileService) closedError() error {
	service.mu.RLock()
	defer service.mu.RUnlock()
	if service.uncertain {
		return ErrProfileStateUncertain
	}
	return ErrProfileServiceClosed
}

func (service *RuntimeProfileService) completeRequest(request profileActivationRequest) {
	response := service.activate(request.ctx, request.profileID, request.expected)
	completeProfileRequest(request, response)
}

func completeProfileRequest(request profileActivationRequest, response profileActivationResponse) {
	select {
	case request.result <- response:
	default:
	}
}

func (service *RuntimeProfileService) activate(ctx context.Context, requestedID string, expected ...*profileActionSnapshot) profileActivationResponse {
	if err := ctx.Err(); err != nil {
		return profileActivationResponse{err: err}
	}
	var expectedSnapshot *profileActionSnapshot
	if len(expected) > 0 {
		expectedSnapshot = expected[0]
	}
	service.mu.RLock()
	if expectedSnapshot != nil && !matchesProfileActionSnapshot(*expectedSnapshot, service.currentID, service.currentBinding) {
		service.mu.RUnlock()
		return profileActivationResponse{err: errProfileActionBindingChanged}
	}
	if service.uncertain {
		service.mu.RUnlock()
		return profileActivationResponse{err: ErrProfileStateUncertain}
	}
	if service.closed {
		service.mu.RUnlock()
		return profileActivationResponse{err: ErrProfileServiceClosed}
	}
	currentID := service.currentID
	service.mu.RUnlock()
	if requestedID == currentID {
		return profileActivationResponse{result: ActivationResult{ProfileID: currentID, Changed: false}}
	}
	target, ok := service.catalog.Lookup(requestedID)
	if !ok {
		return profileActivationResponse{err: fmt.Errorf("%w: %q", ErrUnknownProfile, requestedID)}
	}
	page, err := pageForProfile(target)
	if err != nil {
		return profileActivationResponse{err: fmt.Errorf("prepare profile %q: %w", requestedID, err)}
	}
	if err := ctx.Err(); err != nil {
		return profileActivationResponse{err: err}
	}
	service.mu.RLock()
	closed := service.closed
	uncertain := service.uncertain
	service.mu.RUnlock()
	if closed {
		return profileActivationResponse{err: ErrProfileServiceClosed}
	}
	if uncertain {
		return profileActivationResponse{err: ErrProfileStateUncertain}
	}
	service.beginTransition(currentID, target.ID)
	defer service.endTransition(currentID, target.ID)
	update, err := d200x.BuildLivePageUpdate(page)
	if err != nil {
		service.logTransition("prepare-failed", currentID, target.ID, 0)
		return profileActivationResponse{err: fmt.Errorf("prepare profile %q live page: %w", requestedID, err)}
	}
	service.logTransition("prepared", currentID, target.ID, 1)
	if err := service.sender.SendLivePageUpdate(ctx, update); err != nil {
		service.markUncertain(err)
		service.logTransition("write-failed", currentID, target.ID, 1)
		return profileActivationResponse{err: err}
	}
	service.mu.Lock()
	service.current = target
	service.currentID = target.ID
	service.currentBinding = target.Bindings()
	service.mu.Unlock()
	service.logTransition("committed", currentID, target.ID, 1)
	return profileActivationResponse{result: ActivationResult{ProfileID: target.ID, Changed: true}}
}

func matchesProfileActionSnapshot(expected profileActionSnapshot, currentID string, currentBindings []profile.Binding) bool {
	if expected.profileID != currentID || len(expected.bindings) != len(currentBindings) {
		return false
	}
	for index := range expected.bindings {
		if expected.bindings[index] != currentBindings[index] {
			return false
		}
	}
	return true
}

func (service *RuntimeProfileService) markUncertain(err error) {
	service.mu.Lock()
	if service.uncertain {
		service.mu.Unlock()
		return
	}
	service.uncertain = true
	terminal := service.terminal
	cancel := service.cancel
	service.mu.Unlock()
	if terminal != nil {
		terminal(err)
	}
	if cancel != nil {
		cancel()
	}
}

func pageForProfile(current profile.Profile) (d200x.Page, error) {
	positions, err := profilePositions(current)
	if err != nil {
		return d200x.Page{}, err
	}
	page := d200x.NewPage(positions)
	if err := d200x.ValidatePage(page); err != nil {
		return d200x.Page{}, err
	}
	return page, nil
}

func profilePositions(current profile.Profile) ([]d200x.Position, error) {
	positions := make([]d200x.Position, 0, len(current.Values))
	for _, value := range current.Values {
		positions = append(positions, d200x.Position{
			ID:         value.ID,
			Position:   value.Position,
			Label:      value.Label,
			Background: value.Background,
		})
	}
	if len(positions) != d200x.DisplayPositionCount {
		return nil, fmt.Errorf("profile has %d positions, want %d", len(positions), d200x.DisplayPositionCount)
	}
	return positions, nil
}

func eventPositionsForProfile(current profile.Profile) map[byte]eventPosition {
	positions := make(map[byte]eventPosition, len(current.Values))
	for _, value := range current.Values {
		spec, ok := d200x.LookupPosition(value.Position)
		if !ok {
			continue
		}
		positions[spec.WireIndex] = eventPosition{id: value.ID, position: value.Position}
	}
	return positions
}

func cloneRuntimeProfile(current profile.Profile) profile.Profile {
	values := current.ValuesCopy()
	return profile.Profile{ID: current.ID, Label: current.Label, Values: values}
}

func cloneRuntimeBindings(bindings []profile.Binding) []profile.Binding {
	if bindings == nil {
		return nil
	}
	owned := make([]profile.Binding, len(bindings))
	copy(owned, bindings)
	return owned
}

var _ ProfileService = (*RuntimeProfileService)(nil)

func (service *RuntimeProfileService) beginTransition(currentID, targetID string) {
	if service == nil || service.transition == nil {
		return
	}
	service.transition.begin()
	service.logTransition("started", currentID, targetID, 1)
}

func (service *RuntimeProfileService) endTransition(currentID, targetID string) {
	if service == nil || service.transition == nil {
		return
	}
	service.transition.end()
	service.logTransition("ended", currentID, targetID, 1)
}

func (service *RuntimeProfileService) profileTransitionGate() *profileTransitionGate {
	if service == nil {
		return nil
	}
	return service.transition
}

func (service *RuntimeProfileService) logTransition(phase, currentID, targetID string, frames int) {
	if service == nil || !service.verbose || service.logger == nil {
		return
	}
	service.logMu.Lock()
	defer service.logMu.Unlock()
	_, _ = fmt.Fprintf(service.logger, "runtime profile transition phase=%s current=%q target=%q frames=%d\n", phase, currentID, targetID, frames)
}

type profileTransitionSource interface {
	profileTransitionGate() *profileTransitionGate
}

type profileTransitionGate struct {
	mu         sync.RWMutex
	active     bool
	generation uint64
	activeDone chan struct{}
	resets     []func()
}

func (gate *profileTransitionGate) begin() {
	gate.mu.Lock()
	gate.generation++
	gate.active = true
	gate.activeDone = make(chan struct{})
	for _, reset := range gate.resets {
		reset()
	}
	gate.mu.Unlock()
}

func (gate *profileTransitionGate) end() {
	gate.mu.Lock()
	gate.active = false
	gate.generation++
	if gate.activeDone != nil {
		close(gate.activeDone)
		gate.activeDone = nil
	}
	gate.mu.Unlock()
}

func (gate *profileTransitionGate) waitInactive(ctx context.Context) error {
	if gate == nil {
		return nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	for {
		gate.mu.RLock()
		active := gate.active
		done := gate.activeDone
		gate.mu.RUnlock()
		if !active {
			return nil
		}
		select {
		case <-done:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

func (gate *profileTransitionGate) snapshot() (uint64, bool) {
	if gate == nil {
		return 0, false
	}
	gate.mu.RLock()
	defer gate.mu.RUnlock()
	return gate.generation, gate.active
}

func (gate *profileTransitionGate) registerReset(reset func()) {
	if gate == nil || reset == nil {
		return
	}
	gate.mu.Lock()
	gate.resets = append(gate.resets, reset)
	if gate.active {
		reset()
	}
	gate.mu.Unlock()
}

var _ PageSender = (*d200x.Session)(nil)
var _ LivePageSender = (*d200x.Session)(nil)
