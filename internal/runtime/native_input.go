package runtime

import (
	"context"
	"errors"
	"slices"

	"hidhogg/internal/execution"
	"hidhogg/internal/ipc"
	"hidhogg/internal/nativeinput"
)

type nativeWorker interface {
	Submit(nativeinput.Request) (execution.Record, error)
	Status() nativeinput.Status
	RequestPermission(context.Context) (nativeinput.Status, error)
	ListSummaries(int) ([]execution.Summary, error)
	Get(string) (execution.Record, bool)
	Close() error
}

type nativeWorkerFactory func() nativeWorker

type runtimeActionSubmitter struct {
	executionSubmitter
	native nativeWorker
}

func (submitter runtimeActionSubmitter) nativeInputSubmitter() nativeWorker { return submitter.native }

type runtimeIPCInputService struct{ runtime *Runtime }

func (service runtimeIPCInputService) worker() nativeWorker {
	if service.runtime == nil {
		return nil
	}
	service.runtime.mu.Lock()
	worker := service.runtime.nativeWorker
	service.runtime.mu.Unlock()
	return worker
}

func inputStatus(status nativeinput.Status) ipc.InputStatus {
	if status.Ready && status.Detail == "" {
		status.Detail = "Native input is ready."
	}
	return ipc.InputStatus{BackendState: string(status.BackendState), Permission: string(status.Permission), Ready: status.Ready, QueueDepth: status.QueueDepth, QueueCapacity: status.QueueCapacity, RequestInProgress: status.RequestInProgress, Detail: status.Detail}
}

func (service runtimeIPCInputService) Status() ipc.InputStatus {
	worker := service.worker()
	if worker == nil {
		return ipc.InputStatus{BackendState: "closed", Permission: "not_granted", Detail: "Restart the runtime to initialize native input."}
	}
	return inputStatus(worker.Status())
}

func (service runtimeIPCInputService) RequestPermission(ctx context.Context) (ipc.InputStatus, error) {
	worker := service.worker()
	if worker == nil {
		return service.Status(), ipc.ErrShuttingDown
	}
	status, err := worker.RequestPermission(ctx)
	if errors.Is(err, nativeinput.ErrClosed) {
		return inputStatus(status), ipc.ErrShuttingDown
	}
	if errors.Is(err, nativeinput.ErrBusy) {
		return inputStatus(status), ipc.ErrBusy
	}
	if err != nil {
		return inputStatus(status), errors.New("native input permission request failed")
	}
	return inputStatus(status), nil
}

func (service runtimeIPCInputService) Doctor() ipc.DoctorResult {
	status := service.Status()
	doctor := ipc.DoctorResult{Input: status, Checks: []ipc.DoctorCheck{
		{Name: "runtime", State: "closed", Detail: "Start the runtime before using device actions."},
		{Name: "config", State: "attention", Detail: "Run config.status for safe validation details, correct the configuration, and retry config.reload."},
		{Name: "device", State: "attention", Detail: "Connect one supported device and restart the runtime."},
		{Name: "input", State: "attention", Detail: status.Detail},
	}}
	if service.runtime == nil {
		return doctor
	}
	r := service.runtime
	r.mu.Lock()
	started, closed, deviceReady, terminal := r.started, r.closed, r.session != nil, r.terminalErr != nil
	r.mu.Unlock()
	if started && !closed && !terminal {
		doctor.Checks[0] = ipc.DoctorCheck{Name: "runtime", State: "ready", Detail: "Runtime is serving this generation."}
	}
	if terminal && !closed {
		doctor.Checks[0] = ipc.DoctorCheck{Name: "runtime", State: "attention", Detail: "The runtime withdrew readiness after a terminal failure. Restart the runtime."}
	}
	config := r.ReloadStatus()
	if config.Revision > 0 && config.Outcome != ReloadOutcomeRejected {
		doctor.Checks[1] = ipc.DoctorCheck{Name: "config", State: "ready", Detail: "The effective configuration is valid."}
	}
	if config.Revision > 0 && config.Outcome == ReloadOutcomeRejected {
		doctor.Checks[1].Detail = "The last-known-good effective configuration remains valid. Run config.status for safe key and line details, correct the candidate, and retry config.reload."
	}
	if deviceReady && !closed && !terminal {
		doctor.Checks[2] = ipc.DoctorCheck{Name: "device", State: "ready", Detail: "The device session is initialized."}
	}
	if status.Ready {
		doctor.Checks[3].State = "ready"
	}
	if status.BackendState == "closed" {
		doctor.Checks[3].State = "closed"
	}
	return doctor
}

func (history runtimeExecutionHistory) nativeWorker() nativeWorker {
	return (runtimeIPCInputService{runtime: history.runtime}).worker()
}

func mergedHistory(command executionWorker, native nativeWorker, limit int) ([]execution.Summary, error) {
	if limit < 1 || limit > execution.HistoryLimit {
		return nil, execution.ErrInvalidRequest
	}
	if command == nil && native == nil {
		return nil, execution.ErrClosed
	}
	summaries := make([]execution.Summary, 0, execution.HistoryLimit*2)
	if command != nil {
		items, err := command.ListSummaries(execution.HistoryLimit)
		if err != nil {
			return nil, err
		}
		summaries = append(summaries, items...)
	}
	if native != nil {
		items, err := native.ListSummaries(execution.HistoryLimit)
		if err != nil {
			return nil, err
		}
		summaries = append(summaries, items...)
	}
	slices.SortFunc(summaries, func(left, right execution.Summary) int {
		if compared := right.SubmittedAt.Compare(left.SubmittedAt); compared != 0 {
			return compared
		}
		if left.ID < right.ID {
			return -1
		}
		if left.ID > right.ID {
			return 1
		}
		return 0
	})
	if len(summaries) > limit {
		summaries = summaries[:limit]
	}
	return summaries, nil
}
