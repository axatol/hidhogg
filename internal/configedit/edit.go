package configedit

import (
	"bytes"
	"fmt"

	"hidhogg/internal/config"

	"github.com/pelletier/go-toml/v2/unstable/edit"
)

// UpdateProfileLabel returns TOML with the matching profile's label updated.
func UpdateProfileLabel(source []byte, profileID, label string) ([]byte, error) {
	decoded, err := config.Decode(source)
	if err != nil {
		return nil, fmt.Errorf("decode configuration before profile label update: %w", err)
	}

	profile, ok := profileByID(decoded, profileID)
	if !ok {
		return nil, fmt.Errorf("profile ID %q does not resolve to a profile", profileID)
	}

	if profile.Label == label {
		return bytes.Clone(source), nil
	}

	document, err := edit.Parse(source)
	if err != nil {
		return nil, fmt.Errorf("parse configuration for profile label update: %w", err)
	}
	path := []string{"profiles", profileID, "label"}
	if err := document.Set(path, label); err != nil {
		return nil, fmt.Errorf("update profile label: %w", err)
	}

	updated := document.Bytes()
	if _, err := config.Decode(updated); err != nil {
		return nil, fmt.Errorf("validate configuration after profile label update: %w", err)
	}
	return updated, nil
}
