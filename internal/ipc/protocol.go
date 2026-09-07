package ipc

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"unicode"
	"unicode/utf8"
)

const (
	ProtocolVersion     = 1
	MaxFrameBytes       = 16 * 1024
	ReadyState          = "ready"
	maxProfileSummaries = 31
)

type Method string

const (
	MethodHealth           Method = "health"
	MethodStatus           Method = "status"
	MethodProfilesList     Method = "profiles.list"
	MethodProfilesActivate Method = "profiles.activate"
)

type Request struct {
	ProtocolVersion int    `json:"protocol_version"`
	RequestID       string `json:"request_id"`
	Method          Method `json:"method"`
	InstanceID      string `json:"instance_id"`
	ProfileID       string `json:"profile_id,omitempty"`
}

// ProfileSummary is the intentionally narrow profile discovery shape. Layout
// values and actions remain runtime-owned and are never placed on the wire.
type ProfileSummary struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	IsDefault bool   `json:"is_default"`
	IsCurrent bool   `json:"is_current"`
}

// ActivationResult reports the profile committed by an activation request.
type ActivationResult struct {
	ProfileID string `json:"profile_id"`
	Changed   bool   `json:"changed"`
}

type Result struct {
	InstanceID      string           `json:"instance_id"`
	State           string           `json:"state"`
	ProtocolVersion *int             `json:"protocol_version,omitempty"`
	Profiles        []ProfileSummary `json:"profiles,omitempty"`
	ProfileID       string           `json:"profile_id,omitempty"`
	Changed         bool             `json:"changed,omitempty"`
}

type Error struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type Response struct {
	ProtocolVersion int     `json:"protocol_version"`
	RequestID       *string `json:"request_id"`
	Result          *Result `json:"result"`
	Error           *Error  `json:"error"`
}

const (
	ErrorInvalidJSON        = "invalid_json"
	ErrorInvalidEnvelope    = "invalid_envelope"
	ErrorUnsupportedVers    = "unsupported_version"
	ErrorUnsupportedVersion = ErrorUnsupportedVers
	ErrorUnknownMethod      = "unknown_method"
	ErrorInstanceMismatch   = "instance_mismatch"
	ErrorMessageTooLarge    = "message_too_large"
	ErrorInternal           = "internal"
	ErrorProfileNotFound    = "profile_not_found"
	ErrorActivationFailed   = "activation_failed"
	ErrorDeviceWriteFailed  = "device_write_failed"
	ErrorShuttingDown       = "shutting_down"
	ErrorBusy               = "busy"
)

var stableErrorCodes = map[string]struct{}{
	ErrorInvalidJSON:       {},
	ErrorInvalidEnvelope:   {},
	ErrorUnsupportedVers:   {},
	ErrorUnknownMethod:     {},
	ErrorInstanceMismatch:  {},
	ErrorMessageTooLarge:   {},
	ErrorInternal:          {},
	ErrorProfileNotFound:   {},
	ErrorActivationFailed:  {},
	ErrorDeviceWriteFailed: {},
	ErrorShuttingDown:      {},
	ErrorBusy:              {},
}

const (
	messageInvalidJSON       = "request is not valid JSON"
	messageInvalidEnvelope   = "request envelope is invalid"
	messageUnsupportedVers   = "protocol version is not supported"
	messageUnknownMethod     = "request method is not supported"
	messageInstanceMismatch  = "runtime instance does not match"
	messageMessageTooLarge   = "request message is too large"
	messageInternal          = "internal server error"
	messageProfileNotFound   = "requested profile does not exist"
	messageActivationFailed  = "profile activation failed"
	messageDeviceWriteFailed = "device write failed"
	messageShuttingDown      = "runtime is shutting down"
	messageBusy              = "runtime is busy"
)

var (
	ErrProfileNotFound   = errors.New("profile not found")
	ErrActivationFailed  = errors.New("profile activation failed")
	ErrDeviceWriteFailed = errors.New("device write failed")
	ErrShuttingDown      = errors.New("runtime is shutting down")
	ErrBusy              = errors.New("runtime is busy")
)

var profileIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

func decodeProfileSummary(value jsonValue) (ProfileSummary, error) {
	if value.kind != jsonObject || !hasExactly(value.object, "id", "label", "is_default", "is_current") {
		return ProfileSummary{}, errors.New("profile summary fields are invalid")
	}
	id, label := value.object["id"], value.object["label"]
	isDefault, isCurrent := value.object["is_default"], value.object["is_current"]
	if id.kind != jsonString || label.kind != jsonString || isDefault.kind != jsonBool || isCurrent.kind != jsonBool {
		return ProfileSummary{}, errors.New("profile summary values are invalid")
	}
	summary := ProfileSummary{ID: id.string, Label: label.string, IsDefault: isDefault.bool, IsCurrent: isCurrent.bool}
	if err := validateProfileSummary(summary); err != nil {
		return ProfileSummary{}, err
	}
	return summary, nil
}

func validateProfileSummary(summary ProfileSummary) error {
	if !validProfileID(summary.ID) {
		return errors.New("profile summary ID is invalid")
	}
	if !validProfileLabel(summary.Label) {
		return errors.New("profile summary label is invalid")
	}
	return nil
}

func validProfileID(value string) bool {
	return profileIDPattern.MatchString(value) && utf8.ValidString(value)
}

func validProfileLabel(value string) bool {
	if !utf8.ValidString(value) || utf8.RuneCountInString(value) < 1 || utf8.RuneCountInString(value) > 64 || len([]byte(value)) > 256 {
		return false
	}
	visible := false
	for _, character := range value {
		if unicode.IsControl(character) || unicode.Is(unicode.Cf, character) {
			return false
		}
		if unicode.IsSpace(character) || unicode.Is(unicode.Mn, character) || unicode.Is(unicode.Me, character) || unicode.Is(unicode.Cn, character) || unicode.Is(unicode.Co, character) || unicode.Is(unicode.Cs, character) {
			continue
		}
		visible = true
	}
	return visible
}

type protocolError struct {
	code      string
	message   string
	requestID string
	echoID    bool
}

func (e *protocolError) response() Response {
	var requestID *string
	if e.echoID {
		id := e.requestID
		requestID = &id
	}
	return Response{
		ProtocolVersion: ProtocolVersion,
		RequestID:       requestID,
		Error:           &Error{Code: e.code, Message: e.message},
	}
}

func (e *protocolError) Error() string {
	return e.code + ": " + e.message
}

func newProtocolError(code, message string) *protocolError {
	return &protocolError{code: code, message: message}
}

func DecodeRequest(frame []byte) (Request, Response, error) {
	value, err := decodeJSONFrame(frame)
	if err != nil {
		if errors.Is(err, errDuplicateKey) {
			failure := newProtocolError(ErrorInvalidEnvelope, messageInvalidEnvelope)
			return Request{}, failure.response(), nil
		}
		failure := newProtocolError(ErrorInvalidJSON, messageInvalidJSON)
		return Request{}, failure.response(), nil
	}

	if value.kind != jsonObject {
		failure := newProtocolError(ErrorInvalidEnvelope, messageInvalidEnvelope)
		return Request{}, failure.response(), nil
	}
	if !hasExactly(value.object, "protocol_version", "request_id", "method", "params") {
		requestID := canonicalString(value.object["request_id"])
		failure := newProtocolError(ErrorInvalidEnvelope, messageInvalidEnvelope)
		failure.requestID = requestID
		failure.echoID = requestID != ""
		return Request{}, failure.response(), nil
	}

	requestID := canonicalString(value.object["request_id"])
	if requestID == "" {
		failure := newProtocolError(ErrorInvalidEnvelope, messageInvalidEnvelope)
		return Request{}, failure.response(), nil
	}
	methodValue, methodOK := value.object["method"]
	paramsValue, paramsOK := value.object["params"]
	if !methodOK || methodValue.kind != jsonString || !paramsOK || paramsValue.kind != jsonObject {
		failure := newProtocolError(ErrorInvalidEnvelope, messageInvalidEnvelope)
		failure.requestID = requestID
		failure.echoID = true
		return Request{}, failure.response(), nil
	}

	request := Request{RequestID: requestID, Method: Method(methodValue.string), ProtocolVersion: ProtocolVersion}
	versionValue, versionOK := value.object["protocol_version"]
	if !versionOK || versionValue.kind != jsonNumber || versionValue.number.String() != "1" {
		failure := newProtocolError(ErrorUnsupportedVers, messageUnsupportedVers)
		failure.requestID = requestID
		failure.echoID = true
		return Request{}, failure.response(), nil
	}

	if !isSupportedMethod(request.Method) {
		failure := newProtocolError(ErrorUnknownMethod, messageUnknownMethod)
		failure.requestID = requestID
		failure.echoID = true
		return Request{}, failure.response(), nil
	}

	paramsFields := []string{"instance_id"}
	if request.Method == MethodProfilesActivate {
		paramsFields = append(paramsFields, "profile_id")
	}
	if !hasExactly(paramsValue.object, paramsFields...) {
		failure := newProtocolError(ErrorInvalidEnvelope, messageInvalidEnvelope)
		failure.requestID = requestID
		failure.echoID = true
		return Request{}, failure.response(), nil
	}
	instanceID := canonicalString(paramsValue.object["instance_id"])
	if instanceID == "" {
		failure := newProtocolError(ErrorInvalidEnvelope, messageInvalidEnvelope)
		failure.requestID = requestID
		failure.echoID = true
		return Request{}, failure.response(), nil
	}
	request.InstanceID = instanceID
	if request.Method == MethodProfilesActivate {
		profileValue := paramsValue.object["profile_id"]
		if profileValue.kind != jsonString || profileValue.string == "" {
			failure := newProtocolError(ErrorInvalidEnvelope, messageInvalidEnvelope)
			failure.requestID = requestID
			failure.echoID = true
			return Request{}, failure.response(), nil
		}
		request.ProfileID = profileValue.string
	}
	return request, Response{}, nil
}

func ValidateRequest(frame []byte, runtimeInstanceID string) (Request, Response, error) {
	request, failure, err := DecodeRequest(frame)
	if err != nil || failure.Error != nil {
		return request, failure, err
	}
	if request.InstanceID != runtimeInstanceID {
		validation := newProtocolError(ErrorInstanceMismatch, messageInstanceMismatch)
		validation.requestID = request.RequestID
		validation.echoID = true
		return Request{}, validation.response(), nil
	}
	return request, Response{}, nil
}

func EncodeRequest(request Request) ([]byte, error) {
	if request.ProtocolVersion == 0 {
		request.ProtocolVersion = ProtocolVersion
	}
	if request.ProtocolVersion != ProtocolVersion {
		return nil, errors.New("request protocol version is not supported")
	}
	if !isCanonicalUUID(request.RequestID) || !isCanonicalUUID(request.InstanceID) {
		return nil, errors.New("request identifiers must be canonical UUIDs")
	}
	if !isSupportedMethod(request.Method) {
		return nil, errors.New("request method is not supported")
	}
	if request.Method == MethodProfilesActivate && request.ProfileID == "" {
		return nil, errors.New("profile ID is required")
	}
	if request.Method != MethodProfilesActivate && request.ProfileID != "" {
		return nil, errors.New("profile ID is not permitted")
	}
	payload := struct {
		ProtocolVersion int    `json:"protocol_version"`
		RequestID       string `json:"request_id"`
		Method          Method `json:"method"`
		Params          struct {
			InstanceID string `json:"instance_id"`
			ProfileID  string `json:"profile_id,omitempty"`
		} `json:"params"`
	}{
		ProtocolVersion: request.ProtocolVersion,
		RequestID:       request.RequestID,
		Method:          request.Method,
	}
	payload.Params.InstanceID = request.InstanceID
	payload.Params.ProfileID = request.ProfileID
	return encodeJSONFrame(payload)
}

func EncodeResponse(response Response) ([]byte, error) {
	if err := validateResponseShape(response, "", "", false); err != nil {
		return nil, err
	}
	payload := struct {
		ProtocolVersion int         `json:"protocol_version"`
		RequestID       *string     `json:"request_id"`
		Result          *resultJSON `json:"result"`
		Error           *Error      `json:"error"`
	}{
		ProtocolVersion: response.ProtocolVersion,
		RequestID:       response.RequestID,
		Error:           response.Error,
	}
	if response.Result != nil {
		result := response.Result
		encodedResult := &resultJSON{ProtocolVersion: result.ProtocolVersion}
		switch resultMethod(result) {
		case MethodHealth, MethodStatus:
			instanceID, state := result.InstanceID, result.State
			encodedResult.InstanceID = &instanceID
			encodedResult.State = &state
		case MethodProfilesList:
			instanceID := result.InstanceID
			profiles := make([]ProfileSummary, len(result.Profiles))
			copy(profiles, result.Profiles)
			encodedResult.InstanceID = &instanceID
			encodedResult.Profiles = &profiles
		case MethodProfilesActivate:
			profileID, changed := result.ProfileID, result.Changed
			encodedResult.ProfileID = &profileID
			encodedResult.Changed = &changed
		}
		payload.Result = encodedResult
	}
	return encodeJSONFrame(payload)
}

type resultJSON struct {
	InstanceID      *string           `json:"instance_id,omitempty"`
	State           *string           `json:"state,omitempty"`
	ProtocolVersion *int              `json:"protocol_version,omitempty"`
	Profiles        *[]ProfileSummary `json:"profiles,omitempty"`
	ProfileID       *string           `json:"profile_id,omitempty"`
	Changed         *bool             `json:"changed,omitempty"`
}

func DecodeResponse(frame []byte, expectedRequestID, expectedMethod, expectedInstanceID string) (Response, error) {
	value, err := decodeJSONFrame(frame)
	if err != nil {
		return Response{}, fmt.Errorf("decode response: %w", err)
	}
	if value.kind != jsonObject || !hasExactly(value.object, "protocol_version", "request_id", "result", "error") {
		return Response{}, errors.New("response envelope is invalid")
	}
	version := value.object["protocol_version"]
	if version.kind != jsonNumber || version.number.String() != "1" {
		return Response{}, errors.New("response protocol version is invalid")
	}

	requestIDValue := value.object["request_id"]
	var requestID *string
	if requestIDValue.kind == jsonNull {
		requestID = nil
	} else if requestIDValue.kind == jsonString && isCanonicalUUID(requestIDValue.string) {
		id := requestIDValue.string
		requestID = &id
	} else {
		return Response{}, errors.New("response request ID is invalid")
	}

	resultValue := value.object["result"]
	errorValue := value.object["error"]
	if resultValue.kind == jsonNull && errorValue.kind == jsonNull {
		return Response{}, errors.New("response has no result or error")
	}
	if resultValue.kind != jsonNull && errorValue.kind != jsonNull {
		return Response{}, errors.New("response has both result and error")
	}
	response := Response{ProtocolVersion: ProtocolVersion, RequestID: requestID}
	if resultValue.kind != jsonNull {
		result, err := decodeResult(resultValue, expectedMethod, expectedInstanceID)
		if err != nil {
			return Response{}, err
		}
		response.Result = &result
	} else {
		failure, err := decodeError(errorValue)
		if err != nil {
			return Response{}, err
		}
		response.Error = &failure
	}

	if response.Result != nil {
		if expectedRequestID == "" || requestID == nil || *requestID != expectedRequestID {
			return Response{}, errors.New("response request ID does not match")
		}
	} else if requestID != nil && expectedRequestID != "" && *requestID != expectedRequestID {
		return Response{}, errors.New("response request ID does not match")
	}
	if err := validateResponseShape(response, expectedRequestID, expectedInstanceID, response.Result != nil); err != nil {
		return Response{}, err
	}
	return response, nil
}

func validateResponseShape(response Response, expectedRequestID, expectedInstanceID string, requireRequestID bool) error {
	if response.ProtocolVersion != ProtocolVersion {
		return errors.New("response protocol version is invalid")
	}
	if response.Result == nil && response.Error == nil || response.Result != nil && response.Error != nil {
		return errors.New("response must contain exactly one result or error")
	}
	if response.RequestID != nil && !isCanonicalUUID(*response.RequestID) {
		return errors.New("response request ID is invalid")
	}
	if requireRequestID && (response.RequestID == nil || expectedRequestID == "" || *response.RequestID != expectedRequestID) {
		return errors.New("response request ID does not match")
	}
	if response.Result != nil {
		method := resultMethod(response.Result)
		if method == "" {
			return errors.New("response result is invalid")
		}
		if err := validateResultForMethod(*response.Result, method, expectedInstanceID); err != nil {
			return err
		}
	} else {
		if response.Error == nil {
			return errors.New("response error is invalid")
		}
		if _, ok := stableErrorCodes[response.Error.Code]; !ok || !utf8.ValidString(response.Error.Message) || len([]byte(response.Error.Message)) > 256 {
			return errors.New("response error is invalid")
		}
	}
	return nil
}

func decodeResult(value jsonValue, method, expectedInstanceID string) (Result, error) {
	if value.kind != jsonObject {
		return Result{}, errors.New("response result is invalid")
	}
	switch Method(method) {
	case MethodHealth, MethodStatus:
		allowed := []string{"instance_id", "state"}
		if Method(method) == MethodStatus {
			allowed = append(allowed, "protocol_version")
		}
		if !hasExactly(value.object, allowed...) {
			return Result{}, errors.New("response result fields are invalid")
		}
		instanceID := canonicalString(value.object["instance_id"])
		state, ok := value.object["state"]
		if instanceID == "" || !ok || state.kind != jsonString || state.string != ReadyState {
			return Result{}, errors.New("response result values are invalid")
		}
		if expectedInstanceID != "" && instanceID != expectedInstanceID {
			return Result{}, errors.New("response instance ID does not match")
		}
		result := Result{InstanceID: instanceID, State: state.string}
		if Method(method) == MethodStatus {
			version := value.object["protocol_version"]
			if version.kind != jsonNumber || version.number.String() != "1" {
				return Result{}, errors.New("response result protocol version is invalid")
			}
			versionNumber := ProtocolVersion
			result.ProtocolVersion = &versionNumber
		}
		return result, nil
	case MethodProfilesList:
		if !hasExactly(value.object, "instance_id", "profiles") {
			return Result{}, errors.New("response result fields are invalid")
		}
		instanceID := canonicalString(value.object["instance_id"])
		if instanceID == "" || (expectedInstanceID != "" && instanceID != expectedInstanceID) {
			return Result{}, errors.New("response instance ID does not match")
		}
		profilesValue := value.object["profiles"]
		if profilesValue.kind != jsonArray || len(profilesValue.array) > maxProfileSummaries {
			return Result{}, errors.New("response profiles are invalid")
		}
		profiles := make([]ProfileSummary, len(profilesValue.array))
		seenIDs := make(map[string]struct{}, len(profiles))
		for index, profileValue := range profilesValue.array {
			summary, err := decodeProfileSummary(profileValue)
			if err != nil {
				return Result{}, fmt.Errorf("response profile %d: %w", index, err)
			}
			if _, exists := seenIDs[summary.ID]; exists {
				return Result{}, errors.New("response profile IDs are duplicated")
			}
			seenIDs[summary.ID] = struct{}{}
			profiles[index] = summary
		}
		return Result{InstanceID: instanceID, Profiles: profiles}, nil
	case MethodProfilesActivate:
		if !hasExactly(value.object, "profile_id", "changed") {
			return Result{}, errors.New("response result fields are invalid")
		}
		profileID := value.object["profile_id"]
		changed := value.object["changed"]
		if profileID.kind != jsonString || profileID.string == "" || changed.kind != jsonBool {
			return Result{}, errors.New("response result values are invalid")
		}
		return Result{ProfileID: profileID.string, Changed: changed.bool}, nil
	default:
		return Result{}, errors.New("response method is invalid")
	}
}

func validateResultForMethod(result Result, method Method, expectedInstanceID string) error {
	switch method {
	case MethodHealth:
		if !isCanonicalUUID(result.InstanceID) || (expectedInstanceID != "" && result.InstanceID != expectedInstanceID) || result.State != ReadyState || result.Profiles != nil || result.ProfileID != "" || result.Changed {
			return errors.New("response result is invalid")
		}
		if result.ProtocolVersion != nil {
			return errors.New("health result has an unexpected protocol version")
		}
	case MethodStatus:
		if !isCanonicalUUID(result.InstanceID) || (expectedInstanceID != "" && result.InstanceID != expectedInstanceID) || result.State != ReadyState || result.Profiles != nil || result.ProfileID != "" || result.Changed {
			return errors.New("response result is invalid")
		}
		if result.ProtocolVersion == nil || *result.ProtocolVersion != ProtocolVersion {
			return errors.New("status result protocol version is invalid")
		}
	case MethodProfilesList:
		if !isCanonicalUUID(result.InstanceID) || (expectedInstanceID != "" && result.InstanceID != expectedInstanceID) || result.State != "" || result.ProtocolVersion != nil || result.ProfileID != "" || result.Profiles == nil || len(result.Profiles) > maxProfileSummaries {
			return errors.New("response profile list is invalid")
		}
		for _, summary := range result.Profiles {
			if err := validateProfileSummary(summary); err != nil {
				return err
			}
		}
	case MethodProfilesActivate:
		if result.InstanceID != "" || result.State != "" || result.ProtocolVersion != nil || result.Profiles != nil || !validProfileID(result.ProfileID) {
			return errors.New("response activation is invalid")
		}
	default:
		return errors.New("response method is invalid")
	}
	return nil
}

func resultMethod(result *Result) Method {
	if result == nil {
		return ""
	}
	if result.Profiles != nil {
		return MethodProfilesList
	}
	if result.ProfileID != "" {
		return MethodProfilesActivate
	}
	if result.ProtocolVersion != nil {
		return MethodStatus
	}
	if result.InstanceID != "" || result.State != "" {
		return MethodHealth
	}
	return ""
}

func isSupportedMethod(method Method) bool {
	switch method {
	case MethodHealth, MethodStatus, MethodProfilesList, MethodProfilesActivate:
		return true
	default:
		return false
	}
}

func decodeError(value jsonValue) (Error, error) {
	if value.kind != jsonObject || !hasExactly(value.object, "code", "message") {
		return Error{}, errors.New("response error is invalid")
	}
	code, codeOK := value.object["code"]
	message, messageOK := value.object["message"]
	if !codeOK || code.kind != jsonString || !messageOK || message.kind != jsonString {
		return Error{}, errors.New("response error fields are invalid")
	}
	if _, ok := stableErrorCodes[code.string]; !ok || len([]byte(message.string)) > 256 {
		return Error{}, errors.New("response error values are invalid")
	}
	return Error{Code: code.string, Message: message.string}, nil
}

func hasExactly(values map[string]jsonValue, expected ...string) bool {
	if len(values) != len(expected) {
		return false
	}
	for _, key := range expected {
		if _, ok := values[key]; !ok {
			return false
		}
	}
	return true
}

func canonicalString(value jsonValue) string {
	if value.kind != jsonString || !isCanonicalUUID(value.string) {
		return ""
	}
	return value.string
}

func isCanonicalUUID(value string) bool {
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return false
	}
	for index, character := range []byte(value) {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			continue
		}
		if !((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')) {
			return false
		}
	}
	return true
}

type jsonKind uint8

const (
	jsonNull jsonKind = iota
	jsonBool
	jsonNumber
	jsonString
	jsonObject
	jsonArray
)

type jsonValue struct {
	kind   jsonKind
	bool   bool
	number json.Number
	string string
	object map[string]jsonValue
	array  []jsonValue
}

var errDuplicateKey = errors.New("duplicate JSON object key")

func decodeJSONFrame(frame []byte) (jsonValue, error) {
	if !utf8.Valid(frame) {
		return jsonValue{}, errors.New("invalid UTF-8")
	}
	decoder := json.NewDecoder(bytes.NewReader(frame))
	decoder.UseNumber()
	value, err := decodeJSONValue(decoder)
	if err != nil {
		return jsonValue{}, err
	}
	if token, err := decoder.Token(); err != io.EOF {
		if err == nil {
			return jsonValue{}, errors.New("trailing JSON value")
		}
		return jsonValue{}, err
	} else if token != nil {
		return jsonValue{}, errors.New("trailing JSON value")
	}
	return value, nil
}

func decodeJSONValue(decoder *json.Decoder) (jsonValue, error) {
	token, err := decoder.Token()
	if err != nil {
		return jsonValue{}, err
	}
	switch token := token.(type) {
	case nil:
		return jsonValue{kind: jsonNull}, nil
	case bool:
		return jsonValue{kind: jsonBool, bool: token}, nil
	case string:
		return jsonValue{kind: jsonString, string: token}, nil
	case json.Number:
		return jsonValue{kind: jsonNumber, number: token}, nil
	case json.Delim:
		switch token {
		case '{':
			object := make(map[string]jsonValue)
			for decoder.More() {
				key, err := decoder.Token()
				if err != nil {
					return jsonValue{}, err
				}
				keyString, ok := key.(string)
				if !ok {
					return jsonValue{}, errors.New("object key is not a string")
				}
				if _, exists := object[keyString]; exists {
					return jsonValue{}, errDuplicateKey
				}
				value, err := decodeJSONValue(decoder)
				if err != nil {
					return jsonValue{}, err
				}
				object[keyString] = value
			}
			closing, err := decoder.Token()
			if err != nil || closing != json.Delim('}') {
				if err == nil {
					err = errors.New("object is not closed")
				}
				return jsonValue{}, err
			}
			return jsonValue{kind: jsonObject, object: object}, nil
		case '[':
			var array []jsonValue
			for decoder.More() {
				value, err := decodeJSONValue(decoder)
				if err != nil {
					return jsonValue{}, err
				}
				array = append(array, value)
			}
			closing, err := decoder.Token()
			if err != nil || closing != json.Delim(']') {
				if err == nil {
					err = errors.New("array is not closed")
				}
				return jsonValue{}, err
			}
			return jsonValue{kind: jsonArray, array: array}, nil
		default:
			return jsonValue{}, errors.New("unexpected JSON delimiter")
		}
	default:
		return jsonValue{}, errors.New("unexpected JSON token")
	}
}

func encodeJSONFrame(value any) ([]byte, error) {
	encoded, err := json.Marshal(value)
	if err != nil {
		return nil, err
	}
	if !utf8.Valid(encoded) {
		return nil, errors.New("encoded JSON is not UTF-8")
	}
	frame := append(encoded, '\n')
	if len(frame) > MaxFrameBytes {
		return nil, errors.New("encoded JSON frame is too large")
	}
	return frame, nil
}
