package config

import (
	"errors"
	"fmt"
	"io/fs"
	"path/filepath"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	toml "github.com/pelletier/go-toml/v2"
)

const (
	MaximumDiagnosticKeyBytes    = 160
	MaximumDiagnosticDetailBytes = 160
	MaximumDiagnosticLocation    = 1_000_000
)

type DiagnosticCategory string

const (
	DiagnosticReadNotFound  DiagnosticCategory = "read-not-found"
	DiagnosticReadDenied    DiagnosticCategory = "read-denied"
	DiagnosticReadInvalid   DiagnosticCategory = "read-invalid"
	DiagnosticRead          DiagnosticCategory = "read"
	DiagnosticDecode        DiagnosticCategory = "decode"
	DiagnosticUnknownKey    DiagnosticCategory = "unknown-key"
	DiagnosticMissingKey    DiagnosticCategory = "missing-key"
	DiagnosticSchemaVersion DiagnosticCategory = "schema-version"
	DiagnosticValidation    DiagnosticCategory = "validation"
)

// Diagnostic is the owner-local, non-disclosing projection of one
// configuration failure. Cause is retained through Unwrap but never rendered.
type Diagnostic struct {
	Path     string
	Category DiagnosticCategory
	Key      string
	Line     int
	Column   int
	Detail   string
	cause    error
}

// DiagnosticProjection is the bounded, path-free diagnostic view that may be
// shared with status consumers. It intentionally has no source path or cause.
type DiagnosticProjection struct {
	Category DiagnosticCategory
	Key      string
	Line     int
	Column   int
	Detail   string
}

// SafeProjection returns an immutable copy of the fields safe for status
// consumers. A nil diagnostic remains absent.
func (diagnostic *Diagnostic) SafeProjection() *DiagnosticProjection {
	if diagnostic == nil {
		return nil
	}
	category := diagnostic.Category
	if !validDiagnosticCategory(category) {
		category = DiagnosticDecode
	}
	projection := &DiagnosticProjection{
		Category: category,
		Key:      safeDiagnosticText(diagnostic.Key, MaximumDiagnosticKeyBytes),
	}
	projection.Detail = diagnosticProjectionDetail(projection.Category, projection.Key)
	if diagnostic.Line > 0 && diagnostic.Line <= MaximumDiagnosticLocation &&
		diagnostic.Column > 0 && diagnostic.Column <= MaximumDiagnosticLocation {
		projection.Line = diagnostic.Line
		projection.Column = diagnostic.Column
	}
	return projection
}

// SafeDiagnosticProjection extracts a status-safe diagnostic or returns a
// fixed decode-category fallback for an opaque candidate-construction error.
func SafeDiagnosticProjection(err error) *DiagnosticProjection {
	var diagnostic *Diagnostic
	if errors.As(err, &diagnostic) && diagnostic != nil {
		return diagnostic.SafeProjection()
	}
	return &DiagnosticProjection{
		Category: DiagnosticDecode,
		Detail:   diagnosticProjectionDetail(DiagnosticDecode, ""),
	}
}

func validDiagnosticCategory(category DiagnosticCategory) bool {
	switch category {
	case DiagnosticReadNotFound, DiagnosticReadDenied, DiagnosticReadInvalid, DiagnosticRead,
		DiagnosticDecode, DiagnosticUnknownKey, DiagnosticMissingKey, DiagnosticSchemaVersion,
		DiagnosticValidation:
		return true
	default:
		return false
	}
}

func diagnosticProjectionDetail(category DiagnosticCategory, key string) string {
	switch category {
	case DiagnosticReadNotFound:
		return "configuration file was not found"
	case DiagnosticReadDenied:
		return "configuration file is not readable"
	case DiagnosticReadInvalid:
		return "configuration path is invalid"
	case DiagnosticRead:
		return "configuration file could not be read"
	case DiagnosticUnknownKey:
		if key == "pages" {
			return "pages is obsolete; use profiles"
		}
		return "key is not supported"
	case DiagnosticMissingKey:
		return "required key is missing"
	case DiagnosticSchemaVersion:
		return "use schema_version = 2"
	case DiagnosticValidation:
		return "value violates configuration constraints"
	default:
		return "TOML syntax or value type is invalid"
	}
}

func (diagnostic *Diagnostic) Error() string {
	if diagnostic == nil {
		return "configuration failure"
	}
	var output strings.Builder
	output.WriteString("configuration path=")
	output.WriteString(strconv.Quote(diagnostic.Path))
	output.WriteString(" category=")
	output.WriteString(string(diagnostic.Category))
	if diagnostic.Key != "" {
		output.WriteString(" key=")
		output.WriteString(strconv.Quote(diagnostic.Key))
	}
	if diagnostic.Line > 0 && diagnostic.Column > 0 {
		fmt.Fprintf(&output, " line=%d column=%d", diagnostic.Line, diagnostic.Column)
	}
	output.WriteString(" detail=")
	output.WriteString(strconv.Quote(diagnostic.Detail))
	return output.String()
}

func (diagnostic *Diagnostic) Unwrap() error {
	if diagnostic == nil {
		return nil
	}
	return diagnostic.cause
}

func newDiagnostic(sourcePath string, cause error) *Diagnostic {
	absolutePath, pathErr := filepath.Abs(sourcePath)
	if pathErr == nil {
		sourcePath = absolutePath
	}
	diagnostic := &Diagnostic{Path: sourcePath, cause: cause}

	var validationError *ValidationError
	var strictError *toml.StrictMissingError
	var decodeError *toml.DecodeError
	switch {
	case errors.Is(cause, fs.ErrNotExist):
		diagnostic.Category = DiagnosticReadNotFound
		diagnostic.Detail = "configuration file was not found"
	case errors.Is(cause, fs.ErrPermission):
		diagnostic.Category = DiagnosticReadDenied
		diagnostic.Detail = "configuration file is not readable"
	case errors.Is(cause, fs.ErrInvalid):
		diagnostic.Category = DiagnosticReadInvalid
		diagnostic.Detail = "configuration path is invalid"
	case errors.As(cause, &strictError):
		diagnostic.Category = DiagnosticUnknownKey
		diagnostic.Detail = "key is not supported"
		if len(strictError.Errors) > 0 {
			setDecodeLocation(diagnostic, &strictError.Errors[0])
			if diagnostic.Key == "pages" {
				diagnostic.Detail = "pages is obsolete; use profiles"
			}
		}
	case errors.As(cause, &validationError):
		diagnostic.Category = DiagnosticValidation
		diagnostic.Detail = "value violates configuration constraints"
		if len(validationError.Issues) > 0 {
			diagnostic.Key = safeDiagnosticText(validationError.Issues[0].Path, MaximumDiagnosticDetailBytes)
			switch {
			case diagnostic.Key == "schema_version":
				diagnostic.Category = DiagnosticSchemaVersion
				diagnostic.Detail = "use schema_version = 2"
			case validationError.Issues[0].Kind == ValidationIssueRequired:
				diagnostic.Category = DiagnosticMissingKey
				diagnostic.Detail = "required key is missing"
			}
		}
	case errors.As(cause, &decodeError):
		diagnostic.Category = DiagnosticDecode
		diagnostic.Detail = "TOML syntax or value type is invalid"
		setDecodeLocation(diagnostic, decodeError)
	default:
		diagnostic.Category = DiagnosticRead
		diagnostic.Detail = "configuration file could not be read"
	}
	diagnostic.Detail = safeDiagnosticText(diagnostic.Detail, MaximumDiagnosticDetailBytes)
	return diagnostic
}

func setDecodeLocation(diagnostic *Diagnostic, decodeError *toml.DecodeError) {
	if decodeError == nil {
		return
	}
	diagnostic.Line, diagnostic.Column = decodeError.Position()
	key := decodeError.Key()
	parts := make([]string, 0, len(key))
	for _, part := range key {
		parts = append(parts, safeDiagnosticText(part, MaximumDiagnosticDetailBytes))
	}
	diagnostic.Key = safeDiagnosticText(strings.Join(parts, "."), MaximumDiagnosticDetailBytes)
}

func safeDiagnosticText(value string, maximumBytes int) string {
	if maximumBytes <= 0 {
		return ""
	}
	var output strings.Builder
	for _, character := range strings.ToValidUTF8(value, "") {
		if unicode.IsControl(character) || unicode.Is(unicode.Cf, character) {
			continue
		}
		if output.Len()+utf8.RuneLen(character) > maximumBytes {
			break
		}
		output.WriteRune(character)
	}
	return output.String()
}
