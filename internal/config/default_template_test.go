package config

import (
	"path/filepath"
	"testing"
)

func TestBundledDefaultConfigurationLoads(t *testing.T) {
	configurationPath := filepath.Join("..", "..", "macos", "Hidhogg", "DefaultConfig.toml")
	configuration, err := Load(configurationPath)
	if err != nil {
		t.Fatal(err)
	}
	if len(configuration.Profiles) != 1 {
		t.Fatalf("profile count = %d, want 1", len(configuration.Profiles))
	}
	if len(configuration.Profiles[0].Positions) != RequiredPositionCount {
		t.Fatalf("position count = %d, want %d", len(configuration.Profiles[0].Positions), RequiredPositionCount)
	}
	for index, position := range configuration.Profiles[0].Positions {
		if position.Action != nil {
			t.Fatalf("position %d has an action, want none", index)
		}
	}
}
