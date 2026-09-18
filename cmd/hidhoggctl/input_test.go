package main

import (
	"testing"

	"hidhogg/internal/ipc"
)

func TestParseCommandInputAndDoctorMethods(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want string
	}{
		{name: "input status", args: []string{"input", "status"}, want: string(ipc.MethodInputStatus)},
		{name: "permission hyphen", args: []string{"input", "request-permission"}, want: string(ipc.MethodInputRequestPermission)},
		{name: "permission underscore", args: []string{"input", "request_permission"}, want: string(ipc.MethodInputRequestPermission)},
		{name: "doctor", args: []string{"doctor"}, want: string(ipc.MethodDoctor)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			method, profileID, err := parseCommand("health", "", test.args)
			if err != nil {
				t.Fatal(err)
			}
			if method != test.want || profileID != "" {
				t.Fatalf("parseCommand = %q/%q, want %q/empty", method, profileID, test.want)
			}
		})
	}
}

func TestParseCommandRejectsUnknownInputCommands(t *testing.T) {
	for _, args := range [][]string{
		{"input", "unknown"},
		{"input", "status", "extra"},
	} {
		if _, _, err := parseCommand("health", "", args); err == nil {
			t.Fatalf("accepted invalid input command %q", args)
		}
	}
}
