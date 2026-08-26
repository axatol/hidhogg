package main

import (
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
