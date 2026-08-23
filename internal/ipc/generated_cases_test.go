package ipc

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
)

type generatedCaseManifest struct {
	ID string `json:"id"`
}

type protocolCaseManifest struct {
	ProtocolVersion int                     `json:"protocol_version"`
	GeneratedCases  []generatedCaseManifest `json:"generated_cases"`
}

type runningTestServer struct {
	server *Server
	cancel context.CancelFunc
	done   chan error
	once   sync.Once
}

func TestGeneratedCaseManifest(t *testing.T) {
	manifestData := readFixture(t, "cases.json")
	var manifest protocolCaseManifest
	if err := json.Unmarshal(manifestData, &manifest); err != nil {
		t.Fatalf("decode protocol manifest: %v", err)
	}
	if manifest.ProtocolVersion != ProtocolVersion {
		t.Fatalf("manifest protocol version = %d, want %d", manifest.ProtocolVersion, ProtocolVersion)
	}
	tests := map[string]func(*testing.T){
		"frame.invalid-utf8":          testGeneratedInvalidUTF8,
		"frame.missing-lf":            testGeneratedMissingLF,
		"frame.partial-delivery":      testGeneratedPartialDelivery,
		"frame.concatenated-records":  testGeneratedConcatenatedRecords,
		"frame.maximum":               testGeneratedMaximumFrame,
		"frame.too-large":             testGeneratedTooLargeFrame,
		"request.duplicate-any-depth": testGeneratedDuplicateKeys,
		"request.request-id-invalid":  testGeneratedInvalidRequestIDs,
		"request.top-level-field-set": testGeneratedTopLevelFieldSet,
		"request.version-type":        testGeneratedVersionTypes,
		"request.method-type":         testGeneratedMethodTypes,
		"request.params-type":         testGeneratedParamsTypes,
		"request.version-noninteger":  testGeneratedNonIntegerVersion,
		"request.params-shape":        testGeneratedParamsShape,
		"request.internal":            testGeneratedInternal,
		"server.connection-limit":     testGeneratedConnectionLimit,
		"server.recovery":             testGeneratedRecovery,
		"response.strict-success":     testGeneratedStrictSuccess,
		"response.strict-error":       testGeneratedStrictError,
		"io.blocked-reader":           testGeneratedBlockedReader,
		"io.blocked-writer":           testGeneratedBlockedWriter,
	}
	seen := make(map[string]bool, len(manifest.GeneratedCases))
	for _, generatedCase := range manifest.GeneratedCases {
		if seen[generatedCase.ID] {
			t.Errorf("generated case %q appears more than once", generatedCase.ID)
			continue
		}
		testCase, ok := tests[generatedCase.ID]
		if !ok {
			t.Errorf("generated case %q has no Go test", generatedCase.ID)
			continue
		}
		seen[generatedCase.ID] = true
		t.Run(generatedCase.ID, testCase)
	}
	for id := range tests {
		if !seen[id] {
			t.Errorf("Go test %q is absent from cases.json", id)
		}
	}
}

func testGeneratedInvalidUTF8(t *testing.T) {
	running := startGeneratedServer(t, ServerConfig{Deadlines: shortDeadlines()})
	frame := rawExchange(t, running.server.config.SocketPath, []byte{0xff, '\n'})
	assertErrorFrame(t, frame, ErrorInvalidJSON, "", MethodHealth)
}

func testGeneratedMissingLF(t *testing.T) {
	running := startGeneratedServer(t, ServerConfig{Deadlines: shortDeadlines()})
	connection := dialRaw(t, running.server.config.SocketPath)
	defer connection.Close()
	request := bytes.TrimSuffix(readFixture(t, "valid/health.request.jsonl"), []byte{'\n'})
	writeAll(t, connection, request)
	_ = connection.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	if _, err := readFrame(connection); !errors.Is(err, errFrameIncomplete) {
		t.Fatalf("missing-LF result = %v, want EOF without response", err)
	}
}

func testGeneratedPartialDelivery(t *testing.T) {
	running := startGeneratedServer(t, ServerConfig{Deadlines: shortDeadlines()})
	connection := dialRaw(t, running.server.config.SocketPath)
	defer connection.Close()
	request := readFixture(t, "valid/health.request.jsonl")
	chunkSizes := []int{1, 7, 13}
	for offset, chunkIndex := 0, 0; offset < len(request); chunkIndex++ {
		chunkSize := chunkSizes[chunkIndex%len(chunkSizes)]
		remaining := len(request) - offset
		if chunkSize > remaining {
			chunkSize = remaining
		}
		writeAll(t, connection, request[offset:offset+chunkSize])
		offset += chunkSize
	}
	frame := readResponseFrame(t, connection)
	assertHealthFrame(t, frame, "11111111-1111-4111-8111-111111111111")
}

func testGeneratedConcatenatedRecords(t *testing.T) {
	running := startGeneratedServer(t, ServerConfig{Deadlines: shortDeadlines()})
	connection := dialRaw(t, running.server.config.SocketPath)
	defer connection.Close()
	request := readFixture(t, "valid/health.request.jsonl")
	writeAll(t, connection, append(append([]byte{}, request...), request...))
	frame := readResponseFrame(t, connection)
	assertHealthFrame(t, frame, "11111111-1111-4111-8111-111111111111")
	_ = connection.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	if _, err := readFrame(connection); !errors.Is(err, errFrameIncomplete) {
		t.Fatalf("concatenated response stream = %v, want exactly one response", err)
	}
}

func testGeneratedMaximumFrame(t *testing.T) {
	running := startGeneratedServer(t, ServerConfig{Deadlines: shortDeadlines()})
	frame := padFixture(readFixture(t, "valid/health.request.jsonl"), MaxFrameBytes, ' ')
	responseFrame := rawExchange(t, running.server.config.SocketPath, frame)
	assertHealthFrame(t, responseFrame, "11111111-1111-4111-8111-111111111111")
}

func testGeneratedTooLargeFrame(t *testing.T) {
	running := startGeneratedServer(t, ServerConfig{Deadlines: shortDeadlines()})
	frame := padFixture(readFixture(t, "valid/health.request.jsonl"), MaxFrameBytes+1, ' ')
	responseFrame := rawExchange(t, running.server.config.SocketPath, frame)
	assertErrorFrame(t, responseFrame, ErrorMessageTooLarge, "", MethodHealth)
}

func testGeneratedDuplicateKeys(t *testing.T) {
	base := readFixture(t, "valid/health.request.jsonl")
	mutations := [][]byte{
		[]byte(`{"protocol_version":1,"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"health","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}}` + "\n"),
		[]byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","request_id":"11111111-1111-4111-8111-111111111111","method":"health","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}}` + "\n"),
		[]byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"health","method":"health","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}}` + "\n"),
		[]byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"health","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}}` + "\n"),
	}
	if len(base) == 0 {
		t.Fatal("valid fixture is empty")
	}
	for index, mutation := range mutations {
		_, response, err := ValidateRequest(mutation, testInstanceID)
		if err != nil {
			t.Fatalf("mutation %d: %v", index, err)
		}
		if response.Error == nil || response.Error.Code != ErrorInvalidEnvelope || response.RequestID != nil {
			t.Fatalf("mutation %d response = %#v", index, response)
		}
	}
}

func testGeneratedInvalidRequestIDs(t *testing.T) {
	base := readFixture(t, "valid/health.request.jsonl")
	for name, value := range map[string]json.RawMessage{
		"null":         json.RawMessage("null"),
		"number":       json.RawMessage("1"),
		"uppercase":    json.RawMessage(`"UPPERCASE"`),
		"unhyphenated": json.RawMessage(`"11111111111141118111111111111111"`),
	} {
		request := replaceTopLevelField(t, base, "request_id", value)
		_, response, err := ValidateRequest(request, testInstanceID)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if response.Error == nil || response.Error.Code != ErrorInvalidEnvelope || response.RequestID != nil {
			t.Fatalf("%s response = %#v", name, response)
		}
	}
}

func testGeneratedTopLevelFieldSet(t *testing.T) {
	base := readFixture(t, "valid/health.request.jsonl")
	for _, field := range []string{"protocol_version", "request_id", "method", "params"} {
		request := removeTopLevelField(t, base, field)
		_, response, err := ValidateRequest(request, testInstanceID)
		if err != nil {
			t.Fatalf("remove %s: %v", field, err)
		}
		if response.Error == nil || response.Error.Code != ErrorInvalidEnvelope {
			t.Fatalf("remove %s response = %#v", field, response)
		}
		if field == "request_id" && response.RequestID != nil {
			t.Fatalf("remove request_id echoed %v", *response.RequestID)
		}
	}
	request := replaceTopLevelField(t, base, "extra", json.RawMessage("true"))
	_, response, err := ValidateRequest(request, testInstanceID)
	if err != nil {
		t.Fatal(err)
	}
	if response.Error == nil || response.Error.Code != ErrorInvalidEnvelope || response.RequestID == nil {
		t.Fatalf("unknown field response = %#v", response)
	}
}

func testGeneratedVersionTypes(t *testing.T) {
	base := readFixture(t, "valid/health.request.jsonl")
	for name, value := range map[string]json.RawMessage{
		"null":   json.RawMessage("null"),
		"true":   json.RawMessage("true"),
		"string": json.RawMessage(`"1"`),
		"float":  json.RawMessage("1.5"),
	} {
		request := replaceTopLevelField(t, base, "protocol_version", value)
		_, response, err := ValidateRequest(request, testInstanceID)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		assertRequestError(t, response, ErrorUnsupportedVers, true)
	}
}

func testGeneratedMethodTypes(t *testing.T) {
	base := readFixture(t, "valid/health.request.jsonl")
	for name, value := range map[string]json.RawMessage{
		"null":   json.RawMessage("null"),
		"true":   json.RawMessage("true"),
		"number": json.RawMessage("1"),
		"object": json.RawMessage(`{}`),
	} {
		request := replaceTopLevelField(t, base, "method", value)
		_, response, err := ValidateRequest(request, testInstanceID)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		assertRequestError(t, response, ErrorInvalidEnvelope, true)
	}
}

func testGeneratedParamsTypes(t *testing.T) {
	base := readFixture(t, "valid/health.request.jsonl")
	for name, value := range map[string]json.RawMessage{
		"null":   json.RawMessage("null"),
		"true":   json.RawMessage("true"),
		"number": json.RawMessage("1"),
		"array":  json.RawMessage(`[]`),
	} {
		request := replaceTopLevelField(t, base, "params", value)
		_, response, err := ValidateRequest(request, testInstanceID)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		assertRequestError(t, response, ErrorInvalidEnvelope, true)
	}
}

func testGeneratedNonIntegerVersion(t *testing.T) {
	base := readFixture(t, "valid/health.request.jsonl")
	request := replaceTopLevelField(t, base, "protocol_version", json.RawMessage("1.0"))
	_, response, err := ValidateRequest(request, testInstanceID)
	if err != nil {
		t.Fatal(err)
	}
	assertRequestError(t, response, ErrorUnsupportedVers, true)
}

func testGeneratedParamsShape(t *testing.T) {
	base := readFixture(t, "valid/health.request.jsonl")
	params := map[string]json.RawMessage{
		"instance_id": json.RawMessage(`"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"`),
	}
	mutations := map[string]func(map[string]json.RawMessage){
		"missing_instance_id": func(fields map[string]json.RawMessage) { delete(fields, "instance_id") },
		"null_instance_id":    func(fields map[string]json.RawMessage) { fields["instance_id"] = json.RawMessage("null") },
		"wrong_type_instance_id": func(fields map[string]json.RawMessage) {
			fields["instance_id"] = json.RawMessage("1")
		},
		"uppercase_uuid": func(fields map[string]json.RawMessage) {
			fields["instance_id"] = json.RawMessage(`"AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"`)
		},
		"malformed_uuid": func(fields map[string]json.RawMessage) {
			fields["instance_id"] = json.RawMessage(`"not-a-uuid"`)
		},
		"unknown_field": func(fields map[string]json.RawMessage) {
			fields["extra"] = json.RawMessage("true")
		},
	}
	for name, mutate := range mutations {
		fields := cloneRawFields(params)
		mutate(fields)
		request := replaceTopLevelField(t, base, "params", marshalRawObject(t, fields))
		_, response, err := ValidateRequest(request, testInstanceID)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		assertRequestError(t, response, ErrorInvalidEnvelope, true)
	}
}

func testGeneratedInternal(t *testing.T) {
	running := startGeneratedServer(t, ServerConfig{
		Deadlines: shortDeadlines(),
		Handler: HandlerFunc(func(context.Context, Request) (Result, error) {
			return Result{}, errors.New("injected handler failure")
		}),
	})
	frame := rawExchange(t, running.server.config.SocketPath, readFixture(t, "valid/health.request.jsonl"))
	assertErrorFrame(t, frame, ErrorInternal, "11111111-1111-4111-8111-111111111111", MethodHealth)
}

func testGeneratedConnectionLimit(t *testing.T) {
	entered := make(chan struct{}, 8)
	release := make(chan struct{})
	running := startGeneratedServer(t, ServerConfig{
		Deadlines:      shortDeadlines(),
		MaxConnections: 8,
		Handler: HandlerFunc(func(_ context.Context, request Request) (Result, error) {
			entered <- struct{}{}
			<-release
			return Result{InstanceID: request.InstanceID, State: ReadyState}, nil
		}),
	})
	connections := make([]net.Conn, 0, 8)
	for index := 0; index < cap(connections); index++ {
		connection := dialRaw(t, running.server.config.SocketPath)
		connections = append(connections, connection)
		writeAll(t, connection, readFixture(t, "valid/health.request.jsonl"))
	}
	for index := 0; index < cap(connections); index++ {
		select {
		case <-entered:
		case <-time.After(2 * time.Second):
			t.Fatalf("handler %d did not enter", index)
		}
	}
	for _, connection := range connections {
		defer connection.Close()
	}
	ninth := dialRaw(t, running.server.config.SocketPath)
	_ = ninth.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	if _, err := readFrame(ninth); !errors.Is(err, errFrameIncomplete) {
		_ = ninth.Close()
		t.Fatalf("ninth connection result = %v, want EOF without response", err)
	}
	_ = ninth.Close()
	close(release)
	for _, connection := range connections {
		frame := readResponseFrame(t, connection)
		assertHealthFrame(t, frame, "11111111-1111-4111-8111-111111111111")
	}
}

func testGeneratedRecovery(t *testing.T) {
	running := startGeneratedServer(t, ServerConfig{Deadlines: shortDeadlines()})
	tests := []struct {
		name      string
		request   []byte
		code      string
		requestID string
		method    Method
	}{
		{name: "invalid utf8", request: []byte{0xff, '\n'}, code: ErrorInvalidJSON, method: MethodHealth},
		{name: "invalid json", request: readFixture(t, "invalid/json-syntax.request.jsonl"), code: ErrorInvalidJSON, method: MethodHealth},
		{name: "invalid envelope", request: readFixture(t, "invalid/unknown-field.request.jsonl"), code: ErrorInvalidEnvelope, requestID: "33333333-3333-4333-8333-333333333333", method: MethodHealth},
		{name: "unsupported version", request: readFixture(t, "invalid/unsupported-version.request.jsonl"), code: ErrorUnsupportedVers, requestID: "55555555-5555-4555-8555-555555555555", method: MethodHealth},
		{name: "unknown method", request: readFixture(t, "invalid/unknown-method.request.jsonl"), code: ErrorUnknownMethod, requestID: "66666666-6666-4666-8666-666666666666", method: MethodHealth},
		{name: "instance mismatch", request: readFixture(t, "invalid/instance-mismatch.request.jsonl"), code: ErrorInstanceMismatch, requestID: "77777777-7777-4777-8777-777777777777", method: MethodHealth},
		{name: "message too large", request: padFixture(readFixture(t, "valid/health.request.jsonl"), MaxFrameBytes+1, ' '), code: ErrorMessageTooLarge, method: MethodHealth},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			frame := rawExchange(t, running.server.config.SocketPath, test.request)
			assertErrorFrame(t, frame, test.code, test.requestID, test.method)
		})
	}
	client, err := NewClient(ClientConfig{SocketPath: running.server.config.SocketPath, Deadlines: shortDeadlines()})
	if err != nil {
		t.Fatal(err)
	}
	response, err := client.Call(context.Background(), MethodHealth, testInstanceID)
	if err != nil {
		t.Fatalf("health after malformed requests: %v", err)
	}
	if response.Error != nil || response.Result == nil {
		t.Fatalf("health after malformed requests = %#v", response)
	}
}

func testGeneratedStrictSuccess(t *testing.T) {
	base := readFixture(t, "valid/health.response.jsonl")
	mutations := make([]struct {
		name string
		body []byte
	}, 0, 32)
	for _, field := range []string{"protocol_version", "request_id", "result", "error"} {
		field := field
		mutations = append(mutations, struct {
			name string
			body []byte
		}{"missing " + field, removeTopLevelField(t, base, field)})
	}
	for _, field := range []string{"instance_id", "state"} {
		field := field
		mutations = append(mutations, struct {
			name string
			body []byte
		}{"missing result." + field, removeNestedObjectField(t, base, "result", field)})
	}
	mutations = append(mutations,
		struct {
			name string
			body []byte
		}{"duplicate protocol_version", []byte(`{"protocol_version":1,"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","result":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","state":"ready"},"error":null}` + "\n")},
		struct {
			name string
			body []byte
		}{"duplicate request_id", []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","request_id":"11111111-1111-4111-8111-111111111111","result":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","state":"ready"},"error":null}` + "\n")},
		struct {
			name string
			body []byte
		}{"duplicate result", []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","result":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","state":"ready"},"result":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","state":"ready"},"error":null}` + "\n")},
		struct {
			name string
			body []byte
		}{"duplicate error", []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","result":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","state":"ready"},"error":null,"error":null}` + "\n")},
		struct {
			name string
			body []byte
		}{"duplicate result.instance_id", []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","result":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","state":"ready"},"error":null}` + "\n")},
		struct {
			name string
			body []byte
		}{"duplicate result.state", []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","result":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","state":"ready","state":"ready"},"error":null}` + "\n")},
	)
	for _, field := range []string{"protocol_version", "request_id", "result", "error"} {
		value := json.RawMessage(`true`)
		if field == "protocol_version" {
			value = json.RawMessage(`"1"`)
		}
		if field == "request_id" {
			value = json.RawMessage(`1`)
		}
		mutations = append(mutations, struct {
			name string
			body []byte
		}{"wrong type " + field, replaceTopLevelField(t, base, field, value)})
	}
	mutations = append(mutations,
		struct {
			name string
			body []byte
		}{"wrong type result.instance_id", replaceNestedObjectField(t, base, "result", "instance_id", json.RawMessage(`1`))},
		struct {
			name string
			body []byte
		}{"wrong type result.state", replaceNestedObjectField(t, base, "result", "state", json.RawMessage(`1`))},
		struct {
			name string
			body []byte
		}{"wrong request_id", replaceTopLevelField(t, base, "request_id", json.RawMessage(`"22222222-2222-4222-8222-222222222222"`))},
		struct {
			name string
			body []byte
		}{"wrong instance_id", replaceNestedObjectField(t, base, "result", "instance_id", json.RawMessage(`"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"`))},
		struct {
			name string
			body []byte
		}{"wrong state", replaceNestedObjectField(t, base, "result", "state", json.RawMessage(`"stopped"`))},
		struct {
			name string
			body []byte
		}{"both result and error", replaceTopLevelField(t, base, "error", json.RawMessage(`{"code":"internal","message":"internal server error"}`))},
		struct {
			name string
			body []byte
		}{"both null", replaceTopLevelField(t, base, "result", json.RawMessage(`null`))},
		struct {
			name string
			body []byte
		}{"unknown top-level field", replaceTopLevelField(t, base, "extra", json.RawMessage(`true`))},
		struct {
			name string
			body []byte
		}{"unknown result field", replaceNestedObjectField(t, base, "result", "extra", json.RawMessage(`true`))},
	)
	for _, mutation := range mutations {
		mutation := mutation
		t.Run(mutation.name, func(t *testing.T) {
			if _, err := DecodeResponse(mutation.body, "11111111-1111-4111-8111-111111111111", string(MethodHealth), testInstanceID); err == nil {
				t.Fatal("mutated success response was accepted")
			}
		})
	}
}

func testGeneratedStrictError(t *testing.T) {
	base := readFixture(t, "invalid/unknown-method.response.jsonl")
	mutations := make([]struct {
		name string
		body []byte
	}, 0, 24)
	for _, field := range []string{"protocol_version", "request_id", "result", "error"} {
		field := field
		mutations = append(mutations, struct {
			name string
			body []byte
		}{"missing " + field, removeTopLevelField(t, base, field)})
	}
	for _, field := range []string{"code", "message"} {
		field := field
		mutations = append(mutations, struct {
			name string
			body []byte
		}{"missing error." + field, removeNestedObjectField(t, base, "error", field)})
	}
	mutations = append(mutations,
		struct {
			name string
			body []byte
		}{"duplicate protocol_version", []byte(`{"protocol_version":1,"protocol_version":1,"request_id":"66666666-6666-4666-8666-666666666666","result":null,"error":{"code":"unknown_method","message":"request method is not supported"}}` + "\n")},
		struct {
			name string
			body []byte
		}{"duplicate request_id", []byte(`{"protocol_version":1,"request_id":"66666666-6666-4666-8666-666666666666","request_id":"66666666-6666-4666-8666-666666666666","result":null,"error":{"code":"unknown_method","message":"request method is not supported"}}` + "\n")},
		struct {
			name string
			body []byte
		}{"duplicate result", []byte(`{"protocol_version":1,"request_id":"66666666-6666-4666-8666-666666666666","result":null,"result":null,"error":{"code":"unknown_method","message":"request method is not supported"}}` + "\n")},
		struct {
			name string
			body []byte
		}{"duplicate error", []byte(`{"protocol_version":1,"request_id":"66666666-6666-4666-8666-666666666666","result":null,"error":{"code":"unknown_method","message":"request method is not supported"},"error":{"code":"unknown_method","message":"request method is not supported"}}` + "\n")},
		struct {
			name string
			body []byte
		}{"duplicate error.code", []byte(`{"protocol_version":1,"request_id":"66666666-6666-4666-8666-666666666666","result":null,"error":{"code":"unknown_method","code":"unknown_method","message":"request method is not supported"}}` + "\n")},
		struct {
			name string
			body []byte
		}{"duplicate error.message", []byte(`{"protocol_version":1,"request_id":"66666666-6666-4666-8666-666666666666","result":null,"error":{"code":"unknown_method","message":"request method is not supported","message":"request method is not supported"}}` + "\n")},
	)
	for _, field := range []string{"protocol_version", "request_id", "result", "error"} {
		value := json.RawMessage(`true`)
		if field == "protocol_version" {
			value = json.RawMessage(`"1"`)
		}
		if field == "request_id" {
			value = json.RawMessage(`1`)
		}
		mutations = append(mutations, struct {
			name string
			body []byte
		}{"wrong type " + field, replaceTopLevelField(t, base, field, value)})
	}
	mutations = append(mutations,
		struct {
			name string
			body []byte
		}{"wrong type error.code", replaceNestedObjectField(t, base, "error", "code", json.RawMessage(`1`))},
		struct {
			name string
			body []byte
		}{"wrong type error.message", replaceNestedObjectField(t, base, "error", "message", json.RawMessage(`[]`))},
		struct {
			name string
			body []byte
		}{"unknown top-level field", replaceTopLevelField(t, base, "extra", json.RawMessage(`true`))},
		struct {
			name string
			body []byte
		}{"unknown error field", replaceNestedObjectField(t, base, "error", "extra", json.RawMessage(`true`))},
		struct {
			name string
			body []byte
		}{"unknown error code", replaceNestedObjectField(t, base, "error", "code", json.RawMessage(`"bogus"`))},
		struct {
			name string
			body []byte
		}{"message 257 bytes", replaceNestedObjectField(t, base, "error", "message", json.RawMessage(`"`+strings.Repeat("x", 257)+`"`))},
		struct {
			name string
			body []byte
		}{"non-null result", replaceTopLevelField(t, base, "result", json.RawMessage(`{}`))},
	)
	for _, mutation := range mutations {
		mutation := mutation
		t.Run(mutation.name, func(t *testing.T) {
			if _, err := DecodeResponse(mutation.body, "66666666-6666-4666-8666-666666666666", string(MethodHealth), testInstanceID); err == nil {
				t.Fatal("mutated error response was accepted")
			}
		})
	}
}

func testGeneratedBlockedReader(t *testing.T) {
	reader, writer := net.Pipe()
	defer reader.Close()
	defer writer.Close()
	if err := writer.SetWriteDeadline(time.Now().Add(50 * time.Millisecond)); err != nil {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() { result <- writeFrame(writer, []byte("{}\n")) }()
	select {
	case err := <-result:
		var networkError net.Error
		if !errors.As(err, &networkError) || !networkError.Timeout() {
			t.Fatalf("blocked writer error = %v, want timeout", err)
		}
	case <-time.After(time.Second):
		t.Fatal("blocked writer did not honor deadline")
	}
}

func testGeneratedBlockedWriter(t *testing.T) {
	running := startGeneratedServer(t, ServerConfig{Deadlines: shortDeadlines()})
	connection := dialRaw(t, running.server.config.SocketPath)
	defer connection.Close()
	request := readFixture(t, "valid/health.request.jsonl")
	writeAll(t, connection, request[:len(request)/2])
	_ = connection.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	if _, err := readFrame(connection); err == nil {
		t.Fatal("stalled request unexpectedly received a response")
	} else {
		var networkError net.Error
		if !errors.Is(err, errFrameIncomplete) && (!errors.As(err, &networkError) || !networkError.Timeout()) {
			t.Fatalf("stalled request error = %v, want timeout", err)
		}
	}
	client, err := NewClient(ClientConfig{SocketPath: running.server.config.SocketPath, Deadlines: shortDeadlines()})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Call(context.Background(), MethodHealth, testInstanceID); err != nil {
		t.Fatalf("health after stalled request: %v", err)
	}
}

func TestPeerVerifierSeam(t *testing.T) {
	running := startGeneratedServer(t, ServerConfig{Deadlines: shortDeadlines()})
	if running.server.peerVerifier == nil {
		t.Fatal("server did not install mandatory peer verifier")
	}
	client, err := NewClient(ClientConfig{SocketPath: running.server.config.SocketPath, Deadlines: shortDeadlines()})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.Call(context.Background(), MethodHealth, testInstanceID); err != nil {
		t.Fatalf("default peer verifier rejected current user: %v", err)
	}
	rejected := errors.New("peer rejected by test verifier")
	server := startGeneratedServer(t, ServerConfig{
		Deadlines: shortDeadlines(),
		PeerVerifier: func(net.Conn) error {
			return rejected
		},
	})
	connection := dialRaw(t, server.server.config.SocketPath)
	_ = connection.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	if _, err := readFrame(connection); !errors.Is(err, errFrameIncomplete) {
		_ = connection.Close()
		t.Fatalf("rejected server connection result = %v, want EOF", err)
	}
	_ = connection.Close()
	rejectingClient, err := NewClient(ClientConfig{
		SocketPath: server.server.config.SocketPath,
		Deadlines:  shortDeadlines(),
		PeerVerifier: func(net.Conn) error {
			return rejected
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := rejectingClient.Call(context.Background(), MethodHealth, testInstanceID); !errors.Is(err, rejected) {
		t.Fatalf("rejected client error = %v, want %v", err, rejected)
	}
}

func startGeneratedServer(t *testing.T, config ServerConfig) *runningTestServer {
	t.Helper()
	directory := shortTempDirectory(t)
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	if config.SocketPath == "" {
		config.SocketPath = filepath.Join(directory, "runtime.sock")
	}
	if config.InstanceID == "" {
		config.InstanceID = testInstanceID
	}
	server, err := NewServer(config)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	running := &runningTestServer{server: server, cancel: cancel, done: make(chan error, 1)}
	t.Cleanup(running.stop)
	go func() { running.done <- server.Serve(ctx) }()
	waitForSocket(t, config.SocketPath)
	return running
}

func (running *runningTestServer) stop() {
	running.once.Do(func() {
		running.cancel()
		_ = running.server.Close()
		select {
		case <-running.done:
		case <-time.After(3 * time.Second):
		}
	})
}

func shortDeadlines() Deadlines {
	return Deadlines{Connect: 250 * time.Millisecond, Read: 150 * time.Millisecond, Write: 150 * time.Millisecond}
}

func dialRaw(t *testing.T, path string) net.Conn {
	t.Helper()
	connection, err := net.DialTimeout("unix", path, time.Second)
	if err != nil {
		t.Fatalf("dial %s: %v", path, err)
	}
	return connection
}

func writeAll(t *testing.T, connection net.Conn, data []byte) {
	t.Helper()
	for len(data) > 0 {
		written, err := connection.Write(data)
		if written > 0 {
			data = data[written:]
		}
		if err != nil {
			t.Fatalf("write bytes: %v", err)
		}
		if written == 0 {
			t.Fatal("write made no progress")
		}
	}
}

func readResponseFrame(t *testing.T, connection net.Conn) []byte {
	t.Helper()
	_ = connection.SetReadDeadline(time.Now().Add(2 * time.Second))
	frame, err := readFrame(connection)
	if err != nil {
		t.Fatalf("read response frame: %v", err)
	}
	return frame
}

func rawExchange(t *testing.T, path string, request []byte) []byte {
	t.Helper()
	connection := dialRaw(t, path)
	defer connection.Close()
	writeAll(t, connection, request)
	return readResponseFrame(t, connection)
}

func assertErrorFrame(t *testing.T, frame []byte, code, expectedRequestID string, method Method) {
	t.Helper()
	response, err := DecodeResponse(frame, expectedRequestID, string(method), testInstanceID)
	if err != nil {
		t.Fatalf("decode error response: %v", err)
	}
	if response.Error == nil || response.Error.Code != code {
		t.Fatalf("error response = %#v, want %q", response, code)
	}
	if expectedRequestID == "" {
		if response.RequestID != nil {
			t.Fatalf("error response request ID = %q, want null", *response.RequestID)
		}
	} else if response.RequestID == nil || *response.RequestID != expectedRequestID {
		t.Fatalf("error response request ID = %v, want %q", response.RequestID, expectedRequestID)
	}
}

func assertHealthFrame(t *testing.T, frame []byte, requestID string) {
	t.Helper()
	response, err := DecodeResponse(frame, requestID, string(MethodHealth), testInstanceID)
	if err != nil {
		t.Fatalf("decode health response: %v", err)
	}
	if response.Error != nil || response.Result == nil || response.Result.InstanceID != testInstanceID || response.Result.State != ReadyState || response.Result.ProtocolVersion != nil {
		t.Fatalf("health response = %#v", response)
	}
}

func assertRequestError(t *testing.T, response Response, code string, echoRequestID bool) {
	t.Helper()
	if response.Error == nil || response.Error.Code != code {
		t.Fatalf("request response = %#v, want error %q", response, code)
	}
	if echoRequestID {
		if response.RequestID == nil || *response.RequestID != "11111111-1111-4111-8111-111111111111" {
			t.Fatalf("request response ID = %v, want valid request ID", response.RequestID)
		}
	} else if response.RequestID != nil {
		t.Fatalf("request response ID = %q, want null", *response.RequestID)
	}
}

func padFixture(base []byte, total int, padding byte) []byte {
	base = bytes.TrimSuffix(append([]byte(nil), base...), []byte{'\n'})
	if total < len(base)+1 {
		panic(fmt.Sprintf("fixture length %d exceeds target frame length %d", len(base)+1, total))
	}
	frame := append(base, bytes.Repeat([]byte{padding}, total-len(base)-1)...)
	return append(frame, '\n')
}

func topLevelFields(t *testing.T, frame []byte) map[string]json.RawMessage {
	t.Helper()
	fields := make(map[string]json.RawMessage)
	if err := json.Unmarshal(bytes.TrimSpace(frame), &fields); err != nil {
		t.Fatalf("decode object fields: %v", err)
	}
	return fields
}

func marshalRawObject(t *testing.T, fields map[string]json.RawMessage) []byte {
	t.Helper()
	encoded, err := json.Marshal(fields)
	if err != nil {
		t.Fatalf("encode object fields: %v", err)
	}
	return encoded
}

func replaceTopLevelField(t *testing.T, base []byte, field string, value json.RawMessage) []byte {
	fields := topLevelFields(t, base)
	fields[field] = append(json.RawMessage(nil), bytes.TrimSpace(value)...)
	return append(marshalRawObject(t, fields), '\n')
}

func removeTopLevelField(t *testing.T, base []byte, field string) []byte {
	fields := topLevelFields(t, base)
	delete(fields, field)
	return append(marshalRawObject(t, fields), '\n')
}

func replaceNestedObjectField(t *testing.T, base []byte, parent, field string, value json.RawMessage) []byte {
	root := topLevelFields(t, base)
	parentValue, ok := root[parent]
	if !ok {
		t.Fatalf("response has no %s object", parent)
	}
	nested := make(map[string]json.RawMessage)
	if err := json.Unmarshal(parentValue, &nested); err != nil {
		t.Fatalf("decode %s object: %v", parent, err)
	}
	nested[field] = append(json.RawMessage(nil), bytes.TrimSpace(value)...)
	root[parent] = marshalRawObject(t, nested)
	return append(marshalRawObject(t, root), '\n')
}

func removeNestedObjectField(t *testing.T, base []byte, parent, field string) []byte {
	root := topLevelFields(t, base)
	parentValue, ok := root[parent]
	if !ok {
		t.Fatalf("response has no %s object", parent)
	}
	nested := make(map[string]json.RawMessage)
	if err := json.Unmarshal(parentValue, &nested); err != nil {
		t.Fatalf("decode %s object: %v", parent, err)
	}
	delete(nested, field)
	root[parent] = marshalRawObject(t, nested)
	return append(marshalRawObject(t, root), '\n')
}

func cloneRawFields(fields map[string]json.RawMessage) map[string]json.RawMessage {
	clone := make(map[string]json.RawMessage, len(fields))
	for key, value := range fields {
		clone[key] = append(json.RawMessage(nil), value...)
	}
	return clone
}
