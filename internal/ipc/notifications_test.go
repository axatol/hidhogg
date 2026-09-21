package ipc

import (
	"bytes"
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/notification"
)

const testNotificationID = "22222222-2222-4222-8222-222222222222"

type testNotificationService struct {
	mu          sync.Mutex
	emitResult  notification.EmitResult
	clearResult notification.ClearResult
	emitErr     error
	clearErr    error
	delay       time.Duration
	emitCalls   int
	clearCalls  int
	lastEmit    notification.EmitRequest
	lastClear   string
}

func (service *testNotificationService) EmitNotification(_ context.Context, request notification.EmitRequest) (notification.EmitResult, error) {
	if service.delay > 0 {
		time.Sleep(service.delay)
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	service.emitCalls++
	service.lastEmit = notification.CloneEmitRequest(request)
	return service.emitResult, service.emitErr
}

func (service *testNotificationService) ClearNotification(_ context.Context, identifier string) (notification.ClearResult, error) {
	if service.delay > 0 {
		time.Sleep(service.delay)
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	service.clearCalls++
	service.lastClear = identifier
	return service.clearResult, service.clearErr
}

func TestNotificationRequestCodecIsNestedAndStrict(t *testing.T) {
	ttl := 86400
	emit := Request{
		ProtocolVersion: ProtocolVersion,
		RequestID:       testInstanceID,
		Method:          MethodNotificationsEmit,
		InstanceID:      testInstanceID,
		Source:          "alerts.v2",
		Text:            "Hello world",
		TTLSeconds:      &ttl,
	}
	encoded, err := EncodeRequest(emit)
	if err != nil {
		t.Fatalf("encode emit: %v", err)
	}
	want := `{"protocol_version":1,"request_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","method":"notifications.emit","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","source":"alerts.v2","text":"Hello world","ttl_seconds":86400}}` + "\n"
	if string(encoded) != want {
		t.Fatalf("encoded emit = %q, want %q", encoded, want)
	}
	decoded, failure, err := DecodeRequest(encoded)
	if err != nil || failure.Error != nil {
		t.Fatalf("decode emit = %#v, %#v, %v", decoded, failure, err)
	}
	if decoded.Method != emit.Method || decoded.InstanceID != emit.InstanceID || decoded.Source != emit.Source || decoded.Text != emit.Text || decoded.TTLSeconds == nil || *decoded.TTLSeconds != ttl {
		t.Fatalf("decoded emit = %#v", decoded)
	}

	clear := Request{
		ProtocolVersion: ProtocolVersion,
		RequestID:       testInstanceID,
		Method:          MethodNotificationsClear,
		InstanceID:      testInstanceID,
		NotificationID:  testNotificationID,
	}
	encoded, err = EncodeRequest(clear)
	if err != nil {
		t.Fatalf("encode clear: %v", err)
	}
	want = `{"protocol_version":1,"request_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","method":"notifications.clear","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","notification_id":"22222222-2222-4222-8222-222222222222"}}` + "\n"
	if string(encoded) != want {
		t.Fatalf("encoded clear = %q, want %q", encoded, want)
	}

	base := string(encoded)
	tests := []struct {
		name string
		body string
	}{
		{name: "duplicate field", body: strings.Replace(base, `,"notification_id":"22222222-2222-4222-8222-222222222222"`, `,"notification_id":"22222222-2222-4222-8222-222222222222","notification_id":"22222222-2222-4222-8222-222222222222"`, 1)},
		{name: "null ID", body: strings.Replace(base, `"notification_id":"22222222-2222-4222-8222-222222222222"`, `"notification_id":null`, 1)},
		{name: "foreign field", body: strings.Replace(base, `"notification_id":"22222222-2222-4222-8222-222222222222"`, `"notification_id":"22222222-2222-4222-8222-222222222222","text":"unexpected"`, 1)},
		{name: "invalid ID", body: strings.Replace(base, `22222222-2222-4222-8222-222222222222`, `22222222-2222-4222-8222-22222222222Z`, 1)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, response, err := DecodeRequest([]byte(test.body))
			if err != nil || response.Error == nil || response.Error.Code != ErrorInvalidEnvelope {
				t.Fatalf("decode invalid notification = %#v, %v", response, err)
			}
		})
	}

	emitBase := `{"protocol_version":1,"request_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","method":"notifications.emit","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","source":"alerts","text":"hello","ttl_seconds":1}}` + "\n"
	for _, test := range []struct {
		name string
		body string
	}{
		{name: "null TTL", body: strings.Replace(emitBase, `"ttl_seconds":1`, `"ttl_seconds":null`, 1)},
		{name: "zero TTL", body: strings.Replace(emitBase, `"ttl_seconds":1`, `"ttl_seconds":0`, 1)},
		{name: "fractional TTL", body: strings.Replace(emitBase, `"ttl_seconds":1`, `"ttl_seconds":1.5`, 1)},
		{name: "invalid source", body: strings.Replace(emitBase, `"source":"alerts"`, `"source":"-alerts"`, 1)},
		{name: "control text", body: strings.Replace(emitBase, `"text":"hello"`, `"text":"hello\nworld"`, 1)},
		{name: "duplicate source", body: strings.Replace(emitBase, `,"source":"alerts"`, `,"source":"alerts","source":"alerts"`, 1)},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, response, err := DecodeRequest([]byte(test.body))
			if err != nil || response.Error == nil || response.Error.Code != ErrorInvalidEnvelope {
				t.Fatalf("decode invalid emit = %#v, %v", response, err)
			}
		})
	}
}

func TestNotificationResponseCountsAreExplicitAndBounded(t *testing.T) {
	requestID := "11111111-1111-4111-8111-111111111111"
	server := &Server{config: ServerConfig{NotificationService: &testNotificationService{
		emitResult:  notification.EmitResult{NotificationID: testNotificationID, MatchedCount: 0},
		clearResult: notification.ClearResult{ClearedCount: 0},
	}}}
	emitResponse := server.handleRequest(Request{RequestID: requestID, Method: MethodNotificationsEmit, InstanceID: testInstanceID, Source: "alerts", Text: "hello"})
	frame, err := EncodeResponse(emitResponse)
	if err != nil {
		t.Fatalf("encode zero emit: %v", err)
	}
	if !bytes.Contains(frame, []byte(`"matched_count":0`)) || bytes.Contains(frame, []byte(`"text"`)) {
		t.Fatalf("zero emit frame = %s", frame)
	}
	if _, err := DecodeResponse(frame, requestID, string(MethodNotificationsEmit), testInstanceID); err != nil {
		t.Fatalf("decode zero emit: %v", err)
	}

	clearResponse := server.handleRequest(Request{RequestID: requestID, Method: MethodNotificationsClear, InstanceID: testInstanceID, NotificationID: testNotificationID})
	frame, err = EncodeResponse(clearResponse)
	if err != nil {
		t.Fatalf("encode zero clear: %v", err)
	}
	if !bytes.Contains(frame, []byte(`"cleared_count":0`)) || bytes.Contains(frame, []byte(`"text"`)) {
		t.Fatalf("zero clear frame = %s", frame)
	}
	if _, err := DecodeResponse(frame, requestID, string(MethodNotificationsClear), testInstanceID); err != nil {
		t.Fatalf("decode zero clear: %v", err)
	}

	for _, method := range []Method{MethodNotificationsEmit, MethodNotificationsClear} {
		response := Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID}
		if method == MethodNotificationsEmit {
			response.Result = &Result{InstanceID: testInstanceID, NotificationID: testNotificationID, MatchedCount: 15, notificationMethod: method}
		} else {
			response.Result = &Result{InstanceID: testInstanceID, ClearedCount: 15, notificationMethod: method}
		}
		if _, err := EncodeResponse(response); err == nil {
			t.Fatalf("method %s accepted count 15", method)
		}
		if method == MethodNotificationsEmit {
			response.Result.MatchedCount = 14
		} else {
			response.Result.ClearedCount = 14
		}
		frame, err := EncodeResponse(response)
		if err != nil {
			t.Fatalf("method %s rejected count 14: %v", method, err)
		}
		if _, err := DecodeResponse(frame, requestID, string(method), testInstanceID); err != nil {
			t.Fatalf("method %s failed count 14 round trip: %v", method, err)
		}
	}

	legacyResults := []struct {
		method Method
		result Result
	}{
		{method: MethodHealth, result: Result{InstanceID: testInstanceID, State: ReadyState, NotificationID: testNotificationID}},
		{method: MethodProfilesList, result: Result{InstanceID: testInstanceID, Profiles: []ProfileSummary{}, MatchedCount: 1}},
		{method: MethodInputStatus, result: Result{Input: &InputStatus{}, NotificationID: testNotificationID}},
		{method: MethodDoctor, result: Result{Doctor: &DoctorResult{}, ClearedCount: 1}},
	}
	for _, test := range legacyResults {
		if err := validateResultForMethod(test.result, test.method, testInstanceID); err == nil {
			t.Fatalf("legacy method %s accepted foreign notification fields", test.method)
		}
	}

	emitChanged := Result{InstanceID: testInstanceID, NotificationID: testNotificationID, MatchedCount: 1, Changed: true, notificationMethod: MethodNotificationsEmit}
	if err := validateResultForMethod(emitChanged, MethodNotificationsEmit, testInstanceID); err == nil {
		t.Fatal("notification emit accepted changed field")
	}
	clearChanged := Result{InstanceID: testInstanceID, ClearedCount: 1, Changed: true, notificationMethod: MethodNotificationsClear}
	if err := validateResultForMethod(clearChanged, MethodNotificationsClear, testInstanceID); err == nil {
		t.Fatal("notification clear accepted changed field")
	}
}

func TestNotificationServerMapsStaticErrorsAndClonesTTL(t *testing.T) {
	ttl := 4
	service := &testNotificationService{emitResult: notification.EmitResult{NotificationID: testNotificationID, MatchedCount: 1}}
	server := &Server{config: ServerConfig{NotificationService: service}}
	request := Request{RequestID: testInstanceID, Method: MethodNotificationsEmit, InstanceID: testInstanceID, Source: "alerts", Text: "hello", TTLSeconds: &ttl}
	response := server.handleRequest(request)
	if response.Error != nil || response.Result == nil {
		t.Fatalf("emit response = %#v", response)
	}
	service.mu.Lock()
	gotTTL := service.lastEmit.TTLSeconds
	service.mu.Unlock()
	if gotTTL == nil || *gotTTL != ttl || gotTTL == request.TTLSeconds {
		t.Fatalf("service TTL = %v, request pointer = %p, service pointer = %p", gotTTL, request.TTLSeconds, gotTTL)
	}

	for _, test := range []struct {
		name string
		err  error
		code string
	}{
		{name: "invalid", err: notification.ErrInvalid, code: ErrorNotificationInvalid},
		{name: "busy", err: notification.ErrBusy, code: ErrorBusy},
		{name: "closed", err: notification.ErrClosed, code: ErrorShuttingDown},
		{name: "uncertain", err: notification.ErrUncertain, code: ErrorDeviceWriteFailed},
		{name: "internal", err: errors.New("payload must not escape"), code: ErrorInternal},
	} {
		t.Run(test.name, func(t *testing.T) {
			service.emitErr = test.err
			response := server.handleRequest(request)
			if response.Error == nil || response.Error.Code != test.code || response.Error.Message == "payload must not escape" {
				t.Fatalf("mapped response = %#v, want code %q", response, test.code)
			}
		})
	}
}

func TestNotificationClientDefaultReadAllowsSlowReplyAndHonorsTighterDeadlines(t *testing.T) {
	directory := shortTempDirectory(t)
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	socketPath := filepath.Join(directory, "runtime.sock")
	service := &testNotificationService{
		delay:      1100 * time.Millisecond,
		emitResult: notification.EmitResult{NotificationID: testNotificationID, MatchedCount: 1},
	}
	server, err := NewServer(ServerConfig{
		SocketPath:          socketPath,
		InstanceID:          testInstanceID,
		Deadlines:           Deadlines{Read: 3 * time.Second, Write: 3 * time.Second},
		NotificationService: service,
		PeerVerifier:        func(net.Conn) error { return nil },
	})
	if err != nil {
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
	if response, err := client.EmitNotification(context.Background(), testInstanceID, notification.EmitRequest{Source: "alerts", Text: "hello"}); err != nil || response.Result == nil {
		t.Fatalf("default slow notification call = %#v, %v", response, err)
	}

	explicitClient, err := NewClient(ClientConfig{
		SocketPath:   socketPath,
		Deadlines:    Deadlines{Connect: time.Second, Read: 75 * time.Millisecond, Write: time.Second},
		PeerVerifier: func(net.Conn) error { return nil },
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := explicitClient.EmitNotification(context.Background(), testInstanceID, notification.EmitRequest{Source: "alerts", Text: "hello"}); err == nil {
		t.Fatal("explicit short notification read unexpectedly succeeded")
	}

	tightContext, tightCancel := context.WithTimeout(context.Background(), 75*time.Millisecond)
	defer tightCancel()
	if _, err := client.EmitNotification(tightContext, testInstanceID, notification.EmitRequest{Source: "alerts", Text: "hello"}); err == nil {
		t.Fatal("context deadline did not bound notification read")
	}

	cancel()
	if err := server.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("notification server did not stop")
	}
	service.mu.Lock()
	emitCalls := service.emitCalls
	service.mu.Unlock()
	if emitCalls != 3 {
		t.Fatalf("notification service calls = %d, want one call per request without retries", emitCalls)
	}
}
