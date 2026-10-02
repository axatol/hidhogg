package ipc

import (
	"context"
	"strings"
	"testing"
)

func TestDisplayHostStateProtocolIsExactAndCorrelated(t *testing.T) {
	request := Request{
		ProtocolVersion: ProtocolVersion,
		RequestID:       "11111111-1111-4111-8111-111111111111",
		Method:          MethodDisplayHostStateSet,
		InstanceID:      testInstanceID,
		DisplayAwake:    false,
	}
	encoded, err := EncodeRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","method":"display.host_state.set","params":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","display_awake":false}}` + "\n"
	if string(encoded) != want {
		t.Fatalf("encoded request = %s, want %s", encoded, want)
	}
	decoded, failure, err := ValidateRequest(encoded, testInstanceID)
	if err != nil || failure.Error != nil || decoded.DisplayAwake {
		t.Fatalf("decoded request = %+v failure=%+v err=%v", decoded, failure, err)
	}

	extra := strings.Replace(string(encoded), `"display_awake":false`, `"display_awake":false,"extra":true`, 1)
	_, failure, err = ValidateRequest([]byte(extra), testInstanceID)
	if err != nil || failure.Error == nil || failure.Error.Code != ErrorInvalidEnvelope {
		t.Fatalf("extra-field failure = %+v err=%v", failure, err)
	}
	_, mismatch, err := ValidateRequest(encoded, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
	if err != nil || mismatch.Error == nil || mismatch.Error.Code != ErrorInstanceMismatch {
		t.Fatalf("generation mismatch = %+v err=%v", mismatch, err)
	}
}

func TestDisplayHostStateServerResultIsExact(t *testing.T) {
	service := &displayHostStateTestService{}
	server := &Server{config: ServerConfig{DisplayHostState: service}}
	request := Request{
		ProtocolVersion: ProtocolVersion,
		RequestID:       "11111111-1111-4111-8111-111111111111",
		Method:          MethodDisplayHostStateSet,
		InstanceID:      testInstanceID,
		DisplayAwake:    true,
	}
	response := server.handleRequest(request)
	if response.Error != nil || response.Result == nil || !response.Result.DisplayAwake || !response.Result.Changed {
		t.Fatalf("response = %+v", response)
	}
	encoded, err := EncodeResponse(response)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"protocol_version":1,"request_id":"11111111-1111-4111-8111-111111111111","result":{"instance_id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","changed":true,"display_awake":true},"error":null}` + "\n"
	if string(encoded) != want {
		t.Fatalf("encoded response = %s, want %s", encoded, want)
	}
	decoded, err := DecodeResponse(encoded, request.RequestID, string(request.Method), request.InstanceID)
	if err != nil || decoded.Result == nil || !decoded.Result.DisplayAwake || !decoded.Result.Changed {
		t.Fatalf("decoded response = %+v err=%v", decoded, err)
	}
	if _, err := DecodeResponse(encoded, request.RequestID, string(request.Method), "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"); err == nil {
		t.Fatal("response from stale generation was accepted")
	}
}

type displayHostStateTestService struct{}

func (*displayHostStateTestService) SetDisplayHostState(_ context.Context, displayAwake bool) (DisplayHostStateResult, error) {
	return DisplayHostStateResult{InstanceID: testInstanceID, DisplayAwake: displayAwake, Changed: true}, nil
}
