package ipc

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

const configTestRequestID = "11111111-1111-4111-8111-111111111111"

func TestConfigRequestRoundTripsWithExactNoParameterShapes(t *testing.T) {
	for _, method := range []Method{MethodConfigReload, MethodConfigStatus} {
		t.Run(string(method), func(t *testing.T) {
			request := Request{
				ProtocolVersion: ProtocolVersion,
				RequestID:       configTestRequestID,
				Method:          method,
				InstanceID:      testInstanceID,
			}
			encoded, err := EncodeRequest(request)
			if err != nil {
				t.Fatalf("encode request: %v", err)
			}
			want := fmt.Sprintf(`{"protocol_version":1,"request_id":"%s","method":"%s","params":{"instance_id":"%s"}}
`, configTestRequestID, method, testInstanceID)
			if string(encoded) != want {
				t.Fatalf("request = %q, want %q", encoded, want)
			}
			decoded, failure, err := DecodeRequest(encoded)
			if err != nil || failure.Error != nil {
				t.Fatalf("decode request = %#v, %#v, %v", decoded, failure, err)
			}
			if !reflect.DeepEqual(decoded, request) {
				t.Fatalf("decoded request = %#v, want %#v", decoded, request)
			}
		})
	}
}

func TestConfigResponseRoundTripsAndPreservesFalseFlags(t *testing.T) {
	reload := Response{
		ProtocolVersion: ProtocolVersion,
		RequestID:       stringPointer(configTestRequestID),
		Result: &Result{
			InstanceID: testInstanceID,
			Revision:   7,
			Changed:    false,
			Effect:     "unchanged",
		},
	}
	encoded, err := EncodeResponse(reload)
	if err != nil {
		t.Fatalf("encode reload response: %v", err)
	}
	assertObjectKeys(t, encoded, "result", []string{
		"instance_id", "revision", "changed", "effect", "catalog_changed", "default_changed",
		"current_profile_changed", "current_profile_fallback", "action_changed", "display_changed",
		"brightness_changed", "idle_changed", "display_updated",
	})
	assertFalseFields(t, encoded, "result", []string{
		"changed", "catalog_changed", "default_changed", "current_profile_changed", "current_profile_fallback",
		"action_changed", "display_changed", "brightness_changed", "idle_changed", "display_updated",
	})
	decoded, err := DecodeResponse(encoded, configTestRequestID, string(MethodConfigReload), testInstanceID)
	if err != nil {
		t.Fatalf("decode reload response: %v", err)
	}
	if decoded.Result == nil || decoded.Result.Revision != 7 || decoded.Result.Changed || decoded.Result.Effect != "unchanged" || decoded.Result.DisplayUpdated {
		t.Fatalf("decoded reload response = %#v", decoded)
	}

	status := Response{
		ProtocolVersion: ProtocolVersion,
		RequestID:       stringPointer(configTestRequestID),
		Result: &Result{
			InstanceID: testInstanceID,
			Revision:   7,
			Active:     false,
			State:      "idle",
			Outcome:    "unchanged",
			Reason:     "none",
		},
	}
	encoded, err = EncodeResponse(status)
	if err != nil {
		t.Fatalf("encode status response: %v", err)
	}
	assertObjectKeys(t, encoded, "result", []string{"instance_id", "revision", "active", "state", "outcome", "reason", "diagnostic"})
	assertValueKindAtPath(t, encoded, []string{"result", "diagnostic"}, jsonNull)
	assertFalseFields(t, encoded, "result", []string{"active"})
	decoded, err = DecodeResponse(encoded, configTestRequestID, string(MethodConfigStatus), testInstanceID)
	if err != nil {
		t.Fatalf("decode status response: %v", err)
	}
	if decoded.Result == nil || decoded.Result.Revision != 7 || decoded.Result.Active || decoded.Result.State != "idle" || decoded.Result.Outcome != "unchanged" || decoded.Result.Reason != "none" || decoded.Result.Diagnostic != nil {
		t.Fatalf("decoded status response = %#v", decoded)
	}

	line, column := 12, 9
	key := "profiles.positions.action.unknown"
	status.Result.Outcome = "rejected"
	status.Result.Reason = "candidate-rejected"
	status.Result.Diagnostic = &ConfigDiagnostic{Category: "unknown-key", Key: &key, Line: &line, Column: &column, Detail: "key is not supported"}
	encoded, err = EncodeResponse(status)
	if err != nil {
		t.Fatalf("encode rejected status response: %v", err)
	}
	assertObjectKeys(t, encoded, "result", []string{"instance_id", "revision", "active", "state", "outcome", "reason", "diagnostic"})
	assertObjectKeysAtPath(t, encoded, []string{"result", "diagnostic"}, []string{"category", "key", "line", "column", "detail"})
	decoded, err = DecodeResponse(encoded, configTestRequestID, string(MethodConfigStatus), testInstanceID)
	if err != nil || decoded.Result == nil || !reflect.DeepEqual(decoded.Result.Diagnostic, status.Result.Diagnostic) {
		t.Fatalf("decode rejected status = %#v, %v", decoded, err)
	}
}

func TestConfigRequestRejectsForbiddenAndMalformedParams(t *testing.T) {
	base := fmt.Sprintf(`{"protocol_version":1,"request_id":"%s","method":"config.reload","params":{"instance_id":"%s"}}
`, configTestRequestID, testInstanceID)
	tests := []struct {
		name string
		body string
	}{
		{name: "missing instance", body: strings.Replace(base, fmt.Sprintf(`"instance_id":"%s"`, testInstanceID), `"other":"value"`, 1)},
		{name: "profile ID", body: strings.Replace(base, `"instance_id":"`+testInstanceID+`"`, `"instance_id":"`+testInstanceID+`","profile_id":"default"`, 1)},
		{name: "limit", body: strings.Replace(base, `"instance_id":"`+testInstanceID+`"`, `"instance_id":"`+testInstanceID+`","limit":1`, 1)},
		{name: "execution ID", body: strings.Replace(base, `"instance_id":"`+testInstanceID+`"`, `"instance_id":"`+testInstanceID+`","execution_id":"exec-1"`, 1)},
		{name: "wrong instance type", body: strings.Replace(base, `"instance_id":"`+testInstanceID+`"`, `"instance_id":false`, 1)},
		{name: "wrong params type", body: strings.Replace(base, `"params":{"instance_id":"`+testInstanceID+`"}`, `"params":[]`, 1)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, failure, err := DecodeRequest([]byte(test.body))
			if err != nil || failure.Error == nil || failure.Error.Code != ErrorInvalidEnvelope {
				t.Fatalf("failure = %#v, err = %v", failure, err)
			}
		})
	}
}

func TestConfigResponseRejectsMissingExtraWrongTypeAndEnumFields(t *testing.T) {
	base := string(configReloadFrame(t))
	tests := []struct {
		name string
		body string
	}{
		{name: "missing flag", body: strings.Replace(base, `,"display_updated":false`, "", 1)},
		{name: "extra field", body: strings.Replace(base, `,"error":null`, `,"error":null`, 1)},
		{name: "wrong revision type", body: strings.Replace(base, `"revision":1`, `"revision":"1"`, 1)},
		{name: "wrong flag type", body: strings.Replace(base, `"changed":false`, `"changed":"false"`, 1)},
		{name: "invalid effect", body: strings.Replace(base, `"effect":"unchanged"`, `"effect":"toml"`, 1)},
	}
	// Add the extra field without relying on a response key-order assumption.
	var object map[string]json.RawMessage
	if err := json.Unmarshal(bytes.TrimSpace([]byte(base)), &object); err != nil {
		t.Fatal(err)
	}
	object["extra"] = json.RawMessage(`true`)
	extra, err := json.Marshal(object)
	if err != nil {
		t.Fatal(err)
	}
	tests[1].body = string(append(extra, '\n'))
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := DecodeResponse([]byte(test.body), configTestRequestID, string(MethodConfigReload), testInstanceID); err == nil {
				t.Fatal("malformed configuration reload response was accepted")
			}
		})
	}

	status := string(configStatusFrame(t))
	statusTests := []struct {
		name string
		body string
	}{
		{name: "missing reason", body: strings.Replace(status, `,"reason":"none"`, "", 1)},
		{name: "missing diagnostic", body: strings.Replace(status, `,"diagnostic":null`, "", 1)},
		{name: "wrong active type", body: strings.Replace(status, `"active":false`, `"active":"false"`, 1)},
		{name: "invalid state", body: strings.Replace(status, `"state":"idle"`, `"state":"ready"`, 1)},
		{name: "invalid outcome", body: strings.Replace(status, `"outcome":"unchanged"`, `"outcome":"applied"`, 1)},
		{name: "invalid reason", body: strings.Replace(status, `"reason":"none"`, `"reason":"toml"`, 1)},
		{name: "diagnostic on success", body: strings.Replace(status, `"diagnostic":null`, `"diagnostic":{"category":"decode","key":null,"line":null,"column":null,"detail":"TOML syntax or value type is invalid"}`, 1)},
	}
	for _, test := range statusTests {
		t.Run("status/"+test.name, func(t *testing.T) {
			if _, err := DecodeResponse([]byte(test.body), configTestRequestID, string(MethodConfigStatus), testInstanceID); err == nil {
				t.Fatal("malformed configuration status response was accepted")
			}
		})
	}

	rejected := string(configRejectedStatusFrame(t))
	rejectedTests := []struct {
		name string
		body string
	}{
		{name: "null diagnostic", body: replaceDiagnosticObject(rejected, "null")},
		{name: "extra field", body: strings.Replace(rejected, `"detail":"key is not supported"`, `"detail":"key is not supported","path":"/private/secret"`, 1)},
		{name: "unknown category", body: strings.Replace(rejected, `"category":"unknown-key"`, `"category":"parser"`, 1)},
		{name: "wrong key type", body: strings.Replace(rejected, `"key":"pages"`, `"key":false`, 1)},
		{name: "empty key", body: strings.Replace(rejected, `"key":"pages"`, `"key":""`, 1)},
		{name: "control key", body: string(configRejectedStatusFrameWithDiagnostic(t, "pages\n", "key is not supported"))},
		{name: "wrong line type", body: strings.Replace(rejected, `"line":4`, `"line":"4"`, 1)},
		{name: "zero line", body: strings.Replace(rejected, `"line":4`, `"line":0`, 1)},
		{name: "unbounded column", body: strings.Replace(rejected, `"column":2`, `"column":1000001`, 1)},
		{name: "partial location", body: strings.Replace(rejected, `"column":2`, `"column":null`, 1)},
		{name: "wrong detail type", body: strings.Replace(rejected, `"detail":"key is not supported"`, `"detail":false`, 1)},
		{name: "control detail", body: string(configRejectedStatusFrameWithDiagnostic(t, "pages", "unsafe\ntext"))},
		{name: "wrong outcome", body: strings.Replace(rejected, `"outcome":"rejected"`, `"outcome":"unchanged"`, 1)},
		{name: "wrong reason", body: strings.Replace(rejected, `"reason":"candidate-rejected"`, `"reason":"none"`, 1)},
	}
	for _, test := range rejectedTests {
		t.Run("status/diagnostic/"+test.name, func(t *testing.T) {
			if _, err := DecodeResponse([]byte(test.body), configTestRequestID, string(MethodConfigStatus), testInstanceID); err == nil {
				t.Fatal("malformed configuration diagnostic was accepted")
			}
		})
	}
}

func TestConfigResponseFrameIsBounded(t *testing.T) {
	frame := configReloadFrame(t)
	if len(frame) >= MaxFrameBytes {
		t.Fatalf("configuration reload response length = %d, want less than %d", len(frame), MaxFrameBytes)
	}
	status := configStatusFrame(t)
	if len(status) >= MaxFrameBytes {
		t.Fatalf("configuration status response length = %d, want less than %d", len(status), MaxFrameBytes)
	}
}

func TestServerDispatchesConfigReloadAndStatus(t *testing.T) {
	service := &configIPCService{
		reloadResult: ConfigReloadResult{Revision: 2, Changed: true, Effect: "display", DisplayChanged: true, DisplayUpdated: true},
		status:       ConfigStatus{Revision: 2, State: "idle", Outcome: "changed", Reason: "none"},
	}
	server := newConfigTestServer(t, service)
	reload := server.handleRequest(Request{RequestID: configTestRequestID, Method: MethodConfigReload, InstanceID: testInstanceID})
	if reload.Error != nil || reload.Result == nil || reload.Result.InstanceID != testInstanceID || !reload.Result.Changed || reload.Result.Effect != "display" || !reload.Result.DisplayUpdated {
		t.Fatalf("reload response = %#v", reload)
	}
	status := server.handleRequest(Request{RequestID: configTestRequestID, Method: MethodConfigStatus, InstanceID: testInstanceID})
	if status.Error != nil || status.Result == nil || status.Result.InstanceID != testInstanceID || status.Result.State != "idle" || status.Result.Outcome != "changed" {
		t.Fatalf("status response = %#v", status)
	}
	if service.reloadCalls != 1 || service.statusCalls != 1 {
		t.Fatalf("service calls = %d/%d, want 1/1", service.reloadCalls, service.statusCalls)
	}
}

func TestServerConfigUnavailableIsInternal(t *testing.T) {
	server := newConfigTestServer(t, nil)
	for _, method := range []Method{MethodConfigReload, MethodConfigStatus} {
		response := server.handleRequest(Request{RequestID: configTestRequestID, Method: method, InstanceID: testInstanceID})
		if response.Result != nil || response.Error == nil || response.Error.Code != ErrorInternal {
			t.Fatalf("%s response = %#v", method, response)
		}
	}
}

func TestServerMapsStableConfigErrorsWithoutRawDetails(t *testing.T) {
	tests := []struct {
		name string
		err  error
		code string
	}{
		{name: "busy", err: fmt.Errorf("busy detail: %w", ErrBusy), code: ErrorBusy},
		{name: "shutdown", err: fmt.Errorf("closed detail: %w", ErrShuttingDown), code: ErrorShuttingDown},
		{name: "device", err: fmt.Errorf("device detail: %w", ErrDeviceWriteFailed), code: ErrorDeviceWriteFailed},
		{name: "rejected", err: errors.New("/private/config.toml parse detail"), code: ErrorReloadRejected},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := newConfigTestServer(t, &configIPCService{reloadErr: test.err})
			response := server.handleRequest(Request{RequestID: configTestRequestID, Method: MethodConfigReload, InstanceID: testInstanceID})
			if response.Result != nil || response.Error == nil || response.Error.Code != test.code {
				t.Fatalf("response = %#v, want %q", response, test.code)
			}
			if strings.Contains(response.Error.Message, "config.toml") || strings.Contains(response.Error.Message, "detail") {
				t.Fatalf("raw error leaked in response: %#v", response.Error)
			}
			if _, err := EncodeResponse(response); err != nil {
				t.Fatalf("encode response: %v", err)
			}
		})
	}
}

func TestClientConfigMethodsUseStrictServerShapes(t *testing.T) {
	directory := shortTempDirectory(t)
	socketPath := filepath.Join(directory, "runtime.sock")
	service := &configIPCService{
		reloadResult: ConfigReloadResult{Revision: 1, Effect: "unchanged"},
		status:       ConfigStatus{Revision: 1, State: "idle", Outcome: "ready", Reason: "none"},
	}
	server, err := NewServer(ServerConfig{SocketPath: socketPath, InstanceID: testInstanceID, ConfigService: service, PeerVerifier: func(net.Conn) error { return nil }})
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
	response, err := client.ReloadConfig(context.Background(), testInstanceID)
	if err != nil || response.Error != nil || response.Result == nil || response.Result.Effect != "unchanged" {
		t.Fatalf("reload = %#v, %v", response, err)
	}
	response, err = client.ConfigStatus(context.Background(), testInstanceID)
	if err != nil || response.Error != nil || response.Result == nil || response.Result.State != "idle" {
		t.Fatalf("status = %#v, %v", response, err)
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("server did not stop")
	}
}

func configReloadFrame(t *testing.T) []byte {
	t.Helper()
	response := Response{
		ProtocolVersion: ProtocolVersion,
		RequestID:       stringPointer(configTestRequestID),
		Result: &Result{
			InstanceID:             testInstanceID,
			Revision:               1,
			Changed:                false,
			Effect:                 "unchanged",
			CatalogChanged:         false,
			DefaultChanged:         false,
			CurrentProfileChanged:  false,
			CurrentProfileFallback: false,
			ActionChanged:          false,
			DisplayChanged:         false,
			BrightnessChanged:      false,
			IdleChanged:            false,
			DisplayUpdated:         false,
		},
	}
	frame, err := EncodeResponse(response)
	if err != nil {
		t.Fatal(err)
	}
	return frame
}

func configStatusFrame(t *testing.T) []byte {
	t.Helper()
	response := Response{
		ProtocolVersion: ProtocolVersion,
		RequestID:       stringPointer(configTestRequestID),
		Result:          &Result{InstanceID: testInstanceID, Revision: 1, Active: false, State: "idle", Outcome: "unchanged", Reason: "none"},
	}
	frame, err := EncodeResponse(response)
	if err != nil {
		t.Fatal(err)
	}
	return frame
}

func configRejectedStatusFrame(t *testing.T) []byte {
	t.Helper()
	key, line, column := "pages", 4, 2
	response := Response{
		ProtocolVersion: ProtocolVersion,
		RequestID:       stringPointer(configTestRequestID),
		Result: &Result{
			InstanceID: testInstanceID,
			Revision:   1,
			State:      "idle",
			Outcome:    "rejected",
			Reason:     "candidate-rejected",
			Diagnostic: &ConfigDiagnostic{Category: "unknown-key", Key: &key, Line: &line, Column: &column, Detail: "key is not supported"},
		},
	}
	frame, err := EncodeResponse(response)
	if err != nil {
		t.Fatal(err)
	}
	return frame
}

type configStatusWire struct {
	ProtocolVersion int                    `json:"protocol_version"`
	RequestID       *string                `json:"request_id"`
	Result          configStatusResultWire `json:"result"`
	Error           *Error                 `json:"error"`
}

type configStatusResultWire struct {
	InstanceID string            `json:"instance_id"`
	Revision   uint64            `json:"revision"`
	Active     bool              `json:"active"`
	State      string            `json:"state"`
	Outcome    string            `json:"outcome"`
	Reason     string            `json:"reason"`
	Diagnostic *ConfigDiagnostic `json:"diagnostic"`
}

func configRejectedStatusFrameWithDiagnostic(t *testing.T, key, detail string) []byte {
	t.Helper()
	line, column := 4, 2
	requestID := configTestRequestID
	frame, err := json.Marshal(configStatusWire{
		ProtocolVersion: ProtocolVersion,
		RequestID:       &requestID,
		Result: configStatusResultWire{
			InstanceID: testInstanceID,
			Revision:   1,
			State:      "idle",
			Outcome:    "rejected",
			Reason:     "candidate-rejected",
			Diagnostic: &ConfigDiagnostic{Category: "unknown-key", Key: &key, Line: &line, Column: &column, Detail: detail},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	return append(frame, '\n')
}

func replaceDiagnosticObject(frame, replacement string) string {
	start := strings.Index(frame, `"diagnostic":{`)
	if start < 0 {
		return frame
	}
	objectStart := start + len(`"diagnostic":`)
	depth := 0
	for index := objectStart; index < len(frame); index++ {
		switch frame[index] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return frame[:objectStart] + replacement + frame[index+1:]
			}
		}
	}
	return frame
}

func assertObjectKeys(t *testing.T, frame []byte, field string, want []string) {
	t.Helper()
	assertObjectKeysAtPath(t, frame, []string{field}, want)
}

func assertObjectKeysAtPath(t *testing.T, frame []byte, path, want []string) {
	t.Helper()
	value, err := decodeJSONFrame(bytes.TrimSuffix(frame, []byte{'\n'}))
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range path {
		if value.kind != jsonObject {
			t.Fatalf("%s is not an object", strings.Join(path, "."))
		}
		var ok bool
		value, ok = value.object[field]
		if !ok {
			t.Fatalf("%s is missing", strings.Join(path, "."))
		}
	}
	object := value
	if object.kind != jsonObject {
		t.Fatalf("%s is not an object", strings.Join(path, "."))
	}
	if len(object.object) != len(want) {
		t.Fatalf("%s fields = %v, want %v", strings.Join(path, "."), object.object, want)
	}
	for _, key := range want {
		if _, ok := object.object[key]; !ok {
			t.Fatalf("%s omitted field %q: %v", strings.Join(path, "."), key, object.object)
		}
	}
}

func assertValueKindAtPath(t *testing.T, frame []byte, path []string, want jsonKind) {
	t.Helper()
	value, err := decodeJSONFrame(bytes.TrimSuffix(frame, []byte{'\n'}))
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range path {
		if value.kind != jsonObject {
			t.Fatalf("%s is not an object", strings.Join(path, "."))
		}
		var ok bool
		value, ok = value.object[field]
		if !ok {
			t.Fatalf("%s is missing", strings.Join(path, "."))
		}
	}
	if value.kind != want {
		t.Fatalf("%s kind = %v, want %v", strings.Join(path, "."), value.kind, want)
	}
}

func assertFalseFields(t *testing.T, frame []byte, field string, names []string) {
	t.Helper()
	value, err := decodeJSONFrame(bytes.TrimSuffix(frame, []byte{'\n'}))
	if err != nil {
		t.Fatal(err)
	}
	object := value.object[field]
	for _, name := range names {
		entry, ok := object.object[name]
		if !ok || entry.kind != jsonBool || entry.bool {
			t.Fatalf("%s.%s = %#v, want explicit false", field, name, entry)
		}
	}
}

func stringPointer(value string) *string {
	return &value
}

type configIPCService struct {
	reloadResult ConfigReloadResult
	reloadErr    error
	status       ConfigStatus
	reloadCalls  int
	statusCalls  int
}

func (service *configIPCService) Reload(context.Context) (ConfigReloadResult, error) {
	service.reloadCalls++
	return service.reloadResult, service.reloadErr
}

func (service *configIPCService) Status() ConfigStatus {
	service.statusCalls++
	return service.status
}

func newConfigTestServer(t *testing.T, service ConfigService) *Server {
	t.Helper()
	server, err := NewServer(ServerConfig{
		SocketPath:    filepath.Join(shortTempDirectory(t), "runtime.sock"),
		InstanceID:    testInstanceID,
		ConfigService: service,
	})
	if err != nil {
		t.Fatal(err)
	}
	return server
}
