package ipc

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"testing"
)

const testInstanceID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

func TestSharedFixtures(t *testing.T) {
	tests := []struct {
		name string
		file string
	}{
		{name: "health", file: "valid/health"},
		{name: "status", file: "valid/status"},
		{name: "json syntax", file: "invalid/json-syntax"},
		{name: "unknown field", file: "invalid/unknown-field"},
		{name: "duplicate key", file: "invalid/duplicate-key"},
		{name: "unsupported version", file: "invalid/unsupported-version"},
		{name: "unknown method", file: "invalid/unknown-method"},
		{name: "instance mismatch", file: "invalid/instance-mismatch"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			requestBytes := readFixture(t, test.file+".request.jsonl")
			expectedResponse := readFixture(t, test.file+".response.jsonl")
			_, response, err := ValidateRequest(requestBytes, testInstanceID)
			if err != nil {
				t.Fatalf("validate request: %v", err)
			}
			if response.Error == nil {
				request, _, err := ValidateRequest(requestBytes, testInstanceID)
				if err != nil {
					t.Fatalf("validate successful request: %v", err)
				}
				requestID := request.RequestID
				response = Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID}
				response.Result = &Result{InstanceID: request.InstanceID, State: ReadyState}
				if request.Method == MethodStatus {
					version := ProtocolVersion
					response.Result.ProtocolVersion = &version
				}
			}
			encoded, err := EncodeResponse(response)
			if err != nil {
				t.Fatalf("encode response: %v", err)
			}
			actualValue, err := decodeJSONFrame(encoded)
			if err != nil {
				t.Fatalf("decode actual response: %v", err)
			}
			expectedValue, err := decodeJSONFrame(expectedResponse)
			if err != nil {
				t.Fatalf("decode expected response: %v", err)
			}
			if test.file == "invalid/duplicate-key" {
				// The frozen README and generated duplicate-key policy require null;
				// the older static fixture still contains the echoed ID.
				expectedValue.object["request_id"] = jsonValue{kind: jsonNull}
			}
			if !sameJSONValue(actualValue, expectedValue) {
				t.Fatalf("response mismatch\n got: %swant: %s", encoded, expectedResponse)
			}
		})
	}
}

func TestFrameBoundaries(t *testing.T) {
	base := []byte(`{"protocol_version":1}`)
	maximum := append(append([]byte{}, base...), bytes.Repeat([]byte{' '}, MaxFrameBytes-len(base)-1)...)
	maximum = append(maximum, '\n')
	frame, err := readFrame(bytes.NewReader(maximum))
	if err != nil {
		t.Fatalf("read maximum frame: %v", err)
	}
	if len(frame) != MaxFrameBytes {
		t.Fatalf("maximum frame length = %d", len(frame))
	}
	tooLarge := append(append([]byte{}, maximum[:len(maximum)-1]...), ' ', '\n')
	if _, err := readFrame(bytes.NewReader(tooLarge)); !errors.Is(err, errFrameTooLarge) {
		t.Fatalf("oversized frame error = %v", err)
	}
	if _, err := readFrame(bytes.NewReader(bytes.TrimSuffix(maximum, []byte{'\n'}))); !errors.Is(err, errFrameIncomplete) {
		t.Fatalf("incomplete frame error = %v", err)
	}
	if _, err := readFrame(bytes.NewReader(nil)); !errors.Is(err, errFrameIncomplete) {
		t.Fatalf("empty frame error = %v", err)
	}
	var output bytes.Buffer
	if err := writeFrame(&output, []byte("{}\n")); err != nil {
		t.Fatalf("write frame: %v", err)
	}
	if !bytes.Equal(output.Bytes(), []byte("{}\n")) {
		t.Fatalf("written frame = %q", output.Bytes())
	}
	if err := writeFrame(io.Discard, []byte("{}")); err == nil {
		t.Fatal("unterminated frame was written")
	}
}

func TestMaximumRequestRemainsValid(t *testing.T) {
	base := readFixture(t, "valid/health.request.jsonl")
	base = bytes.TrimSuffix(base, []byte{'\n'})
	frame := append(append([]byte{}, base...), bytes.Repeat([]byte{' '}, MaxFrameBytes-len(base)-1)...)
	frame = append(frame, '\n')
	request, response, err := ValidateRequest(frame, testInstanceID)
	if err != nil {
		t.Fatal(err)
	}
	if response.Error != nil || request.Method != MethodHealth || request.InstanceID != testInstanceID {
		t.Fatalf("maximum request = %#v, %#v", request, response)
	}
}

func sameJSONValue(left, right jsonValue) bool {
	if left.kind != right.kind || left.bool != right.bool || left.string != right.string || left.number.String() != right.number.String() || len(left.array) != len(right.array) || len(left.object) != len(right.object) {
		return false
	}
	for key, leftValue := range left.object {
		rightValue, ok := right.object[key]
		if !ok || !sameJSONValue(leftValue, rightValue) {
			return false
		}
	}
	for index := range left.array {
		if !sameJSONValue(left.array[index], right.array[index]) {
			return false
		}
	}
	return true
}

func TestDecodeRequestValidationPrecedence(t *testing.T) {
	valid := []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"health","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}}` + "\n")
	tests := []struct {
		name      string
		request   []byte
		code      string
		echo      bool
		requestID string
	}{
		{name: "duplicate nested", request: []byte(`{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"health","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"}}` + "\n"), code: ErrorInvalidEnvelope},
		{name: "wrong version type", request: bytes.Replace(valid, []byte(`"protocol_version":1`), []byte(`"protocol_version":1.0`), 1), code: ErrorUnsupportedVers, echo: true, requestID: "11111111-1111-4111-8111-111111111111"},
		{name: "wrong method type", request: bytes.Replace(valid, []byte(`"method":"health"`), []byte(`"method":true`), 1), code: ErrorInvalidEnvelope, echo: true, requestID: "11111111-1111-4111-8111-111111111111"},
		{name: "invalid UUID", request: bytes.Replace(valid, []byte(`"request_id":"11111111-1111-4111-8111-111111111111"`), []byte(`"request_id":"UPPERCASE"`), 1), code: ErrorInvalidEnvelope},
		{name: "invalid UTF-8", request: []byte{0xff, '\n'}, code: ErrorInvalidJSON},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, response, err := ValidateRequest(test.request, testInstanceID)
			if err != nil {
				t.Fatalf("validate: %v", err)
			}
			if response.Error == nil || response.Error.Code != test.code {
				t.Fatalf("error = %#v, want code %q", response.Error, test.code)
			}
			if test.echo != (response.RequestID != nil) {
				t.Fatalf("request ID echo = %v, want %v", response.RequestID != nil, test.echo)
			}
			if test.echo && *response.RequestID != test.requestID {
				t.Fatalf("request ID = %q, want %q", *response.RequestID, test.requestID)
			}
		})
	}
}

func TestDecodeResponseRejectsMutations(t *testing.T) {
	base := readFixture(t, "valid/health.response.jsonl")
	tests := []struct {
		name string
		body []byte
	}{
		{name: "unknown field", body: bytes.Replace(base, []byte(`,"error":null`), []byte(`,"error":null,"extra":true`), 1)},
		{name: "both values", body: bytes.Replace(base, []byte(`"error":null`), []byte(`"error":{"code":"internal","message":"x"}`), 1)},
		{name: "wrong state", body: bytes.Replace(base, []byte(`"state":"ready"`), []byte(`"state":"stopped"`), 1)},
		{name: "wrong request ID", body: bytes.Replace(base, []byte(`11111111-1111-4111-8111-111111111111`), []byte(`22222222-2222-4222-8222-222222222222`), 1)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if _, err := DecodeResponse(test.body, "11111111-1111-4111-8111-111111111111", string(MethodHealth), testInstanceID); err == nil {
				t.Fatal("mutated response was accepted")
			}
		})
	}
}

func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	path := filepath.Join("..", "..", "api", "protocol", "v1", name)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return data
}
