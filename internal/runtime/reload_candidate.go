package runtime

import (
	"bytes"
	"errors"
	"slices"
	"time"

	"hidhogg/internal/d200x"
	"hidhogg/internal/profile"
)

type reloadSettings struct {
	brightness  int
	idleTimeout time.Duration
}

type reloadCandidate struct {
	catalog                profile.Catalog
	currentProfile         profile.Profile
	currentProfileID       string
	defaultProfileID       string
	page                   d200x.Page
	settings               reloadSettings
	renderedPage           []byte
	livePageUpdate         d200x.LivePageUpdate
	currentProfileFallback bool
}

type reloadEffectKind string

const (
	reloadEffectUnchanged  reloadEffectKind = "unchanged"
	reloadEffectActionOnly reloadEffectKind = "action-only"
	reloadEffectDisplay    reloadEffectKind = "display"
	reloadEffectBrightness reloadEffectKind = "brightness"
	reloadEffectIdle       reloadEffectKind = "idle"
	reloadEffectDefault    reloadEffectKind = "default"
	reloadEffectCatalog    reloadEffectKind = "catalog"
)

type reloadEffects struct {
	effect                 reloadEffectKind
	catalogChanged         bool
	defaultChanged         bool
	currentProfileChanged  bool
	currentProfileFallback bool
	actionChanged          bool
	displayChanged         bool
	brightnessChanged      bool
	idleChanged            bool
}

func buildReloadCandidate(configPath, currentProfileID string) (reloadCandidate, error) {
	configuration, err := loadConfiguration(configPath)
	if err != nil {
		return reloadCandidate{}, err
	}
	catalog, err := configuration.ProfileCatalog()
	if err != nil {
		return reloadCandidate{}, errors.New("invalid configuration")
	}
	defaultProfile, ok := catalog.Default()
	if !ok {
		return reloadCandidate{}, errors.New("invalid configuration")
	}

	currentProfile, ok := catalog.Lookup(currentProfileID)
	fallback := false
	if !ok {
		currentProfile = defaultProfile
		currentProfileID = defaultProfile.ID
		fallback = true
	}
	page, err := pageForProfile(currentProfile)
	if err != nil {
		return reloadCandidate{}, errors.New("invalid configuration")
	}
	livePageUpdate, err := d200x.BuildLivePageUpdate(page)
	if err != nil {
		return reloadCandidate{}, errors.New("invalid configuration")
	}

	return reloadCandidate{
		catalog:                catalog,
		currentProfile:         cloneRuntimeProfile(currentProfile),
		currentProfileID:       currentProfileID,
		defaultProfileID:       configuration.DefaultProfileID,
		page:                   livePageUpdate.Page(),
		settings:               reloadSettings{brightness: configuration.Brightness, idleTimeout: time.Duration(configuration.IdleTimeoutSeconds) * time.Second},
		renderedPage:           livePageUpdate.Archive().Data,
		livePageUpdate:         livePageUpdate,
		currentProfileFallback: fallback,
	}, nil
}

func compareReloadCandidate(current, candidate reloadCandidate) reloadEffects {
	diff := reloadEffects{
		catalogChanged:         !equalProfileCatalog(current.catalog, candidate.catalog),
		defaultChanged:         current.defaultProfileID != candidate.defaultProfileID,
		currentProfileChanged:  current.currentProfileID != candidate.currentProfileID || !equalProfiles(current.currentProfile, candidate.currentProfile),
		currentProfileFallback: candidate.currentProfileFallback,
		actionChanged:          !equalProfileBindings(current.currentProfile.Bindings(), candidate.currentProfile.Bindings()),
		displayChanged:         !bytes.Equal(current.renderedPage, candidate.renderedPage),
		brightnessChanged:      current.settings.brightness != candidate.settings.brightness,
		idleChanged:            current.settings.idleTimeout != candidate.settings.idleTimeout,
	}
	diff.effect = reloadEffectFor(diff)
	return diff
}

func reloadEffectFor(diff reloadEffects) reloadEffectKind {
	if !diff.anyChanged() {
		return reloadEffectUnchanged
	}
	if diff.actionChanged && !diff.displayChanged && !diff.brightnessChanged && !diff.idleChanged && !diff.defaultChanged && !diff.currentProfileFallback && diff.currentProfileChanged {
		return reloadEffectActionOnly
	}
	if diff.displayChanged {
		return reloadEffectDisplay
	}
	if diff.brightnessChanged {
		return reloadEffectBrightness
	}
	if diff.idleChanged {
		return reloadEffectIdle
	}
	if diff.defaultChanged || diff.currentProfileFallback {
		return reloadEffectDefault
	}
	return reloadEffectCatalog
}

func (diff reloadEffects) anyChanged() bool {
	return diff.catalogChanged || diff.defaultChanged || diff.currentProfileChanged || diff.currentProfileFallback || diff.actionChanged || diff.displayChanged || diff.brightnessChanged || diff.idleChanged
}

func (diff reloadEffects) Effect() reloadEffectKind {
	return diff.effect
}

func (diff reloadEffects) CatalogChanged() bool {
	return diff.catalogChanged
}

func (diff reloadEffects) DefaultChanged() bool {
	return diff.defaultChanged
}

func (diff reloadEffects) CurrentProfileChanged() bool {
	return diff.currentProfileChanged
}

func (diff reloadEffects) CurrentProfileFallback() bool {
	return diff.currentProfileFallback
}

func (diff reloadEffects) ActionChanged() bool {
	return diff.actionChanged
}

func (diff reloadEffects) DisplayChanged() bool {
	return diff.displayChanged
}

func (diff reloadEffects) BrightnessChanged() bool {
	return diff.brightnessChanged
}

func (diff reloadEffects) IdleChanged() bool {
	return diff.idleChanged
}

func (candidate reloadCandidate) Catalog() profile.Catalog {
	return candidate.catalog
}

func (candidate reloadCandidate) CurrentProfile() profile.Profile {
	return cloneRuntimeProfile(candidate.currentProfile)
}

func (candidate reloadCandidate) CurrentProfileID() string {
	return candidate.currentProfileID
}

func (candidate reloadCandidate) DefaultProfileID() string {
	return candidate.defaultProfileID
}

func (candidate reloadCandidate) Page() d200x.Page {
	return d200x.NewPage(candidate.page.Positions)
}

func (candidate reloadCandidate) Settings() reloadSettings {
	return candidate.settings
}

func (candidate reloadCandidate) RenderedPage() []byte {
	return append([]byte(nil), candidate.renderedPage...)
}

func (candidate reloadCandidate) LivePageUpdate() d200x.LivePageUpdate {
	return candidate.livePageUpdate
}

func (candidate reloadCandidate) CurrentProfileFallback() bool {
	return candidate.currentProfileFallback
}

func equalProfileCatalog(left, right profile.Catalog) bool {
	leftProfiles := left.Profiles()
	rightProfiles := right.Profiles()
	if len(leftProfiles) != len(rightProfiles) {
		return false
	}
	for index := range leftProfiles {
		if !equalProfiles(leftProfiles[index], rightProfiles[index]) {
			return false
		}
	}
	return true
}

func equalProfiles(left, right profile.Profile) bool {
	if left.ID != right.ID || left.Label != right.Label || len(left.Values) != len(right.Values) {
		return false
	}
	for index := range left.Values {
		if !equalProfileValues(left.Values[index], right.Values[index]) {
			return false
		}
	}
	return true
}

func equalProfileValues(left, right profile.Value) bool {
	if left.ID != right.ID || left.Position != right.Position || left.Label != right.Label || left.Background != right.Background {
		return false
	}
	return equalProfileActions(left.Action, right.Action)
}

func equalProfileActions(left, right *profile.Action) bool {
	if left == nil || right == nil {
		return left == nil && right == nil
	}
	return left.Type == right.Type &&
		left.Gesture == right.Gesture &&
		left.ProfileID == right.ProfileID &&
		left.Executable == right.Executable &&
		slices.Equal(left.Arguments, right.Arguments) &&
		left.TimeoutSeconds == right.TimeoutSeconds
}

func equalProfileBindings(left, right []profile.Binding) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if !equalProfileBinding(left[index], right[index]) {
			return false
		}
	}
	return true
}
