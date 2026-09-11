package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/discovery"
	"hidhogg/internal/ipc"
)

func TestParseCommandConfigOperations(t *testing.T) {
	tests := []struct {
		name       string
		defaultCmd string
		profileID  string
		args       []string
		wantMethod string
		wantError  string
	}{
		{name: "reload subcommand", defaultCmd: "health", args: []string{"config", "reload"}, wantMethod: string(ipc.MethodConfigReload)},
		{name: "status subcommand", defaultCmd: "health", args: []string{"config", "status"}, wantMethod: string(ipc.MethodConfigStatus)},
		{name: "reload dotted", defaultCmd: "health", args: []string{"config.reload"}, wantMethod: string(ipc.MethodConfigReload)},
		{name: "status dotted", defaultCmd: "health", args: []string{"config.status"}, wantMethod: string(ipc.MethodConfigStatus)},
		{name: "method flag default", defaultCmd: string(ipc.MethodConfigReload), wantMethod: string(ipc.MethodConfigReload)},
		{name: "profile conflict", defaultCmd: "health", profileID: "default", args: []string{"config", "status"}, wantError: "only valid for profiles activate"},
		{name: "unknown config command", defaultCmd: "health", args: []string{"config", "unknown"}, wantError: `unknown config command "unknown"`},
		{name: "unknown dotted method", defaultCmd: "health", args: []string{"config.unknown"}, wantError: `method "config.unknown" is not supported`},
		{name: "extra config argument", defaultCmd: "health", args: []string{"config", "reload", "unexpected"}, wantError: "at most one method argument"},
		{name: "extra dotted argument", defaultCmd: "health", args: []string{"config.status", "unexpected"}, wantError: "at most one method argument"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			method, profileID, err := parseCommand(test.defaultCmd, test.profileID, test.args)
			if test.wantError != "" {
				if err == nil || !strings.Contains(err.Error(), test.wantError) {
					t.Fatalf("error = %v, want substring %q", err, test.wantError)
				}
				return
			}
			if err != nil || method != test.wantMethod || profileID != "" {
				t.Fatalf("parsed command = %q/%q, error = %v; want %q/empty", method, profileID, err, test.wantMethod)
			}
		})
	}
}

func TestRunWithOutputConfigOperationsSupportsDiscoveryAndLegacy(t *testing.T) {
	runtimeDir, instanceID, service, cleanup := startConfigCLIControllerRuntime(t)
	defer cleanup()

	var output bytes.Buffer
	if err := runWithOutput([]string{"--runtime-dir", runtimeDir, "config", "status"}, &output); err != nil {
		t.Fatalf("discovery config status: %v", err)
	}
	status := decodeCLIConfigResponse(t, output.Bytes(), ipc.MethodConfigStatus, instanceID)
	if status.Result == nil || status.Result.Revision != 1 || status.Result.State != "idle" || status.Result.Outcome != "ready" || status.Result.Reason != "none" {
		t.Fatalf("discovery status = %#v", status)
	}

	output.Reset()
	if err := runWithOutput([]string{"--runtime-dir", runtimeDir, "--method", "config.status"}, &output); err != nil {
		t.Fatalf("discovery dotted config status method: %v", err)
	}
	status = decodeCLIConfigResponse(t, output.Bytes(), ipc.MethodConfigStatus, instanceID)
	if status.Result == nil || status.Result.Revision != 1 || status.Result.State != "idle" || status.Result.Outcome != "ready" || status.Result.Reason != "none" {
		t.Fatalf("discovery dotted method status = %#v", status)
	}

	output.Reset()
	if err := runWithOutput([]string{"--runtime-dir", runtimeDir, "--method", "config.reload"}, &output); err != nil {
		t.Fatalf("discovery dotted config reload: %v", err)
	}
	reload := decodeCLIConfigResponse(t, output.Bytes(), ipc.MethodConfigReload, instanceID)
	if reload.Result == nil || reload.Result.Revision != 1 || reload.Result.Changed || reload.Result.Effect != "unchanged" {
		t.Fatalf("discovery reload = %#v", reload)
	}

	output.Reset()
	if err := runWithOutput([]string{"--runtime-dir", runtimeDir, "config", "reload"}, &output); err != nil {
		t.Fatalf("discovery config reload subcommand: %v", err)
	}
	reload = decodeCLIConfigResponse(t, output.Bytes(), ipc.MethodConfigReload, instanceID)
	if reload.Result == nil || reload.Result.Revision != 1 || reload.Result.Changed || reload.Result.Effect != "unchanged" {
		t.Fatalf("discovery subcommand reload = %#v", reload)
	}

	output.Reset()
	if err := runWithOutput([]string{
		"--socket-path", filepath.Join(runtimeDir, discovery.SocketFileName),
		"--instance-id", strings.ToUpper(instanceID),
		"config.status",
	}, &output); err != nil {
		t.Fatalf("legacy config status: %v", err)
	}
	status = decodeCLIConfigResponse(t, output.Bytes(), ipc.MethodConfigStatus, instanceID)
	if status.Result == nil || status.Result.InstanceID != instanceID {
		t.Fatalf("legacy status = %#v", status)
	}

	output.Reset()
	if err := runWithOutput([]string{
		"--socket-path", filepath.Join(runtimeDir, discovery.SocketFileName),
		"--instance-id", instanceID,
		"config", "status",
	}, &output); err != nil {
		t.Fatalf("legacy config status subcommand: %v", err)
	}
	status = decodeCLIConfigResponse(t, output.Bytes(), ipc.MethodConfigStatus, instanceID)
	if status.Result == nil || status.Result.InstanceID != instanceID {
		t.Fatalf("legacy subcommand status = %#v", status)
	}

	output.Reset()
	if err := runWithOutput([]string{
		"--socket-path", filepath.Join(runtimeDir, discovery.SocketFileName),
		"--instance-id", instanceID,
		"--method", "config.reload",
	}, &output); err != nil {
		t.Fatalf("legacy dotted config reload method: %v", err)
	}
	reload = decodeCLIConfigResponse(t, output.Bytes(), ipc.MethodConfigReload, instanceID)
	if reload.Result == nil || reload.Result.InstanceID != instanceID || reload.Result.Revision != 1 {
		t.Fatalf("legacy reload = %#v", reload)
	}

	output.Reset()
	if err := runWithOutput([]string{
		"--socket-path", filepath.Join(runtimeDir, discovery.SocketFileName),
		"--instance-id", instanceID,
		"config", "reload",
	}, &output); err != nil {
		t.Fatalf("legacy config reload subcommand: %v", err)
	}
	reload = decodeCLIConfigResponse(t, output.Bytes(), ipc.MethodConfigReload, instanceID)
	if reload.Result == nil || reload.Result.InstanceID != instanceID || reload.Result.Revision != 1 {
		t.Fatalf("legacy subcommand reload = %#v", reload)
	}
	if service.reloadCalls != 4 || service.statusCalls != 4 {
		t.Fatalf("service calls = %d/%d, want 4/4", service.reloadCalls, service.statusCalls)
	}
}

func TestRunWithOutputConfigRejectsForbiddenFlagsBeforeDiscovery(t *testing.T) {
	methods := []struct {
		name string
		args []string
	}{
		{name: "reload", args: []string{"--method", string(ipc.MethodConfigReload)}},
		{name: "status", args: []string{"--method", string(ipc.MethodConfigStatus)}},
	}
	flags := []struct {
		name string
		args []string
		want string
	}{
		{name: "profile ID", args: []string{"--profile-id", "default"}, want: "only valid for profiles activate"},
		{name: "execution ID", args: []string{"--execution-id", "execution-1"}, want: "only valid for executions.get"},
		{name: "nonzero limit", args: []string{"--limit", "1"}, want: "only valid for executions.list"},
	}
	for _, method := range methods {
		for _, flag := range flags {
			t.Run(method.name+"/"+flag.name, func(t *testing.T) {
				args := append([]string{"--runtime-dir", "/missing"}, method.args...)
				args = append(args, flag.args...)
				var output bytes.Buffer
				err := runWithOutput(args, &output)
				if err == nil || !strings.Contains(err.Error(), flag.want) {
					t.Fatalf("error = %v, want substring %q", err, flag.want)
				}
				if output.Len() != 0 {
					t.Fatalf("invalid config command wrote stdout: %q", output.String())
				}
			})
		}
	}

	t.Run("extra command argument", func(t *testing.T) {
		var output bytes.Buffer
		err := runWithOutput([]string{"--runtime-dir", "/missing", "config", "reload", "unexpected"}, &output)
		if err == nil || !strings.Contains(err.Error(), "at most one method argument") {
			t.Fatalf("error = %v, want extra argument rejection", err)
		}
		if output.Len() != 0 {
			t.Fatalf("invalid config command wrote stdout: %q", output.String())
		}
	})
}

func TestRunWithOutputConfigStatusRevalidatesDiscoveryGeneration(t *testing.T) {
	runtimeDir, _, service, cleanup := startConfigCLIControllerRuntime(t)
	defer cleanup()
	paths, err := discovery.NewPaths(runtimeDir)
	if err != nil {
		t.Fatal(err)
	}
	var mutate sync.Once
	service.statusHook = func() {
		mutate.Do(func() {
			if err := os.Remove(paths.SocketPath); err != nil {
				service.hookError = fmt.Errorf("remove socket: %w", err)
				return
			}
			if err := os.WriteFile(paths.SocketPath, []byte("foreign"), 0o600); err != nil {
				service.hookError = fmt.Errorf("replace socket: %w", err)
			}
		})
	}
	var output bytes.Buffer
	err = runWithOutput([]string{"--runtime-dir", runtimeDir, "config.status"}, &output)
	if err == nil || !strings.Contains(err.Error(), "after IPC call") {
		t.Fatalf("generation revalidation error = %v", err)
	}
	if service.hookError != nil {
		t.Fatal(service.hookError)
	}
	if output.Len() != 0 {
		t.Fatalf("substituted generation wrote stdout: %q", output.String())
	}
}

func TestRunWithOutputConfigReloadRevalidatesDiscoveryGeneration(t *testing.T) {
	runtimeDir, _, service, cleanup := startConfigCLIControllerRuntime(t)
	defer cleanup()
	paths, err := discovery.NewPaths(runtimeDir)
	if err != nil {
		t.Fatal(err)
	}
	var mutate sync.Once
	service.reloadHook = func() {
		mutate.Do(func() {
			if err := os.Remove(paths.SocketPath); err != nil {
				service.hookError = fmt.Errorf("remove socket: %w", err)
				return
			}
			if err := os.WriteFile(paths.SocketPath, []byte("foreign"), 0o600); err != nil {
				service.hookError = fmt.Errorf("replace socket: %w", err)
			}
		})
	}
	var output bytes.Buffer
	err = runWithOutput([]string{"--runtime-dir", runtimeDir, "config", "reload"}, &output)
	if err == nil || !strings.Contains(err.Error(), "after IPC call") {
		t.Fatalf("generation revalidation error = %v", err)
	}
	if service.hookError != nil {
		t.Fatal(service.hookError)
	}
	if output.Len() != 0 {
		t.Fatalf("substituted generation wrote stdout: %q", output.String())
	}
}

func decodeCLIConfigResponse(t *testing.T, body []byte, method ipc.Method, instanceID string) ipc.Response {
	t.Helper()
	var envelope struct {
		RequestID *string `json:"request_id"`
	}
	if err := jsonUnmarshal(body, &envelope); err != nil {
		t.Fatal(err)
	}
	if envelope.RequestID == nil {
		t.Fatal("CLI response omitted request ID")
	}
	response, err := ipc.DecodeResponse(body, *envelope.RequestID, string(method), instanceID)
	if err != nil {
		t.Fatal(err)
	}
	return response
}

type configCLIService struct {
	reloadResult ConfigReloadResultAlias
	status       ConfigStatusAlias
	reloadCalls  int
	statusCalls  int
	reloadHook   func()
	statusHook   func()
	hookError    error
}

func (service *configCLIService) Reload(context.Context) (ipc.ConfigReloadResult, error) {
	service.reloadCalls++
	if service.reloadHook != nil {
		service.reloadHook()
	}
	return ipc.ConfigReloadResult(service.reloadResult), nil
}

func (service *configCLIService) Status() ipc.ConfigStatus {
	service.statusCalls++
	if service.statusHook != nil {
		service.statusHook()
	}
	return ipc.ConfigStatus(service.status)
}

type ConfigReloadResultAlias = ipc.ConfigReloadResult
type ConfigStatusAlias = ipc.ConfigStatus

func startConfigCLIControllerRuntime(t *testing.T) (string, string, *configCLIService, func()) {
	t.Helper()
	runtimeDir := makeM03ControllerRuntimeDir(t)
	generation, err := discovery.Open(discovery.Options{RuntimeDir: runtimeDir, InstanceID: controllerTestInstanceID})
	if err != nil {
		t.Fatal(err)
	}
	service := &configCLIService{
		reloadResult: ConfigReloadResultAlias{Revision: 1, Effect: "unchanged"},
		status:       ConfigStatusAlias{Revision: 1, State: "idle", Outcome: "ready", Reason: "none"},
	}
	server, err := ipc.NewServer(ipc.ServerConfig{
		SocketPath:    generation.SocketPath(),
		InstanceID:    generation.InstanceID(),
		ConfigService: service,
		PeerVerifier:  func(net.Conn) error { return nil },
	})
	if err != nil {
		_ = generation.Close()
		t.Fatal(err)
	}
	if err := server.Start(); err != nil {
		_ = server.Close()
		_ = generation.Close()
		if m03UnixSocketUnavailable(err) {
			t.Skipf("Unix socket creation unavailable in this environment: %v", err)
		}
		t.Fatal(err)
	}
	if _, err := generation.RecordSocket(); err != nil {
		_ = server.Close()
		_ = generation.Close()
		t.Fatal(err)
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
		t.Fatal(err)
	case <-time.After(2 * time.Second):
		cancel()
		_ = server.Close()
		_ = generation.Close()
		t.Fatal("config controller server did not become ready")
	}
	if err := generation.PublishMetadata(); err != nil {
		cancel()
		_ = server.Close()
		_ = generation.Close()
		t.Fatal(err)
	}
	cleanup := func() {
		cancel()
		_ = server.Close()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Errorf("config controller server did not stop")
		}
		_ = generation.Close()
	}
	return runtimeDir, generation.InstanceID(), service, cleanup
}

func jsonUnmarshal(data []byte, target any) error {
	return json.Unmarshal(data, target)
}

var _ = errors.Is
