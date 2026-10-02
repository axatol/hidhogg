package ipc

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	appconfig "hidhogg/internal/config"
)

const editorTestDigest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func TestConfigEditorRequestsRoundTripWithExactShapes(t *testing.T) {
	tests := []struct {
		name    string
		method  Method
		request Request
		params  string
	}{
		{
			method:  MethodConfigEditorSnapshot,
			request: Request{ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorSnapshot, InstanceID: testInstanceID},
			params:  fmt.Sprintf(`{"instance_id":"%s"}`, testInstanceID),
		},
		{
			method: MethodConfigEditorProfileGet,
			request: Request{
				ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorProfileGet,
				InstanceID: testInstanceID, SourceDigest: editorTestDigest, ProfileID: "Work.Profile",
			},
			params: fmt.Sprintf(`{"instance_id":"%s","source_digest":"%s","profile_id":"Work.Profile"}`, testInstanceID, editorTestDigest),
		},
		{
			method: MethodConfigEditorPositionsList,
			request: Request{
				ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorPositionsList,
				InstanceID: testInstanceID, SourceDigest: editorTestDigest, ProfileID: "Work.Profile",
			},
			params: fmt.Sprintf(`{"instance_id":"%s","source_digest":"%s","profile_id":"Work.Profile"}`, testInstanceID, editorTestDigest),
		},
		{
			method: MethodConfigEditorPositionGet,
			request: Request{
				ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorPositionGet,
				InstanceID: testInstanceID, SourceDigest: editorTestDigest, ProfileID: "Work.Profile", PositionID: "0_0",
			},
			params: fmt.Sprintf(`{"instance_id":"%s","source_digest":"%s","profile_id":"Work.Profile","position_id":"0_0"}`, testInstanceID, editorTestDigest),
		},
		{
			method: MethodConfigEditorLabelSet,
			request: Request{
				ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorLabelSet,
				InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "Work.Profile", Label: "Work",
			},
			params: fmt.Sprintf(`{"instance_id":"%s","expected_digest":"%s","profile_id":"Work.Profile","label":"Work"}`, testInstanceID, editorTestDigest),
		},
		{
			method: MethodConfigEditorPositionLabelSet,
			request: Request{
				ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorPositionLabelSet,
				InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "Work.Profile", PositionID: "0_0", Label: "Work",
			},
			params: fmt.Sprintf(`{"instance_id":"%s","expected_digest":"%s","profile_id":"Work.Profile","position_id":"0_0","label":"Work"}`, testInstanceID, editorTestDigest),
		},
		{
			name:   "profile create defaults source at commit",
			method: MethodConfigEditorProfileCreate,
			request: Request{
				ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorProfileCreate,
				InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "Copy.Profile", Label: "Copy",
			},
			params: fmt.Sprintf(`{"instance_id":"%s","expected_digest":"%s","profile_id":"Copy.Profile","label":"Copy"}`, testInstanceID, editorTestDigest),
		},
		{
			name:   "profile create names source",
			method: MethodConfigEditorProfileCreate,
			request: Request{
				ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorProfileCreate,
				InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "Copy.Profile", Label: "Copy", SourceProfileID: "Work.Profile",
			},
			params: fmt.Sprintf(`{"instance_id":"%s","expected_digest":"%s","profile_id":"Copy.Profile","label":"Copy","source_profile_id":"Work.Profile"}`, testInstanceID, editorTestDigest),
		},
		{
			method: MethodConfigEditorProfileDelete,
			request: Request{
				ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorProfileDelete,
				InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "Work.Profile",
			},
			params: fmt.Sprintf(`{"instance_id":"%s","expected_digest":"%s","profile_id":"Work.Profile"}`, testInstanceID, editorTestDigest),
		},
	}
	for _, test := range tests {
		name := test.name
		if name == "" {
			name = string(test.method)
		}
		t.Run(name, func(t *testing.T) {
			frame, err := EncodeRequest(test.request)
			if err != nil {
				t.Fatalf("encode request: %v", err)
			}
			want := fmt.Sprintf(`{"protocol_version":1,"request_id":"%s","method":"%s","params":%s}`+"\n", configTestRequestID, test.method, test.params)
			if string(frame) != want {
				t.Fatalf("request = %q, want %q", frame, want)
			}
			decoded, failure, err := DecodeRequest(frame)
			if err != nil || failure.Error != nil || decoded != test.request {
				t.Fatalf("decoded request = %#v, failure = %#v, err = %v", decoded, failure, err)
			}
			if len(frame) > MaxFrameBytes {
				t.Fatalf("request frame length = %d, maximum = %d", len(frame), MaxFrameBytes)
			}
		})
	}
}

func TestConfigEditorRequestsRejectInvalidDigestsAndUnexpectedFields(t *testing.T) {
	validGet := fmt.Sprintf(`{"protocol_version":1,"request_id":"%s","method":"%s","params":{"instance_id":"%s","source_digest":"%s","profile_id":"profile"}}`+"\n", configTestRequestID, MethodConfigEditorProfileGet, testInstanceID, editorTestDigest)
	invalid := []struct {
		name string
		body string
	}{
		{name: "uppercase digest", body: strings.Replace(validGet, editorTestDigest, strings.ToUpper(editorTestDigest), 1)},
		{name: "short digest", body: strings.Replace(validGet, editorTestDigest, editorTestDigest[:63], 1)},
		{name: "extra path", body: strings.Replace(validGet, `"profile_id":"profile"`, `"profile_id":"profile","path":"/private/config.toml"`, 1)},
		{name: "duplicate digest", body: strings.Replace(validGet, `"profile_id":"profile"`, `"source_digest":"`+editorTestDigest+`","profile_id":"profile"`, 1)},
		{name: "invalid profile ID", body: strings.Replace(validGet, `"profile_id":"profile"`, `"profile_id":"bad id"`, 1)},
	}
	for _, test := range invalid {
		t.Run(test.name, func(t *testing.T) {
			_, failure, err := DecodeRequest([]byte(test.body))
			if err != nil || failure.Error == nil || failure.Error.Code != ErrorInvalidEnvelope {
				t.Fatalf("failure = %#v, err = %v", failure, err)
			}
		})
	}

	valid := Request{ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorLabelSet, InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "profile", Label: "New label"}
	if _, err := EncodeRequest(valid); err != nil {
		t.Fatalf("encode valid label request: %v", err)
	}
	valid.ExpectedDigest = strings.ToUpper(editorTestDigest)
	if _, err := EncodeRequest(valid); err == nil {
		t.Fatal("encoder accepted a non-lowercase source digest")
	}
	valid.ExpectedDigest = editorTestDigest
	valid.SourceDigest = editorTestDigest
	if _, err := EncodeRequest(valid); err == nil {
		t.Fatal("encoder accepted an unexpected digest field")
	}
}

func TestConfigEditorLifecycleRequestsRejectMalformedFields(t *testing.T) {
	validCreate := fmt.Sprintf(`{"protocol_version":1,"request_id":"%s","method":"%s","params":{"instance_id":"%s","expected_digest":"%s","profile_id":"copy","label":"Copy"}}`+"\n", configTestRequestID, MethodConfigEditorProfileCreate, testInstanceID, editorTestDigest)
	validCreateWithSource := strings.Replace(validCreate, `"label":"Copy"`, `"label":"Copy","source_profile_id":"source"`, 1)
	validDelete := fmt.Sprintf(`{"protocol_version":1,"request_id":"%s","method":"%s","params":{"instance_id":"%s","expected_digest":"%s","profile_id":"target"}}`+"\n", configTestRequestID, MethodConfigEditorProfileDelete, testInstanceID, editorTestDigest)
	invalid := []struct {
		name string
		body string
	}{
		{name: "create missing label", body: strings.Replace(validCreate, `,"label":"Copy"`, "", 1)},
		{name: "create extra field", body: strings.Replace(validCreate, `"label":"Copy"`, `"label":"Copy","path":"not-a-wire-field"`, 1)},
		{name: "create invalid digest", body: strings.Replace(validCreate, editorTestDigest, strings.ToUpper(editorTestDigest), 1)},
		{name: "create invalid new profile ID", body: strings.Replace(validCreate, `"profile_id":"copy"`, `"profile_id":"bad id"`, 1)},
		{name: "create invalid label", body: strings.Replace(validCreate, `"label":"Copy"`, `"label":""`, 1)},
		{name: "create explicit empty source profile ID", body: strings.Replace(validCreate, `"label":"Copy"`, `"label":"Copy","source_profile_id":""`, 1)},
		{name: "create invalid source profile ID", body: strings.Replace(validCreateWithSource, `"source_profile_id":"source"`, `"source_profile_id":"bad id"`, 1)},
		{name: "create source profile ID has wrong type", body: strings.Replace(validCreateWithSource, `"source_profile_id":"source"`, `"source_profile_id":false`, 1)},
		{name: "create duplicate source profile ID", body: strings.Replace(validCreateWithSource, `"source_profile_id":"source"`, `"source_profile_id":"source","source_profile_id":"other"`, 1)},
		{name: "delete missing target ID", body: strings.Replace(validDelete, `,"profile_id":"target"`, "", 1)},
		{name: "delete extra field", body: strings.Replace(validDelete, `"profile_id":"target"`, `"profile_id":"target","label":"Target"`, 1)},
		{name: "delete duplicate target ID", body: strings.Replace(validDelete, `"profile_id":"target"`, `"profile_id":"target","profile_id":"other"`, 1)},
		{name: "delete invalid target ID", body: strings.Replace(validDelete, `"profile_id":"target"`, `"profile_id":"bad id"`, 1)},
	}
	for _, test := range invalid {
		t.Run(test.name, func(t *testing.T) {
			_, failure, err := DecodeRequest([]byte(test.body))
			if err != nil || failure.Error == nil || failure.Error.Code != ErrorInvalidEnvelope {
				t.Fatalf("failure = %#v, err = %v", failure, err)
			}
			if failure.RequestID != nil && *failure.RequestID != configTestRequestID || failure.Error.Message != messageInvalidEnvelope {
				t.Fatalf("failure is not correlated with a path-free stable error: %#v", failure)
			}
		})
	}

	validCreateRequest := Request{
		ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorProfileCreate,
		InstanceID: testInstanceID, ExpectedDigest: editorTestDigest,
		ProfileID: strings.Repeat("p", 64), Label: strings.Repeat("L", 64), SourceProfileID: strings.Repeat("s", 64),
	}
	frame, err := EncodeRequest(validCreateRequest)
	if err != nil {
		t.Fatalf("encode largest valid lifecycle request: %v", err)
	}
	if len(frame) > MaxFrameBytes {
		t.Fatalf("largest valid lifecycle request is %d bytes, maximum is %d", len(frame), MaxFrameBytes)
	}
	for _, test := range []struct {
		name    string
		request Request
	}{
		{name: "invalid new profile ID", request: Request{ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorProfileCreate, InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "bad id", Label: "Copy"}},
		{name: "invalid source profile ID", request: Request{ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorProfileCreate, InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "copy", Label: "Copy", SourceProfileID: "bad id"}},
		{name: "invalid create label", request: Request{ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorProfileCreate, InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "copy", Label: "\n"}},
		{name: "delete cannot set label", request: Request{ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorProfileDelete, InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "target", Label: "Target"}},
		{name: "delete cannot set source ID", request: Request{ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorProfileDelete, InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "target", SourceProfileID: "source"}},
	} {
		t.Run("encode rejects "+test.name, func(t *testing.T) {
			if _, err := EncodeRequest(test.request); err == nil {
				t.Fatal("encoder accepted invalid lifecycle fields")
			}
		})
	}
}

func TestConfigEditorPositionRequestsRejectMalformedFields(t *testing.T) {
	valid := []Request{
		{ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorPositionsList, InstanceID: testInstanceID, SourceDigest: editorTestDigest, ProfileID: "work"},
		{ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorPositionGet, InstanceID: testInstanceID, SourceDigest: editorTestDigest, ProfileID: "work", PositionID: "0_0"},
		{ProtocolVersion: ProtocolVersion, RequestID: configTestRequestID, Method: MethodConfigEditorPositionLabelSet, InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "work", PositionID: "0_0", Label: "Clock"},
	}
	frames := make([]string, len(valid))
	for index, request := range valid {
		frame, err := EncodeRequest(request)
		if err != nil {
			t.Fatalf("encode valid %s request: %v", request.Method, err)
		}
		frames[index] = string(frame)
		decoded, failure, err := DecodeRequest(frame)
		if err != nil || failure.Error != nil || decoded != request {
			t.Fatalf("decode %s request = %#v, failure=%#v, err=%v", request.Method, decoded, failure, err)
		}
		if len(frame) > MaxFrameBytes {
			t.Fatalf("%s request is %d bytes, maximum is %d", request.Method, len(frame), MaxFrameBytes)
		}
	}

	invalid := []struct {
		name  string
		frame string
	}{
		{name: "list extra position ID", frame: strings.Replace(frames[0], `"profile_id":"work"`, `"profile_id":"work","position_id":"tile-0"`, 1)},
		{name: "get arbitrary position ID", frame: strings.Replace(frames[1], `"position_id":"0_0"`, `"position_id":"tile-0"`, 1)},
		{name: "get unsupported position ID", frame: strings.Replace(frames[1], `"position_id":"0_0"`, `"position_id":"5_2"`, 1)},
		{name: "get unexpected label", frame: strings.Replace(frames[1], `"position_id":"0_0"`, `"position_id":"0_0","label":"Clock"`, 1)},
		{name: "set duplicate position ID", frame: strings.Replace(frames[2], `"position_id":"0_0"`, `"position_id":"0_0","position_id":"1_0"`, 1)},
		{name: "set arbitrary position ID", frame: strings.Replace(frames[2], `"position_id":"0_0"`, `"position_id":"tile-0"`, 1)},
		{name: "set unsupported position ID", frame: strings.Replace(frames[2], `"position_id":"0_0"`, `"position_id":"5_2"`, 1)},
		{name: "set source digest field", frame: strings.Replace(frames[2], `"expected_digest":"`+editorTestDigest+`"`, `"expected_digest":"`+editorTestDigest+`","source_digest":"`+editorTestDigest+`"`, 1)},
	}
	for _, test := range invalid {
		t.Run(test.name, func(t *testing.T) {
			_, failure, err := DecodeRequest([]byte(test.frame))
			if err != nil || failure.Error == nil || failure.Error.Code != ErrorInvalidEnvelope || failure.Error.Message != messageInvalidEnvelope {
				t.Fatalf("failure = %#v, err = %v", failure, err)
			}
		})
	}

	invalidSet := valid[2]
	invalidSet.PositionID = "bad id"
	if _, err := EncodeRequest(invalidSet); err == nil {
		t.Fatal("encoder accepted an invalid position ID")
	}
	invalidSet.PositionID = "tile-0"
	if _, err := EncodeRequest(invalidSet); err == nil {
		t.Fatal("encoder accepted an arbitrary position ID")
	}
	invalidSet.PositionID = "5_2"
	if _, err := EncodeRequest(invalidSet); err == nil {
		t.Fatal("encoder accepted an unsupported position ID")
	}
	for _, positionID := range []string{"tile-0", "5_2"} {
		invalidGet := valid[1]
		invalidGet.PositionID = positionID
		if _, err := EncodeRequest(invalidGet); err == nil {
			t.Fatalf("encoder accepted invalid get position ID %q", positionID)
		}
	}
	invalidSet = valid[2]
	invalidSet.SourceDigest = editorTestDigest
	if _, err := EncodeRequest(invalidSet); err == nil {
		t.Fatal("encoder accepted an unexpected source digest field")
	}
}

func TestConfigEditorResponsesRoundTripAndStayBounded(t *testing.T) {
	profileIDs := make([]string, maxProfileSummaries)
	for index := range profileIDs {
		profileIDs[index] = fmt.Sprintf("profile-%02d", index)
	}
	responses := []struct {
		method Method
		result Result
		keys   []string
	}{
		{
			method: MethodConfigEditorSnapshot,
			result: Result{InstanceID: testInstanceID, EditorSnapshot: &ConfigEditorSnapshot{
				SourceDigest: editorTestDigest, Revision: 12, DefaultProfileID: profileIDs[0],
				CurrentProfileID: profileIDs[1], ProfileIDs: profileIDs,
			}},
			keys: []string{"instance_id", "source_digest", "revision", "default_profile_id", "current_profile_id", "profile_ids"},
		},
		{
			method: MethodConfigEditorProfileGet,
			result: Result{InstanceID: testInstanceID, EditorProfile: &ConfigEditorProfile{SourceDigest: editorTestDigest, ProfileID: "Work.Profile", Label: "Work"}},
			keys:   []string{"instance_id", "source_digest", "profile_id", "label"},
		},
		{
			method: MethodConfigEditorPositionsList,
			result: Result{InstanceID: testInstanceID, EditorPositions: &ConfigEditorPositions{
				SourceDigest: editorTestDigest, ProfileID: "Work.Profile", Positions: testEditorPositions(),
			}},
			keys: []string{"instance_id", "source_digest", "profile_id", "positions"},
		},
		{
			method: MethodConfigEditorPositionGet,
			result: Result{InstanceID: testInstanceID, EditorPositionLabel: &ConfigEditorPositionLabel{
				SourceDigest: editorTestDigest, ProfileID: "Work.Profile", PositionID: "0_0", Label: "Clock",
			}},
			keys: []string{"instance_id", "source_digest", "profile_id", "position_id", "label"},
		},
		{
			method: MethodConfigEditorLabelSet,
			result: Result{InstanceID: testInstanceID, EditorLabelResult: &ConfigEditorLabelResult{
				SourceDigest: editorTestDigest, FileCommit: EditorFileCommitCommitted, ReloadOutcome: EditorReloadChanged,
				Revision: 13, Effect: "catalog", Reason: "none",
			}},
			keys: []string{"instance_id", "source_digest", "file_commit", "reload_outcome", "revision", "effect", "reason"},
		},
		{
			method: MethodConfigEditorPositionLabelSet,
			result: Result{InstanceID: testInstanceID, EditorPositionLabelResult: &ConfigEditorPositionLabelResult{
				SourceDigest: editorTestDigest, FileCommit: EditorFileCommitCommitted, ReloadOutcome: EditorReloadChanged,
				Revision: 13, Effect: "display", Reason: "none",
			}},
			keys: []string{"instance_id", "source_digest", "file_commit", "reload_outcome", "revision", "effect", "reason"},
		},
		{
			method: MethodConfigEditorProfileCreate,
			result: Result{InstanceID: testInstanceID, EditorProfileCreateResult: &ConfigEditorMutationResult{
				SourceDigest: editorTestDigest, FileCommit: EditorFileCommitCommitted, ReloadOutcome: EditorReloadChanged,
				Revision: 13, Effect: "catalog", Reason: "none",
			}},
			keys: []string{"instance_id", "source_digest", "file_commit", "reload_outcome", "revision", "effect", "reason"},
		},
		{
			method: MethodConfigEditorProfileDelete,
			result: Result{InstanceID: testInstanceID, EditorProfileDeleteResult: &ConfigEditorMutationResult{
				SourceDigest: editorTestDigest, FileCommit: EditorFileCommitCommitted, ReloadOutcome: EditorReloadChanged,
				Revision: 13, Effect: "catalog", Reason: "none",
			}},
			keys: []string{"instance_id", "source_digest", "file_commit", "reload_outcome", "revision", "effect", "reason"},
		},
	}
	for _, test := range responses {
		t.Run(string(test.method), func(t *testing.T) {
			frame, err := EncodeResponse(Response{ProtocolVersion: ProtocolVersion, RequestID: stringPointer(configTestRequestID), Result: &test.result})
			if err != nil {
				t.Fatalf("encode response: %v", err)
			}
			if len(frame) > MaxFrameBytes {
				t.Fatalf("response frame length = %d, maximum = %d", len(frame), MaxFrameBytes)
			}
			assertObjectKeys(t, frame, "result", test.keys)
			if strings.Contains(string(frame), "config.toml") || strings.Contains(string(frame), "action") || strings.Contains(string(frame), "source_text") {
				t.Fatalf("editor response leaked forbidden configuration material: %s", frame)
			}
			decoded, err := DecodeResponse(frame, configTestRequestID, string(test.method), testInstanceID)
			if err != nil || decoded.Result == nil {
				t.Fatalf("decode response = %#v, %v", decoded, err)
			}
		})
	}
}

func TestConfigEditorPositionResponseDecoderRejectsMalformedShapes(t *testing.T) {
	validList := string(configEditorPositionsFrame(t))
	invalidLists := []struct {
		name string
		body string
	}{
		{name: "mismatched ID and coordinate", body: strings.Replace(validList, `"position_id":"0_0"`, `"position_id":"1_0"`, 1)},
		{name: "arbitrary stable ID", body: strings.Replace(validList, `"position_id":"0_0"`, `"position_id":"tile-0"`, 1)},
		{name: "duplicate position identity", body: strings.Replace(validList, `"position_id":"1_0","position":"1_0"`, `"position_id":"0_0","position":"0_0"`, 1)},
		{name: "unsupported coordinate", body: strings.Replace(validList, `"position_id":"0_0","position":"0_0"`, `"position_id":"9_9","position":"9_9"`, 1)},
		{name: "nested extra field", body: strings.Replace(validList, `"position":"0_0"`, `"position":"0_0","label":"full profile field"`, 1)},
	}
	for _, test := range invalidLists {
		t.Run(test.name, func(t *testing.T) {
			if _, err := DecodeResponse([]byte(test.body), configTestRequestID, string(MethodConfigEditorPositionsList), testInstanceID); err == nil {
				t.Fatal("malformed editor position list response was accepted")
			}
		})
	}

	validLabel := string(configEditorPositionLabelFrame(t))
	invalidLabels := []struct {
		name string
		body string
	}{
		{name: "extra source field", body: strings.Replace(validLabel, `"label":"Clock"`, `"label":"Clock","source_text":"not permitted"`, 1)},
		{name: "arbitrary position ID", body: strings.Replace(validLabel, `"position_id":"0_0"`, `"position_id":"tile-0"`, 1)},
		{name: "unsupported position ID", body: strings.Replace(validLabel, `"position_id":"0_0"`, `"position_id":"5_2"`, 1)},
		{name: "invalid label type", body: strings.Replace(validLabel, `"label":"Clock"`, `"label":false`, 1)},
	}
	for _, test := range invalidLabels {
		t.Run(test.name, func(t *testing.T) {
			if _, err := DecodeResponse([]byte(test.body), configTestRequestID, string(MethodConfigEditorPositionGet), testInstanceID); err == nil {
				t.Fatal("malformed editor position label response was accepted")
			}
		})
	}
}

func TestConfigEditorResponseDecoderRejectsMalformedShapes(t *testing.T) {
	valid := string(configEditorProfileFrame(t))
	invalid := []struct {
		name string
		body string
	}{
		{name: "extra path field", body: strings.Replace(valid, `"label":"Work"`, `"label":"Work","path":"/private/config.toml"`, 1)},
		{name: "duplicate digest", body: strings.Replace(valid, `"profile_id":"Work.Profile"`, `"source_digest":"`+editorTestDigest+`","profile_id":"Work.Profile"`, 1)},
		{name: "uppercase digest", body: strings.Replace(valid, editorTestDigest, strings.ToUpper(editorTestDigest), 1)},
		{name: "wrong label type", body: strings.Replace(valid, `"label":"Work"`, `"label":false`, 1)},
	}
	for _, test := range invalid {
		t.Run(test.name, func(t *testing.T) {
			if _, err := DecodeResponse([]byte(test.body), configTestRequestID, string(MethodConfigEditorProfileGet), testInstanceID); err == nil {
				t.Fatal("malformed editor profile response was accepted")
			}
		})
	}

	for _, method := range []Method{MethodConfigEditorProfileCreate, MethodConfigEditorProfileDelete} {
		t.Run(string(method), func(t *testing.T) {
			result := Result{InstanceID: testInstanceID}
			mutation := &ConfigEditorMutationResult{
				SourceDigest: editorTestDigest, FileCommit: EditorFileCommitCommitted, ReloadOutcome: EditorReloadChanged,
				Revision: 13, Effect: "catalog", Reason: "none",
			}
			if method == MethodConfigEditorProfileCreate {
				result.EditorProfileCreateResult = mutation
			} else {
				result.EditorProfileDeleteResult = mutation
			}
			frame, err := EncodeResponse(Response{ProtocolVersion: ProtocolVersion, RequestID: stringPointer(configTestRequestID), Result: &result})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := DecodeResponse(frame, "22222222-2222-4222-8222-222222222222", string(method), testInstanceID); err == nil {
				t.Fatal("mutation response accepted a different request ID")
			}
			if _, err := DecodeResponse(frame, configTestRequestID, string(method), "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"); err == nil {
				t.Fatal("mutation response accepted a different instance ID")
			}
			valid := string(frame)
			invalidMutation := []struct {
				name string
				body string
			}{
				{name: "extra field", body: strings.Replace(valid, `"reason":"none"`, `"reason":"none","profile_id":"unrequested"`, 1)},
				{name: "duplicate digest", body: strings.Replace(valid, `"file_commit":"committed"`, `"source_digest":"`+editorTestDigest+`","file_commit":"committed"`, 1)},
				{name: "invalid digest", body: strings.Replace(valid, editorTestDigest, strings.ToUpper(editorTestDigest), 1)},
				{name: "invalid file commit", body: strings.Replace(valid, `"file_commit":"committed"`, `"file_commit":"unknown"`, 1)},
				{name: "zero revision", body: strings.Replace(valid, `"revision":13`, `"revision":0`, 1)},
				{name: "missing reload outcome", body: strings.Replace(valid, `,"reload_outcome":"changed"`, "", 1)},
			}
			for _, test := range invalidMutation {
				t.Run(test.name, func(t *testing.T) {
					if _, err := DecodeResponse([]byte(test.body), configTestRequestID, string(method), testInstanceID); err == nil {
						t.Fatal("malformed editor mutation response was accepted")
					}
				})
			}
		})
	}

	tooManyIDs := make([]string, maxProfileSummaries+1)
	for index := range tooManyIDs {
		tooManyIDs[index] = fmt.Sprintf("profile-%02d", index)
	}
	response := Response{ProtocolVersion: ProtocolVersion, RequestID: stringPointer(configTestRequestID), Result: &Result{
		InstanceID: testInstanceID,
		EditorSnapshot: &ConfigEditorSnapshot{
			SourceDigest: editorTestDigest, Revision: 1, DefaultProfileID: tooManyIDs[0],
			CurrentProfileID: tooManyIDs[1], ProfileIDs: tooManyIDs,
		},
	}}
	if _, err := EncodeResponse(response); err == nil {
		t.Fatal("encoder accepted more than 31 profile IDs")
	}
}

func TestConfigEditorServerDispatchesNarrowServiceCalls(t *testing.T) {
	service := &configEditorTestService{
		snapshot:  ConfigEditorSnapshot{SourceDigest: editorTestDigest, Revision: 2, DefaultProfileID: "default", CurrentProfileID: "default", ProfileIDs: []string{"default", "work"}},
		positions: ConfigEditorPositions{SourceDigest: editorTestDigest, ProfileID: "work", Positions: testEditorPositions()},
		profile:   ConfigEditorProfile{SourceDigest: editorTestDigest, ProfileID: "work", Label: "Work"},
		positionLabel: ConfigEditorPositionLabel{
			SourceDigest: editorTestDigest, ProfileID: "work", PositionID: "0_0", Label: "Clock",
		},
		label:               ConfigEditorLabelResult{SourceDigest: editorTestDigest, FileCommit: EditorFileCommitCommitted, ReloadOutcome: EditorReloadChanged, Revision: 3, Effect: "catalog", Reason: "none"},
		positionLabelResult: ConfigEditorPositionLabelResult{SourceDigest: editorTestDigest, FileCommit: EditorFileCommitCommitted, ReloadOutcome: EditorReloadChanged, Revision: 6, Effect: "display", Reason: "none"},
		create:              ConfigEditorMutationResult{SourceDigest: editorTestDigest, FileCommit: EditorFileCommitCommitted, ReloadOutcome: EditorReloadChanged, Revision: 4, Effect: "catalog", Reason: "none"},
		delete:              ConfigEditorMutationResult{SourceDigest: editorTestDigest, FileCommit: EditorFileCommitCommitted, ReloadOutcome: EditorReloadChanged, Revision: 5, Effect: "catalog", Reason: "none"},
	}
	server := &Server{config: ServerConfig{ConfigEditorService: service}}

	snapshot := server.handleRequest(Request{RequestID: configTestRequestID, Method: MethodConfigEditorSnapshot, InstanceID: testInstanceID})
	if snapshot.Error != nil || snapshot.Result == nil || snapshot.Result.EditorSnapshot == nil || snapshot.Result.EditorSnapshot.SourceDigest != editorTestDigest {
		t.Fatalf("snapshot response = %#v", snapshot)
	}
	positions := server.handleRequest(Request{RequestID: configTestRequestID, Method: MethodConfigEditorPositionsList, InstanceID: testInstanceID, SourceDigest: editorTestDigest, ProfileID: "work"})
	if positions.Error != nil || positions.Result == nil || positions.Result.EditorPositions == nil || len(positions.Result.EditorPositions.Positions) != appconfig.RequiredPositionCount {
		t.Fatalf("positions response = %#v", positions)
	}
	profile := server.handleRequest(Request{RequestID: configTestRequestID, Method: MethodConfigEditorProfileGet, InstanceID: testInstanceID, SourceDigest: editorTestDigest, ProfileID: "work"})
	if profile.Error != nil || profile.Result == nil || profile.Result.EditorProfile == nil || profile.Result.EditorProfile.Label != "Work" {
		t.Fatalf("profile response = %#v", profile)
	}
	positionLabel := server.handleRequest(Request{RequestID: configTestRequestID, Method: MethodConfigEditorPositionGet, InstanceID: testInstanceID, SourceDigest: editorTestDigest, ProfileID: "work", PositionID: "0_0"})
	if positionLabel.Error != nil || positionLabel.Result == nil || positionLabel.Result.EditorPositionLabel == nil || positionLabel.Result.EditorPositionLabel.Label != "Clock" {
		t.Fatalf("position label response = %#v", positionLabel)
	}
	label := server.handleRequest(Request{RequestID: configTestRequestID, Method: MethodConfigEditorLabelSet, InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "work", Label: "Work"})
	if label.Error != nil || label.Result == nil || label.Result.EditorLabelResult == nil || label.Result.EditorLabelResult.ReloadOutcome != EditorReloadChanged {
		t.Fatalf("label response = %#v", label)
	}
	positionLabelSet := server.handleRequest(Request{RequestID: configTestRequestID, Method: MethodConfigEditorPositionLabelSet, InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "work", PositionID: "0_0", Label: "Clock"})
	if positionLabelSet.Error != nil || positionLabelSet.Result == nil || positionLabelSet.Result.EditorPositionLabelResult == nil || positionLabelSet.Result.EditorPositionLabelResult.Revision != 6 {
		t.Fatalf("position label set response = %#v", positionLabelSet)
	}
	if service.lastPositionID != "0_0" || service.lastLabel != "Clock" || service.positionsCalls != 1 || service.positionLabelCalls != 1 || service.positionLabelSetCalls != 1 {
		t.Fatalf("position service calls or arguments are invalid: %#v", service)
	}
	create := server.handleRequest(Request{RequestID: configTestRequestID, Method: MethodConfigEditorProfileCreate, InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "copy", Label: "Copy", SourceProfileID: "source"})
	if create.Error != nil || create.Result == nil || create.Result.EditorProfileCreateResult == nil || create.Result.EditorProfileCreateResult.Revision != 4 {
		t.Fatalf("profile create response = %#v", create)
	}
	if service.lastDigest != editorTestDigest || service.lastProfileID != "copy" || service.lastLabel != "Copy" || service.lastSourceProfileID != "source" {
		t.Fatalf("profile create service arguments are invalid: %#v", service)
	}
	createDefault := server.handleRequest(Request{RequestID: configTestRequestID, Method: MethodConfigEditorProfileCreate, InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "copy-current", Label: "Copy Current"})
	if createDefault.Error != nil || createDefault.Result == nil || createDefault.Result.EditorProfileCreateResult == nil || service.lastSourceProfileID != "" {
		t.Fatalf("profile create current-source response or arguments are invalid: %#v service=%#v", createDefault, service)
	}
	delete := server.handleRequest(Request{RequestID: configTestRequestID, Method: MethodConfigEditorProfileDelete, InstanceID: testInstanceID, ExpectedDigest: editorTestDigest, ProfileID: "work"})
	if delete.Error != nil || delete.Result == nil || delete.Result.EditorProfileDeleteResult == nil || delete.Result.EditorProfileDeleteResult.Revision != 5 {
		t.Fatalf("profile delete response = %#v", delete)
	}
	if service.lastDigest != editorTestDigest || service.lastProfileID != "work" {
		t.Fatalf("profile delete service arguments are invalid: %#v", service)
	}
	if service.snapshotCalls != 1 || service.profileCalls != 1 || service.labelCalls != 1 || service.createCalls != 2 || service.deleteCalls != 1 || service.lastDigest != editorTestDigest {
		t.Fatalf("service calls or arguments are invalid: %#v", service)
	}
	for _, response := range []Response{snapshot, positions, profile, positionLabel, label, positionLabelSet, create, createDefault, delete} {
		if _, err := EncodeResponse(response); err != nil {
			t.Fatalf("encode dispatched response: %v", err)
		}
	}
}

func TestConfigEditorServerRejectsProfileResultsThatDoNotMatchRequest(t *testing.T) {
	tests := []struct {
		name    string
		profile ConfigEditorProfile
	}{
		{name: "different source digest", profile: ConfigEditorProfile{SourceDigest: strings.Repeat("a", 64), ProfileID: "work", Label: "Work"}},
		{name: "different profile ID", profile: ConfigEditorProfile{SourceDigest: editorTestDigest, ProfileID: "other", Label: "Work"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := &Server{config: ServerConfig{ConfigEditorService: &configEditorTestService{profile: test.profile}}}
			response := server.handleRequest(Request{
				RequestID: configTestRequestID, Method: MethodConfigEditorProfileGet, InstanceID: testInstanceID,
				SourceDigest: editorTestDigest, ProfileID: "work",
			})
			if response.Result != nil || response.Error == nil || response.Error.Code != ErrorInternal {
				t.Fatalf("response = %#v, want fixed internal error", response)
			}
			if _, err := EncodeResponse(response); err != nil {
				t.Fatalf("encode response: %v", err)
			}
		})
	}
}

func TestConfigEditorServerRejectsPositionResultsThatDoNotMatchRequest(t *testing.T) {
	tests := []struct {
		name    string
		method  Method
		service *configEditorTestService
		request Request
	}{
		{
			name:   "positions from different profile",
			method: MethodConfigEditorPositionsList,
			service: &configEditorTestService{positions: ConfigEditorPositions{
				SourceDigest: editorTestDigest, ProfileID: "other", Positions: testEditorPositions(),
			}},
			request: Request{SourceDigest: editorTestDigest, ProfileID: "work"},
		},
		{
			name:   "position label for different ID",
			method: MethodConfigEditorPositionGet,
			service: &configEditorTestService{positionLabel: ConfigEditorPositionLabel{
				SourceDigest: editorTestDigest, ProfileID: "work", PositionID: "1_0", Label: "Clock",
			}},
			request: Request{SourceDigest: editorTestDigest, ProfileID: "work", PositionID: "0_0"},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := &Server{config: ServerConfig{ConfigEditorService: test.service}}
			request := test.request
			request.RequestID = configTestRequestID
			request.Method = test.method
			request.InstanceID = testInstanceID
			response := server.handleRequest(request)
			if response.Result != nil || response.Error == nil || response.Error.Code != ErrorInternal {
				t.Fatalf("response = %#v, want fixed internal error", response)
			}
			if _, err := EncodeResponse(response); err != nil {
				t.Fatalf("encode response: %v", err)
			}
		})
	}
}

func TestConfigEditorLifecycleClientWrappersCorrelateMutationResults(t *testing.T) {
	for _, method := range []Method{MethodConfigEditorProfileCreate, MethodConfigEditorProfileDelete} {
		t.Run(string(method), func(t *testing.T) {
			directory := shortTempDirectory(t)
			socketPath := filepath.Join(directory, "runtime.sock")
			listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socketPath, Net: "unix"})
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			if err := os.Chmod(socketPath, 0o600); err != nil {
				t.Fatal(err)
			}

			serverErr := make(chan error, 1)
			go func() {
				connection, err := listener.AcceptUnix()
				if err != nil {
					serverErr <- err
					return
				}
				defer connection.Close()
				requestFrame, err := readFrame(connection)
				if err != nil {
					serverErr <- err
					return
				}
				request, failure, err := DecodeRequest(requestFrame)
				if err != nil || failure.Error != nil || request.Method != method || request.ExpectedDigest != editorTestDigest {
					serverErr <- fmt.Errorf("decode client request: request=%#v failure=%#v err=%v", request, failure, err)
					return
				}
				if method == MethodConfigEditorProfileCreate {
					if request.ProfileID != "copy" || request.Label != "Copy" || request.SourceProfileID != "" {
						serverErr <- fmt.Errorf("create request fields are invalid: %#v", request)
						return
					}
				} else if request.ProfileID != "target" || request.Label != "" || request.SourceProfileID != "" {
					serverErr <- fmt.Errorf("delete request fields are invalid: %#v", request)
					return
				}

				result := Result{InstanceID: request.InstanceID}
				mutation := &ConfigEditorMutationResult{
					SourceDigest: editorTestDigest, FileCommit: EditorFileCommitCommitted, ReloadOutcome: EditorReloadChanged,
					Revision: 13, Effect: "catalog", Reason: "none",
				}
				if method == MethodConfigEditorProfileCreate {
					result.EditorProfileCreateResult = mutation
				} else {
					result.EditorProfileDeleteResult = mutation
				}
				responseFrame, err := EncodeResponse(Response{ProtocolVersion: ProtocolVersion, RequestID: stringPointer(request.RequestID), Result: &result})
				if err != nil {
					serverErr <- err
					return
				}
				serverErr <- writeFrame(connection, responseFrame)
			}()

			client, err := NewClient(ClientConfig{SocketPath: socketPath, PeerVerifier: func(net.Conn) error { return nil }})
			if err != nil {
				t.Fatal(err)
			}
			var response Response
			if method == MethodConfigEditorProfileCreate {
				response, err = client.CreateConfigEditorProfile(context.Background(), testInstanceID, editorTestDigest, "copy", "Copy", "")
			} else {
				response, err = client.DeleteConfigEditorProfile(context.Background(), testInstanceID, editorTestDigest, "target")
			}
			if err != nil || response.Result == nil {
				t.Fatalf("client response = %#v, err = %v", response, err)
			}
			if method == MethodConfigEditorProfileCreate && response.Result.EditorProfileCreateResult == nil || method == MethodConfigEditorProfileDelete && response.Result.EditorProfileDeleteResult == nil {
				t.Fatalf("client returned a result for the wrong lifecycle method: %#v", response.Result)
			}
			if err := <-serverErr; err != nil {
				t.Fatalf("fake peer: %v", err)
			}
		})
	}
}

func TestConfigEditorPositionClientWrappersUseNarrowContracts(t *testing.T) {
	service := &configEditorTestService{
		positions: ConfigEditorPositions{SourceDigest: editorTestDigest, ProfileID: "work", Positions: testEditorPositions()},
		positionLabel: ConfigEditorPositionLabel{
			SourceDigest: editorTestDigest, ProfileID: "work", PositionID: "0_0", Label: "Clock",
		},
		positionLabelResult: ConfigEditorPositionLabelResult{
			SourceDigest: editorTestDigest, FileCommit: EditorFileCommitCommitted, ReloadOutcome: EditorReloadChanged,
			Revision: 13, Effect: "display", Reason: "none",
		},
	}
	running := startGeneratedServer(t, ServerConfig{Deadlines: shortDeadlines(), ConfigEditorService: service})
	client, err := NewClient(ClientConfig{SocketPath: running.server.config.SocketPath, Deadlines: shortDeadlines()})
	if err != nil {
		t.Fatal(err)
	}

	positions, err := client.ListConfigEditorPositions(context.Background(), testInstanceID, editorTestDigest, "work")
	if err != nil || positions.Result == nil || positions.Result.EditorPositions == nil || len(positions.Result.EditorPositions.Positions) != appconfig.RequiredPositionCount {
		t.Fatalf("position list = %#v, err = %v", positions, err)
	}
	positionLabel, err := client.GetConfigEditorPositionLabel(context.Background(), testInstanceID, editorTestDigest, "work", "0_0")
	if err != nil || positionLabel.Result == nil || positionLabel.Result.EditorPositionLabel == nil || positionLabel.Result.EditorPositionLabel.Label != "Clock" {
		t.Fatalf("position label = %#v, err = %v", positionLabel, err)
	}
	mutation, err := client.SetConfigEditorPositionLabel(context.Background(), testInstanceID, editorTestDigest, "work", "0_0", "Renamed Clock")
	if err != nil || mutation.Result == nil || mutation.Result.EditorPositionLabelResult == nil || mutation.Result.EditorPositionLabelResult.FileCommit != EditorFileCommitCommitted {
		t.Fatalf("position label mutation = %#v, err = %v", mutation, err)
	}
	if service.positionsCalls != 1 || service.positionLabelCalls != 1 || service.positionLabelSetCalls != 1 || service.lastDigest != editorTestDigest || service.lastProfileID != "work" || service.lastPositionID != "0_0" || service.lastLabel != "Renamed Clock" {
		t.Fatalf("position service calls or arguments are invalid: %#v", service)
	}
}

func TestConfigEditorServerMapsStableErrorsWithoutRawDetails(t *testing.T) {
	tests := []struct {
		name   string
		err    error
		method Method
		code   string
	}{
		{name: "stale source", err: fmt.Errorf("source /private/config.toml changed: %w", ErrStaleSource), method: MethodConfigEditorProfileGet, code: ErrorStaleSource},
		{name: "invalid edit", err: fmt.Errorf("typed label detail: %w", ErrEditInvalid), method: MethodConfigEditorLabelSet, code: ErrorEditInvalid},
		{name: "commit", err: fmt.Errorf("file detail: %w", ErrFileCommitFailed), method: MethodConfigEditorLabelSet, code: ErrorFileCommitFailed},
		{name: "create invalid", err: fmt.Errorf("typed create detail: %w", ErrEditInvalid), method: MethodConfigEditorProfileCreate, code: ErrorEditInvalid},
		{name: "delete stale source", err: fmt.Errorf("source detail: %w", ErrStaleSource), method: MethodConfigEditorProfileDelete, code: ErrorStaleSource},
		{name: "busy", err: fmt.Errorf("gate detail: %w", ErrBusy), method: MethodConfigEditorSnapshot, code: ErrorBusy},
		{name: "shutdown", err: fmt.Errorf("closed detail: %w", ErrShuttingDown), method: MethodConfigEditorSnapshot, code: ErrorShuttingDown},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			service := &configEditorTestService{snapshotErr: test.err, profileErr: test.err, labelErr: test.err, createErr: test.err, deleteErr: test.err}
			server := &Server{config: ServerConfig{ConfigEditorService: service}}
			response := server.handleRequest(Request{RequestID: configTestRequestID, Method: test.method, InstanceID: testInstanceID, SourceDigest: editorTestDigest, ExpectedDigest: editorTestDigest, ProfileID: "work", Label: "Work"})
			if response.Result != nil || response.Error == nil || response.Error.Code != test.code {
				t.Fatalf("response = %#v, want code %q", response, test.code)
			}
			if strings.Contains(response.Error.Message, "private") || strings.Contains(response.Error.Message, "detail") || strings.Contains(response.Error.Message, "label") {
				t.Fatalf("raw service error leaked: %#v", response.Error)
			}
			if _, err := EncodeResponse(response); err != nil {
				t.Fatalf("encode error response: %v", err)
			}
		})
	}
}

func configEditorProfileFrame(t *testing.T) []byte {
	t.Helper()
	frame, err := EncodeResponse(Response{
		ProtocolVersion: ProtocolVersion,
		RequestID:       stringPointer(configTestRequestID),
		Result: &Result{InstanceID: testInstanceID, EditorProfile: &ConfigEditorProfile{
			SourceDigest: editorTestDigest, ProfileID: "Work.Profile", Label: "Work",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	return frame
}

func configEditorPositionsFrame(t *testing.T) []byte {
	t.Helper()
	frame, err := EncodeResponse(Response{
		ProtocolVersion: ProtocolVersion,
		RequestID:       stringPointer(configTestRequestID),
		Result: &Result{InstanceID: testInstanceID, EditorPositions: &ConfigEditorPositions{
			SourceDigest: editorTestDigest, ProfileID: "work", Positions: testEditorPositions(),
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	return frame
}

func configEditorPositionLabelFrame(t *testing.T) []byte {
	t.Helper()
	frame, err := EncodeResponse(Response{
		ProtocolVersion: ProtocolVersion,
		RequestID:       stringPointer(configTestRequestID),
		Result: &Result{InstanceID: testInstanceID, EditorPositionLabel: &ConfigEditorPositionLabel{
			SourceDigest: editorTestDigest, ProfileID: "work", PositionID: "0_0", Label: "Clock",
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	return frame
}

type configEditorTestService struct {
	snapshot              ConfigEditorSnapshot
	positions             ConfigEditorPositions
	profile               ConfigEditorProfile
	positionLabel         ConfigEditorPositionLabel
	label                 ConfigEditorLabelResult
	positionLabelResult   ConfigEditorPositionLabelResult
	create                ConfigEditorMutationResult
	delete                ConfigEditorMutationResult
	snapshotErr           error
	positionsErr          error
	profileErr            error
	positionLabelErr      error
	labelErr              error
	positionLabelSetErr   error
	createErr             error
	deleteErr             error
	snapshotCalls         int
	positionsCalls        int
	profileCalls          int
	positionLabelCalls    int
	labelCalls            int
	positionLabelSetCalls int
	createCalls           int
	deleteCalls           int
	lastDigest            string
	lastProfileID         string
	lastPositionID        string
	lastSourceProfileID   string
	lastLabel             string
}

func (service *configEditorTestService) Snapshot(context.Context) (ConfigEditorSnapshot, error) {
	service.snapshotCalls++
	return service.snapshot, service.snapshotErr
}

func (service *configEditorTestService) ListPositions(_ context.Context, digest, profileID string) (ConfigEditorPositions, error) {
	service.positionsCalls++
	service.lastDigest = digest
	service.lastProfileID = profileID
	return service.positions, service.positionsErr
}

func (service *configEditorTestService) GetProfile(_ context.Context, digest, profileID string) (ConfigEditorProfile, error) {
	service.profileCalls++
	service.lastDigest = digest
	service.lastProfileID = profileID
	return service.profile, service.profileErr
}

func (service *configEditorTestService) GetPositionLabel(_ context.Context, digest, profileID, positionID string) (ConfigEditorPositionLabel, error) {
	service.positionLabelCalls++
	service.lastDigest = digest
	service.lastProfileID = profileID
	service.lastPositionID = positionID
	return service.positionLabel, service.positionLabelErr
}

func (service *configEditorTestService) SetProfileLabel(_ context.Context, digest, profileID, label string) (ConfigEditorLabelResult, error) {
	service.labelCalls++
	service.lastDigest = digest
	service.lastProfileID = profileID
	service.lastLabel = label
	return service.label, service.labelErr
}

func (service *configEditorTestService) SetPositionLabel(_ context.Context, digest, profileID, positionID, label string) (ConfigEditorPositionLabelResult, error) {
	service.positionLabelSetCalls++
	service.lastDigest = digest
	service.lastProfileID = profileID
	service.lastPositionID = positionID
	service.lastLabel = label
	return service.positionLabelResult, service.positionLabelSetErr
}

func (service *configEditorTestService) CreateProfile(_ context.Context, digest, sourceID, profileID, label string) (ConfigEditorMutationResult, error) {
	service.createCalls++
	service.lastDigest = digest
	service.lastSourceProfileID = sourceID
	service.lastProfileID = profileID
	service.lastLabel = label
	return service.create, service.createErr
}

func (service *configEditorTestService) DeleteProfile(_ context.Context, digest, profileID string) (ConfigEditorMutationResult, error) {
	service.deleteCalls++
	service.lastDigest = digest
	service.lastProfileID = profileID
	return service.delete, service.deleteErr
}

var _ ConfigEditorService = (*configEditorTestService)(nil)

func TestConfigEditorMutationReplyOutlivesInitialReadDeadline(t *testing.T) {
	const readDeadline = 80 * time.Millisecond
	const serviceDelay = 240 * time.Millisecond
	service := newConfigEditorDisconnectTestService(serviceDelay)
	running := startGeneratedServer(t, ServerConfig{
		Deadlines:           Deadlines{Read: readDeadline, Write: time.Second},
		ConfigEditorService: service,
	})
	connection := dialRaw(t, running.server.config.SocketPath)
	defer connection.Close()

	request := configEditorMutationRequest(MethodConfigEditorLabelSet)
	frame, err := EncodeRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	started := time.Now()
	writeAll(t, connection, frame)
	select {
	case method := <-service.started:
		if method != request.Method {
			t.Fatalf("service method = %q, want %q", method, request.Method)
		}
	case <-time.After(time.Second):
		t.Fatal("mutation service did not start")
	}

	responseFrame := readResponseFrame(t, connection)
	if elapsed := time.Since(started); elapsed < serviceDelay {
		t.Fatalf("response arrived after %s, before the %s service delay completed", elapsed, serviceDelay)
	}
	response, err := DecodeResponse(responseFrame, request.RequestID, string(request.Method), request.InstanceID)
	if err != nil || response.Result == nil || response.Result.EditorLabelResult == nil {
		t.Fatalf("decoded response = %#v, err = %v", response, err)
	}
}

func TestConfigEditorMutationDisconnectCancelsWaitingService(t *testing.T) {
	methods := []Method{
		MethodConfigEditorLabelSet,
		MethodConfigEditorPositionLabelSet,
		MethodConfigEditorProfileCreate,
		MethodConfigEditorProfileDelete,
	}
	for _, method := range methods {
		t.Run(string(method), func(t *testing.T) {
			service := newConfigEditorDisconnectTestService(0)
			running := startGeneratedServer(t, ServerConfig{
				Deadlines:           Deadlines{Read: time.Second, Write: time.Second},
				ConfigEditorService: service,
			})
			connection := dialRaw(t, running.server.config.SocketPath)
			request := configEditorMutationRequest(method)
			frame, err := EncodeRequest(request)
			if err != nil {
				t.Fatal(err)
			}
			writeAll(t, connection, frame)
			select {
			case startedMethod := <-service.started:
				if startedMethod != method {
					t.Fatalf("service method = %q, want %q", startedMethod, method)
				}
			case <-time.After(time.Second):
				t.Fatal("mutation service did not start")
			}
			if err := connection.Close(); err != nil {
				t.Fatalf("close client connection: %v", err)
			}
			select {
			case canceledMethod := <-service.canceled:
				if canceledMethod != method {
					t.Fatalf("canceled service method = %q, want %q", canceledMethod, method)
				}
			case <-time.After(time.Second):
				t.Fatal("full connection close did not cancel the waiting mutation")
			}
		})
	}
}

func TestConfigEditorMutationCloseWriteCancelsWaitingService(t *testing.T) {
	service := newConfigEditorDisconnectTestService(0)
	running := startGeneratedServer(t, ServerConfig{
		Deadlines:           Deadlines{Read: time.Second, Write: time.Second},
		ConfigEditorService: service,
	})
	connection := dialRaw(t, running.server.config.SocketPath)
	defer connection.Close()

	request := configEditorMutationRequest(MethodConfigEditorProfileCreate)
	frame, err := EncodeRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	writeAll(t, connection, frame)
	select {
	case <-service.started:
	case <-time.After(time.Second):
		t.Fatal("mutation service did not start")
	}

	unixConnection, ok := connection.(*net.UnixConn)
	if !ok {
		t.Fatalf("dial returned %T, want *net.UnixConn", connection)
	}
	if err := unixConnection.CloseWrite(); err != nil {
		t.Fatalf("half-close client write side: %v", err)
	}
	select {
	case <-service.canceled:
	case <-time.After(time.Second):
		t.Fatal("CloseWrite did not cancel the mutation; half-close is unsupported")
	}

	responseFrame := readResponseFrame(t, connection)
	response, err := DecodeResponse(responseFrame, request.RequestID, string(request.Method), request.InstanceID)
	if err != nil || response.Error == nil || response.Error.Code != ErrorShuttingDown {
		t.Fatalf("response = %#v, err = %v, want stable cancellation error", response, err)
	}
}

type configEditorDisconnectTestService struct {
	delay    time.Duration
	started  chan Method
	canceled chan Method
}

func newConfigEditorDisconnectTestService(delay time.Duration) *configEditorDisconnectTestService {
	return &configEditorDisconnectTestService{
		delay:    delay,
		started:  make(chan Method, 1),
		canceled: make(chan Method, 1),
	}
}

func (service *configEditorDisconnectTestService) Snapshot(context.Context) (ConfigEditorSnapshot, error) {
	return ConfigEditorSnapshot{}, nil
}

func (service *configEditorDisconnectTestService) ListPositions(context.Context, string, string) (ConfigEditorPositions, error) {
	return ConfigEditorPositions{}, nil
}

func (service *configEditorDisconnectTestService) GetProfile(context.Context, string, string) (ConfigEditorProfile, error) {
	return ConfigEditorProfile{}, nil
}

func (service *configEditorDisconnectTestService) GetPositionLabel(context.Context, string, string, string) (ConfigEditorPositionLabel, error) {
	return ConfigEditorPositionLabel{}, nil
}

func (service *configEditorDisconnectTestService) SetProfileLabel(ctx context.Context, _, _, _ string) (ConfigEditorLabelResult, error) {
	result, err := service.wait(ctx, MethodConfigEditorLabelSet)
	return ConfigEditorLabelResult(result), err
}

func (service *configEditorDisconnectTestService) SetPositionLabel(ctx context.Context, _, _, _, _ string) (ConfigEditorPositionLabelResult, error) {
	result, err := service.wait(ctx, MethodConfigEditorPositionLabelSet)
	return ConfigEditorPositionLabelResult(result), err
}

func (service *configEditorDisconnectTestService) CreateProfile(ctx context.Context, _, _, _, _ string) (ConfigEditorMutationResult, error) {
	return service.wait(ctx, MethodConfigEditorProfileCreate)
}

func (service *configEditorDisconnectTestService) DeleteProfile(ctx context.Context, _, _ string) (ConfigEditorMutationResult, error) {
	return service.wait(ctx, MethodConfigEditorProfileDelete)
}

func (service *configEditorDisconnectTestService) wait(ctx context.Context, method Method) (ConfigEditorMutationResult, error) {
	service.started <- method
	if service.delay <= 0 {
		<-ctx.Done()
		service.canceled <- method
		return ConfigEditorMutationResult{}, ctx.Err()
	}
	timer := time.NewTimer(service.delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		service.canceled <- method
		return ConfigEditorMutationResult{}, ctx.Err()
	case <-timer.C:
		return ConfigEditorMutationResult{
			SourceDigest: editorTestDigest, FileCommit: EditorFileCommitCommitted, ReloadOutcome: EditorReloadChanged,
			Revision: 13, Effect: "catalog", Reason: "none",
		}, nil
	}
}

func configEditorMutationRequest(method Method) Request {
	request := Request{
		ProtocolVersion: ProtocolVersion,
		RequestID:       configTestRequestID,
		Method:          method,
		InstanceID:      testInstanceID,
		ExpectedDigest:  editorTestDigest,
	}
	switch method {
	case MethodConfigEditorLabelSet:
		request.ProfileID = "work"
		request.Label = "Work"
	case MethodConfigEditorPositionLabelSet:
		request.ProfileID = "work"
		request.PositionID = "0_0"
		request.Label = "Work"
	case MethodConfigEditorProfileCreate:
		request.ProfileID = "copy"
		request.Label = "Copy"
	case MethodConfigEditorProfileDelete:
		request.ProfileID = "work"
	}
	return request
}

func testEditorPositions() []ConfigEditorPosition {
	supported := appconfig.SupportedPositions()
	positions := make([]ConfigEditorPosition, len(supported))
	for index, spec := range supported {
		positions[index] = ConfigEditorPosition{ID: spec.Name, Position: spec.Name}
	}
	return positions
}

func TestConfigEditorErrorClassifierKeepsUnknownFailuresInternal(t *testing.T) {
	if code, message := classifyConfigEditorError(errors.New("untrusted filesystem path /private/config.toml")); code != ErrorInternal || message != messageInternal {
		t.Fatalf("classification = %q/%q, want path-free internal error", code, message)
	}
}

func TestConfigEditorClientRejectsProfileResponseThatDoesNotMatchRequest(t *testing.T) {
	tests := []struct {
		name    string
		profile ConfigEditorProfile
	}{
		{name: "different source digest", profile: ConfigEditorProfile{SourceDigest: strings.Repeat("a", 64), ProfileID: "work", Label: "Work"}},
		{name: "different profile ID", profile: ConfigEditorProfile{SourceDigest: editorTestDigest, ProfileID: "other", Label: "Work"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response := Response{Result: &Result{EditorProfile: &test.profile}}
			if err := validateConfigEditorProfileResponse(response, editorTestDigest, "work"); err == nil {
				t.Fatal("client accepted editor profile data for another request")
			}
		})
	}
	if err := validateConfigEditorProfileResponse(Response{Error: &Error{Code: ErrorStaleSource, Message: messageStaleSource}}, editorTestDigest, "work"); err != nil {
		t.Fatalf("client rejected a stable service error response: %v", err)
	}
}

func TestConfigEditorClientWrapperRejectsWrongProfileResponse(t *testing.T) {
	tests := []struct {
		name    string
		profile ConfigEditorProfile
	}{
		{name: "different source digest", profile: ConfigEditorProfile{SourceDigest: strings.Repeat("a", 64), ProfileID: "work", Label: "Work"}},
		{name: "different profile ID", profile: ConfigEditorProfile{SourceDigest: editorTestDigest, ProfileID: "other", Label: "Work"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			directory := shortTempDirectory(t)
			socketPath := filepath.Join(directory, "runtime.sock")
			listener, err := net.ListenUnix("unix", &net.UnixAddr{Name: socketPath, Net: "unix"})
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()
			if err := os.Chmod(socketPath, 0o600); err != nil {
				t.Fatal(err)
			}

			serverErr := make(chan error, 1)
			go func() {
				connection, err := listener.AcceptUnix()
				if err != nil {
					serverErr <- err
					return
				}
				defer connection.Close()
				requestFrame, err := readFrame(connection)
				if err != nil {
					serverErr <- err
					return
				}
				request, failure, err := DecodeRequest(requestFrame)
				if err != nil || failure.Error != nil {
					serverErr <- fmt.Errorf("decode client request: failure=%#v err=%v", failure, err)
					return
				}
				requestID := request.RequestID
				responseFrame, err := EncodeResponse(Response{
					ProtocolVersion: ProtocolVersion,
					RequestID:       &requestID,
					Result: &Result{
						InstanceID: request.InstanceID,
						EditorProfile: &ConfigEditorProfile{
							SourceDigest: test.profile.SourceDigest, ProfileID: test.profile.ProfileID, Label: test.profile.Label,
						},
					},
				})
				if err != nil {
					serverErr <- err
					return
				}
				serverErr <- writeFrame(connection, responseFrame)
			}()

			client, err := NewClient(ClientConfig{SocketPath: socketPath, PeerVerifier: func(net.Conn) error { return nil }})
			if err != nil {
				t.Fatal(err)
			}
			response, err := client.GetConfigEditorProfile(context.Background(), testInstanceID, editorTestDigest, "work")
			if err == nil || response.Result != nil {
				t.Fatalf("client accepted mismatched profile response: response=%#v err=%v", response, err)
			}
			if serverErr := <-serverErr; serverErr != nil {
				t.Fatalf("fake peer: %v", serverErr)
			}
		})
	}
}
