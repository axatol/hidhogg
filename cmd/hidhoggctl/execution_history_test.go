package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/discovery"
	"hidhogg/internal/execution"
	"hidhogg/internal/ipc"
)

func TestExecutionHistoryCLIFlagsAreStrict(t *testing.T) {
	tests := []struct {
		name string
		args []string
		want string
	}{
		{name: "list limit zero", args: []string{"--method", "executions.list", "--limit", "0"}, want: "between 1 and 32"},
		{name: "list execution ID", args: []string{"--method", "executions.list", "--execution-id", "execution-1"}, want: "only valid for executions.get"},
		{name: "get missing ID", args: []string{"--method", "executions.get"}, want: "execution-id is required"},
		{name: "get limit", args: []string{"--method", "executions.get", "--execution-id", "execution-1", "--limit", "1"}, want: "only valid for executions.list"},
		{name: "health limit", args: []string{"--method", "health", "--limit", "1"}, want: "only valid for executions.list"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var output bytes.Buffer
			err := runWithOutput(test.args, &output)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want %q", err, test.want)
			}
			if output.Len() != 0 {
				t.Fatalf("invalid invocation wrote stdout: %q", output.String())
			}
		})
	}
}

func TestExecutionHistoryCLIQueriesDiscoveryAndLegacy(t *testing.T) {
	runtimeDir, instanceID, recordID, cleanup := startCLIHistoryRuntime(t)
	defer cleanup()

	var output bytes.Buffer
	if err := runWithOutput([]string{"--runtime-dir", runtimeDir, "--method", "executions.list", "--limit", "1"}, &output); err != nil {
		t.Fatalf("discovery list: %v", err)
	}
	list := decodeCLIExecutionResponse(t, output.Bytes(), ipc.MethodExecutionsList, instanceID)
	if list.Error != nil || list.Result == nil || len(list.Result.Executions) != 1 || list.Result.Executions[0].ID != recordID {
		t.Fatalf("discovery list = %#v", list)
	}
	if bytes.Contains(output.Bytes(), []byte(`"executable"`)) || bytes.Contains(output.Bytes(), []byte(`"stdout"`)) {
		t.Fatalf("list exposed private/output fields: %s", output.Bytes())
	}

	output.Reset()
	if err := runWithOutput([]string{
		"--socket-path", filepath.Join(runtimeDir, discovery.SocketFileName),
		"--instance-id", strings.ToUpper(instanceID),
		"--method", "executions.get", "--execution-id", recordID,
	}, &output); err != nil {
		t.Fatalf("legacy get: %v", err)
	}
	get := decodeCLIExecutionResponse(t, output.Bytes(), ipc.MethodExecutionsGet, instanceID)
	if get.Error != nil || get.Result == nil || get.Result.Execution == nil || string(get.Result.Execution.Stdout.Tail) != "stdout" {
		t.Fatalf("legacy get = %#v", get)
	}
	if bytes.Contains(output.Bytes(), []byte(`"command"`)) || bytes.Contains(output.Bytes(), []byte(`"environment"`)) || bytes.Contains(output.Bytes(), []byte(`"cwd"`)) {
		t.Fatalf("get exposed private fields: %s", output.Bytes())
	}

	output.Reset()
	if err := runWithOutput([]string{"--runtime-dir", runtimeDir, "--method", "executions.get", "--execution-id", "missing-1"}, &output); err != nil {
		t.Fatalf("missing execution query returned CLI error: %v", err)
	}
	missing := decodeCLIExecutionResponse(t, output.Bytes(), ipc.MethodExecutionsGet, instanceID)
	if missing.Result != nil || missing.Error == nil || missing.Error.Code != ipc.ErrorExecutionNotFound {
		t.Fatalf("missing execution = %#v", missing)
	}
}

func decodeCLIExecutionResponse(t *testing.T, body []byte, method ipc.Method, instanceID string) ipc.Response {
	t.Helper()
	var envelope struct {
		RequestID *string `json:"request_id"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		t.Fatalf("decode CLI response envelope: %v", err)
	}
	if envelope.RequestID == nil {
		t.Fatal("CLI response omitted request ID")
	}
	response, err := ipc.DecodeResponse(body, *envelope.RequestID, string(method), instanceID)
	if err != nil {
		t.Fatalf("decode CLI response: %v", err)
	}
	return response
}

type cliExecutionHistory struct {
	mu        sync.Mutex
	summaries []execution.Summary
	records   map[string]execution.Record
}

func (history *cliExecutionHistory) ListSummaries(limit int) ([]execution.Summary, error) {
	history.mu.Lock()
	defer history.mu.Unlock()
	count := limit
	if count > len(history.summaries) {
		count = len(history.summaries)
	}
	result := make([]execution.Summary, count)
	copy(result, history.summaries[:count])
	return result, nil
}

func (history *cliExecutionHistory) Get(id string) (execution.Record, bool) {
	history.mu.Lock()
	defer history.mu.Unlock()
	record, ok := history.records[id]
	return record, ok
}

func startCLIHistoryRuntime(t *testing.T) (string, string, string, func()) {
	t.Helper()
	runtimeDir, err := os.MkdirTemp(".", ".hidhogg-history-cli-")
	if err != nil {
		t.Fatal(err)
	}
	runtimeDir, err = filepath.Abs(runtimeDir)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(runtimeDir, 0o700); err != nil {
		_ = os.RemoveAll(runtimeDir)
		t.Fatal(err)
	}
	generation, err := discovery.Open(discovery.Options{RuntimeDir: runtimeDir, InstanceID: controllerTestInstanceID})
	if err != nil {
		_ = os.RemoveAll(runtimeDir)
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 8, 1, 2, 3, 0, time.UTC)
	record := execution.Record{ID: "execution-1", ProfileID: "default", PositionID: "clock", State: execution.StateExited, SubmittedAt: now, FinishedAt: now.Add(time.Second), Duration: time.Second, Stdout: execution.Output{Tail: []byte("stdout"), TotalBytes: 6}, Stderr: execution.Output{Tail: []byte("stderr"), TotalBytes: 6}}
	history := &cliExecutionHistory{summaries: []execution.Summary{{ID: record.ID, ProfileID: record.ProfileID, PositionID: record.PositionID, State: record.State, SubmittedAt: record.SubmittedAt, FinishedAt: record.FinishedAt, Duration: record.Duration}}, records: map[string]execution.Record{record.ID: record}}
	server, err := ipc.NewServer(ipc.ServerConfig{SocketPath: generation.SocketPath(), InstanceID: generation.InstanceID(), ExecutionHistory: history, PeerVerifier: func(net.Conn) error { return nil }})
	if err != nil {
		_ = generation.Close()
		_ = os.RemoveAll(runtimeDir)
		t.Fatal(err)
	}
	if err := server.Start(); err != nil {
		_ = server.Close()
		_ = generation.Close()
		_ = os.RemoveAll(runtimeDir)
		t.Fatal(err)
	}
	if _, err := generation.RecordSocket(); err != nil {
		_ = server.Close()
		_ = generation.Close()
		_ = os.RemoveAll(runtimeDir)
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- server.Serve(ctx) }()
	select {
	case <-server.ServingReady():
	case serveErr := <-done:
		cancel()
		_ = server.Close()
		_ = generation.Close()
		_ = os.RemoveAll(runtimeDir)
		t.Fatalf("server exited before serving: %v", serveErr)
	case <-time.After(2 * time.Second):
		cancel()
		_ = server.Close()
		_ = generation.Close()
		_ = os.RemoveAll(runtimeDir)
		t.Fatal("server did not become ready")
	}
	if err := generation.PublishMetadata(); err != nil {
		cancel()
		_ = server.Close()
		_ = generation.Close()
		_ = os.RemoveAll(runtimeDir)
		t.Fatal(err)
	}
	cleanup := func() {
		cancel()
		_ = server.Close()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Errorf("history server did not stop")
		}
		_ = generation.Close()
		_ = os.RemoveAll(runtimeDir)
	}
	return runtimeDir, generation.InstanceID(), record.ID, cleanup
}
