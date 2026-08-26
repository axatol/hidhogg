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

	toml "github.com/pelletier/go-toml/v2"
)

const (
	SchemaVersionV1       = 1
	AdapterUlanziD200X    = "ulanzi.d200x"
	RequiredPageCount     = 1
	RequiredPositionCount = 14
	MinimumBrightness     = 0
	MaximumBrightness     = 100
	MaximumStableIDRunes  = 64
	MaximumLabelRunes     = 64
)

// Config is the milestone-private, single-file D200X configuration.
//
// The TOML and JSON tags intentionally use the same names. JSON is used for
// schema projection and fixture validation; TOML is the runtime source format.
type Config struct {
	SchemaVersion int    `toml:"schema_version" json:"schema_version" jsonschema:"configuration schema version"`
	Adapter       string `toml:"adapter" json:"adapter" jsonschema:"device adapter identifier"`
	Brightness    int    `toml:"brightness" json:"brightness" jsonschema:"display brightness percentage"`
	Pages         []Page `toml:"pages" json:"pages" jsonschema:"configured display pages"`
}

// Page is the one configured D200X page. The slice is retained to make the
// exactly-one-page contract explicit in both TOML and JSON Schema.
type Page struct {
	Positions []Position `toml:"positions" json:"positions" jsonschema:"all supported D200X display positions"`
}

// Position describes one physical display position and its rendered content.
type Position struct {
	ID         string `toml:"id" json:"id" jsonschema:"stable position identifier"`
	Position   string `toml:"position" json:"position" jsonschema:"supported D200X grid position"`
	Label      string `toml:"label" json:"label" jsonschema:"display label"`
	Background string `toml:"background" json:"background" jsonschema:"hexadecimal background colour"`
}

// DisplayPosition and Tile are compatibility aliases for callers that use
// either the physical-layout or product terminology. They do not introduce a
// second DTO or a second wire representation.
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

	// A zero brightness is valid, so its presence cannot be inferred from the
	// decoded Go value. The generic pass supplies that one structural presence
	// check while the canonical DTO remains the sole public model.
	var raw map[string]any
	if err := toml.Unmarshal(data, &raw); err != nil {
		return Config{}, fmt.Errorf("inspect configuration TOML: %w", err)
	}
	if _, ok := raw["brightness"]; !ok {
		return Config{}, newValidationError(ValidationIssue{
			Path:    "brightness",
			Message: "is required",
		})
	}

	if err := decoded.Validate(); err != nil {
		return Config{}, err
	}
	return decoded, nil
}

// JSON returns the canonical JSON projection used by schema consumers and
// tests. It carries the same property names as the TOML DTO.
func (c Config) JSON() ([]byte, error) {
	return json.Marshal(c)
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
// cannot express, including the supported-position domain and uniqueness.
func (c Config) Validate() error {
	var issues []ValidationIssue
	if c.SchemaVersion != SchemaVersionV1 {
		issues = append(issues, ValidationIssue{
			Path:    "schema_version",
			Message: fmt.Sprintf("must equal %d", SchemaVersionV1),
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
	if len(c.Pages) != RequiredPageCount {
		issues = append(issues, ValidationIssue{
			Path:    "pages",
			Message: fmt.Sprintf("must contain exactly %d page", RequiredPageCount),
		})
	}
	for pageIndex, page := range c.Pages {
		pagePath := fmt.Sprintf("pages[%d].positions", pageIndex)
		if len(page.Positions) != RequiredPositionCount {
			issues = append(issues, ValidationIssue{
				Path:    pagePath,
				Message: fmt.Sprintf("must contain exactly %d positions", RequiredPositionCount),
			})
		}

		seenIDs := make(map[string]int, len(page.Positions))
		seenPositions := make(map[string]int, len(page.Positions))
		for positionIndex, position := range page.Positions {
			positionPath := fmt.Sprintf("%s[%d]", pagePath, positionIndex)
			validatePosition(&issues, positionPath, position)
			if previous, ok := seenIDs[position.ID]; ok {
				issues = append(issues, ValidationIssue{
					Path:    positionPath + ".id",
					Message: fmt.Sprintf("duplicates %s[%d].id", pagePath, previous),
				})
			} else {
				seenIDs[position.ID] = positionIndex
			}
			if previous, ok := seenPositions[position.Position]; ok {
				issues = append(issues, ValidationIssue{
					Path:    positionPath + ".position",
					Message: fmt.Sprintf("duplicates %s[%d].position", pagePath, previous),
				})
			} else {
				seenPositions[position.Position] = positionIndex
			}
		}
		for _, spec := range supportedPositionSpecs {
			if _, ok := seenPositions[spec.Name]; !ok {
				issues = append(issues, ValidationIssue{
					Path:    pagePath,
					Message: fmt.Sprintf("must include position %q", spec.Name),
				})
			}
		}
	}
	if len(issues) == 0 {
		return nil
	}
	return newValidationError(issues...)
}

func validatePosition(issues *[]ValidationIssue, path string, position Position) {
	if !stableIDPattern.MatchString(position.ID) || utf8.RuneCountInString(position.ID) > MaximumStableIDRunes {
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
}

func validLabel(label string) bool {
	if !utf8.ValidString(label) || strings.TrimSpace(label) == "" || utf8.RuneCountInString(label) > MaximumLabelRunes {
		return false
	}
	for _, character := range label {
		if unicode.IsControl(character) {
			return false
		}
	}
	return true
}

// IsValidationError reports whether err contains semantic validation issues.
func IsValidationError(err error) bool {
	var target *ValidationError
	return errors.As(err, &target)
}
