// Package profile contains immutable, device-neutral profile values and
// action bindings. It deliberately has no runtime, IPC, HID, or filesystem
// dependencies so profile selection can be tested independently.
package profile

import (
	"fmt"
	"path"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	RequiredValueCount   = 14
	MaximumProfileCount  = 31
	MaximumStableIDRunes = 64
	MaximumLabelRunes    = 64
	MaximumLabelBytes    = 256
)

const (
	ActivateProfileType = "activate_profile"
	ExecuteActionType   = "execute"
	PressGesture        = "press"

	DefaultExecuteTimeoutSeconds = 10
	MinimumExecuteTimeoutSeconds = 1
	MaximumExecuteTimeoutSeconds = 60
	MaximumExecuteArgumentCount  = 32
	MaximumExecuteArgumentBytes  = 1024
	MaximumExecuteArgumentsBytes = 8192
)

var stableIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

// Action is a validated press action. The containing Value supplies the
// physical button binding location.
type Action struct {
	Type           string
	Gesture        string
	ProfileID      string
	Executable     string
	Arguments      []string
	TimeoutSeconds int
}

// Value is a complete neutral description of one D200X display position.
// Position identifies the physical coordinate while Action, when non-nil,
// binds a completed press to another profile.
type Value struct {
	ID         string
	Position   string
	Label      string
	Background string
	Action     *Action
}

// Position is an alias retained for consumers that use the physical-layout
// term rather than the profile-value term.
type Position = Value

// Profile is one complete neutral display layout. Values retain the source
// order supplied to NewCatalog.
type Profile struct {
	ID     string
	Label  string
	Values []Value
}

// Definition is a descriptive alias for Profile at construction call sites.
type Definition = Profile

// Binding identifies the value position to which an action is attached.
type Binding struct {
	Position string
	Action   Action
}

// Catalog is an immutable, ordered set of validated profiles. Its fields are
// private so callers can only observe defensive copies of its state.
type Catalog struct {
	profiles         []Profile
	profileByID      map[string]int
	defaultProfileID string
}

// NewCatalog validates and copies profiles into an immutable ordered catalog.
// Profile IDs are compared case-sensitively and the default ID must resolve
// to exactly one profile.
func NewCatalog(defaultProfileID string, profiles []Profile) (Catalog, error) {
	if len(profiles) < 1 || len(profiles) > MaximumProfileCount {
		return Catalog{}, fmt.Errorf("profile catalog must contain between 1 and %d profiles", MaximumProfileCount)
	}

	owned := cloneProfiles(profiles)
	normalizeActionDefaults(owned)
	profileByID := make(map[string]int, len(owned))
	for index, current := range owned {
		if !validStableID(current.ID) {
			return Catalog{}, fmt.Errorf("profile %d has an invalid ID", index)
		}
		if !validLabel(current.Label) {
			return Catalog{}, fmt.Errorf("profile %q has an invalid label", current.ID)
		}
		if _, exists := profileByID[current.ID]; exists {
			return Catalog{}, fmt.Errorf("profile ID %q is duplicated", current.ID)
		}
		profileByID[current.ID] = index
		if err := validateValues(current.Values, nil); err != nil {
			return Catalog{}, fmt.Errorf("profile %q: %w", current.ID, err)
		}
	}
	// Validate actions a second time after every profile ID is known. The first
	// pass catches malformed values early while this pass resolves forward
	// references and targets in profiles declared later in the ordered input.
	for index, current := range owned {
		if err := validateActions(current.Values, profileByID); err != nil {
			return Catalog{}, fmt.Errorf("profile %q: %w", current.ID, err)
		}
		owned[index].Values = cloneValues(current.Values)
	}
	if !validStableID(defaultProfileID) {
		return Catalog{}, fmt.Errorf("default profile ID %q is invalid", defaultProfileID)
	}
	if _, exists := profileByID[defaultProfileID]; !exists {
		return Catalog{}, fmt.Errorf("default profile ID %q does not resolve to exactly one profile", defaultProfileID)
	}

	return Catalog{
		profiles:         owned,
		profileByID:      profileByID,
		defaultProfileID: defaultProfileID,
	}, nil
}

// Profiles returns profiles in their configured order. Every nested slice and
// action pointer is copied, so mutating the result cannot mutate the catalog.
func (c Catalog) Profiles() []Profile {
	return cloneProfiles(c.profiles)
}

// OrderedProfiles is an explicit alias for Profiles.
func (c Catalog) OrderedProfiles() []Profile {
	return c.Profiles()
}

// Count returns the number of profiles in the catalog.
func (c Catalog) Count() int {
	return len(c.profiles)
}

// DefaultProfileID returns the exact case-sensitive configured default ID.
func (c Catalog) DefaultProfileID() string {
	return c.defaultProfileID
}

// Lookup resolves a case-sensitive profile ID and returns an independent copy.
func (c Catalog) Lookup(id string) (Profile, bool) {
	index, ok := c.profileByID[id]
	if !ok || index < 0 || index >= len(c.profiles) {
		return Profile{}, false
	}
	return cloneProfile(c.profiles[index]), true
}

// Default returns the configured default profile and an existence marker.
func (c Catalog) Default() (Profile, bool) {
	return c.Lookup(c.defaultProfileID)
}

// DefaultProfile is an explicit alias for Default.
func (c Catalog) DefaultProfile() (Profile, bool) {
	return c.Default()
}

// ResolveTarget resolves an action's target profile ID. It intentionally
// accepts the ID separately so callers can resolve an IPC or other validated
// intent without constructing an Action value.
func (c Catalog) ResolveTarget(profileID string) (Profile, bool) {
	return c.Lookup(profileID)
}

// ResolveActionTarget resolves the target named by an action after checking
// that the action has the catalog's exact supported shape.
func (c Catalog) ResolveActionTarget(action Action) (Profile, bool) {
	if action.Type != ActivateProfileType || action.Gesture != PressGesture {
		return Profile{}, false
	}
	return c.ResolveTarget(action.ProfileID)
}

// ResolveAction is a concise alias for ResolveActionTarget.
func (c Catalog) ResolveAction(action Action) (Profile, bool) {
	return c.ResolveActionTarget(action)
}

// Values returns an independent copy of a profile's values in source order.
func (p Profile) ValuesCopy() []Value {
	return cloneValues(p.Values)
}

// ValueAt resolves a profile value by physical coordinate and returns an
// independent copy.
func (p Profile) ValueAt(position string) (Value, bool) {
	for _, value := range p.Values {
		if value.Position == position {
			return cloneValue(value), true
		}
	}
	return Value{}, false
}

// Bindings returns every configured action binding in source order.
func (p Profile) Bindings() []Binding {
	bindings := make([]Binding, 0)
	for _, value := range p.Values {
		if value.Action == nil {
			continue
		}
		bindings = append(bindings, Binding{Position: value.Position, Action: *cloneAction(value.Action)})
	}
	return bindings
}

func validateValues(values []Value, profileByID map[string]int) error {
	if len(values) != RequiredValueCount {
		return fmt.Errorf("has %d values, want %d", len(values), RequiredValueCount)
	}
	seenIDs := make(map[string]int, len(values))
	seenPositions := make(map[string]int, len(values))
	for index, value := range values {
		if !validStableID(value.ID) {
			return fmt.Errorf("value %d has an invalid ID", index)
		}
		if previous, exists := seenIDs[value.ID]; exists {
			return fmt.Errorf("value ID %q is duplicated at indexes %d and %d", value.ID, previous, index)
		}
		seenIDs[value.ID] = index
		if _, exists := positionByName[value.Position]; !exists {
			return fmt.Errorf("value %d has unsupported position %q", index, value.Position)
		}
		if previous, exists := seenPositions[value.Position]; exists {
			return fmt.Errorf("position %q is duplicated at indexes %d and %d", value.Position, previous, index)
		}
		seenPositions[value.Position] = index
		if !validLabel(value.Label) {
			return fmt.Errorf("value %d has an invalid label", index)
		}
		if !validBackground(value.Background) {
			return fmt.Errorf("value %d has an invalid background", index)
		}
		if value.Action != nil {
			if err := validateAction(*value.Action, profileByID); err != nil {
				return fmt.Errorf("value %d action: %w", index, err)
			}
		}
	}
	for _, position := range supportedPositions {
		if _, exists := seenPositions[position]; !exists {
			return fmt.Errorf("missing position %q", position)
		}
	}
	return nil
}

func validateActions(values []Value, profileByID map[string]int) error {
	for index, value := range values {
		if value.Action == nil {
			continue
		}
		if err := validateAction(*value.Action, profileByID); err != nil {
			return fmt.Errorf("value %d action: %w", index, err)
		}
		if value.Action.Type == ActivateProfileType {
			if _, ok := profileByID[value.Action.ProfileID]; !ok {
				return fmt.Errorf("value %d action target %q does not resolve to exactly one profile", index, value.Action.ProfileID)
			}
		}
	}
	return nil
}

func validateAction(action Action, profileByID map[string]int) error {
	if action.Type != ActivateProfileType && action.Type != ExecuteActionType {
		return fmt.Errorf("type must be %q or %q", ActivateProfileType, ExecuteActionType)
	}
	if action.Gesture != PressGesture {
		return fmt.Errorf("gesture must be %q", PressGesture)
	}
	switch action.Type {
	case ActivateProfileType:
		if action.Executable != "" {
			return fmt.Errorf("executable is forbidden for %q action", ActivateProfileType)
		}
		if action.Arguments != nil {
			return fmt.Errorf("arguments are forbidden for %q action", ActivateProfileType)
		}
		if action.TimeoutSeconds != 0 {
			return fmt.Errorf("timeout_seconds is forbidden for %q action", ActivateProfileType)
		}
		if !validStableID(action.ProfileID) {
			return fmt.Errorf("profile ID %q is invalid", action.ProfileID)
		}
		if profileByID != nil {
			if _, ok := profileByID[action.ProfileID]; !ok {
				return fmt.Errorf("target %q does not resolve to exactly one profile", action.ProfileID)
			}
		}
	case ExecuteActionType:
		if action.ProfileID != "" {
			return fmt.Errorf("profile_id is forbidden for %q action", ExecuteActionType)
		}
		if !validExecutable(action.Executable) {
			return fmt.Errorf("executable must be a non-empty absolute UTF-8 path without NUL")
		}
		if err := validateExecuteArguments(action.Arguments); err != nil {
			return err
		}
		if action.TimeoutSeconds < MinimumExecuteTimeoutSeconds || action.TimeoutSeconds > MaximumExecuteTimeoutSeconds {
			return fmt.Errorf("timeout_seconds must be between %d and %d", MinimumExecuteTimeoutSeconds, MaximumExecuteTimeoutSeconds)
		}
	}
	return nil
}

func validExecutable(value string) bool {
	return value != "" && path.IsAbs(value) && utf8.ValidString(value) && !strings.ContainsRune(value, '\x00')
}

func validateExecuteArguments(arguments []string) error {
	if len(arguments) > MaximumExecuteArgumentCount {
		return fmt.Errorf("arguments must contain at most %d arguments", MaximumExecuteArgumentCount)
	}
	aggregateBytes := 0
	for index, argument := range arguments {
		if !utf8.ValidString(argument) || strings.ContainsRune(argument, '\x00') {
			return fmt.Errorf("argument %d must be valid UTF-8 without NUL", index)
		}
		if len([]byte(argument)) > MaximumExecuteArgumentBytes {
			return fmt.Errorf("argument %d must be at most %d UTF-8 bytes", index, MaximumExecuteArgumentBytes)
		}
		aggregateBytes += len([]byte(argument))
	}
	if aggregateBytes > MaximumExecuteArgumentsBytes {
		return fmt.Errorf("arguments must total at most %d UTF-8 bytes", MaximumExecuteArgumentsBytes)
	}
	return nil
}

func validStableID(value string) bool {
	return stableIDPattern.MatchString(value) && utf8.ValidString(value)
}

func validLabel(value string) bool {
	if !utf8.ValidString(value) || utf8.RuneCountInString(value) < 1 || utf8.RuneCountInString(value) > MaximumLabelRunes || len([]byte(value)) > MaximumLabelBytes {
		return false
	}
	visible := false
	for _, character := range value {
		if unicode.IsControl(character) || unicode.Is(unicode.Cf, character) {
			return false
		}
		if invisibleLabelRune(character) {
			continue
		}
		visible = true
	}
	return visible
}

func invisibleLabelRune(character rune) bool {
	return unicode.IsSpace(character) || unicode.Is(unicode.Mn, character) || unicode.Is(unicode.Me, character) || unicode.Is(unicode.Cn, character) || unicode.Is(unicode.Co, character) || unicode.Is(unicode.Cs, character)
}

func validBackground(value string) bool {
	if len(value) != 7 && len(value) != 9 || value[0] != '#' {
		return false
	}
	for _, character := range value[1:] {
		if !isHex(character) {
			return false
		}
	}
	return true
}

func isHex(character rune) bool {
	return character >= '0' && character <= '9' || character >= 'a' && character <= 'f' || character >= 'A' && character <= 'F'
}

func cloneProfiles(source []Profile) []Profile {
	if source == nil {
		return nil
	}
	owned := make([]Profile, len(source))
	for index, current := range source {
		owned[index] = cloneProfile(current)
	}
	return owned
}

func cloneProfile(source Profile) Profile {
	return Profile{ID: source.ID, Label: source.Label, Values: cloneValues(source.Values)}
}

func cloneValues(source []Value) []Value {
	if source == nil {
		return nil
	}
	owned := make([]Value, len(source))
	for index, current := range source {
		owned[index] = cloneValue(current)
	}
	return owned
}

func cloneValue(source Value) Value {
	owned := source
	owned.Action = cloneAction(source.Action)
	return owned
}

func cloneAction(source *Action) *Action {
	if source == nil {
		return nil
	}
	owned := *source
	owned.Arguments = cloneArguments(source.Arguments)
	return &owned
}

func cloneArguments(source []string) []string {
	if source == nil {
		return nil
	}
	owned := make([]string, len(source))
	copy(owned, source)
	return owned
}

func normalizeActionDefaults(profiles []Profile) {
	for profileIndex := range profiles {
		for valueIndex := range profiles[profileIndex].Values {
			action := profiles[profileIndex].Values[valueIndex].Action
			if action == nil || action.Type != ExecuteActionType {
				continue
			}
			if action.Arguments == nil {
				action.Arguments = []string{}
			}
			if action.TimeoutSeconds == 0 {
				action.TimeoutSeconds = DefaultExecuteTimeoutSeconds
			}
		}
	}
}

var supportedPositions = [...]string{
	"0_0",
	"1_0",
	"2_0",
	"3_0",
	"4_0",
	"0_1",
	"1_1",
	"2_1",
	"3_1",
	"4_1",
	"0_2",
	"1_2",
	"2_2",
	"3_2",
}

var positionByName = func() map[string]struct{} {
	result := make(map[string]struct{}, len(supportedPositions))
	for _, position := range supportedPositions {
		result[position] = struct{}{}
	}
	return result
}()
