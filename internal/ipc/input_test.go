package ipc

import (
	"bytes"
	"context"
	"testing"
	"time"

	"hidhogg/internal/execution"
)

type fakeInputService struct {
	statusCalls  int
	requestCalls int
	doctorCalls  int
}

func (service *fakeInputService) Status() InputStatus {
	service.statusCalls++
	return InputStatus{BackendState: "ready", Permission: "granted", Ready: true, QueueCapacity: maximumInputQueueCapacity, Detail: "Native input is ready."}
}

func (service *fakeInputService) RequestPermission(context.Context) (InputStatus, error) {
	service.requestCalls++
	return service.Status(), nil
}

func (service *fakeInputService) Doctor() DoctorResult {
	service.doctorCalls++
	doctor := DoctorResult{Input: service.Status()}
	for _, name := range []string{"runtime", "config", "device", "input"} {
		doctor.Checks = append(doctor.Checks, DoctorCheck{Name: name, State: "ready", Detail: "The check is ready."})
	}
	return doctor
}

func TestInputMethodsStrictDispatchAndRoundTrip(t *testing.T) {
	service := &fakeInputService{}
	server := &Server{config: ServerConfig{InputService: service}}
	for _, method := range []Method{MethodInputStatus, MethodInputRequestPermission, MethodDoctor} {
		request := Request{ProtocolVersion: ProtocolVersion, RequestID: testInstanceID, InstanceID: testInstanceID, Method: method}
		encodedRequest, err := EncodeRequest(request)
		if err != nil {
			t.Fatal(err)
		}
		decoded, failure, err := DecodeRequest(encodedRequest)
		if err != nil || failure.Error != nil {
			t.Fatalf("decode %s failed: %#v %v", method, failure, err)
		}
		response := server.handleRequest(decoded)
		encoded, err := EncodeResponse(response)
		if err != nil {
			t.Fatalf("encode %s: %v", method, err)
		}
		if _, err := DecodeResponse(encoded, request.RequestID, string(method), testInstanceID); err != nil {
			t.Fatalf("round trip %s: %v", method, err)
		}
		invalid := bytes.Replace(encodedRequest, []byte(`"params":{`), []byte(`"params":{"limit":1,`), 1)
		if _, failure, err := DecodeRequest(invalid); err == nil && failure.Error == nil {
			t.Fatalf("%s accepted a parameter", method)
		}
	}
	if service.requestCalls != 1 || service.doctorCalls != 1 {
		t.Fatalf("mutating dispatch calls: request=%d doctor=%d", service.requestCalls, service.doctorCalls)
	}
}

func TestInputResponseRejectsUnexpectedAndInvalidFields(t *testing.T) {
	requestID := testInstanceID
	status := (&fakeInputService{}).Status()
	response := Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &Result{InstanceID: testInstanceID, Input: &status}}
	encoded, err := EncodeResponse(response)
	if err != nil {
		t.Fatal(err)
	}
	for _, invalid := range [][]byte{
		bytes.Replace(encoded, []byte(`"input":{`), []byte(`"input":{"unknown":true,`), 1),
		bytes.Replace(encoded, []byte(`"queue_depth":0`), []byte(`"queue_depth":17`), 1),
		bytes.Replace(encoded, []byte(`"ready":true`), []byte(`"ready":false`), 1),
		bytes.Replace(encoded, []byte(`"permission":"granted"`), []byte(`"permission":"unknown"`), 1),
	} {
		if _, err := DecodeResponse(invalid, requestID, string(MethodInputStatus), testInstanceID); err == nil {
			t.Fatalf("accepted invalid response %s", invalid)
		}
	}
	if _, err := DecodeResponse(encoded, requestID, string(MethodHealth), testInstanceID); err == nil {
		t.Fatal("health accepted input result")
	}
	response.Result.Executions = []execution.Summary{}
	if _, err := EncodeResponse(response); err == nil {
		t.Fatal("input accepted execution result fields")
	}
}

func TestNativeHistoryStrictVariants(t *testing.T) {
	now := time.Date(2026, 9, 18, 0, 0, 0, 0, time.UTC)
	for _, state := range []execution.State{execution.StateQueued, execution.StateRunning, execution.StatePosted, execution.StatePermissionDenied, execution.StateFailed, execution.StateCanceled, execution.StateRejectedQueueFull, execution.StateRejectedBusy} {
		record := execution.Record{ActionType: "type_text", ID: "native", ProfileID: "default", PositionID: "button", State: state, SubmittedAt: now}
		switch state {
		case execution.StateRunning:
			record.StartedAt = now
		case execution.StateQueued:
		case execution.StatePosted:
			record.StartedAt, record.FinishedAt = now, now
		default:
			record.FinishedAt = now
		}
		requestID := testInstanceID
		response := Response{ProtocolVersion: ProtocolVersion, RequestID: &requestID, Result: &Result{InstanceID: testInstanceID, Execution: &record}}
		encoded, err := EncodeResponse(response)
		if err != nil {
			t.Fatalf("encode %s: %v", state, err)
		}
		if _, err := DecodeResponse(encoded, requestID, string(MethodExecutionsGet), testInstanceID); err != nil {
			t.Fatalf("decode %s: %v", state, err)
		}
	}
	base := execution.Record{ActionType: "key_press", ID: "native", ProfileID: "default", PositionID: "button", State: execution.StatePosted, SubmittedAt: now, StartedAt: now, FinishedAt: now}
	for _, change := range []func(*execution.Record){
		func(record *execution.Record) { record.ActionType = "unknown" },
		func(record *execution.Record) { record.State = execution.StateExited },
		func(record *execution.Record) { record.ExitCode = intPointer(0) },
		func(record *execution.Record) { record.Signal = intPointer(1) },
		func(record *execution.Record) { record.Stdout.Tail = []byte("payload") },
		func(record *execution.Record) { record.Stderr.TotalBytes = 1 },
		func(record *execution.Record) { record.SupervisionError = true },
		func(record *execution.Record) { record.FinishedAt = time.Time{} },
		func(record *execution.Record) { record.StartedAt = time.Time{} },
		func(record *execution.Record) { record.State = execution.StateQueued },
	} {
		record := base
		change(&record)
		if err := validateExecutionRecord(record); err == nil {
			t.Fatalf("accepted invalid native history: %#v", record)
		}
	}
}
