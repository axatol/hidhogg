package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf16"
	"unicode/utf8"

	"hidhogg/internal/profile"

	toml "github.com/pelletier/go-toml/v2"
)

const (
	// SchemaVersionV1 through SchemaVersionV3 identify rejected predecessor formats.
	SchemaVersionV1 = 1
	SchemaVersionV2 = 2
	SchemaVersionV3 = 3
	SchemaVersionV4 = 4
	SchemaVersion   = SchemaVersionV4

	AdapterUlanziD200X             = "ulanzi.d200x"
	RequiredPositionCount          = 14
	MaximumProfileCount            = 31
	MinimumBrightness              = 0
	MaximumBrightness              = 100
	DefaultIdleTimeoutSeconds      = 300
	DefaultPositionBackground      = "#000000"
	MaximumIdleTimeoutSeconds      = 86400
	MaximumStableIDRunes           = 64
	MaximumNotificationSourceCount = profile.MaximumNotificationSourceCount
	MaximumLabelRunes              = 64
	MaximumLabelBytes              = 256
	LabelAlignmentBottom           = "bottom"
	LabelAlignmentCenter           = "center"
	DefaultLabelAlignment          = LabelAlignmentBottom
	DefaultLabelSize               = 10
	MinimumLabelSize               = 8
	MaximumLabelSize               = 32
	ExecuteActionType              = "execute"
	TypeTextActionType             = profile.TypeTextActionType
	KeyPressActionType             = profile.KeyPressActionType
	MaximumTextUTF16Units          = profile.MaximumTextUTF16Units
	DefaultExecuteTimeoutSeconds   = 10
	MinimumExecuteTimeoutSeconds   = 1
	MaximumExecuteTimeoutSeconds   = 60
	MaximumExecuteArgumentCount    = 32
	MaximumExecuteArgumentBytes    = 1024
	MaximumExecuteArgumentsBytes   = 8192
)

// Config is the normalized schema-v4 D200X configuration. Its field tags keep
// stable normalized names; Decode and JSON use the separate keyed source DTO.
type Config struct {
	SchemaVersion      int       `toml:"schema_version" json:"schema_version" jsonschema:"configuration schema version"`
	Adapter            string    `toml:"adapter" json:"adapter" jsonschema:"device adapter identifier"`
	Brightness         int       `toml:"brightness" json:"brightness" jsonschema:"display brightness percentage"`
	IdleTimeoutSeconds int       `toml:"idle_timeout_seconds" json:"idle_timeout_seconds" jsonschema:"application-owned idle timeout in seconds"`
	DefaultProfileID   string    `toml:"default_profile_id" json:"default_profile_id" jsonschema:"profile selected at startup"`
	Profiles           []Profile `toml:"profiles" json:"profiles" jsonschema:"ordered configured display profiles"`
}

// Profile is one named, complete D200X display layout.
type Profile struct {
	ID        string     `toml:"id" json:"id" jsonschema:"case-sensitive stable profile identifier"`
	Label     string     `toml:"label" json:"label" jsonschema:"display profile label"`
	Positions []Position `toml:"positions" json:"positions" jsonschema:"all supported D200X display positions"`
}

// Position describes one physical display position and its rendered content.
// Action, when present, is bound to one input gesture at this position.
type Position struct {
	ID                  string   `toml:"id" json:"id" jsonschema:"stable position identifier"`
	Position            string   `toml:"position" json:"position" jsonschema:"supported D200X grid position"`
	Label               string   `toml:"label" json:"label" jsonschema:"display label"`
	Background          string   `toml:"background" json:"background" jsonschema:"hexadecimal background colour"`
	NotificationSources []string `toml:"notification_sources,omitempty" json:"notification_sources,omitempty" jsonschema:"optional exact notification source filters"`
	LabelAlignment      string   `toml:"label_alignment,omitempty" json:"label_alignment,omitempty" jsonschema:"firmware-rendered label alignment"`
	LabelSize           int      `toml:"label_size,omitempty" json:"label_size,omitempty" jsonschema:"firmware-rendered label size"`
	Action              *Action  `toml:"action" json:"action,omitempty" jsonschema:"optional input-gesture action binding"`
}

// Action is a schema-v4 input-gesture action. The Type field selects one of
// the activate_profile and execute variants; each variant has a strict field
// set. Gesture defaults to release when omitted.
type Action struct {
	Type           string   `toml:"type" json:"type" jsonschema:"action type"`
	Gesture        string   `toml:"gesture" json:"gesture,omitempty" jsonschema:"input gesture"`
	ProfileID      string   `toml:"profile_id" json:"profile_id,omitempty" jsonschema:"case-sensitive target profile identifier"`
	Executable     string   `toml:"executable" json:"executable,omitempty" jsonschema:"absolute executable path"`
	Arguments      []string `toml:"arguments" json:"arguments,omitempty" jsonschema:"executable arguments"`
	TimeoutSeconds int      `toml:"timeout_seconds" json:"timeout_seconds,omitempty" jsonschema:"maximum synchronous execution time in seconds"`
	Text           string   `toml:"text" json:"text,omitempty" jsonschema:"UTF-8 text payload"`
	Key            string   `toml:"key" json:"key,omitempty" jsonschema:"supported physical key"`
}

type sourceConfig struct {
	SchemaVersion      int                      `toml:"schema_version" json:"schema_version" jsonschema:"configuration schema version"`
	Adapter            string                   `toml:"adapter" json:"adapter" jsonschema:"device adapter identifier"`
	Brightness         int                      `toml:"brightness" json:"brightness" jsonschema:"display brightness percentage"`
	IdleTimeoutSeconds int                      `toml:"idle_timeout_seconds" json:"idle_timeout_seconds" jsonschema:"application-owned idle timeout in seconds"`
	DefaultProfileID   string                   `toml:"default_profile_id" json:"default_profile_id" jsonschema:"profile selected at startup"`
	Profiles           map[string]sourceProfile `toml:"profiles" json:"profiles" jsonschema:"profiles keyed by immutable profile ID"`
}

type sourceProfile struct {
	Label     string                    `toml:"label" json:"label" jsonschema:"display profile label"`
	Positions map[string]sourcePosition `toml:"positions,omitempty" json:"positions,omitempty" jsonschema:"optional positions keyed by D200X coordinate"`
}

type sourcePosition struct {
	Label               string   `toml:"label,omitempty" json:"label,omitempty" jsonschema:"display label; defaults to blank"`
	Background          string   `toml:"background,omitempty" json:"background,omitempty" jsonschema:"hexadecimal background colour; defaults to black"`
	NotificationSources []string `toml:"notification_sources,omitempty" json:"notification_sources,omitempty" jsonschema:"optional exact notification source filters"`
	LabelAlignment      string   `toml:"label_alignment,omitempty" json:"label_alignment,omitempty" jsonschema:"firmware-rendered label alignment"`
	LabelSize           int      `toml:"label_size,omitempty" json:"label_size,omitempty" jsonschema:"firmware-rendered label size"`
	Action              *Action  `toml:"action,omitempty" json:"action,omitempty" jsonschema:"optional input-gesture action binding"`
}

// DisplayPosition and Tile are compatibility aliases for callers that use
// either the physical-layout or product terminology.
type DisplayPosition = Position
type Tile = Position

// PositionSpec maps a supported display coordinate to the stable D200X wire
// index used by the adapter. Wide is true only for the 3_2 display position.
type PositionSpec struct {
	Name      string
	WireIndex byte
	Wide      bool
}

var supportedPositionSpecs = [...]PositionSpec{
	{Name: "0_0", WireIndex: 0},
	{Name: "1_0", WireIndex: 1},
	{Name: "2_0", WireIndex: 2},
	{Name: "3_0", WireIndex: 3},
	{Name: "4_0", WireIndex: 4},
	{Name: "0_1", WireIndex: 5},
	{Name: "1_1", WireIndex: 6},
	{Name: "2_1", WireIndex: 7},
	{Name: "3_1", WireIndex: 8},
	{Name: "4_1", WireIndex: 9},
	{Name: "0_2", WireIndex: 10},
	{Name: "1_2", WireIndex: 11},
	{Name: "2_2", WireIndex: 12},
	{Name: "3_2", WireIndex: 13, Wide: true},
}

var (
	stableIDPattern   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
	backgroundPattern = regexp.MustCompile(`^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$`)
)

var supportedPositionByName = func() map[string]PositionSpec {
	result := make(map[string]PositionSpec, len(supportedPositionSpecs))
	for _, spec := range supportedPositionSpecs {
		result[spec.Name] = spec
	}
	return result
}()

// SupportedPositions returns the supported display positions in deterministic
// wire-index order. The returned slice is independent of package state.
func SupportedPositions() []PositionSpec {
	return append([]PositionSpec(nil), supportedPositionSpecs[:]...)
}

// LookupPosition resolves a configured coordinate to its D200X wire mapping.
func LookupPosition(name string) (PositionSpec, bool) {
	spec, ok := supportedPositionByName[name]
	return spec, ok
}

// PositionForWireIndex resolves an adapter input index to its configured
// display coordinate.
func PositionForWireIndex(index byte) (PositionSpec, bool) {
	if int(index) >= len(supportedPositionSpecs) {
		return PositionSpec{}, false
	}
	return supportedPositionSpecs[index], true
}

// Load reads, strictly decodes, and semantically validates one TOML file.
func Load(path string) (Config, error) {
	absolutePath, err := filepath.Abs(path)
	if err != nil {
		return Config{}, newDiagnostic(path, err)
	}
	data, err := os.ReadFile(absolutePath)
	if err != nil {
		return Config{}, newDiagnostic(absolutePath, err)
	}
	configuration, err := Decode(data)
	if err != nil {
		return Config{}, newDiagnostic(absolutePath, err)
	}
	return configuration, nil
}

// LoadFile is an explicit alias for Load for callers that want to distinguish
// file loading from byte decoding at call sites.
func LoadFile(path string) (Config, error) {
	return Load(path)
}

// Decode strictly decodes and semantically validates one TOML document.
// Unknown fields, duplicate TOML keys, malformed syntax, and type mismatches
// are rejected before the returned value can be used by a device adapter.
func Decode(data []byte) (Config, error) {
	var raw map[string]any
	if err := toml.Unmarshal(data, &raw); err != nil {
		return Config{}, fmt.Errorf("inspect configuration TOML: %w", err)
	}
	if version, ok := raw["schema_version"].(int64); ok && version != SchemaVersionV4 {
		return Config{}, newValidationError(ValidationIssue{
			Path:    "schema_version",
			Message: fmt.Sprintf("must equal %d", SchemaVersionV4),
		})
	}
	var decoded sourceConfig
	decoder := toml.NewDecoder(bytes.NewReader(data)).DisallowUnknownFields()
	if err := decoder.Decode(&decoded); err != nil {
		return Config{}, fmt.Errorf("decode configuration TOML: %w", err)
	}
	if issues := missingRequiredFields(raw); len(issues) > 0 {
		return Config{}, newValidationError(issues...)
	}
	applySourceDefaults(&decoded, raw)
	if issues := validateRawLabelStyleFields(raw, decoded); len(issues) > 0 {
		return Config{}, newValidationError(issues...)
	}
	if issues := validateRawActionFields(raw, decoded); len(issues) > 0 {
		return Config{}, newValidationError(issues...)
	}
	if issues := validateSourcePositionKeys(decoded); len(issues) > 0 {
		return Config{}, newValidationError(issues...)
	}
	configuration := normalizeSource(decoded)
	if err := configuration.Validate(); err != nil {
		return Config{}, err
	}
	return configuration, nil
}

func applySourceDefaults(decoded *sourceConfig, raw map[string]any) {
	if _, exists := raw["idle_timeout_seconds"]; !exists {
		decoded.IdleTimeoutSeconds = DefaultIdleTimeoutSeconds
	}
	rawProfiles := rawMap(raw["profiles"])
	for profileID, current := range decoded.Profiles {
		rawProfile := rawMap(rawProfiles[profileID])
		rawPositions := rawMap(rawProfile["positions"])
		for coordinate, position := range current.Positions {
			rawPosition := rawMap(rawPositions[coordinate])
			if _, exists := rawPosition["background"]; !exists {
				position.Background = DefaultPositionBackground
			}
			if _, exists := rawPosition["label_alignment"]; !exists {
				position.LabelAlignment = DefaultLabelAlignment
			}
			if _, exists := rawPosition["label_size"]; !exists {
				position.LabelSize = DefaultLabelSize
			}
			if actionMap := rawMap(rawPosition["action"]); actionMap != nil && position.Action != nil {
				if _, exists := actionMap["gesture"]; !exists {
					position.Action.Gesture = profile.DefaultGesture
				}
				if position.Action.Type == ExecuteActionType {
					if _, exists := actionMap["arguments"]; !exists {
						position.Action.Arguments = []string{}
					}
					if _, exists := actionMap["timeout_seconds"]; !exists {
						position.Action.TimeoutSeconds = DefaultExecuteTimeoutSeconds
					}
				}
			}
			current.Positions[coordinate] = position
		}
		decoded.Profiles[profileID] = current
	}
}

func validateRawLabelStyleFields(raw map[string]any, decoded sourceConfig) []ValidationIssue {
	var issues []ValidationIssue
	for profileID, rawProfileValue := range rawMap(raw["profiles"]) {
		rawProfile := rawMap(rawProfileValue)
		for coordinate, rawPositionValue := range rawMap(rawProfile["positions"]) {
			rawPosition := rawMap(rawPositionValue)
			position := decoded.Profiles[profileID].Positions[coordinate]
			positionPath := sourcePositionPath(profileID, coordinate)
			if _, exists := rawPosition["label_alignment"]; exists && position.LabelAlignment == "" {
				issues = append(issues, ValidationIssue{Path: positionPath + ".label_alignment", Message: fmt.Sprintf("must equal %q or %q", LabelAlignmentBottom, LabelAlignmentCenter)})
			}
			if _, exists := rawPosition["label_size"]; exists && position.LabelSize == 0 {
				issues = append(issues, ValidationIssue{Path: positionPath + ".label_size", Message: fmt.Sprintf("must be between %d and %d", MinimumLabelSize, MaximumLabelSize)})
			}
		}
	}
	return issues
}

func validateRawActionFields(raw map[string]any, decoded sourceConfig) []ValidationIssue {
	var issues []ValidationIssue
	for profileID, rawProfileValue := range rawMap(raw["profiles"]) {
		rawProfile := rawMap(rawProfileValue)
		for coordinate, rawPositionValue := range rawMap(rawProfile["positions"]) {
			rawPosition := rawMap(rawPositionValue)
			actionMap := rawMap(rawPosition["action"])
			if actionMap == nil {
				continue
			}
			position, exists := decoded.Profiles[profileID].Positions[coordinate]
			if !exists || position.Action == nil {
				continue
			}
			actionPath := sourcePositionPath(profileID, coordinate) + ".action"
			action := position.Action
			if _, exists := actionMap["gesture"]; exists && action.Gesture == "" {
				issues = append(issues, ValidationIssue{Path: actionPath + ".gesture", Message: fmt.Sprintf("must equal %q or %q", profile.PressGesture, profile.ReleaseGesture)})
			}
			switch action.Type {
			case ExecuteActionType:
				if _, exists := actionMap["profile_id"]; exists {
					issues = append(issues, ValidationIssue{Path: actionPath + ".profile_id", Message: "is forbidden for execute actions"})
				}
				for _, field := range []string{"text", "key"} {
					if _, exists := actionMap[field]; exists {
						issues = append(issues, ValidationIssue{Path: actionPath + "." + field, Message: "is forbidden for execute actions"})
					}
				}
				if _, exists := actionMap["timeout_seconds"]; exists && action.TimeoutSeconds == 0 {
					issues = append(issues, ValidationIssue{Path: actionPath + ".timeout_seconds", Message: fmt.Sprintf("must be between %d and %d", MinimumExecuteTimeoutSeconds, MaximumExecuteTimeoutSeconds)})
				}
			case profileActionType:
				for _, field := range []string{"executable", "arguments", "timeout_seconds", "text", "key"} {
					if _, exists := actionMap[field]; exists {
						issues = append(issues, ValidationIssue{Path: actionPath + "." + field, Message: "is forbidden for activate_profile actions"})
					}
				}
			case TypeTextActionType:
				for _, field := range []string{"profile_id", "executable", "arguments", "timeout_seconds", "key"} {
					if _, exists := actionMap[field]; exists {
						issues = append(issues, ValidationIssue{Path: actionPath + "." + field, Message: "is forbidden for type_text actions"})
					}
				}
			case KeyPressActionType:
				for _, field := range []string{"profile_id", "executable", "arguments", "timeout_seconds", "text"} {
					if _, exists := actionMap[field]; exists {
						issues = append(issues, ValidationIssue{Path: actionPath + "." + field, Message: "is forbidden for key_press actions"})
					}
				}
			}
		}
	}
	return issues
}

func rawMap(value any) map[string]any {
	result, _ := value.(map[string]any)
	return result
}

func missingRequiredFields(raw map[string]any) []ValidationIssue {
	fields := []string{"schema_version", "adapter", "brightness", "default_profile_id", "profiles"}
	issues := make([]ValidationIssue, 0, len(fields))
	for _, field := range fields {
		if _, ok := raw[field]; !ok {
			issues = append(issues, ValidationIssue{Path: field, Kind: ValidationIssueRequired, Message: "is required"})
		}
	}
	for profileID, profileValue := range rawMap(raw["profiles"]) {
		if _, exists := rawMap(profileValue)["label"]; !exists {
			issues = append(issues, ValidationIssue{Path: sourceProfilePath(profileID) + ".label", Kind: ValidationIssueRequired, Message: "is required"})
		}
	}
	return issues
}

func validateSourcePositionKeys(source sourceConfig) []ValidationIssue {
	var issues []ValidationIssue
	for profileID, current := range source.Profiles {
		for coordinate := range current.Positions {
			if _, supported := LookupPosition(coordinate); !supported {
				issues = append(issues, ValidationIssue{Path: sourcePositionPath(profileID, coordinate), Message: "is not a supported D200X position"})
			}
		}
	}
	return issues
}

func normalizeSource(source sourceConfig) Config {
	profileIDs := make([]string, 0, len(source.Profiles))
	for profileID := range source.Profiles {
		profileIDs = append(profileIDs, profileID)
	}
	sort.Strings(profileIDs)
	sort.SliceStable(profileIDs, func(left, right int) bool {
		if profileIDs[left] == source.DefaultProfileID {
			return profileIDs[right] != source.DefaultProfileID
		}
		if profileIDs[right] == source.DefaultProfileID {
			return false
		}
		return profileIDs[left] < profileIDs[right]
	})

	configuration := Config{
		SchemaVersion:      source.SchemaVersion,
		Adapter:            source.Adapter,
		Brightness:         source.Brightness,
		IdleTimeoutSeconds: source.IdleTimeoutSeconds,
		DefaultProfileID:   source.DefaultProfileID,
		Profiles:           make([]Profile, 0, len(profileIDs)),
	}
	for _, profileID := range profileIDs {
		current := source.Profiles[profileID]
		normalized := Profile{ID: profileID, Label: current.Label, Positions: make([]Position, 0, RequiredPositionCount)}
		for _, spec := range supportedPositionSpecs {
			position, exists := current.Positions[spec.Name]
			if !exists {
				position = sourcePosition{
					Background:     DefaultPositionBackground,
					LabelAlignment: DefaultLabelAlignment,
					LabelSize:      DefaultLabelSize,
				}
			}
			normalized.Positions = append(normalized.Positions, Position{
				ID:                  spec.Name,
				Position:            spec.Name,
				Label:               position.Label,
				Background:          position.Background,
				NotificationSources: cloneNotificationSources(position.NotificationSources),
				LabelAlignment:      position.LabelAlignment,
				LabelSize:           position.LabelSize,
				Action:              cloneConfigAction(position.Action),
			})
		}
		configuration.Profiles = append(configuration.Profiles, normalized)
	}
	return configuration
}

func sourceProfilePath(profileID string) string {
	return fmt.Sprintf("profiles[%q]", profileID)
}

func sourcePositionPath(profileID, coordinate string) string {
	return fmt.Sprintf("%s.positions[%q]", sourceProfilePath(profileID), coordinate)
}

// JSON returns the canonical keyed source projection used by schema consumers.
func (c Config) JSON() ([]byte, error) {
	if err := c.Validate(); err != nil {
		return nil, err
	}
	projection := sourceConfig{
		SchemaVersion:      c.SchemaVersion,
		Adapter:            c.Adapter,
		Brightness:         c.Brightness,
		IdleTimeoutSeconds: c.IdleTimeoutSeconds,
		DefaultProfileID:   c.DefaultProfileID,
		Profiles:           make(map[string]sourceProfile, len(c.Profiles)),
	}
	for _, current := range c.Profiles {
		profileProjection := sourceProfile{Label: current.Label, Positions: make(map[string]sourcePosition, len(current.Positions))}
		for _, position := range current.Positions {
			profileProjection.Positions[position.Position] = sourcePosition{
				Label:               position.Label,
				Background:          position.Background,
				NotificationSources: cloneNotificationSources(position.NotificationSources),
				LabelAlignment:      effectiveLabelAlignment(position.LabelAlignment),
				LabelSize:           effectiveLabelSize(position.LabelSize),
				Action:              cloneConfigAction(position.Action),
			}
		}
		projection.Profiles[current.ID] = profileProjection
	}
	return json.Marshal(projection)
}

// ProfileCatalog validates and converts this configuration into an immutable,
// ordered catalog of neutral profile values and action bindings.
func (c Config) ProfileCatalog() (profile.Catalog, error) {
	if err := c.Validate(); err != nil {
		return profile.Catalog{}, err
	}
	definitions := make([]profile.Profile, len(c.Profiles))
	for profileIndex, source := range c.Profiles {
		values := make([]profile.Value, len(source.Positions))
		for positionIndex, value := range source.Positions {
			converted := profile.Value{
				ID:                  value.ID,
				Position:            value.Position,
				Label:               value.Label,
				Background:          value.Background,
				NotificationSources: cloneNotificationSources(value.NotificationSources),
				LabelAlignment:      effectiveLabelAlignment(value.LabelAlignment),
				LabelSize:           effectiveLabelSize(value.LabelSize),
			}
			if value.Action != nil {
				converted.Action = &profile.Action{
					Type:           value.Action.Type,
					Gesture:        value.Action.Gesture,
					ProfileID:      value.Action.ProfileID,
					Executable:     value.Action.Executable,
					Arguments:      cloneArguments(value.Action.Arguments),
					TimeoutSeconds: value.Action.TimeoutSeconds,
					Text:           value.Action.Text,
					Key:            value.Action.Key,
				}
			}
			values[positionIndex] = converted
		}
		definitions[profileIndex] = profile.Profile{
			ID:     source.ID,
			Label:  source.Label,
			Values: values,
		}
	}
	return profile.NewCatalog(c.DefaultProfileID, definitions)
}

// Catalog is a concise alias for ProfileCatalog at call sites that already
// have a validated configuration value.
func (c Config) Catalog() (profile.Catalog, error) {
	return c.ProfileCatalog()
}

// ValidationIssue identifies one semantic violation by canonical field path.
type ValidationIssue struct {
	Path    string
	Kind    ValidationIssueKind
	Message string
}

type ValidationIssueKind string

const ValidationIssueRequired ValidationIssueKind = "required"

// ValidationError reports all semantic violations in deterministic order.
type ValidationError struct {
	Issues []ValidationIssue
}

func newValidationError(issues ...ValidationIssue) *ValidationError {
	copyIssues := append([]ValidationIssue(nil), issues...)
	sort.SliceStable(copyIssues, func(left, right int) bool {
		if copyIssues[left].Path == copyIssues[right].Path {
			return copyIssues[left].Message < copyIssues[right].Message
		}
		return copyIssues[left].Path < copyIssues[right].Path
	})
	return &ValidationError{Issues: copyIssues}
}

func (e *ValidationError) Error() string {
	if e == nil || len(e.Issues) == 0 {
		return "invalid configuration"
	}
	parts := make([]string, len(e.Issues))
	for index, issue := range e.Issues {
		parts[index] = issue.Path + " " + issue.Message
	}
	return "invalid configuration: " + strings.Join(parts, "; ")
}

// Validate applies semantic constraints that reflection and TOML decoding
// cannot express, including profile/action resolution and position domains.
func (c Config) Validate() error {
	var issues []ValidationIssue
	if c.SchemaVersion != SchemaVersionV4 {
		issues = append(issues, ValidationIssue{
			Path:    "schema_version",
			Message: fmt.Sprintf("must equal %d", SchemaVersionV4),
		})
	}
	if c.Adapter != AdapterUlanziD200X {
		issues = append(issues, ValidationIssue{
			Path:    "adapter",
			Message: fmt.Sprintf("must equal %q", AdapterUlanziD200X),
		})
	}
	if c.Brightness < MinimumBrightness || c.Brightness > MaximumBrightness {
		issues = append(issues, ValidationIssue{
			Path:    "brightness",
			Message: fmt.Sprintf("must be between %d and %d", MinimumBrightness, MaximumBrightness),
		})
	}
	if c.IdleTimeoutSeconds < 0 || c.IdleTimeoutSeconds > MaximumIdleTimeoutSeconds {
		issues = append(issues, ValidationIssue{
			Path:    "idle_timeout_seconds",
			Message: fmt.Sprintf("must be between 0 and %d", MaximumIdleTimeoutSeconds),
		})
	}
	if !validStableID(c.DefaultProfileID) {
		issues = append(issues, ValidationIssue{
			Path:    "default_profile_id",
			Message: "must start with an ASCII letter or digit and contain only ASCII letters, digits, '.', '_' or '-' (maximum 64 characters)",
		})
	}
	if len(c.Profiles) < 1 || len(c.Profiles) > MaximumProfileCount {
		issues = append(issues, ValidationIssue{
			Path:    "profiles",
			Message: fmt.Sprintf("must contain between 1 and %d profiles", MaximumProfileCount),
		})
	}

	profileOccurrences := make(map[string][]int, len(c.Profiles))
	for profileIndex, current := range c.Profiles {
		profileOccurrences[current.ID] = append(profileOccurrences[current.ID], profileIndex)
	}
	for profileIndex, current := range c.Profiles {
		profilePath := sourceProfilePath(current.ID)
		validateProfile(&issues, profilePath, current, profileOccurrences)
		if occurrences := profileOccurrences[current.ID]; len(occurrences) > 1 && occurrences[0] == profileIndex {
			for _, duplicateIndex := range occurrences[1:] {
				issues = append(issues, ValidationIssue{
					Path:    sourceProfilePath(c.Profiles[duplicateIndex].ID) + ".id",
					Message: fmt.Sprintf("duplicates %s.id", sourceProfilePath(current.ID)),
				})
			}
		}
	}
	if occurrences := profileOccurrences[c.DefaultProfileID]; len(occurrences) != 1 {
		issues = append(issues, ValidationIssue{
			Path:    "default_profile_id",
			Message: fmt.Sprintf("must resolve to exactly one profile (found %d)", len(occurrences)),
		})
	}

	if len(issues) == 0 {
		return nil
	}
	return newValidationError(issues...)
}

func validateProfile(issues *[]ValidationIssue, currentPath string, current Profile, profileOccurrences map[string][]int) {
	if !validStableID(current.ID) {
		*issues = append(*issues, ValidationIssue{
			Path:    currentPath,
			Message: "must start with an ASCII letter or digit and contain only ASCII letters, digits, '.', '_' or '-' (maximum 64 characters)",
		})
	}
	if !validLabel(current.Label) {
		*issues = append(*issues, ValidationIssue{
			Path:    currentPath + ".label",
			Message: "must contain visible text and be at most 64 characters",
		})
	}
	positionsPath := currentPath + ".positions"
	if len(current.Positions) != RequiredPositionCount {
		*issues = append(*issues, ValidationIssue{
			Path:    positionsPath,
			Message: fmt.Sprintf("must contain exactly %d positions", RequiredPositionCount),
		})
	}

	seenIDs := make(map[string]int, len(current.Positions))
	seenPositions := make(map[string]int, len(current.Positions))
	for positionIndex, position := range current.Positions {
		positionPath := sourcePositionPath(current.ID, position.Position)
		validatePosition(issues, positionPath, position, profileOccurrences)
		if previous, ok := seenIDs[position.ID]; ok {
			*issues = append(*issues, ValidationIssue{
				Path:    positionPath + ".id",
				Message: fmt.Sprintf("duplicates %s.id", sourcePositionPath(current.ID, current.Positions[previous].Position)),
			})
		} else {
			seenIDs[position.ID] = positionIndex
		}
		if previous, ok := seenPositions[position.Position]; ok {
			*issues = append(*issues, ValidationIssue{
				Path:    positionPath + ".position",
				Message: fmt.Sprintf("duplicates %s[%d].position", positionsPath, previous),
			})
		} else {
			seenPositions[position.Position] = positionIndex
		}
	}
	for _, spec := range supportedPositionSpecs {
		if _, ok := seenPositions[spec.Name]; !ok {
			*issues = append(*issues, ValidationIssue{
				Path:    positionsPath,
				Message: fmt.Sprintf("must include position %q", spec.Name),
			})
		}
	}
}

func validatePosition(issues *[]ValidationIssue, path string, position Position, profileOccurrences map[string][]int) {
	if !validStableID(position.ID) {
		*issues = append(*issues, ValidationIssue{
			Path:    path + ".id",
			Message: "must start with an ASCII letter or digit and contain only ASCII letters, digits, '.', '_' or '-' (maximum 64 characters)",
		})
	}
	if position.ID != position.Position {
		*issues = append(*issues, ValidationIssue{Path: path + ".id", Message: "must equal the canonical coordinate"})
	}
	if _, ok := LookupPosition(position.Position); !ok {
		*issues = append(*issues, ValidationIssue{
			Path:    path + ".position",
			Message: "is not a supported D200X position",
		})
	}
	if position.Label != "" && !validLabel(position.Label) {
		*issues = append(*issues, ValidationIssue{
			Path:    path + ".label",
			Message: "must contain visible text and be at most 64 characters",
		})
	}
	if position.LabelAlignment != "" && !validLabelAlignment(position.LabelAlignment) {
		*issues = append(*issues, ValidationIssue{
			Path:    path + ".label_alignment",
			Message: fmt.Sprintf("must equal %q or %q", LabelAlignmentBottom, LabelAlignmentCenter),
		})
	}
	if position.LabelSize != 0 && (position.LabelSize < MinimumLabelSize || position.LabelSize > MaximumLabelSize) {
		*issues = append(*issues, ValidationIssue{
			Path:    path + ".label_size",
			Message: fmt.Sprintf("must be between %d and %d", MinimumLabelSize, MaximumLabelSize),
		})
	}
	if !backgroundPattern.MatchString(position.Background) {
		*issues = append(*issues, ValidationIssue{
			Path:    path + ".background",
			Message: "must be a hexadecimal colour such as #102030 or #102030ff",
		})
	}
	validateNotificationSources(issues, path+".notification_sources", position.NotificationSources)
	if position.Action == nil {
		return
	}
	actionPath := path + ".action"
	if !validActionType(position.Action.Type) {
		*issues = append(*issues, ValidationIssue{Path: actionPath + ".type", Message: fmt.Sprintf("must equal %q, %q, %q, or %q", profileActionType, ExecuteActionType, TypeTextActionType, KeyPressActionType)})
	}
	if position.Action.Gesture != "" && position.Action.Gesture != profile.PressGesture && position.Action.Gesture != profile.ReleaseGesture {
		*issues = append(*issues, ValidationIssue{Path: actionPath + ".gesture", Message: fmt.Sprintf("must equal %q or %q", profile.PressGesture, profile.ReleaseGesture)})
	}
	switch position.Action.Type {
	case profileActionType:
		if position.Action.Executable != "" {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".executable", Message: "is forbidden for activate_profile actions"})
		}
		if position.Action.Arguments != nil {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".arguments", Message: "is forbidden for activate_profile actions"})
		}
		if position.Action.TimeoutSeconds != 0 {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".timeout_seconds", Message: "is forbidden for activate_profile actions"})
		}
		if position.Action.Text != "" {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".text", Message: "is forbidden for activate_profile actions"})
		}
		if position.Action.Key != "" {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".key", Message: "is forbidden for activate_profile actions"})
		}
		if !validStableID(position.Action.ProfileID) {
			*issues = append(*issues, ValidationIssue{
				Path:    actionPath + ".profile_id",
				Message: "must start with an ASCII letter or digit and contain only ASCII letters, digits, '.', '_' or '-' (maximum 64 characters)",
			})
		}
		if occurrences := profileOccurrences[position.Action.ProfileID]; len(occurrences) != 1 {
			*issues = append(*issues, ValidationIssue{
				Path:    actionPath + ".profile_id",
				Message: fmt.Sprintf("must resolve to exactly one profile (found %d)", len(occurrences)),
			})
		}
	case ExecuteActionType:
		if position.Action.ProfileID != "" {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".profile_id", Message: "is forbidden for execute actions"})
		}
		if position.Action.Text != "" {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".text", Message: "is forbidden for execute actions"})
		}
		if position.Action.Key != "" {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".key", Message: "is forbidden for execute actions"})
		}
		if !validExecutable(position.Action.Executable) {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".executable", Message: "must be a non-empty absolute UTF-8 path without NUL"})
		}
		validateExecuteArguments(issues, actionPath, position.Action.Arguments)
		if position.Action.TimeoutSeconds != 0 && (position.Action.TimeoutSeconds < MinimumExecuteTimeoutSeconds || position.Action.TimeoutSeconds > MaximumExecuteTimeoutSeconds) {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".timeout_seconds", Message: fmt.Sprintf("must be between %d and %d", MinimumExecuteTimeoutSeconds, MaximumExecuteTimeoutSeconds)})
		}
	case TypeTextActionType:
		if position.Action.ProfileID != "" {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".profile_id", Message: "is forbidden for type_text actions"})
		}
		if position.Action.Executable != "" {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".executable", Message: "is forbidden for type_text actions"})
		}
		if position.Action.Arguments != nil {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".arguments", Message: "is forbidden for type_text actions"})
		}
		if position.Action.TimeoutSeconds != 0 {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".timeout_seconds", Message: "is forbidden for type_text actions"})
		}
		if position.Action.Key != "" {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".key", Message: "is forbidden for type_text actions"})
		}
		if !validText(position.Action.Text) {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".text", Message: fmt.Sprintf("must be non-empty valid UTF-8 without NUL and at most %d UTF-16 units", MaximumTextUTF16Units)})
		}
	case KeyPressActionType:
		if position.Action.ProfileID != "" {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".profile_id", Message: "is forbidden for key_press actions"})
		}
		if position.Action.Executable != "" {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".executable", Message: "is forbidden for key_press actions"})
		}
		if position.Action.Arguments != nil {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".arguments", Message: "is forbidden for key_press actions"})
		}
		if position.Action.TimeoutSeconds != 0 {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".timeout_seconds", Message: "is forbidden for key_press actions"})
		}
		if position.Action.Text != "" {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".text", Message: "is forbidden for key_press actions"})
		}
		if position.Action.Key != "enter" {
			*issues = append(*issues, ValidationIssue{Path: actionPath + ".key", Message: "must equal \"enter\" for key_press actions"})
		}
	}
}

func validActionType(actionType string) bool {
	switch actionType {
	case profileActionType, ExecuteActionType, TypeTextActionType, KeyPressActionType:
		return true
	default:
		return false
	}
}

func validText(value string) bool {
	if value == "" || !utf8.ValidString(value) || strings.ContainsRune(value, '\x00') {
		return false
	}
	return len(utf16.Encode([]rune(value))) <= MaximumTextUTF16Units
}

func validLabelAlignment(value string) bool {
	return value == LabelAlignmentBottom || value == LabelAlignmentCenter
}

func effectiveLabelAlignment(value string) string {
	if value == "" {
		return DefaultLabelAlignment
	}
	return value
}

func effectiveLabelSize(value int) int {
	if value == 0 {
		return DefaultLabelSize
	}
	return value
}

func validExecutable(value string) bool {
	return value != "" && path.IsAbs(value) && utf8.ValidString(value) && !strings.ContainsRune(value, '\x00')
}

func validateExecuteArguments(issues *[]ValidationIssue, actionPath string, arguments []string) {
	if len(arguments) > MaximumExecuteArgumentCount {
		*issues = append(*issues, ValidationIssue{Path: actionPath + ".arguments", Message: fmt.Sprintf("must contain at most %d arguments", MaximumExecuteArgumentCount)})
	}
	aggregateBytes := 0
	for index, argument := range arguments {
		argumentPath := fmt.Sprintf("%s.arguments[%d]", actionPath, index)
		if !utf8.ValidString(argument) || strings.ContainsRune(argument, '\x00') {
			*issues = append(*issues, ValidationIssue{Path: argumentPath, Message: "must be valid UTF-8 without NUL"})
		}
		if len([]byte(argument)) > MaximumExecuteArgumentBytes {
			*issues = append(*issues, ValidationIssue{Path: argumentPath, Message: fmt.Sprintf("must be at most %d UTF-8 bytes", MaximumExecuteArgumentBytes)})
		}
		aggregateBytes += len([]byte(argument))
	}
	if aggregateBytes > MaximumExecuteArgumentsBytes {
		*issues = append(*issues, ValidationIssue{Path: actionPath + ".arguments", Message: fmt.Sprintf("must total at most %d UTF-8 bytes", MaximumExecuteArgumentsBytes)})
	}
}

func cloneArguments(source []string) []string {
	if source == nil {
		return nil
	}
	owned := make([]string, len(source))
	copy(owned, source)
	return owned
}

func cloneConfigAction(source *Action) *Action {
	if source == nil {
		return nil
	}
	owned := *source
	owned.Arguments = cloneArguments(source.Arguments)
	return &owned
}

func cloneNotificationSources(source []string) []string {
	if source == nil {
		return nil
	}
	owned := make([]string, len(source))
	copy(owned, source)
	return owned
}

func validateNotificationSources(issues *[]ValidationIssue, path string, sources []string) {
	if sources == nil {
		return
	}
	if len(sources) < 1 || len(sources) > MaximumNotificationSourceCount {
		*issues = append(*issues, ValidationIssue{
			Path:    path,
			Message: fmt.Sprintf("must contain between 1 and %d notification sources", MaximumNotificationSourceCount),
		})
	}
	seen := make(map[string]int, len(sources))
	for index, source := range sources {
		sourcePath := fmt.Sprintf("%s[%d]", path, index)
		if !validStableID(source) {
			*issues = append(*issues, ValidationIssue{
				Path:    sourcePath,
				Message: "must start with an ASCII letter or digit and contain only ASCII letters, digits, '.', '_' or '-' (maximum 64 characters)",
			})
		}
		if previous, ok := seen[source]; ok {
			*issues = append(*issues, ValidationIssue{
				Path:    sourcePath,
				Message: fmt.Sprintf("duplicates %s[%d]", path, previous),
			})
		} else {
			seen[source] = index
		}
	}
}

func validStableID(value string) bool {
	return stableIDPattern.MatchString(value) && utf8.ValidString(value)
}

func validLabel(label string) bool {
	if !utf8.ValidString(label) || utf8.RuneCountInString(label) < 1 || utf8.RuneCountInString(label) > MaximumLabelRunes || len([]byte(label)) > MaximumLabelBytes {
		return false
	}
	visible := false
	for _, character := range label {
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

// IsValidationError reports whether err contains semantic validation issues.
func IsValidationError(err error) bool {
	var target *ValidationError
	return errors.As(err, &target)
}
