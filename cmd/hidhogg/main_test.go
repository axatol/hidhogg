package main

import (
	"path/filepath"
	"strings"
	"testing"
)

const cliTestInstanceID = "11111111-1111-4111-8111-111111111111"

func TestRunArgsRequiresConfigPath(t *testing.T) {
	err := runArgs([]string{
		"--socket-path", "/tmp/hidhogg-runtime.sock",
		"--instance-id", cliTestInstanceID,
	})
	if err == nil || !strings.Contains(err.Error(), "--config-path") {
		t.Fatalf("missing config path error = %v", err)
	}
}

func TestParseArgsSupportsDiscoveryModeAndGeneratesIDLater(t *testing.T) {
	config, err := parseArgs([]string{
		"--runtime-dir", "/tmp/hidhogg-runtime",
		"--config-path", "/tmp/config.toml",
	})
	if err != nil {
		t.Fatalf("parse discovery mode: %v", err)
	}
	if config.RuntimeDir != "/tmp/hidhogg-runtime" || config.SocketPath != "" || config.InstanceID != "" {
		t.Fatalf("discovery config = %+v", config)
	}
}

func TestParseArgsNormalizesExplicitUUIDInBothModes(t *testing.T) {
	uppercase := strings.ToUpper(cliTestInstanceID)
	for name, args := range map[string][]string{
		"discovery": {
			"--runtime-dir", "/tmp/hidhogg-runtime",
			"--instance-id", uppercase,
			"--config-path", "/tmp/config.toml",
		},
		"legacy": {
			"--socket-path", "/tmp/hidhogg-runtime.sock",
			"--instance-id", uppercase,
			"--config-path", "/tmp/config.toml",
		},
	} {
		t.Run(name, func(t *testing.T) {
			config, err := parseArgs(args)
			if err != nil {
				t.Fatalf("parse %s mode: %v", name, err)
			}
			if config.InstanceID != cliTestInstanceID {
				t.Fatalf("normalized instance ID = %q, want %q", config.InstanceID, cliTestInstanceID)
			}
		})
	}
}

func TestParseArgsRejectsInvalidModeCombinationsBeforeFilesystem(t *testing.T) {
	absoluteConfig := filepath.Join(t.TempDir(), "config.toml")
	tests := []struct {
		name string
		args []string
		want string
	}{
		{
			name: "mixed",
			args: []string{
				"--runtime-dir", "/path/that/does/not/exist",
				"--socket-path", "/path/that/does/not/exist/runtime.sock",
				"--config-path", absoluteConfig,
			},
			want: "mutually exclusive",
		},
		{
			name: "discovery missing config",
			args: []string{"--runtime-dir", "/path/that/does/not/exist"},
			want: "--config-path",
		},
		{
			name: "legacy missing instance",
			args: []string{"--socket-path", "/path/that/does/not/exist/runtime.sock", "--config-path", absoluteConfig},
			want: "--instance-id",
		},
		{
			name: "no mode",
			args: []string{"--config-path", absoluteConfig},
			want: "--socket-path",
		},
		{
			name: "relative config",
			args: []string{
				"--socket-path", "/path/that/does/not/exist/runtime.sock",
				"--instance-id", cliTestInstanceID,
				"--config-path", "config.toml",
			},
			want: "absolute",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := parseArgs(test.args); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("parse error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestRunArgsRequiresAbsoluteConfigPath(t *testing.T) {
	err := runArgs([]string{
		"--socket-path", "/tmp/hidhogg-runtime.sock",
		"--instance-id", cliTestInstanceID,
		"--config-path", "config.toml",
	})
	if err == nil || !strings.Contains(err.Error(), "absolute") {
		t.Fatalf("relative config path error = %v", err)
	}
}
