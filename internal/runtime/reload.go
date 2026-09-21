package runtime

import (
	"context"
	"errors"
	"fmt"
	"sync"

	appconfig "hidhogg/internal/config"
	"hidhogg/internal/profile"
)

var (
	ErrReloadBusy            = errors.New("configuration reload is busy")
	ErrReloadClosed          = errors.New("configuration reload is closed")
	ErrReloadSettingsPending = errors.New("configuration settings reload is pending")
)

type ReloadOutcome string

type ReloadState string

type ReloadReason string

const (
	ReloadOutcomeReady       ReloadOutcome = "ready"
	ReloadOutcomeChanged     ReloadOutcome = "changed"
	ReloadOutcomeUnchanged   ReloadOutcome = "unchanged"
	ReloadOutcomeRejected    ReloadOutcome = "rejected"
	ReloadOutcomeUnsupported ReloadOutcome = "unsupported"

	ReloadStateIdle      ReloadState = "idle"
	ReloadStateReloading ReloadState = "reloading"
	ReloadStateClosed    ReloadState = "closed"

	ReloadReasonNone              ReloadReason = "none"
	ReloadReasonCandidateRejected ReloadReason = "candidate-rejected"
	ReloadReasonSettingsPending   ReloadReason = "settings-pending"
	ReloadReasonCanceled          ReloadReason = "canceled"
	ReloadReasonDeviceWriteFailed ReloadReason = "device-write-failed"
	ReloadReasonClosed            ReloadReason = "closed"
)

type ReloadResult struct {
	Revision               uint64
	Changed                bool
	Effect                 reloadEffectKind
	CatalogChanged         bool
	DefaultChanged         bool
	CurrentProfileChanged  bool
	CurrentProfileFallback bool
	ActionChanged          bool
	DisplayChanged         bool
	BrightnessChanged      bool
	IdleChanged            bool
	DisplayUpdated         bool
}

type ReloadStatus struct {
	Revision   uint64
	Active     bool
	State      ReloadState
	Outcome    ReloadOutcome
	Reason     ReloadReason
	Diagnostic *appconfig.DiagnosticProjection
}

type idleSettingsApplyResult struct {
	writeAttempted bool
}

type idleSettingsApplier interface {
	ApplySettings(context.Context, reloadSettings) (idleSettingsApplyResult, error)
}

type effectiveSnapshot struct {
	catalog       profile.Catalog
	current       profile.Profile
	currentID     string
	defaultID     string
	bindings      []profile.Binding
	settings      reloadSettings
	renderedPage  []byte
	notifications notificationSnapshot
	revision      uint64
}

func effectiveSnapshotFromCandidate(candidate reloadCandidate, revision uint64) *effectiveSnapshot {
	return &effectiveSnapshot{
		catalog:       candidate.Catalog(),
		current:       candidate.CurrentProfile(),
		currentID:     candidate.CurrentProfileID(),
		defaultID:     candidate.DefaultProfileID(),
		bindings:      candidate.CurrentProfile().Bindings(),
		settings:      candidate.Settings(),
		renderedPage:  candidate.RenderedPage(),
		notifications: newNotificationSnapshot(candidate.CurrentProfileID(), candidate.RenderedPage()),
		revision:      revision,
	}
}

func (snapshot *effectiveSnapshot) candidate() reloadCandidate {
	if snapshot == nil {
		return reloadCandidate{}
	}
	current := cloneRuntimeProfile(snapshot.current)
	return reloadCandidate{
		catalog:          snapshot.catalog,
		currentProfile:   current,
		currentProfileID: snapshot.currentID,
		defaultProfileID: snapshot.defaultID,
		settings:         snapshot.settings,
		renderedPage:     append([]byte(nil), snapshot.renderedPage...),
	}
}

func (snapshot *effectiveSnapshot) withCurrent(current profile.Profile, renderedPage []byte) *effectiveSnapshot {
	return &effectiveSnapshot{
		catalog:       snapshot.catalog,
		current:       cloneRuntimeProfile(current),
		currentID:     current.ID,
		defaultID:     snapshot.defaultID,
		bindings:      current.Bindings(),
		settings:      snapshot.settings,
		renderedPage:  append([]byte(nil), renderedPage...),
		notifications: newNotificationSnapshot(current.ID, renderedPage),
		revision:      snapshot.revision,
	}
}

func (snapshot *effectiveSnapshot) withNotifications(notifications notificationSnapshot) *effectiveSnapshot {
	if snapshot == nil {
		return nil
	}
	clone := *snapshot
	clone.notifications = notifications.clone()
	return &clone
}

type reloadAdmission struct {
	mu         sync.Mutex
	active     bool
	closed     bool
	dirty      bool
	outcome    ReloadOutcome
	reason     ReloadReason
	diagnostic *appconfig.DiagnosticProjection
}

func (admission *reloadAdmission) begin() error {
	admission.mu.Lock()
	defer admission.mu.Unlock()
	if admission.closed {
		return ErrReloadClosed
	}
	if admission.active {
		return ErrReloadBusy
	}
	admission.active = true
	return nil
}

func (admission *reloadAdmission) beginAutomatic() bool {
	admission.mu.Lock()
	defer admission.mu.Unlock()
	if admission.closed {
		return false
	}
	if admission.active {
		admission.dirty = true
		return false
	}
	admission.active = true
	return true
}

func (admission *reloadAdmission) finish(outcome ReloadOutcome, reason ReloadReason, diagnostic *appconfig.DiagnosticProjection) bool {
	admission.mu.Lock()
	admission.active = false
	admission.outcome = outcome
	admission.reason = reason
	admission.diagnostic = cloneDiagnosticProjection(diagnostic)
	dirty := admission.dirty && !admission.closed
	admission.dirty = false
	admission.mu.Unlock()
	return dirty
}

func (admission *reloadAdmission) close() {
	admission.mu.Lock()
	admission.closed = true
	admission.mu.Unlock()
}

func (r *Runtime) Reload(ctx context.Context) (ReloadResult, error) {
	if r == nil {
		return ReloadResult{}, ErrReloadClosed
	}
	if err := r.reload.begin(); err != nil {
		return ReloadResult{}, err
	}
	return r.reloadStarted(ctx)
}

func (r *Runtime) reloadAutomatically(ctx context.Context) {
	if r == nil || !r.reload.beginAutomatic() {
		return
	}
	_, _ = r.reloadStarted(ctx)
}

func (r *Runtime) reloadStarted(ctx context.Context) (ReloadResult, error) {
	outcome := ReloadOutcomeRejected
	reason := ReloadReasonCandidateRejected
	var statusDiagnostic *appconfig.DiagnosticProjection
	defer func() {
		if r.reload.finish(outcome, reason, statusDiagnostic) {
			r.signalAutomaticReload()
		}
	}()

	service := r.ProfileService()
	if service == nil {
		reason = ReloadReasonClosed
		return ReloadResult{}, ErrReloadClosed
	}
	concrete, ok := service.(*RuntimeProfileService)
	if !ok {
		reason = ReloadReasonClosed
		return ReloadResult{}, ErrReloadClosed
	}
	r.mu.Lock()
	configPath := r.config.ConfigPath
	build := r.reloadBuilder
	r.mu.Unlock()
	if build == nil {
		build = buildReloadCandidate
	}
	var candidateErr error
	result, err := concrete.reload(ctx, func(currentID string) (reloadCandidate, error) {
		candidate, buildErr := build(configPath, currentID)
		candidateErr = buildErr
		return candidate, buildErr
	})
	if result.Revision == 0 {
		result.Revision = concrete.revision()
	}
	switch {
	case err == nil && result.Changed:
		outcome = ReloadOutcomeChanged
		reason = ReloadReasonNone
	case err == nil:
		outcome = ReloadOutcomeUnchanged
		reason = ReloadReasonNone
	case concrete.Uncertain(), errors.Is(err, ErrProfileStateUncertain):
		reason = ReloadReasonDeviceWriteFailed
	case errors.Is(err, ErrReloadSettingsPending):
		outcome = ReloadOutcomeUnsupported
		reason = ReloadReasonSettingsPending
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		reason = ReloadReasonCanceled
	case errors.Is(err, ErrReloadClosed), errors.Is(err, ErrProfileServiceClosed):
		reason = ReloadReasonClosed
	}
	if outcome == ReloadOutcomeRejected && reason == ReloadReasonCandidateRejected {
		statusDiagnostic = appconfig.SafeDiagnosticProjection(candidateErr)
	}
	if candidateErr != nil {
		r.logConfigCandidateRejection(candidateErr)
	}
	return result, err
}

func (r *Runtime) logConfigCandidateRejection(err error) {
	var diagnostic *appconfig.Diagnostic
	if r == nil || !errors.As(err, &diagnostic) || diagnostic == nil {
		return
	}
	r.mu.Lock()
	writer := r.stderr
	r.mu.Unlock()
	if writer != nil {
		_, _ = fmt.Fprintf(writer, "runtime config reload rejected: %s\n", diagnostic)
	}
}

func (r *Runtime) ReloadStatus() ReloadStatus {
	if r == nil {
		return ReloadStatus{State: ReloadStateClosed, Outcome: ReloadOutcomeReady, Reason: ReloadReasonClosed}
	}
	r.reload.mu.Lock()
	active := r.reload.active
	closed := r.reload.closed
	outcome := r.reload.outcome
	reason := r.reload.reason
	diagnostic := cloneDiagnosticProjection(r.reload.diagnostic)
	r.reload.mu.Unlock()
	state := ReloadStateIdle
	if active {
		state = ReloadStateReloading
	} else if closed {
		state = ReloadStateClosed
	}
	service := r.ProfileService()
	if service == nil {
		return ReloadStatus{Active: active, State: state, Outcome: outcome, Reason: reason, Diagnostic: diagnostic}
	}
	concrete, ok := service.(*RuntimeProfileService)
	if !ok {
		return ReloadStatus{Active: active, State: state, Outcome: outcome, Reason: reason, Diagnostic: diagnostic}
	}
	return ReloadStatus{Revision: concrete.revision(), Active: active, State: state, Outcome: outcome, Reason: reason, Diagnostic: diagnostic}
}

func cloneDiagnosticProjection(source *appconfig.DiagnosticProjection) *appconfig.DiagnosticProjection {
	if source == nil {
		return nil
	}
	copy := *source
	return &copy
}
