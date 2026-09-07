package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	"hidhogg/internal/profile"

	toml "github.com/pelletier/go-toml/v2"
)

const (
	// SchemaVersionV1 is retained so callers and diagnostics can identify the
	// rejected predecessor format. Decode and Validate accept only v2.
	SchemaVersionV1 = 1
	SchemaVersionV2 = 2
	SchemaVersion   = SchemaVersionV2

	AdapterUlanziD200X        = "ulanzi.d200x"
	RequiredPositionCount     = 14
	MaximumProfileCount       = 31
	MinimumBrightness         = 0
	MaximumBrightness         = 100
	DefaultIdleTimeoutSeconds = 300
	MaximumIdleTimeoutSeconds = 86400
	MaximumStableIDRunes      = 64
	MaximumLabelRunes         = 64
	MaximumLabelBytes         = 256
)

// Config is the strict schema-v2 D200X configuration.
//
// The TOML and JSON tags intentionally use the same names. JSON is used for
// schema projection and fixture validation; TOML is the runtime source format.
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
// Action, when present, is bound to this position's completed press gesture.
type Position struct {
	ID         string  `toml:"id" json:"id" jsonschema:"stable position identifier"`
	Position   string  `toml:"position" json:"position" jsonschema:"supported D200X grid position"`
	Label      string  `toml:"label" json:"label" jsonschema:"display label"`
	Background string  `toml:"background" json:"background" jsonschema:"hexadecimal background colour"`
	Action     *Action `toml:"action" json:"action,omitempty" jsonschema:"optional press action binding"`
}

// Action is the only action shape accepted by schema v2. Its position binding
// is supplied by the containing Position rather than by another field.
type Action struct {
	Type      string `toml:"type" json:"type" jsonschema:"action type"`
	Gesture   string `toml:"gesture" json:"gesture" jsonschema:"input gesture"`
	ProfileID string `toml:"profile_id" json:"profile_id" jsonschema:"case-sensitive target profile identifier"`
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
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, fmt.Errorf("read configuration %q: %w", path, err)
	}
	return Decode(data)
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
	var decoded Config
	decoder := toml.NewDecoder(bytes.NewReader(data)).DisallowUnknownFields()
	if err := decoder.Decode(&decoded); err != nil {
		return Config{}, fmt.Errorf("decode configuration TOML: %w", err)
	}

	var raw map[string]any
	if err := toml.Unmarshal(data, &raw); err != nil {
		return Config{}, fmt.Errorf("inspect configuration TOML: %w", err)
	}
	if issues := missingRequiredFields(raw); len(issues) > 0 {
		return Config{}, newValidationError(issues...)
	}
	if _, ok := raw["idle_timeout_seconds"]; !ok {
		decoded.IdleTimeoutSeconds = DefaultIdleTimeoutSeconds
	}

	if err := decoded.Validate(); err != nil {
		return Config{}, err
	}
	return decoded, nil
}

func missingRequiredFields(raw map[string]any) []ValidationIssue {
	fields := []string{"schema_version", "adapter", "brightness", "default_profile_id", "profiles"}
	issues := make([]ValidationIssue, 0, len(fields))
	for _, field := range fields {
		if _, ok := raw[field]; !ok {
			issues = append(issues, ValidationIssue{Path: field, Message: "is required"})
		}
	}
	return issues
}

// JSON returns the canonical JSON projection used by schema consumers and
// tests. It carries the same property names as the TOML DTO.
func (c Config) JSON() ([]byte, error) {
	return json.Marshal(c)
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
				ID:         value.ID,
				Position:   value.Position,
				Label:      value.Label,
				Background: value.Background,
			}
			if value.Action != nil {
				converted.Action = &profile.Action{
					Type:      value.Action.Type,
					Gesture:   value.Action.Gesture,
					ProfileID: value.Action.ProfileID,
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
	Message string
}

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
	if c.SchemaVersion != SchemaVersionV2 {
		issues = append(issues, ValidationIssue{
			Path:    "schema_version",
			Message: fmt.Sprintf("must equal %d", SchemaVersionV2),
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
		profilePath := fmt.Sprintf("profiles[%d]", profileIndex)
		validateProfile(&issues, profilePath, current, profileOccurrences)
		if occurrences := profileOccurrences[current.ID]; len(occurrences) > 1 && occurrences[0] == profileIndex {
			for _, duplicateIndex := range occurrences[1:] {
				issues = append(issues, ValidationIssue{
					Path:    fmt.Sprintf("profiles[%d].id", duplicateIndex),
					Message: fmt.Sprintf("duplicates profiles[%d].id", profileIndex),
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
			Path:    currentPath + ".id",
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
		positionPath := fmt.Sprintf("%s[%d]", positionsPath, positionIndex)
		validatePosition(issues, positionPath, position, profileOccurrences)
		if previous, ok := seenIDs[position.ID]; ok {
			*issues = append(*issues, ValidationIssue{
				Path:    positionPath + ".id",
				Message: fmt.Sprintf("duplicates %s[%d].id", positionsPath, previous),
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
	if _, ok := LookupPosition(position.Position); !ok {
		*issues = append(*issues, ValidationIssue{
			Path:    path + ".position",
			Message: "is not a supported D200X position",
		})
	}
	if !validLabel(position.Label) {
		*issues = append(*issues, ValidationIssue{
			Path:    path + ".label",
			Message: "must contain visible text and be at most 64 characters",
		})
	}
	if !backgroundPattern.MatchString(position.Background) {
		*issues = append(*issues, ValidationIssue{
			Path:    path + ".background",
			Message: "must be a hexadecimal colour such as #102030 or #102030ff",
		})
	}
	if position.Action == nil {
		return
	}
	actionPath := path + ".action"
	if position.Action.Type != "activate_profile" {
		*issues = append(*issues, ValidationIssue{Path: actionPath + ".type", Message: "must equal \"activate_profile\""})
	}
	if position.Action.Gesture != "press" {
		*issues = append(*issues, ValidationIssue{Path: actionPath + ".gesture", Message: "must equal \"press\""})
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
