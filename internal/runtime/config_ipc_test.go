package runtime

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"testing"

	"hidhogg/internal/ipc"
)

func TestClassifyReloadIPCErrorUsesStaticSentinels(t *testing.T) {
	tests := []struct {
		name string
		raw  error
		want error
	}{
		{name: "busy", raw: fmt.Errorf("configuration /private/config.toml: %w", ErrReloadBusy), want: ipc.ErrBusy},
		{name: "closed", raw: fmt.Errorf("configuration /private/config.toml: %w", ErrReloadClosed), want: ipc.ErrShuttingDown},
		{name: "service closed", raw: fmt.Errorf("configuration /private/config.toml: %w", ErrProfileServiceClosed), want: ipc.ErrShuttingDown},
		{name: "device", raw: fmt.Errorf("hid report failed: %w", ErrProfileStateUncertain), want: ipc.ErrDeviceWriteFailed},
		{name: "canceled", raw: fmt.Errorf("operation detail: %w", context.Canceled), want: ipc.ErrShuttingDown},
		{name: "deadline", raw: fmt.Errorf("operation detail: %w", context.DeadlineExceeded), want: ipc.ErrShuttingDown},
		{name: "candidate", raw: errors.New("/private/config.toml contains invalid TOML"), want: ipc.ErrReloadRejected},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := classifyReloadIPCError(test.raw)
			if !errors.Is(got, test.want) {
				t.Fatalf("classified error = %v, want %v", got, test.want)
			}
			if got.Error() != test.want.Error() {
				t.Fatalf("classified error text = %q, want static %q", got.Error(), test.want.Error())
			}
			if got.Error() == test.raw.Error() || containsRawReloadDetail(got.Error()) {
				t.Fatalf("raw reload detail leaked through adapter: %q", got.Error())
			}
		})
	}
}

func TestRuntimeIPCConfigAdapterMapsAdmissionErrorsAndStatus(t *testing.T) {
	busyRuntime := &Runtime{reload: reloadAdmission{active: true, outcome: ReloadOutcomeReady, reason: ReloadReasonNone}}
	result, err := (runtimeIPCConfigService{runtime: busyRuntime}).Reload(context.Background())
	if !errors.Is(err, ipc.ErrBusy) || result != (ipc.ConfigReloadResult{}) {
		t.Fatalf("busy reload = %+v, %v", result, err)
	}

	closedRuntime := &Runtime{reload: reloadAdmission{closed: true, outcome: ReloadOutcomeReady, reason: ReloadReasonNone}}
	_, err = (runtimeIPCConfigService{runtime: closedRuntime}).Reload(context.Background())
	if !errors.Is(err, ipc.ErrShuttingDown) {
		t.Fatalf("closed reload error = %v", err)
	}

	statusRuntime := &Runtime{reload: reloadAdmission{outcome: ReloadOutcomeRejected, reason: ReloadReasonCandidateRejected}}
	status := (runtimeIPCConfigService{runtime: statusRuntime}).Status()
	want := ipc.ConfigStatus{Revision: 0, Active: false, State: string(ReloadStateIdle), Outcome: string(ReloadOutcomeRejected), Reason: string(ReloadReasonCandidateRejected)}
	if status != want {
		t.Fatalf("status = %+v, want %+v", status, want)
	}
}

func TestRuntimeIPCConfigAdapterMapsReloadWriteFailure(t *testing.T) {
	base := reloadTestConfiguration()
	sender := &profilePageSender{err: errors.New("hid report detail")}
	runtimeProcess, path := newReloadTestRuntime(t, base, sender, nil)
	changed := bytes.Replace(base, []byte(`label = "default 0"`), []byte(`label = "changed 0"`), 1)
	writeReloadTestFile(t, path, changed)

	result, err := (runtimeIPCConfigService{runtime: runtimeProcess}).Reload(context.Background())
	if !errors.Is(err, ipc.ErrDeviceWriteFailed) {
		t.Fatalf("reload write error = %v, want %v", err, ipc.ErrDeviceWriteFailed)
	}
	if err.Error() != ipc.ErrDeviceWriteFailed.Error() {
		t.Fatalf("reload write error text = %q, want static %q", err.Error(), ipc.ErrDeviceWriteFailed.Error())
	}
	if result.Revision != 1 || result.Changed || !runtimeProcess.profileService.Uncertain() {
		t.Fatalf("reload write result/status = %+v/%t", result, runtimeProcess.profileService.Uncertain())
	}
	if currentID, _ := runtimeProcess.CurrentProfileID(); currentID != "default" {
		t.Fatalf("last-known-good profile = %q, want default", currentID)
	}
}

func containsRawReloadDetail(value string) bool {
	return value == "/private/config.toml contains invalid TOML" || value == "configuration /private/config.toml"
}
