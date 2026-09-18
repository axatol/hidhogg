package ipc

import (
	"context"
	"errors"

	"hidhogg/internal/execution"
)

type InputStatus struct {
	BackendState      string `json:"backend_state"`
	Permission        string `json:"permission"`
	Ready             bool   `json:"ready"`
	QueueDepth        int    `json:"queue_depth"`
	QueueCapacity     int    `json:"queue_capacity"`
	RequestInProgress bool   `json:"request_in_progress"`
	Detail            string `json:"detail"`
}

const maximumInputQueueCapacity = 16

type DoctorCheck struct {
	Name   string `json:"name"`
	State  string `json:"state"`
	Detail string `json:"detail"`
}

type DoctorResult struct {
	Checks []DoctorCheck `json:"checks"`
	Input  InputStatus   `json:"input"`
}

type InputService interface {
	Status() InputStatus
	RequestPermission(context.Context) (InputStatus, error)
	Doctor() DoctorResult
}

func effectiveActionType(value string) string {
	if value == "" {
		return "execute"
	}
	return value
}

func validActionType(value string) bool {
	return value == "execute" || value == "type_text" || value == "key_press"
}

func validateActionHistory(summary execution.Summary) error {
	if summary.ExitCode != nil && summary.Signal != nil {
		return errors.New("execution exit code and signal are mutually exclusive")
	}
	actionType := effectiveActionType(summary.ActionType)
	if !validActionType(actionType) {
		return errors.New("execution action type is invalid")
	}
	if actionType == "execute" {
		switch summary.State {
		case execution.StateRunning, execution.StateExited, execution.StateSignaled, execution.StateTimedOut, execution.StateCanceled, execution.StateStartFailed, execution.StateRejectedBusy:
			return nil
		default:
			return errors.New("command execution state is invalid")
		}
	}
	if summary.SubmittedAt.IsZero() || summary.ExitCode != nil || summary.Signal != nil || summary.SupervisionError || summary.Duration < 0 {
		return errors.New("native action metadata is invalid")
	}
	switch summary.State {
	case execution.StateRunning:
		if summary.StartedAt.IsZero() || !summary.FinishedAt.IsZero() || summary.Duration != 0 {
			return errors.New("running native action timestamps are invalid")
		}
	case execution.StateQueued:
		if !summary.StartedAt.IsZero() || !summary.FinishedAt.IsZero() || summary.Duration != 0 {
			return errors.New("queued action timestamps are invalid")
		}
	case execution.StatePosted, execution.StatePermissionDenied, execution.StateFailed, execution.StateCanceled, execution.StateRejectedQueueFull, execution.StateRejectedBusy:
		if summary.FinishedAt.IsZero() {
			return errors.New("native action completion is missing")
		}
		if summary.StartedAt.IsZero() {
			if summary.Duration != 0 || summary.State == execution.StatePosted {
				return errors.New("native action duration is invalid")
			}
		}
		if (summary.State == execution.StateRejectedQueueFull || summary.State == execution.StateRejectedBusy) && (!summary.StartedAt.IsZero() || summary.Duration != 0) {
			return errors.New("rejected native action timestamps are invalid")
		}
	default:
		return errors.New("native action state is invalid")
	}
	return nil
}

func validateInputStatus(status InputStatus) error {
	switch status.BackendState {
	case "ready", "unsupported", "initialization_failed", "closed":
	default:
		return errors.New("input backend state is invalid")
	}
	switch status.Permission {
	case "granted", "not_granted", "check_failed":
	default:
		return errors.New("input permission is invalid")
	}
	if status.Ready != (status.BackendState == "ready" && status.Permission == "granted" && !status.RequestInProgress) || status.QueueCapacity < 0 || status.QueueCapacity > maximumInputQueueCapacity || status.QueueDepth < 0 || status.QueueDepth > status.QueueCapacity || !validConfigDiagnosticText(status.Detail, true) {
		return errors.New("input status is invalid")
	}
	return nil
}

func validateInputResult(result Result, method Method, instanceID string) error {
	base := result
	base.Input, base.Doctor = nil, nil
	base.State = ReadyState
	if err := validateResultForMethod(base, MethodHealth, instanceID); err != nil {
		return err
	}
	if result.State != "" {
		return errors.New("input result state is unexpected")
	}
	if method != MethodDoctor {
		if result.Input == nil || result.Doctor != nil {
			return errors.New("input result fields are invalid")
		}
		return validateInputStatus(*result.Input)
	}
	if result.Input != nil || result.Doctor == nil || len(result.Doctor.Checks) != 4 {
		return errors.New("doctor result fields are invalid")
	}
	for index, name := range []string{"runtime", "config", "device", "input"} {
		check := result.Doctor.Checks[index]
		if check.Name != name || (check.State != "ready" && check.State != "attention" && check.State != "closed") || !validConfigDiagnosticText(check.Detail, false) {
			return errors.New("doctor check is invalid")
		}
	}
	return validateInputStatus(result.Doctor.Input)
}

func decodeInputStatus(value jsonValue) (InputStatus, error) {
	if value.kind != jsonObject || !hasExactly(value.object, "backend_state", "permission", "ready", "queue_depth", "queue_capacity", "request_in_progress", "detail") {
		return InputStatus{}, errors.New("input status fields are invalid")
	}
	fields := value.object
	for _, name := range []string{"backend_state", "permission", "detail"} {
		if fields[name].kind != jsonString {
			return InputStatus{}, errors.New("input status string is invalid")
		}
	}
	if fields["ready"].kind != jsonBool || fields["request_in_progress"].kind != jsonBool {
		return InputStatus{}, errors.New("input status boolean is invalid")
	}
	depth, err := decodeInteger(fields["queue_depth"])
	if err != nil || depth < 0 || depth > maximumInputQueueCapacity {
		return InputStatus{}, errors.New("input queue depth is invalid")
	}
	capacity, err := decodeInteger(fields["queue_capacity"])
	if err != nil || capacity < 0 || capacity > maximumInputQueueCapacity {
		return InputStatus{}, errors.New("input queue capacity is invalid")
	}
	status := InputStatus{BackendState: fields["backend_state"].string, Permission: fields["permission"].string, Ready: fields["ready"].bool, QueueDepth: int(depth), QueueCapacity: int(capacity), RequestInProgress: fields["request_in_progress"].bool, Detail: fields["detail"].string}
	return status, validateInputStatus(status)
}

func decodeInputResult(value jsonValue, method Method, instanceID string) (Result, error) {
	field := "input"
	if method == MethodDoctor {
		field = "doctor"
	}
	if value.kind != jsonObject || !hasExactly(value.object, "instance_id", field) {
		return Result{}, errors.New("input result fields are invalid")
	}
	result := Result{InstanceID: canonicalString(value.object["instance_id"])}
	if method != MethodDoctor {
		status, err := decodeInputStatus(value.object[field])
		if err != nil {
			return Result{}, err
		}
		result.Input = &status
		return result, validateInputResult(result, method, instanceID)
	}
	doctor := value.object[field]
	if doctor.kind != jsonObject || !hasExactly(doctor.object, "checks", "input") || doctor.object["checks"].kind != jsonArray || len(doctor.object["checks"].array) != 4 {
		return Result{}, errors.New("doctor fields are invalid")
	}
	status, err := decodeInputStatus(doctor.object["input"])
	if err != nil {
		return Result{}, err
	}
	result.Doctor = &DoctorResult{Input: status, Checks: make([]DoctorCheck, 4)}
	for index, check := range doctor.object["checks"].array {
		if check.kind != jsonObject || !hasExactly(check.object, "name", "state", "detail") {
			return Result{}, errors.New("doctor check fields are invalid")
		}
		for _, name := range []string{"name", "state", "detail"} {
			if check.object[name].kind != jsonString {
				return Result{}, errors.New("doctor check string is invalid")
			}
		}
		result.Doctor.Checks[index] = DoctorCheck{Name: check.object["name"].string, State: check.object["state"].string, Detail: check.object["detail"].string}
	}
	return result, validateInputResult(result, method, instanceID)
}
