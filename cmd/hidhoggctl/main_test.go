package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"hidhogg/internal/discovery"
	"hidhogg/internal/ipc"
)

const controllerTestInstanceID = "11111111-1111-4111-8111-111111111111"

func TestParseCommandProfiles(t *testing.T) {
	tests := []struct {
		name        string
		defaultMode string
		profileID   string
		args        []string
		wantMethod  string
		wantProfile string
		wantError   string
	}{
		{
			name:        "list subcommand",
			defaultMode: "health",
			args:        []string{"profiles", "list"},
			wantMethod:  string(ipc.MethodProfilesList),
		},
		{
			name:        "activate positional case preserved",
			defaultMode: "health",
			args:        []string{"profiles", "activate", "Work.Profile"},
			wantMethod:  string(ipc.MethodProfilesActivate),
			wantProfile: "Work.Profile",
		},
		{
			name:        "activate flag",
			defaultMode: "health",
			args:        []string{"profiles", "activate", "--profile-id", "Work.Profile"},
			wantMethod:  string(ipc.MethodProfilesActivate),
			wantProfile: "Work.Profile",
		},
		{
			name:        "dotted compatibility",
			defaultMode: "health",
			args:        []string{"profiles.activate", "Work.Profile"},
			wantMethod:  string(ipc.MethodProfilesActivate),
			wantProfile: "Work.Profile",
		},
		{
			name:        "method flag",
			defaultMode: string(ipc.MethodProfilesActivate),
			profileID:   "Work.Profile",
			wantMethod:  string(ipc.MethodProfilesActivate),
			wantProfile: "Work.Profile",
		},
		{
			name:        "list rejects profile ID",
			defaultMode: string(ipc.MethodProfilesList),
			profileID:   "Work.Profile",
			wantError:   "only valid for profiles activate",
		},
		{
			name:        "activate requires profile ID",
			defaultMode: string(ipc.MethodProfilesActivate),
			wantError:   "requires --profile-id",
		},
		{
			name:        "duplicate profile ID",
			defaultMode: "health",
			profileID:   "Work.Profile",
			args:        []string{"profiles", "activate", "--profile-id", "Other.Profile"},
			wantError:   "provided more than once",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			method, profileID, err := parseCommand(test.defaultMode, test.profileID, test.args)
			if test.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), test.wantError) {
					t.Fatalf("error = %v, want substring %q", err, test.wantError)
				}
				return
			}
			if err != nil {
				t.Fatalf("parse command: %v", err)
			}
			if method != test.wantMethod || profileID != test.wantProfile {
				t.Fatalf("parsed command = %q/%q, want %q/%q", method, profileID, test.wantMethod, test.wantProfile)
			}
		})
	}
}

func TestRunWithOutputRejectsIncompleteAndMixedModes(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want string
	}{
		{
			name: "no mode",
			args: []string{"health"},
			want: "--socket-path",
		},
		{
			name: "legacy missing instance",
			args: []string{"--socket-path", "/path/that/does/not/exist/runtime.sock", "health"},
			want: "--instance-id",
		},
		{
			name: "legacy missing socket",
			args: []string{"--instance-id", controllerTestInstanceID, "health"},
			want: "--socket-path",
		},
		{
			name: "discovery and legacy mixed",
			args: []string{
				"--runtime-dir", "/path/that/does/not/exist",
				"--socket-path", "/path/that/does/not/exist/runtime.sock",
				"health",
			},
			want: "mutually exclusive",
		},
		{
			name: "discovery explicit instance",
			args: []string{
				"--runtime-dir", "/path/that/does/not/exist",
				"--instance-id", controllerTestInstanceID,
				"health",
			},
			want: "only valid with --socket-path",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			err := runWithOutput(test.args, &output)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want substring %q", err, test.want)
			}
			if output.Len() != 0 {
				t.Fatalf("invalid mode wrote stdout: %q", output.String())
			}
		})
	}
}

func TestRunWithOutputDiscoversRuntimeAndRetainsMethodBehavior(t *testing.T) {
	runtimeDir, instanceID, cleanup := startM03ControllerRuntime(t, nil)
	defer cleanup()

	for _, method := range []string{"health", "status"} {
		var output bytes.Buffer
		if err := runWithOutput([]string{"--runtime-dir", runtimeDir, method}, &output); err != nil {
			t.Fatalf("%s call: %v", method, err)
		}
		encoded := output.String()
		if !strings.Contains(encoded, `"state":"ready"`) || !strings.Contains(encoded, fmt.Sprintf(`"instance_id":"%s"`, instanceID)) {
			t.Fatalf("%s response = %q", method, encoded)
		}
		if method == "status" && !strings.Contains(encoded, `"protocol_version":1`) {
			t.Fatalf("status response omitted protocol version: %q", encoded)
		}
	}
}

func TestRunWithOutputLegacyModeNormalizesUppercaseInstanceID(t *testing.T) {
	runtimeDir, instanceID, cleanup := startM03ControllerRuntime(t, nil)
	defer cleanup()

	var output bytes.Buffer
	if err := runWithOutput([]string{
		"--socket-path", filepath.Join(runtimeDir, discovery.SocketFileName),
		"--instance-id", strings.ToUpper(instanceID),
		"health",
	}, &output); err != nil {
		t.Fatalf("legacy health call: %v", err)
	}
	if !strings.Contains(output.String(), fmt.Sprintf(`"instance_id":"%s"`, instanceID)) {
		t.Fatalf("legacy response = %q", output.String())
	}
}

func TestRunWithOutputProfilesSupportsDiscoveryAndLegacyModes(t *testing.T) {
	service := newCLIProfileService()
	runtimeDir, instanceID, cleanup := startM03ProfileControllerRuntime(t, service)
	defer cleanup()

	var output bytes.Buffer
	if err := runWithOutput([]string{"--runtime-dir", runtimeDir, "profiles", "list"}, &output); err != nil {
		t.Fatalf("discovery profile list: %v", err)
	}
	assertCLIProfileListResponse(t, output.Bytes(), instanceID, []ipc.ProfileSummary{
		{ID: "default", Label: "Default", IsDefault: true, IsCurrent: true},
		{ID: "Work.Profile", Label: "Work", IsDefault: false, IsCurrent: false},
	})

	output.Reset()
	if err := runWithOutput([]string{"--runtime-dir", runtimeDir, "profiles", "activate", "Work.Profile"}, &output); err != nil {
		t.Fatalf("discovery profile activation: %v", err)
	}
	response := decodeCLIProfileResponse(t, output.Bytes(), ipc.MethodProfilesActivate, instanceID)
	if response.Error != nil || response.Result == nil || response.Result.ProfileID != "Work.Profile" || !response.Result.Changed {
		t.Fatalf("discovery activation response = %#v", response)
	}

	output.Reset()
	if err := runWithOutput([]string{
		"--socket-path", filepath.Join(runtimeDir, discovery.SocketFileName),
		"--instance-id", strings.ToUpper(instanceID),
		"profiles", "list",
	}, &output); err != nil {
		t.Fatalf("legacy profile list: %v", err)
	}
	assertCLIProfileListResponse(t, output.Bytes(), instanceID, []ipc.ProfileSummary{
		{ID: "default", Label: "Default", IsDefault: true, IsCurrent: false},
		{ID: "Work.Profile", Label: "Work", IsDefault: false, IsCurrent: true},
	})

	output.Reset()
	if err := runWithOutput([]string{
		"--socket-path", filepath.Join(runtimeDir, discovery.SocketFileName),
		"--instance-id", instanceID,
		"profiles.activate", "default",
	}, &output); err != nil {
		t.Fatalf("legacy profile activation: %v", err)
	}
	response = decodeCLIProfileResponse(t, output.Bytes(), ipc.MethodProfilesActivate, instanceID)
	if response.Error != nil || response.Result == nil || response.Result.ProfileID != "default" || !response.Result.Changed {
		t.Fatalf("legacy activation response = %#v", response)
	}

	output.Reset()
	if err := runWithOutput([]string{
		"--socket-path", filepath.Join(runtimeDir, discovery.SocketFileName),
		"--instance-id", instanceID,
		"profiles", "activate", "Missing.Profile",
	}, &output); err != nil {
		t.Fatalf("legacy profile error returned Go error: %v", err)
	}
	response = decodeCLIProfileResponse(t, output.Bytes(), ipc.MethodProfilesActivate, instanceID)
	if response.Result != nil || response.Error == nil || response.Error.Code != ipc.ErrorProfileNotFound || response.Error.Message != "requested profile does not exist" {
		t.Fatalf("legacy profile error response = %#v", response)
	}
}

func assertCLIProfileListResponse(t *testing.T, body []byte, instanceID string, want []ipc.ProfileSummary) {
	t.Helper()
	response := decodeCLIProfileResponse(t, body, ipc.MethodProfilesList, instanceID)
	if response.Error != nil || response.Result == nil || response.Result.InstanceID != instanceID {
		t.Fatalf("profile list response = %#v", response)
	}
	if len(response.Result.Profiles) != len(want) {
		t.Fatalf("profile list summaries = %#v, want %#v", response.Result.Profiles, want)
	}
	for index := range want {
		if response.Result.Profiles[index] != want[index] {
			t.Fatalf("profile summary %d = %#v, want %#v", index, response.Result.Profiles[index], want[index])
		}
	}
}

func decodeCLIProfileResponse(t *testing.T, body []byte, method ipc.Method, instanceID string) ipc.Response {
	t.Helper()
	var envelope struct {
		RequestID *string `json:"request_id"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		t.Fatalf("decode CLI envelope: %v", err)
	}
	if envelope.RequestID == nil {
		t.Fatal("CLI response omitted request ID")
	}
	response, err := ipc.DecodeResponse(body, *envelope.RequestID, string(method), instanceID)
	if err != nil {
		t.Fatalf("decode CLI profile response: %v", err)
	}
	return response
}

type cliProfileService struct {
	mu               sync.Mutex
	profiles         []ipc.ProfileSummary
	currentID        string
	activationErrors map[string]error
}

func newCLIProfileService() *cliProfileService {
	return &cliProfileService{
		profiles: []ipc.ProfileSummary{
			{ID: "default", Label: "Default", IsDefault: true},
			{ID: "Work.Profile", Label: "Work"},
		},
		currentID:        "default",
		activationErrors: make(map[string]error),
	}
}

func (service *cliProfileService) ListProfiles() []ipc.ProfileSummary {
	service.mu.Lock()
	defer service.mu.Unlock()
	summaries := make([]ipc.ProfileSummary, len(service.profiles))
	copy(summaries, service.profiles)
	for index := range summaries {
		summaries[index].IsCurrent = summaries[index].ID == service.currentID
	}
	return summaries
}

func (service *cliProfileService) ActivateProfile(_ context.Context, profileID string) (ipc.ActivationResult, error) {
	service.mu.Lock()
	defer service.mu.Unlock()
	if err, ok := service.activationErrors[profileID]; ok {
		return ipc.ActivationResult{}, err
	}
	known := false
	for _, profile := range service.profiles {
		if profile.ID == profileID {
			known = true
			break
		}
	}
	if !known {
		return ipc.ActivationResult{}, ipc.ErrProfileNotFound
	}
	if service.currentID == profileID {
		return ipc.ActivationResult{ProfileID: profileID}, nil
	}
	service.currentID = profileID
	return ipc.ActivationResult{ProfileID: profileID, Changed: true}, nil
}

func TestRunWithOutputSuppressesStdoutAfterSocketSubstitution(t *testing.T) {
	runtimeDir := makeM03ControllerRuntimeDir(t)
	socketPath := filepath.Join(runtimeDir, discovery.SocketFileName)
	var mutate sync.Once
	mutationResult := make(chan error, 1)
	serverHandler := ipc.HandlerFunc(func(_ context.Context, request ipc.Request) (ipc.Result, error) {
		mutate.Do(func() {
			if err := os.Remove(socketPath); err != nil {
				mutationResult <- fmt.Errorf("remove socket for substitution: %w", err)
				return
			}
			if err := os.WriteFile(socketPath, []byte("foreign"), 0o600); err != nil {
				mutationResult <- fmt.Errorf("write substituted socket: %w", err)
				return
			}
			mutationResult <- nil
		})
		return ipc.Result{InstanceID: request.InstanceID, State: ipc.ReadyState}, nil
	})
	_, _, cleanup := startM03ControllerRuntimeWithDir(t, runtimeDir, serverHandler)
	defer cleanup()

	var output bytes.Buffer
	err := runWithOutput([]string{"--runtime-dir", runtimeDir, "health"}, &output)
	if err == nil || !strings.Contains(err.Error(), "after IPC call") {
		t.Fatalf("substitution error = %v", err)
	}
	if mutationErr := <-mutationResult; mutationErr != nil {
		t.Fatal(mutationErr)
	}
	if output.Len() != 0 {
		t.Fatalf("substituted runtime wrote stdout: %q", output.String())
	}
}

func startM03ControllerRuntime(t *testing.T, handler ipc.Handler) (string, string, func()) {
	t.Helper()
	return startM03ControllerRuntimeWithDir(t, makeM03ControllerRuntimeDir(t), handler)
}

func startM03ControllerRuntimeWithDir(t *testing.T, runtimeDir string, handler ipc.Handler) (string, string, func()) {
	t.Helper()
	return startM03ControllerRuntimeWithDirAndProfileService(t, runtimeDir, handler, nil, true)
}

func startM03ProfileControllerRuntime(t *testing.T, service ipc.ProfileService) (string, string, func()) {
	t.Helper()
	return startM03ControllerRuntimeWithDirAndProfileService(t, makeProfileSocketTestDirectory(t), nil, service, false)
}

func startM03ControllerRuntimeWithDirAndProfileService(t *testing.T, runtimeDir string, handler ipc.Handler, profileService ipc.ProfileService, skipUnavailableSocket bool) (string, string, func()) {
	t.Helper()
	generation, err := discovery.Open(discovery.Options{RuntimeDir: runtimeDir, InstanceID: controllerTestInstanceID})
	if err != nil {
		t.Fatalf("open controller generation: %v", err)
	}
	server, err := ipc.NewServer(ipc.ServerConfig{
		SocketPath:     generation.SocketPath(),
		InstanceID:     generation.InstanceID(),
		Handler:        handler,
		ProfileService: profileService,
	})
	if err != nil {
		_ = generation.Close()
		t.Fatalf("create controller server: %v", err)
	}
	if err := server.Start(); err != nil {
		_ = server.Close()
		_ = generation.Close()
		if skipUnavailableSocket && m03UnixSocketUnavailable(err) {
			t.Skipf("Unix socket creation unavailable in this environment: %v", err)
		}
		t.Fatalf("bind controller server: %v", err)
	}
	if _, err := generation.RecordSocket(); err != nil {
		_ = server.Close()
		_ = generation.Close()
		t.Fatalf("record controller socket: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- server.Serve(ctx) }()
	select {
	case <-server.ServingReady():
	case err := <-done:
		cancel()
		_ = server.Close()
		_ = generation.Close()
		t.Fatalf("controller server exited before serving: %v", err)
	case <-time.After(2 * time.Second):
		cancel()
		_ = server.Close()
		_ = generation.Close()
		t.Fatal("controller server did not become ready")
	}
	if err := generation.PublishMetadata(); err != nil {
		cancel()
		_ = server.Close()
		_ = generation.Close()
		t.Fatalf("publish controller metadata: %v", err)
	}
	cleanup := func() {
		cancel()
		_ = server.Close()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Errorf("controller server did not stop")
		}
		_ = generation.Close()
	}
	return runtimeDir, generation.InstanceID(), cleanup
}

func makeProfileSocketTestDirectory(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp(".", ".hidhogg-socket-test-*")
	if err != nil {
		t.Fatalf("create profile socket test directory: %v", err)
	}
	directory, err = filepath.Abs(directory)
	if err != nil {
		_ = os.Remove(directory)
		t.Fatalf("resolve profile socket test directory: %v", err)
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		_ = os.Remove(directory)
		t.Fatalf("set profile socket test directory mode: %v", err)
	}
	validateProfileSocketTestDirectory(t, directory)
	t.Cleanup(func() { removeProfileSocketTestDirectory(t, directory) })
	return directory
}

func validateProfileSocketTestDirectory(t *testing.T, directory string) {
	t.Helper()
	absolute, err := filepath.Abs(directory)
	if err != nil {
		t.Fatalf("resolve profile socket test directory: %v", err)
	}
	workspace, err := os.Getwd()
	if err != nil {
		t.Fatalf("resolve workspace directory: %v", err)
	}
	if filepath.Dir(absolute) != workspace || !strings.HasPrefix(filepath.Base(absolute), ".hidhogg-socket-test-") {
		t.Fatalf("profile socket test directory is not an exact workspace child: %q", directory)
	}
	info, err := os.Lstat(absolute)
	if err != nil {
		t.Fatalf("inspect profile socket test directory: %v", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0o700 {
		t.Fatalf("profile socket test directory is not owner-private: %s", info.Mode())
	}
}

func removeProfileSocketTestDirectory(t *testing.T, directory string) {
	t.Helper()
	absolute, err := filepath.Abs(directory)
	if err != nil {
		t.Errorf("resolve profile socket test directory for cleanup: %v", err)
		return
	}
	workspace, err := os.Getwd()
	if err != nil {
		t.Errorf("resolve workspace directory for cleanup: %v", err)
		return
	}
	if filepath.Dir(absolute) != workspace || !strings.HasPrefix(filepath.Base(absolute), ".hidhogg-socket-test-") {
		t.Errorf("refusing to clean non-child profile socket test directory %q", directory)
		return
	}
	info, err := os.Lstat(absolute)
	if os.IsNotExist(err) {
		return
	}
	if err != nil {
		t.Errorf("inspect profile socket test directory for cleanup: %v", err)
		return
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0o700 {
		t.Errorf("refusing to clean non-owner-private profile socket test directory %q", directory)
		return
	}
	if err := os.RemoveAll(absolute); err != nil {
		t.Errorf("remove profile socket test directory: %v", err)
	}
}

func makeM03ControllerRuntimeDir(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp(".", ".ctl-")
	if err != nil {
		t.Fatalf("create controller runtime directory: %v", err)
	}
	directory, err = filepath.Abs(directory)
	if err != nil {
		_ = os.RemoveAll(directory)
		t.Fatalf("resolve controller runtime directory: %v", err)
	}
	if err := os.Chmod(directory, 0o700); err != nil {
		_ = os.RemoveAll(directory)
		t.Fatalf("set controller runtime directory mode: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	return directory
}

func m03UnixSocketUnavailable(err error) bool {
	return errors.Is(err, syscall.EPERM) || strings.Contains(err.Error(), "operation not permitted")
}
