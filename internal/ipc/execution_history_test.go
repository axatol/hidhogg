package ipc

import (
	"bytes"
	"context"
	"encoding/base64"
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

	"hidhogg/internal/execution"
)

func TestExecutionRequestsAreStrictAndBounded(t *testing.T) {
	requestID := "11111111-1111-4111-8111-111111111111"
	tests := []struct {
		name       string
		request    []byte
		wantCode   string
		wantLimit  int
		wantMethod Method
	}{
		{
			name: "list default",
			request: []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"executions.list","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}}
`),
			wantLimit: DefaultExecutionHistoryLimit, wantMethod: MethodExecutionsList,
		},
		{
			name: "list explicit maximum",
			request: []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"executions.list","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","limit":32}}
`),
			wantLimit: MaxExecutionHistoryLimit, wantMethod: MethodExecutionsList,
		},
		{
			name: "get exact identifier",
			request: []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"executions.get","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","execution_id":"missing-1"}}
`),
			wantMethod: MethodExecutionsGet,
		},
		{
			name: "unknown list field",
			request: []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"executions.list","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","extra":true}}
`),
			wantCode: ErrorInvalidEnvelope,
		},
		{
			name: "wrong limit type",
			request: []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"executions.list","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","limit":1.0}}
`),
			wantCode: ErrorInvalidEnvelope,
		},
		{
			name: "limit below lower bound",
			request: []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"executions.list","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","limit":0}}
`),
			wantCode: ErrorInvalidEnvelope,
		},
		{
			name: "duplicate limit",
			request: []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"executions.list","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","limit":1,"limit":2}}
`),
			wantCode: ErrorInvalidEnvelope,
		},
		{
			name: "get command field refused",
			request: []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"executions.get","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","execution_id":"missing-1","command":"/bin/echo"}}
`),
			wantCode: ErrorInvalidEnvelope,
		},
		{
			name: "execution trigger method refused",
			request: []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"executions.start","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}}
`),
			wantCode: ErrorUnknownMethod,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request, response, err := ValidateRequest(test.request, testInstanceID)
			if err != nil {
				t.Fatal(err)
			}
			if test.wantCode != "" {
				if response.Error == nil || response.Error.Code != test.wantCode {
					t.Fatalf("response = %#v, want %s", response, test.wantCode)
				}
				return
			}
			if response.Error != nil || request.Method != test.wantMethod || request.RequestID != requestID || request.InstanceID != testInstanceID {
				t.Fatalf("request/response = %#v/%#v", request, response)
			}
			if test.wantLimit != 0 && request.Limit != test.wantLimit {
				t.Fatalf("limit = %d, want %d", request.Limit, test.wantLimit)
			}
		})
	}

	for _, limit := range []int{1, MaxExecutionHistoryLimit} {
		encoded, err := EncodeRequest(Request{ProtocolVersion: ProtocolVersion, RequestID: requestID, Method: MethodExecutionsList, InstanceID: testInstanceID, Limit: limit})
		if err != nil {
			t.Fatalf("encode limit %d: %v", limit, err)
		}
		decoded, failure, err := DecodeRequest(encoded)
		if err != nil || failure.Error != nil || decoded.Limit != limit {
			t.Fatalf("round trip limit %d = %#v/%#v/%v", limit, decoded, failure, err)
		}
	}
}

func TestExecutionResponsesAreStrictPrivateAndRoundTrip(t *testing.T) {
	requestID := "11111111-1111-4111-8111-111111111111"
	now := time.Date(2026, 9, 8, 1, 2, 3, 456000000, time.UTC)
	exitCode := 17
	record := execution.Record{
		ID: "20260908-0102-4700-8000-history00001", ProfileID: "default", PositionID: "clock",
		State: execution.StateExited, SubmittedAt: now, StartedAt: now.Add(time.Millisecond), FinishedAt: now.Add(9 * time.Millisecond), Duration: 8 * time.Millisecond,
		ExitCode: &exitCode, Stdout: execution.Output{Tail: []byte("stdout\x00"), TotalBytes: 7}, Stderr: execution.Output{Tail: []byte("stderr"), TotalBytes: 6},
	}
	summary := execution.Summary{ID: record.ID, ProfileID: record.ProfileID, PositionID: record.PositionID, State: record.State, SubmittedAt: record.SubmittedAt, StartedAt: record.StartedAt, FinishedAt: record.FinishedAt, Duration: record.Duration, ExitCode: record.ExitCode}
	list := Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &Result{InstanceID: testInstanceID, Executions: []execution.Summary{summary}}}
	encoded, err := EncodeResponse(list)
	if err != nil {
		t.Fatalf("encode list: %v", err)
	}
	if len(encoded) >= MaxFrameBytes || bytesContainSensitiveExecutionField(encoded) {
		t.Fatalf("list frame/privacy violation: len=%d body=%s", len(encoded), encoded)
	}
	decoded, err := DecodeResponse(encoded, requestID, string(MethodExecutionsList), testInstanceID)
	if err != nil || decoded.Result == nil || len(decoded.Result.Executions) != 1 || decoded.Result.Executions[0].ID != record.ID {
		t.Fatalf("decode list = %#v, %v", decoded, err)
	}

	get := Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &Result{InstanceID: testInstanceID, Execution: &record}}
	encoded, err = EncodeResponse(get)
	if err != nil {
		t.Fatalf("encode get: %v", err)
	}
	if len(encoded) >= MaxFrameBytes || bytesContainSensitiveExecutionField(encoded) {
		t.Fatalf("get frame/privacy violation: len=%d body=%s", len(encoded), encoded)
	}
	decoded, err = DecodeResponse(encoded, requestID, string(MethodExecutionsGet), testInstanceID)
	if err != nil || decoded.Result == nil || decoded.Result.Execution == nil {
		t.Fatalf("decode get = %#v, %v", decoded, err)
	}
	got := decoded.Result.Execution
	if got.ID != record.ID || string(got.Stdout.Tail) != string(record.Stdout.Tail) || got.Stdout.TotalBytes != record.Stdout.TotalBytes || string(got.Stderr.Tail) != string(record.Stderr.Tail) {
		t.Fatalf("record round trip = %#v, want %#v", *got, record)
	}
	if got.Stdout.Truncated || got.Stderr.Truncated {
		t.Fatal("unexpected truncation after round trip")
	}
}

func bytesContainSensitiveExecutionField(body []byte) bool {
	for _, field := range []string{"command", "executable", "arguments", "args", "environment", "env", "working_directory", "cwd"} {
		if strings.Contains(string(body), `"`+field+`"`) {
			return true
		}
	}
	return false
}

func TestExecutionHistoryRejectsExitCodeAndSignal(t *testing.T) {
	requestID := "11111111-1111-4111-8111-111111111111"
	summary := execution.Summary{ID: "record", ProfileID: "default", PositionID: "button", State: execution.StateExited, ExitCode: intPointer(1)}
	response := Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &Result{InstanceID: testInstanceID, Executions: []execution.Summary{summary}}}
	encoded, err := EncodeResponse(response)
	if err != nil {
		t.Fatal(err)
	}
	invalid := bytes.Replace(encoded, []byte(`"signal":null`), []byte(`"signal":2`), 1)
	if _, err := DecodeResponse(invalid, requestID, string(MethodExecutionsList), testInstanceID); err == nil {
		t.Fatal("decoder accepted both exit code and signal")
	}
	response.Result.Executions[0].Signal = intPointer(2)
	if _, err := EncodeResponse(response); err == nil {
		t.Fatal("encoder accepted both exit code and signal")
	}
}

func TestExecutionHistoryResponseFrameBounds(t *testing.T) {
	requestID := "11111111-1111-4111-8111-111111111111"
	now := time.Date(9999, 12, 31, 23, 59, 59, 999999999, time.UTC)
	profileID := strings.Repeat("p", 64)
	positionID := strings.Repeat("q", 64)
	summaries := make([]execution.Summary, 0, MaxExecutionHistoryLimit)
	for index := 0; index < MaxExecutionHistoryLimit; index++ {
		summaries = append(summaries, execution.Summary{
			ID: fmt.Sprintf("00000000-0000-4000-8000-%012x", index), ProfileID: profileID, PositionID: positionID,
			State: execution.StateExited, SubmittedAt: now, StartedAt: now, FinishedAt: now,
			Duration: time.Duration(1<<63 - 1), ExitCode: intPointer(int(^uint(0) >> 1)), SupervisionError: true,
		})
	}
	listFrame, err := EncodeResponse(Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &Result{InstanceID: testInstanceID, Executions: summaries}})
	if err != nil || len(listFrame) >= MaxFrameBytes {
		t.Fatalf("maximum list frame len=%d err=%v", len(listFrame), err)
	}
	t.Logf("maximum list frame including LF: %d bytes", len(listFrame))
	for index := range summaries {
		summaries[index].ActionType = "key_press"
		summaries[index].State = execution.StatePermissionDenied
		summaries[index].ExitCode = nil
		summaries[index].SupervisionError = false
	}
	nativeFrame, err := EncodeResponse(Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &Result{InstanceID: testInstanceID, Executions: summaries}})
	if err != nil || len(nativeFrame) >= MaxFrameBytes {
		t.Fatalf("maximum native list len=%d err=%v", len(nativeFrame), err)
	}
	t.Logf("maximum native list including LF: %d bytes", len(nativeFrame))
	if bytesContainSensitiveExecutionField(listFrame) || bytes.Contains(listFrame, []byte(`"stdout"`)) || bytes.Contains(listFrame, []byte(`"stderr"`)) {
		t.Fatalf("maximum list privacy violation: %s", listFrame)
	}
	tail := make([]byte, execution.OutputTailLimit)
	for index := range tail {
		tail[index] = byte((index * 131) ^ (index >> 3))
	}
	record := execution.Record{
		ID: "00000000-0000-4000-8000-000000000032", ProfileID: profileID, PositionID: positionID,
		State: execution.StateExited, SubmittedAt: now, StartedAt: now, FinishedAt: now,
		Duration: time.Duration(1<<63 - 1), ExitCode: intPointer(int(^uint(0) >> 1)), SupervisionError: true,
		Stdout: execution.Output{Tail: tail, TotalBytes: ^uint64(0), Truncated: true}, Stderr: execution.Output{Tail: tail, TotalBytes: ^uint64(0), Truncated: true},
	}
	getFrame, err := EncodeResponse(Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &Result{InstanceID: testInstanceID, Execution: &record}})
	if err != nil || len(getFrame) >= MaxFrameBytes {
		t.Fatalf("maximum get frame len=%d err=%v", len(getFrame), err)
	}
	t.Logf("maximum get frame including LF: %d bytes", len(getFrame))
	if bytesContainSensitiveExecutionField(getFrame) {
		t.Fatalf("maximum get privacy violation: %s", getFrame)
	}
}

func TestExecutionHistoryTimestampsNormalizeUTC(t *testing.T) {
	instant := time.Date(2026, 9, 18, 12, 0, 0, 123456789, time.FixedZone("offset", 10*60*60))
	encoded := encodeTimestamp(instant)
	if encoded == nil || *encoded != "2026-09-18T02:00:00.123456789Z" {
		t.Fatalf("timestamp = %v", encoded)
	}
}

func TestExecutionIdentifiersHaveBoundedWireLength(t *testing.T) {
	if !validExecutionID(strings.Repeat("a", MaxExecutionIDBytes)) || validExecutionID(strings.Repeat("a", MaxExecutionIDBytes+1)) {
		t.Fatal("execution ID boundary is invalid")
	}
	request := Request{ProtocolVersion: ProtocolVersion, RequestID: testInstanceID, InstanceID: testInstanceID, Method: MethodExecutionsGet, ExecutionID: strings.Repeat("a", MaxExecutionIDBytes+1)}
	if _, err := EncodeRequest(request); err == nil {
		t.Fatal("accepted an overlong execution identifier")
	}
}

func intPointer(value int) *int {
	return &value
}

type fakeExecutionHistory struct {
	mu        sync.Mutex
	summaries []execution.Summary
	records   map[string]execution.Record
	listErr   error
}

func (history *fakeExecutionHistory) ListSummaries(limit int) ([]execution.Summary, error) {
	history.mu.Lock()
	defer history.mu.Unlock()
	if history.listErr != nil {
		return nil, history.listErr
	}
	count := limit
	if count > len(history.summaries) {
		count = len(history.summaries)
	}
	result := make([]execution.Summary, count)
	copy(result, history.summaries[:count])
	return result, nil
}

func (history *fakeExecutionHistory) Get(id string) (execution.Record, bool) {
	history.mu.Lock()
	defer history.mu.Unlock()
	record, ok := history.records[id]
	return record, ok
}

func TestExecutionHistorySocketE2ERepeated(t *testing.T) {
	directory, err := os.MkdirTemp(".", ".hidhogg-history-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(directory) })
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 9, 8, 1, 2, 3, 0, time.UTC)
	record := execution.Record{ID: "execution-1", ProfileID: "default", PositionID: "clock", State: execution.StateExited, SubmittedAt: now, FinishedAt: now.Add(time.Second), Duration: time.Second, Stdout: execution.Output{Tail: []byte("out"), TotalBytes: 3}, Stderr: execution.Output{Tail: []byte("err"), TotalBytes: 3}}
	history := &fakeExecutionHistory{summaries: []execution.Summary{{ID: record.ID, ProfileID: record.ProfileID, PositionID: record.PositionID, State: record.State, SubmittedAt: record.SubmittedAt, FinishedAt: record.FinishedAt, Duration: record.Duration}}, records: map[string]execution.Record{record.ID: record}}
	socketPath := filepath.Join(directory, "runtime.sock")
	server, err := NewServer(ServerConfig{SocketPath: socketPath, InstanceID: testInstanceID, ExecutionHistory: history, PeerVerifier: func(net.Conn) error { return nil }})
	if err != nil {
		t.Fatal(err)
	}
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- server.Serve(ctx) }()
	waitForSocket(t, socketPath)
	client, err := NewClient(ClientConfig{SocketPath: socketPath, PeerVerifier: func(net.Conn) error { return nil }})
	if err != nil {
		t.Fatal(err)
	}
	for repeat := 0; repeat < 50; repeat++ {
		list, err := client.ListExecutions(context.Background(), testInstanceID, 1)
		if err != nil || list.Error != nil || list.Result == nil || len(list.Result.Executions) != 1 {
			t.Fatalf("list repeat %d = %#v, %v", repeat, list, err)
		}
		get, err := client.GetExecution(context.Background(), testInstanceID, record.ID)
		if err != nil || get.Error != nil || get.Result == nil || get.Result.Execution == nil || string(get.Result.Execution.Stdout.Tail) != "out" {
			t.Fatalf("get repeat %d = %#v, %v", repeat, get, err)
		}
	}
	missing, err := client.GetExecution(context.Background(), testInstanceID, "missing-1")
	if err != nil || missing.Error == nil || missing.Error.Code != ErrorExecutionNotFound {
		t.Fatalf("missing get = %#v, %v", missing, err)
	}
	history.listErr = errors.New("backend unavailable")
	unavailable, err := client.ListExecutions(context.Background(), testInstanceID, 1)
	if err != nil || unavailable.Error == nil || unavailable.Error.Code != ErrorHistoryUnavailable {
		t.Fatalf("unavailable list = %#v, %v", unavailable, err)
	}
	_ = server.Close()
	select {
	case serveErr := <-done:
		if serveErr != nil {
			t.Fatal(serveErr)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("server did not stop")
	}
}

func TestExecutionHistoryOutputUsesCanonicalBase64(t *testing.T) {
	requestID := "11111111-1111-4111-8111-111111111111"
	record := execution.Record{ID: "execution", ProfileID: "profile", PositionID: "position", State: execution.StateExited, Stdout: execution.Output{Tail: []byte{0, 1, 2}, TotalBytes: 3}, Stderr: execution.Output{Tail: []byte{3, 4, 5}, TotalBytes: 3}}
	frame, err := EncodeResponse(Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &Result{InstanceID: testInstanceID, Execution: &record}})
	if err != nil {
		t.Fatal(err)
	}
	var envelope map[string]any
	if err := json.Unmarshal(frame, &envelope); err != nil {
		t.Fatal(err)
	}
	result := envelope["result"].(map[string]any)
	executionValue := result["execution"].(map[string]any)
	if executionValue["stdout"] != base64.StdEncoding.EncodeToString(record.Stdout.Tail) || executionValue["stderr"] != base64.StdEncoding.EncodeToString(record.Stderr.Tail) {
		t.Fatalf("output encoding = %#v", executionValue)
	}
}

func TestExecutionHistoryServerDispatchAndStableErrors(t *testing.T) {
	now := time.Date(2026, 9, 8, 1, 2, 3, 0, time.UTC)
	record := execution.Record{ID: "execution-1", ProfileID: "default", PositionID: "clock", State: execution.StateExited, SubmittedAt: now, FinishedAt: now, Duration: time.Second}
	history := &fakeExecutionHistory{summaries: []execution.Summary{{ID: record.ID, ProfileID: record.ProfileID, PositionID: record.PositionID, State: record.State, SubmittedAt: now, FinishedAt: now, Duration: time.Second}}, records: map[string]execution.Record{record.ID: record}}
	server := &Server{config: ServerConfig{ExecutionHistory: history}}
	requestID := "11111111-1111-4111-8111-111111111111"
	list := server.handleRequest(Request{RequestID: requestID, Method: MethodExecutionsList, InstanceID: testInstanceID, Limit: 1})
	if list.Error != nil || list.Result == nil || len(list.Result.Executions) != 1 {
		t.Fatalf("list response = %#v", list)
	}
	get := server.handleRequest(Request{RequestID: requestID, Method: MethodExecutionsGet, InstanceID: testInstanceID, ExecutionID: record.ID})
	if get.Error != nil || get.Result == nil || get.Result.Execution == nil {
		t.Fatalf("get response = %#v", get)
	}
	missing := server.handleRequest(Request{RequestID: requestID, Method: MethodExecutionsGet, InstanceID: testInstanceID, ExecutionID: "missing-1"})
	if missing.Result != nil || missing.Error == nil || missing.Error.Code != ErrorExecutionNotFound {
		t.Fatalf("missing response = %#v", missing)
	}
	history.listErr = errors.New("history failed")
	unavailable := server.handleRequest(Request{RequestID: requestID, Method: MethodExecutionsList, InstanceID: testInstanceID, Limit: 1})
	if unavailable.Result != nil || unavailable.Error == nil || unavailable.Error.Code != ErrorHistoryUnavailable {
		t.Fatalf("unavailable response = %#v", unavailable)
	}
	server.config.ExecutionHistory = nil
	if response := server.handleRequest(Request{RequestID: requestID, Method: MethodExecutionsGet, InstanceID: testInstanceID, ExecutionID: record.ID}); response.Error == nil || response.Error.Code != ErrorHistoryUnavailable {
		t.Fatalf("nil history response = %#v", response)
	}
}
