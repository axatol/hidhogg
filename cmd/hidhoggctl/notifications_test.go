package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/discovery"
	"hidhogg/internal/ipc"
	"hidhogg/internal/notification"
)

const testNotificationID = "22222222-2222-4222-8222-222222222222"

type cliNotificationService struct {
	mu         sync.Mutex
	emit       notification.EmitResult
	clear      notification.ClearResult
	emitCalls  int
	clearCalls int
	lastEmit   notification.EmitRequest
	lastClear  string
}

func (service *cliNotificationService) EmitNotification(_ context.Context, request notification.EmitRequest) (notification.EmitResult, error) {
	service.mu.Lock()
	defer service.mu.Unlock()
	service.emitCalls++
	service.lastEmit = notification.CloneEmitRequest(request)
	return service.emit, nil
}

func (service *cliNotificationService) ClearNotification(_ context.Context, identifier string) (notification.ClearResult, error) {
	service.mu.Lock()
	defer service.mu.Unlock()
	service.clearCalls++
	service.lastClear = identifier
	return service.clear, nil
}

func TestParseNotificationCommandIsStrictBeforeResolution(t *testing.T) {
	tests := []struct {
		name       string
		args       []string
		wantMethod string
		wantSource string
		wantText   string
		wantTTL    int
		wantID     string
		wantError  string
	}{
		{
			name:       "emit split flags",
			args:       []string{"notifications", "emit", "--source", "alerts.v2", "--text", "hello", "--ttl-seconds", "86400"},
			wantMethod: string(ipc.MethodNotificationsEmit), wantSource: "alerts.v2", wantText: "hello", wantTTL: 86400,
		},
		{
			name:       "clear equals flag",
			args:       []string{"notifications", "clear", "--notification-id=22222222-2222-4222-8222-222222222222"},
			wantMethod: string(ipc.MethodNotificationsClear), wantID: testNotificationID,
		},
		{name: "duplicate source", args: []string{"notifications", "emit", "--source", "alerts", "--source", "other", "--text", "hello"}, wantError: "--source was provided more than once"},
		{name: "duplicate empty source", args: []string{"notifications", "emit", "--source=", "--source", "alerts", "--text", "hello"}, wantError: "--source was provided more than once"},
		{name: "duplicate text", args: []string{"notifications", "emit", "--source", "alerts", "--text", "hello", "--text=again"}, wantError: "--text was provided more than once"},
		{name: "duplicate empty text", args: []string{"notifications", "emit", "--source", "alerts", "--text=", "--text", "hello"}, wantError: "--text was provided more than once"},
		{name: "duplicate TTL", args: []string{"notifications", "emit", "--source", "alerts", "--text", "hello", "--ttl-seconds", "1", "--ttl-seconds=2"}, wantError: "--ttl-seconds was provided more than once"},
		{name: "duplicate clear ID", args: []string{"notifications", "clear", "--notification-id", testNotificationID, "--notification-id=" + testNotificationID}, wantError: "--notification-id was provided more than once"},
		{name: "duplicate empty clear ID", args: []string{"notifications", "clear", "--notification-id=", "--notification-id", testNotificationID}, wantError: "--notification-id was provided more than once"},
		{name: "invalid TTL", args: []string{"notifications", "emit", "--source", "alerts", "--text", "hello", "--ttl-seconds", "0"}, wantError: "between 1 and 86400"},
		{name: "inappropriate clear flag", args: []string{"notifications", "clear", "--source", "alerts", "--notification-id", testNotificationID}, wantError: "only valid for notifications emit"},
		{name: "extra positional", args: []string{"notifications", "emit", "alerts", "--source", "alerts", "--text", "hello"}, wantError: "unknown notifications emit argument"},
		{name: "invalid text", args: []string{"notifications", "emit", "--source", "alerts", "--text", "line\nbreak"}, wantError: "parameters are invalid"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			method, _, options, err := parseCommandDetails("health", "", test.args)
			if test.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), test.wantError) {
					t.Fatalf("error = %v, want %q", err, test.wantError)
				}
				return
			}
			if err != nil || method != test.wantMethod || options.source != test.wantSource || options.text != test.wantText || options.notificationID != test.wantID {
				t.Fatalf("parsed notification = %q/%#v, error = %v", method, options, err)
			}
			if test.wantTTL != 0 {
				if options.ttlSeconds == nil || *options.ttlSeconds != test.wantTTL {
					t.Fatalf("parsed TTL = %v, want %d", options.ttlSeconds, test.wantTTL)
				}
			} else if options.ttlSeconds != nil {
				t.Fatalf("unexpected TTL = %v", options.ttlSeconds)
			}
		})
	}

	for _, args := range [][]string{
		{"--runtime-dir", "/missing-notification-runtime", "notifications", "emit", "--source", "alerts", "--source", "other", "--text", "hello"},
		{"--runtime-dir", "/missing-notification-runtime", "notifications", "clear", "--notification-id", testNotificationID, "extra"},
		{"--runtime-dir", "/missing-notification-runtime", "--profile-id=", "notifications", "emit", "--source", "alerts", "--text", "hello"},
	} {
		var output bytes.Buffer
		err := runWithOutput(args, &output)
		if err == nil || strings.Contains(err.Error(), "runtime discovery") {
			t.Fatalf("invalid CLI was resolved or accepted: args=%v err=%v", args, err)
		}
		if output.Len() != 0 {
			t.Fatalf("invalid CLI wrote output: %q", output.String())
		}
	}
}

func TestRunWithOutputNotificationsSupportsDiscoveryAndLegacyModes(t *testing.T) {
	service := &cliNotificationService{
		emit:  notification.EmitResult{NotificationID: testNotificationID, MatchedCount: 2},
		clear: notification.ClearResult{ClearedCount: 0},
	}
	runtimeDir, instanceID, cleanup := startNotificationCLIControllerRuntime(t, service)
	defer cleanup()

	var output bytes.Buffer
	if err := runWithOutput([]string{
		"--runtime-dir", runtimeDir,
		"notifications", "emit", "--source", "alerts.v2", "--text", "Hello", "--ttl-seconds", "7",
	}, &output); err != nil {
		t.Fatalf("discovery notification emit: %v", err)
	}
	response := decodeCLINotificationResponse(t, output.Bytes(), ipc.MethodNotificationsEmit, instanceID)
	if response.Error != nil || response.Result == nil || response.Result.NotificationID != testNotificationID || response.Result.MatchedCount != 2 {
		t.Fatalf("emit response = %#v", response)
	}
	if strings.Contains(output.String(), "Hello") || strings.Contains(output.String(), "alerts.v2") {
		t.Fatalf("notification payload echoed in response: %q", output.String())
	}
	service.mu.Lock()
	lastEmit := service.lastEmit
	service.mu.Unlock()
	if lastEmit.Source != "alerts.v2" || lastEmit.Text != "Hello" || lastEmit.TTLSeconds == nil || *lastEmit.TTLSeconds != 7 {
		t.Fatalf("service emit request = %#v", lastEmit)
	}

	output.Reset()
	if err := runWithOutput([]string{
		"--socket-path", filepath.Join(runtimeDir, discovery.SocketFileName),
		"--instance-id", strings.ToUpper(instanceID),
		"notifications", "clear", "--notification-id", testNotificationID,
	}, &output); err != nil {
		t.Fatalf("legacy notification clear: %v", err)
	}
	response = decodeCLINotificationResponse(t, output.Bytes(), ipc.MethodNotificationsClear, instanceID)
	if response.Error != nil || response.Result == nil || response.Result.ClearedCount != 0 {
		t.Fatalf("clear response = %#v", response)
	}
	service.mu.Lock()
	clearCalls, lastClear := service.clearCalls, service.lastClear
	service.mu.Unlock()
	if clearCalls != 1 || lastClear != testNotificationID {
		t.Fatalf("service clear call = %d/%q", clearCalls, lastClear)
	}
}

func decodeCLINotificationResponse(t *testing.T, body []byte, method ipc.Method, instanceID string) ipc.Response {
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
		t.Fatalf("decode CLI notification response: %v", err)
	}
	return response
}

func startNotificationCLIControllerRuntime(t *testing.T, service ipc.NotificationService) (string, string, func()) {
	t.Helper()
	runtimeDir := makeM03ControllerRuntimeDir(t)
	generation, err := discovery.Open(discovery.Options{RuntimeDir: runtimeDir, InstanceID: controllerTestInstanceID})
	if err != nil {
		t.Fatalf("open notification generation: %v", err)
	}
	server, err := ipc.NewServer(ipc.ServerConfig{
		SocketPath:          generation.SocketPath(),
		InstanceID:          generation.InstanceID(),
		NotificationService: service,
		PeerVerifier:        func(net.Conn) error { return nil },
	})
	if err != nil {
		_ = generation.Close()
		t.Fatalf("create notification server: %v", err)
	}
	if err := server.Start(); err != nil {
		_ = server.Close()
		_ = generation.Close()
		t.Fatalf("bind notification server: %v", err)
	}
	if _, err := generation.RecordSocket(); err != nil {
		_ = server.Close()
		_ = generation.Close()
		t.Fatalf("record notification socket: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- server.Serve(ctx) }()
	select {
	case <-server.ServingReady():
	case err := <-done:
		cancel()
		_ = generation.Close()
		t.Fatalf("notification server exited: %v", err)
	case <-time.After(2 * time.Second):
		cancel()
		_ = server.Close()
		_ = generation.Close()
		t.Fatal("notification server did not become ready")
	}
	if err := generation.PublishMetadata(); err != nil {
		cancel()
		_ = server.Close()
		_ = generation.Close()
		t.Fatalf("publish notification metadata: %v", err)
	}
	cleanup := func() {
		cancel()
		_ = server.Close()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Errorf("notification server did not stop")
		}
		_ = generation.Close()
	}
	return runtimeDir, generation.InstanceID(), cleanup
}
