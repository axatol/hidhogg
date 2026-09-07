package ipc

import (
	"bytes"
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestServerClientHealthAndStatus(t *testing.T) {
	directory := shortTempDirectory(t)
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	socketPath := filepath.Join(directory, "runtime.sock")
	server, err := NewServer(ServerConfig{SocketPath: socketPath, InstanceID: testInstanceID})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	serverDone := make(chan error, 1)
	go func() { serverDone <- server.Serve(ctx) }()
	waitForSocket(t, socketPath)
	client, err := NewClient(ClientConfig{SocketPath: socketPath})
	if err != nil {
		t.Fatal(err)
	}
	for _, method := range []Method{MethodHealth, MethodStatus} {
		response, err := client.Call(context.Background(), method, testInstanceID)
		if err != nil {
			t.Fatalf("%s call: %v", method, err)
		}
		if response.Error != nil || response.Result == nil || response.Result.InstanceID != testInstanceID || response.Result.State != ReadyState {
			t.Fatalf("%s response = %#v", method, response)
		}
		if method == MethodHealth && response.Result.ProtocolVersion != nil {
			t.Fatal("health response unexpectedly contains protocol version")
		}
		if method == MethodStatus && (response.Result.ProtocolVersion == nil || *response.Result.ProtocolVersion != ProtocolVersion) {
			t.Fatal("status response is missing protocol version")
		}
	}
	cancel()
	select {
	case err := <-serverDone:
		if err != nil {
			t.Fatalf("server: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("server did not stop")
	}
	if _, err := os.Lstat(socketPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("socket after shutdown: %v", err)
	}
}

func TestServerRefusesExistingEndpointAndPreservesReplacement(t *testing.T) {
	directory := shortTempDirectory(t)
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	socketPath := filepath.Join(directory, "runtime.sock")
	if err := os.WriteFile(socketPath, []byte("foreign"), 0o600); err != nil {
		t.Fatal(err)
	}
	server, err := NewServer(ServerConfig{SocketPath: socketPath, InstanceID: testInstanceID})
	if err != nil {
		t.Fatal(err)
	}
	if err := server.Start(); err == nil {
		t.Fatal("server adopted an existing endpoint")
	}
	content, err := os.ReadFile(socketPath)
	if err != nil || string(content) != "foreign" {
		t.Fatalf("existing endpoint changed: %q, %v", content, err)
	}
	if err := os.Remove(socketPath); err != nil {
		t.Fatal(err)
	}
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(socketPath); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(socketPath, []byte("replacement"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	content, err = os.ReadFile(socketPath)
	if err != nil || string(content) != "replacement" {
		t.Fatalf("replacement endpoint was removed: %q, %v", content, err)
	}
}

func TestServerPreservesModeMutatedSocket(t *testing.T) {
	directory := shortTempDirectory(t)
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	socketPath := filepath.Join(directory, "runtime.sock")
	server, err := NewServer(ServerConfig{SocketPath: socketPath, InstanceID: testInstanceID})
	if err != nil {
		t.Fatal(err)
	}
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(socketPath, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(socketPath)
	if err != nil {
		t.Fatalf("mutated socket was removed: %v", err)
	}
	if permissionBits(info.Mode()) != 0o644 {
		t.Fatalf("preserved socket mode = %o, want 644", permissionBits(info.Mode()))
	}
	if err := os.Remove(socketPath); err != nil {
		t.Fatal(err)
	}
}

func TestServerRecoversAfterMalformedRequest(t *testing.T) {
	directory := shortTempDirectory(t)
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	socketPath := filepath.Join(directory, "runtime.sock")
	server, err := NewServer(ServerConfig{SocketPath: socketPath, InstanceID: testInstanceID})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- server.Serve(ctx) }()
	waitForSocket(t, socketPath)
	client, err := NewClient(ClientConfig{SocketPath: socketPath})
	if err != nil {
		t.Fatal(err)
	}
	response, err := client.Call(context.Background(), MethodHealth, testInstanceID)
	if err != nil || response.Result == nil {
		t.Fatalf("health after malformed request: %#v, %v", response, err)
	}
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("server did not stop")
	}
}

func TestServerReturnsBoundedFailures(t *testing.T) {
	directory := shortTempDirectory(t)
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	socketPath := filepath.Join(directory, "runtime.sock")
	server, err := NewServer(ServerConfig{
		SocketPath: socketPath,
		InstanceID: testInstanceID,
		Deadlines:  Deadlines{Read: 2 * time.Second, Write: 2 * time.Second},
		Handler: HandlerFunc(func(context.Context, Request) (Result, error) {
			return Result{}, errors.New("injected handler failure")
		}),
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- server.Serve(ctx) }()
	waitForSocket(t, socketPath)
	connection, err := net.DialTimeout("unix", socketPath, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	request := readFixture(t, "valid/health.request.jsonl")
	if _, err := connection.Write(request); err != nil {
		t.Fatal(err)
	}
	responseFrame, err := readFrame(connection)
	_ = connection.Close()
	if err != nil {
		t.Fatalf("read internal response: %v", err)
	}
	response, err := DecodeResponse(responseFrame, "11111111-1111-4111-8111-111111111111", string(MethodHealth), testInstanceID)
	if err != nil {
		t.Fatal(err)
	}
	if response.Error == nil || response.Error.Code != ErrorInternal {
		t.Fatalf("response = %#v", response)
	}

	connection, err = net.DialTimeout("unix", socketPath, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	oversized := bytes.Repeat([]byte{' '}, MaxFrameBytes+1)
	oversized[len(oversized)-1] = '\n'
	if _, err := connection.Write(oversized); err != nil {
		t.Fatal(err)
	}
	responseFrame, err = readFrame(connection)
	_ = connection.Close()
	if err != nil {
		t.Fatalf("read too-large response: %v", err)
	}
	response, err = DecodeResponse(responseFrame, "", string(MethodHealth), testInstanceID)
	if err != nil {
		t.Fatal(err)
	}
	if response.Error == nil || response.Error.Code != ErrorMessageTooLarge || response.RequestID != nil {
		t.Fatalf("too-large response = %#v", response)
	}
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	<-done
}

func TestServerDispatchesProfileListAndActivation(t *testing.T) {
	service := &testProfileIPCService{
		profiles: []ProfileSummary{
			{ID: "default", Label: "Default", IsDefault: true, IsCurrent: true},
			{ID: "Work.Profile", Label: "Work", IsDefault: false, IsCurrent: false},
		},
		activation: ActivationResult{ProfileID: "Work.Profile", Changed: true},
	}
	server := newProfileTestServer(t, service)
	requestID := "11111111-1111-4111-8111-111111111111"
	list := server.handleRequest(Request{RequestID: requestID, Method: MethodProfilesList, InstanceID: testInstanceID})
	if list.Error != nil || list.Result == nil || len(list.Result.Profiles) != 2 || list.Result.Profiles[1].ID != "Work.Profile" {
		t.Fatalf("profile list response = %#v", list)
	}
	encoded, err := EncodeResponse(list)
	if err != nil {
		t.Fatalf("encode profile list response: %v", err)
	}
	if bytes.Contains(encoded, []byte("layout")) || bytes.Contains(encoded, []byte("action")) {
		t.Fatalf("profile list exposed a layout/action: %s", encoded)
	}

	activation := server.handleRequest(Request{RequestID: requestID, Method: MethodProfilesActivate, InstanceID: testInstanceID, ProfileID: "Work.Profile"})
	if activation.Error != nil || activation.Result == nil || activation.Result.ProfileID != "Work.Profile" || !activation.Result.Changed {
		t.Fatalf("profile activation response = %#v", activation)
	}
	if service.activationCalls != 1 || service.lastProfileID != "Work.Profile" {
		t.Fatalf("activation service calls = %d/%q", service.activationCalls, service.lastProfileID)
	}
}

func TestServerMapsStableProfileErrors(t *testing.T) {
	tests := []struct {
		name string
		err  error
		code string
	}{
		{name: "not found", err: ErrProfileNotFound, code: ErrorProfileNotFound},
		{name: "activation", err: ErrActivationFailed, code: ErrorActivationFailed},
		{name: "device", err: ErrDeviceWriteFailed, code: ErrorDeviceWriteFailed},
		{name: "shutdown", err: ErrShuttingDown, code: ErrorShuttingDown},
		{name: "busy", err: ErrBusy, code: ErrorBusy},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := newProfileTestServer(t, &testProfileIPCService{activationErr: test.err})
			requestID := "11111111-1111-4111-8111-111111111111"
			response := server.handleRequest(Request{RequestID: requestID, Method: MethodProfilesActivate, InstanceID: testInstanceID, ProfileID: "Work.Profile"})
			if response.Result != nil || response.Error == nil || response.Error.Code != test.code || response.RequestID == nil || *response.RequestID != requestID {
				t.Fatalf("error response = %#v, want %q", response, test.code)
			}
			if _, err := EncodeResponse(response); err != nil {
				t.Fatalf("encode %s response: %v", test.name, err)
			}
		})
	}
}

func TestServerProfileDispatchWithoutServiceIsInternal(t *testing.T) {
	server := newProfileTestServer(t, nil)
	requestID := "11111111-1111-4111-8111-111111111111"
	response := server.handleRequest(Request{RequestID: requestID, Method: MethodProfilesList, InstanceID: testInstanceID})
	if response.Error == nil || response.Error.Code != ErrorInternal || response.Result != nil {
		t.Fatalf("missing profile service response = %#v", response)
	}
}

type testProfileIPCService struct {
	profiles        []ProfileSummary
	activation      ActivationResult
	activationErr   error
	activationCalls int
	lastProfileID   string
}

func (service *testProfileIPCService) ListProfiles() []ProfileSummary {
	return append([]ProfileSummary(nil), service.profiles...)
}

func (service *testProfileIPCService) ActivateProfile(_ context.Context, profileID string) (ActivationResult, error) {
	service.activationCalls++
	service.lastProfileID = profileID
	return service.activation, service.activationErr
}

func newProfileTestServer(t *testing.T, service ProfileService) *Server {
	t.Helper()
	directory := shortTempDirectory(t)
	server, err := NewServer(ServerConfig{
		SocketPath:     filepath.Join(directory, "runtime.sock"),
		InstanceID:     testInstanceID,
		ProfileService: service,
	})
	if err != nil {
		t.Fatal(err)
	}
	return server
}

func waitForSocket(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Lstat(path); err == nil {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("socket %s did not appear", path)
}

func shortTempDirectory(t *testing.T) string {
	t.Helper()
	directory, err := os.MkdirTemp(".", ".h-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	return directory
}
