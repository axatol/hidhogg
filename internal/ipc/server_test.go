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
