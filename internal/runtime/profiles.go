package runtime

import (
	"context"
	"errors"
	"fmt"
	"io"
	"slices"
	"sync"
	"sync/atomic"

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
	initialSnapshot  *reloadCandidate
	settingsApplier  idleSettingsApplier
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
	sender     LivePageSender
	terminal   func(error)
	cancel     context.CancelFunc
	verbose    bool
	logger     io.Writer
	logMu      sync.Mutex
	requests   chan profileActivationRequest
	reloads    chan profileReloadRequest
	stop       chan struct{}
	workerDone chan struct{}
	transition *profileTransitionGate
	effective  atomic.Pointer[effectiveSnapshot]
	settings   idleSettingsApplier

	mu        sync.RWMutex
	closed    bool
	uncertain bool
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

type profileReloadRequest struct {
	ctx    context.Context
	build  func(string) (reloadCandidate, error)
	result chan profileReloadResponse
}

type profileReloadResponse struct {
	result ReloadResult
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
	initialCandidate := reloadCandidate{
		catalog:          options.Catalog,
		currentProfile:   cloneRuntimeProfile(initial),
		currentProfileID: initial.ID,
		defaultProfileID: options.Catalog.DefaultProfileID(),
	}
	if options.initialSnapshot != nil {
		initialCandidate = *options.initialSnapshot
	} else {
		page, err := pageForProfile(initial)
		if err != nil {
			return nil, err
		}
		update, err := d200x.BuildLivePageUpdate(page)
		if err != nil {
			return nil, err
		}
		initialCandidate.page = update.Page()
		initialCandidate.renderedPage = update.Archive().Data
		initialCandidate.livePageUpdate = update
	}
	service := &RuntimeProfileService{
		sender:     options.Sender,
		terminal:   options.Terminal,
		cancel:     options.Cancel,
		verbose:    options.Verbose && options.Logger != nil,
		logger:     options.Logger,
		requests:   make(chan profileActivationRequest, profileActivationCapacity),
		reloads:    make(chan profileReloadRequest),
		stop:       make(chan struct{}),
		workerDone: make(chan struct{}),
		transition: &profileTransitionGate{},
		settings:   options.settingsApplier,
	}
	service.effective.Store(effectiveSnapshotFromCandidate(initialCandidate, 1))
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
	snapshot := service.effective.Load()
	if snapshot == nil {
		return nil
	}
	return snapshot.catalog.Profiles()
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
	snapshot := service.effective.Load()
	if snapshot == nil || snapshot.currentID == "" {
		return profile.Profile{}, false
	}
	return cloneRuntimeProfile(snapshot.current), true
}

// CurrentProfileID returns the last successfully committed profile ID.
func (service *RuntimeProfileService) CurrentProfileID() (string, bool) {
	if service == nil {
		return "", false
	}
	snapshot := service.effective.Load()
	if snapshot == nil {
		return "", false
	}
	return snapshot.currentID, snapshot.currentID != ""
}

// CurrentBindings returns the action bindings of the last successfully
// committed profile.
func (service *RuntimeProfileService) CurrentBindings() []profile.Binding {
	if service == nil {
		return nil
	}
	snapshot := service.effective.Load()
	if snapshot == nil {
		return nil
	}
	return cloneRuntimeBindings(snapshot.bindings)
}

func (service *RuntimeProfileService) currentActionSnapshot() profileActionSnapshot {
	if service == nil {
		return profileActionSnapshot{}
	}
	snapshot := service.effective.Load()
	if snapshot == nil {
		return profileActionSnapshot{}
	}
	return profileActionSnapshot{
		profileID: snapshot.currentID,
		bindings:  cloneRuntimeBindings(snapshot.bindings),
	}
}

// CurrentEventPositions returns the committed display-position map used by
// the input and idle policy paths. It is evaluated on every observation so a
// successful activation becomes visible without restarting the policy.
func (service *RuntimeProfileService) CurrentEventPositions() map[byte]eventPosition {
	if service == nil {
		return nil
	}
	snapshot := service.effective.Load()
	if snapshot == nil {
		return nil
	}
	return eventPositionsForProfile(snapshot.current)
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

func (service *RuntimeProfileService) reload(ctx context.Context, build func(string) (reloadCandidate, error)) (ReloadResult, error) {
	if service == nil || build == nil {
		return ReloadResult{}, ErrReloadClosed
	}
	if ctx == nil {
		ctx = context.Background()
	}
	request := profileReloadRequest{ctx: ctx, build: build, result: make(chan profileReloadResponse, 1)}
	select {
	case <-ctx.Done():
		return ReloadResult{}, ctx.Err()
	case <-service.stop:
		return ReloadResult{}, ErrReloadClosed
	case service.reloads <- request:
	}
	select {
	case response := <-request.result:
		return response.result, response.err
	case <-service.stop:
		return ReloadResult{}, ErrReloadClosed
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
		case request := <-service.reloads:
			service.completeReload(request)
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
		case request := <-service.reloads:
			completeReloadRequest(request, profileReloadResponse{err: ErrReloadClosed})
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

func (service *RuntimeProfileService) completeReload(request profileReloadRequest) {
	response := service.applyReload(request.ctx, request.build)
	completeReloadRequest(request, response)
}

func completeReloadRequest(request profileReloadRequest, response profileReloadResponse) {
	select {
	case request.result <- response:
	default:
	}
}

func (service *RuntimeProfileService) applyReload(ctx context.Context, build func(string) (reloadCandidate, error)) profileReloadResponse {
	if err := ctx.Err(); err != nil {
		return profileReloadResponse{err: err}
	}
	current := service.effective.Load()
	if current == nil {
		return profileReloadResponse{err: ErrReloadClosed}
	}
	candidate, err := build(current.currentID)
	if err != nil {
		return profileReloadResponse{result: ReloadResult{Revision: current.revision}, err: err}
	}
	diff := compareReloadCandidate(current.candidate(), candidate)
	result := ReloadResult{
		Revision:               current.revision,
		Effect:                 diff.Effect(),
		CatalogChanged:         diff.CatalogChanged(),
		DefaultChanged:         diff.DefaultChanged(),
		CurrentProfileChanged:  diff.CurrentProfileChanged(),
		CurrentProfileFallback: diff.CurrentProfileFallback(),
		ActionChanged:          diff.ActionChanged(),
		DisplayChanged:         diff.DisplayChanged(),
		BrightnessChanged:      diff.BrightnessChanged(),
		IdleChanged:            diff.IdleChanged(),
	}
	if !diff.anyChanged() {
		return profileReloadResponse{result: result}
	}
	if err := ctx.Err(); err != nil {
		return profileReloadResponse{result: result, err: err}
	}
	service.mu.RLock()
	closed := service.closed
	uncertain := service.uncertain
	service.mu.RUnlock()
	if closed {
		return profileReloadResponse{result: result, err: ErrReloadClosed}
	}
	if uncertain {
		return profileReloadResponse{result: result, err: ErrProfileStateUncertain}
	}
	service.beginTransition(current.currentID, candidate.CurrentProfileID())
	defer service.endTransition(current.currentID, candidate.CurrentProfileID())
	if err := ctx.Err(); err != nil {
		return profileReloadResponse{result: result, err: err}
	}
	displayApplied := false
	if diff.DisplayChanged() {
		if err := service.sender.SendLivePageUpdate(ctx, candidate.LivePageUpdate()); err != nil {
			service.markUncertain(err)
			return profileReloadResponse{result: result, err: uncertainReloadError(err)}
		}
		displayApplied = true
		result.DisplayUpdated = true
	}
	if diff.BrightnessChanged() || diff.IdleChanged() {
		if service.settings == nil {
			if displayApplied {
				service.markUncertain(ErrReloadSettingsPending)
				return profileReloadResponse{result: result, err: uncertainReloadError(ErrReloadSettingsPending)}
			}
			return profileReloadResponse{result: result, err: ErrReloadSettingsPending}
		}
		settingsResult, err := service.settings.ApplySettings(ctx, candidate.Settings())
		if err != nil {
			if displayApplied || settingsResult.writeAttempted {
				service.markUncertain(err)
				return profileReloadResponse{result: result, err: uncertainReloadError(err)}
			}
			return profileReloadResponse{result: result, err: err}
		}
	}
	result.Revision++
	result.Changed = true
	service.effective.Store(effectiveSnapshotFromCandidate(candidate, result.Revision))
	return profileReloadResponse{result: result}
}

func uncertainReloadError(err error) error {
	if err == nil {
		return ErrProfileStateUncertain
	}
	return fmt.Errorf("%w: %w", ErrProfileStateUncertain, err)
}

func (service *RuntimeProfileService) revision() uint64 {
	if service == nil {
		return 0
	}
	snapshot := service.effective.Load()
	if snapshot == nil {
		return 0
	}
	return snapshot.revision
}

func (service *RuntimeProfileService) defaultProfileID() string {
	if service == nil {
		return ""
	}
	snapshot := service.effective.Load()
	if snapshot == nil {
		return ""
	}
	return snapshot.defaultID
}

func (service *RuntimeProfileService) effectiveSettings() reloadSettings {
	if service == nil {
		return reloadSettings{}
	}
	snapshot := service.effective.Load()
	if snapshot == nil {
		return reloadSettings{}
	}
	return snapshot.settings
}

func (service *RuntimeProfileService) activate(ctx context.Context, requestedID string, expected ...*profileActionSnapshot) profileActivationResponse {
	if err := ctx.Err(); err != nil {
		return profileActivationResponse{err: err}
	}
	var expectedSnapshot *profileActionSnapshot
	if len(expected) > 0 {
		expectedSnapshot = expected[0]
	}
	snapshot := service.effective.Load()
	if snapshot == nil {
		return profileActivationResponse{err: ErrProfileServiceClosed}
	}
	service.mu.RLock()
	if expectedSnapshot != nil && !matchesProfileActionSnapshot(*expectedSnapshot, snapshot.currentID, snapshot.bindings) {
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
	currentID := snapshot.currentID
	service.mu.RUnlock()
	if requestedID == currentID {
		return profileActivationResponse{result: ActivationResult{ProfileID: currentID, Changed: false}}
	}
	target, ok := snapshot.catalog.Lookup(requestedID)
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
	service.effective.Store(snapshot.withCurrent(target, update.Archive().Data))
	service.logTransition("committed", currentID, target.ID, 1)
	return profileActivationResponse{result: ActivationResult{ProfileID: target.ID, Changed: true}}
}

func matchesProfileActionSnapshot(expected profileActionSnapshot, currentID string, currentBindings []profile.Binding) bool {
	if expected.profileID != currentID || len(expected.bindings) != len(currentBindings) {
		return false
	}
	for index := range expected.bindings {
		if !equalProfileBinding(expected.bindings[index], currentBindings[index]) {
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
		position := d200x.Position{
			ID:             value.ID,
			Position:       value.Position,
			Label:          value.Label,
			Background:     value.Background,
			LabelAlignment: value.LabelAlignment,
			LabelSize:      value.LabelSize,
		}
		if position.LabelAlignment == "" {
			position.LabelAlignment = d200x.DefaultLabelAlignment
		}
		if position.LabelSize == 0 {
			position.LabelSize = d200x.DefaultLabelSize
		}
		positions = append(positions, position)
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
	for index := range owned {
		owned[index].Action.Arguments = slices.Clone(bindings[index].Action.Arguments)
	}
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
