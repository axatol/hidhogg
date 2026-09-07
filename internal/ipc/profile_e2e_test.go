package ipc

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestClientProfilesEndToEnd(t *testing.T) {
	service := newStatefulProfileIPCService()
	client, cleanup := startProfileIPCServer(t, service)
	defer cleanup()

	response, err := client.ListProfiles(context.Background(), testInstanceID)
	if err != nil {
		t.Fatalf("list profiles: %v", err)
	}
	assertProfileListResponse(t, response, []ProfileSummary{
		{ID: "default", Label: "Default", IsDefault: true, IsCurrent: true},
		{ID: "Work.Profile", Label: "Work", IsDefault: false, IsCurrent: false},
	})

	response, err = client.ActivateProfile(context.Background(), testInstanceID, "default")
	if err != nil {
		t.Fatalf("activate current profile: %v", err)
	}
	if response.Error != nil || response.Result == nil || response.Result.ProfileID != "default" || response.Result.Changed {
		t.Fatalf("current activation response = %#v", response)
	}

	response, err = client.ActivateProfile(context.Background(), testInstanceID, "Work.Profile")
	if err != nil {
		t.Fatalf("activate mixed-case profile ID: %v", err)
	}
	if response.Error != nil || response.Result == nil || response.Result.ProfileID != "Work.Profile" || !response.Result.Changed {
		t.Fatalf("changed activation response = %#v", response)
	}

	response, err = client.ListProfiles(context.Background(), testInstanceID)
	if err != nil {
		t.Fatalf("list profiles after activation: %v", err)
	}
	assertProfileListResponse(t, response, []ProfileSummary{
		{ID: "default", Label: "Default", IsDefault: true, IsCurrent: false},
		{ID: "Work.Profile", Label: "Work", IsDefault: false, IsCurrent: true},
	})
	if got := service.activationIDsSnapshot(); len(got) != 2 || got[0] != "default" || got[1] != "Work.Profile" {
		t.Fatalf("activation IDs = %#v", got)
	}
}

func TestClientProfilesEndToEndStableErrors(t *testing.T) {
	service := newStatefulProfileIPCService()
	service.setActivationError("Activation.Profile", ErrActivationFailed)
	service.setActivationError("Device.Profile", ErrDeviceWriteFailed)
	service.setActivationError("Shutdown.Profile", ErrShuttingDown)
	service.setActivationError("Busy.Profile", ErrBusy)
	client, cleanup := startProfileIPCServer(t, service)
	defer cleanup()

	tests := []struct {
		name      string
		profileID string
		code      string
		message   string
	}{
		{name: "not found", profileID: "Missing.Profile", code: ErrorProfileNotFound, message: "requested profile does not exist"},
		{name: "activation failed", profileID: "Activation.Profile", code: ErrorActivationFailed, message: "profile activation failed"},
		{name: "device write failed", profileID: "Device.Profile", code: ErrorDeviceWriteFailed, message: "device write failed"},
		{name: "shutting down", profileID: "Shutdown.Profile", code: ErrorShuttingDown, message: "runtime is shutting down"},
		{name: "busy", profileID: "Busy.Profile", code: ErrorBusy, message: "runtime is busy"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response, err := client.ActivateProfile(context.Background(), testInstanceID, test.profileID)
			if err != nil {
				t.Fatalf("activate profile: %v", err)
			}
			if response.Result != nil || response.Error == nil || response.Error.Code != test.code || response.Error.Message != test.message {
				t.Fatalf("error response = %#v, want %s/%s", response, test.code, test.message)
			}
			if response.RequestID == nil {
				t.Fatal("stable error response omitted request ID")
			}
		})
	}
}

func assertProfileListResponse(t *testing.T, response Response, want []ProfileSummary) {
	t.Helper()
	if response.Error != nil || response.Result == nil {
		t.Fatalf("profile list response = %#v", response)
	}
	if response.Result.InstanceID != testInstanceID {
		t.Fatalf("profile list instance ID = %q, want %q", response.Result.InstanceID, testInstanceID)
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

type statefulProfileIPCService struct {
	mu               sync.Mutex
	profiles         []ProfileSummary
	currentID        string
	activationErrors map[string]error
	activationCalls  []string
}

func newStatefulProfileIPCService() *statefulProfileIPCService {
	return &statefulProfileIPCService{
		profiles: []ProfileSummary{
			{ID: "default", Label: "Default", IsDefault: true},
			{ID: "Work.Profile", Label: "Work"},
		},
		currentID:        "default",
		activationErrors: make(map[string]error),
	}
}

func (service *statefulProfileIPCService) ListProfiles() []ProfileSummary {
	service.mu.Lock()
	defer service.mu.Unlock()
	summaries := make([]ProfileSummary, len(service.profiles))
	copy(summaries, service.profiles)
	for index := range summaries {
		summaries[index].IsCurrent = summaries[index].ID == service.currentID
	}
	return summaries
}

func (service *statefulProfileIPCService) ActivateProfile(ctx context.Context, profileID string) (ActivationResult, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	select {
	case <-ctx.Done():
		return ActivationResult{}, ctx.Err()
	default:
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	service.activationCalls = append(service.activationCalls, profileID)
	if err, ok := service.activationErrors[profileID]; ok {
		return ActivationResult{}, err
	}
	known := false
	for _, profile := range service.profiles {
		if profile.ID == profileID {
			known = true
			break
		}
	}
	if !known {
		return ActivationResult{}, ErrProfileNotFound
	}
	if service.currentID == profileID {
		return ActivationResult{ProfileID: profileID}, nil
	}
	service.currentID = profileID
	return ActivationResult{ProfileID: profileID, Changed: true}, nil
}

func (service *statefulProfileIPCService) setActivationError(profileID string, err error) {
	service.mu.Lock()
	defer service.mu.Unlock()
	service.activationErrors[profileID] = err
}

func (service *statefulProfileIPCService) activationIDsSnapshot() []string {
	service.mu.Lock()
	defer service.mu.Unlock()
	return append([]string(nil), service.activationCalls...)
}

func startProfileIPCServer(t *testing.T, service ProfileService) (*Client, func()) {
	t.Helper()
	directory := newProfileSocketTestDirectory(t)
	socketPath := filepath.Join(directory, "runtime.sock")
	allowPeer := func(net.Conn) error { return nil }
	server, err := NewServer(ServerConfig{
		SocketPath:     socketPath,
		InstanceID:     testInstanceID,
		Deadlines:      Deadlines{Read: 2 * time.Second, Write: 2 * time.Second},
		ProfileService: service,
		PeerVerifier:   allowPeer,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := server.Start(); err != nil {
		t.Fatalf("start profile IPC server: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- server.Serve(ctx) }()
	select {
	case <-server.ServingReady():
	case err := <-done:
		cancel()
		_ = server.Close()
		t.Fatalf("profile IPC server exited before serving: %v", err)
	case <-time.After(2 * time.Second):
		cancel()
		_ = server.Close()
		t.Fatal("profile IPC server did not become ready")
	}
	client, err := NewClient(ClientConfig{SocketPath: socketPath, PeerVerifier: allowPeer})
	if err != nil {
		cancel()
		_ = server.Close()
		<-done
		t.Fatal(err)
	}
	cleanup := func() {
		cancel()
		_ = server.Close()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Errorf("profile IPC server did not stop")
		}
	}
	return client, cleanup
}

func newProfileSocketTestDirectory(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp(".", ".hidhogg-socket-test-*")
	if err != nil {
		t.Fatalf("create profile socket test directory: %v", err)
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
