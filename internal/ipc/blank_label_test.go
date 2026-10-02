package ipc

import (
	"bytes"
	"testing"
)

func TestBlankPositionLabelRequestRoundTrip(t *testing.T) {
	request := Request{
		ProtocolVersion: ProtocolVersion,
		RequestID:       configTestRequestID,
		InstanceID:      testInstanceID,
		Method:          MethodConfigEditorPositionLabelSet,
		ExpectedDigest:  editorTestDigest,
		ProfileID:       "work",
		PositionID:      "0_0",
		Label:           "",
	}
	frame, err := EncodeRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(frame, []byte(`"label":""`)) {
		t.Fatalf("blank label was omitted from request: %s", frame)
	}
	decoded, failure, err := DecodeRequest(frame)
	if err != nil || failure.Error != nil || decoded.Label != "" {
		t.Fatalf("blank label decode = %+v, failure=%+v, err=%v", decoded, failure, err)
	}
	for _, invalid := range []string{" ", "\n", "\u200b"} {
		request.Label = invalid
		if _, err := EncodeRequest(request); err == nil {
			t.Fatalf("invalid nonempty tile label %q was accepted", invalid)
		}
	}
	request.Method = MethodConfigEditorLabelSet
	request.PositionID = ""
	request.Label = ""
	if _, err := EncodeRequest(request); err == nil {
		t.Fatal("empty profile label was accepted")
	}
}

func TestBlankPositionLabelResponseRoundTrip(t *testing.T) {
	response := Response{
		ProtocolVersion: ProtocolVersion,
		RequestID:       stringPointer(configTestRequestID),
		Result: &Result{
			InstanceID: testInstanceID,
			EditorPositionLabel: &ConfigEditorPositionLabel{
				SourceDigest: editorTestDigest,
				ProfileID:    "work",
				PositionID:   "0_0",
				Label:        "",
			},
		},
	}
	frame, err := EncodeResponse(response)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeResponse(frame, configTestRequestID, string(MethodConfigEditorPositionGet), testInstanceID)
	if err != nil || decoded.Result == nil || decoded.Result.EditorPositionLabel == nil || decoded.Result.EditorPositionLabel.Label != "" {
		t.Fatalf("blank response decode = %+v, err=%v", decoded, err)
	}
}
