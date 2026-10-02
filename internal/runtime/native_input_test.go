package runtime

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/d200x"
	"hidhogg/internal/execution"
	"hidhogg/internal/ipc"
	"hidhogg/internal/nativeinput"
	"hidhogg/internal/profile"
)

type fakeRuntimeNativeWorker struct {
	mu              sync.Mutex
	requests        []nativeinput.Request
	status          nativeinput.Status
	history         []execution.Record
	permissionCalls int
	closes          int
	closed          bool
	onClose         func()
}

func newFakeRuntimeNativeWorker() *fakeRuntimeNativeWorker {
	return &fakeRuntimeNativeWorker{status: nativeinput.Status{BackendState: nativeinput.BackendReady, Permission: nativeinput.PermissionGranted, Ready: true, QueueCapacity: nativeinput.QueueCapacity, Detail: "Native input is ready."}}
}

func (worker *fakeRuntimeNativeWorker) Submit(request nativeinput.Request) (execution.Record, error) {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	if worker.closed {
		return execution.Record{}, nativeinput.ErrClosed
	}
	worker.requests = append(worker.requests, request)
	return execution.Record{State: execution.StateQueued}, nil
}

func (worker *fakeRuntimeNativeWorker) Status() nativeinput.Status {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	return worker.status
}

func (worker *fakeRuntimeNativeWorker) RequestPermission(context.Context) (nativeinput.Status, error) {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	worker.permissionCalls++
	return worker.status, nil
}

func (worker *fakeRuntimeNativeWorker) ListSummaries(limit int) ([]execution.Summary, error) {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	items := make([]execution.Summary, min(limit, len(worker.history)))
	for index := range items {
		record := worker.history[index]
		items[index] = execution.Summary{ActionType: record.ActionType, ID: record.ID, SubmittedAt: record.SubmittedAt}
	}
	return items, nil
}

func (worker *fakeRuntimeNativeWorker) Get(id string) (execution.Record, bool) {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	for _, record := range worker.history {
		if record.ID == id {
			return record, true
		}
	}
	return execution.Record{}, false
}

func (worker *fakeRuntimeNativeWorker) Close() error {
	if worker.onClose != nil {
		worker.onClose()
	}
	worker.mu.Lock()
	defer worker.mu.Unlock()
	worker.closed = true
	worker.closes++
	return nil
}

func TestNativeActionDispatchUsesExistingGestureLatch(t *testing.T) {
	for _, action := range []profile.Action{
		{Type: profile.TypeTextActionType, Text: "1", Gesture: profile.PressGesture},
		{Type: profile.KeyPressActionType, Key: "enter", Gesture: profile.ReleaseGesture},
	} {
		t.Run(action.Type, func(t *testing.T) {
			current := testProfile("default", "Default", "Default")
			current.Values[0].Action = &action
			catalog, err := profile.NewCatalog("default", []profile.Profile{current})
			if err != nil {
				t.Fatal(err)
			}
			service, err := NewProfileService(ProfileServiceOptions{Catalog: catalog, Sender: &profilePageSender{}})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = service.Close() })
			native := newFakeRuntimeNativeWorker()
			command := newFakeExecutionWorker()
			controller := newProfileActionController(service, service.CurrentEventPositions, runtimeActionSubmitter{executionSubmitter: command, native: native})
			press := actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed)
			release := actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased)
			for _, event := range []d200x.InputEvent{press, press, release, release} {
				if err := controller.observe(context.Background(), event); err != nil {
					t.Fatal(err)
				}
			}
			want := nativeinput.Request{ProfileID: "default", PositionID: "0_0", Text: action.Text, Key: action.Key}
			if len(native.requests) != 1 || native.requests[0] != want || command.submitCount() != 0 {
				t.Fatalf("native=%#v command=%d", native.requests, command.submitCount())
			}
			controller.consumePhysical(press)
			controller.reset()
			if err := controller.observe(context.Background(), release); err != nil {
				t.Fatal(err)
			}
			if len(native.requests) != 1 {
				t.Fatal("idle-wake physical gesture dispatched native action")
			}
		})
	}
}

func TestNativeActionSnapshotAndReloadEqualityIncludePayload(t *testing.T) {
	for _, action := range []profile.Action{{Type: profile.TypeTextActionType, Text: "1"}, {Type: profile.KeyPressActionType, Key: "enter"}} {
		binding := profile.Binding{Position: "0_0", Action: action}
		snapshot := profileActionSnapshot{profileID: "default", bindings: []profile.Binding{binding}}
		candidate := profileActionCandidate{snapshot: snapshot.clone(), binding: binding, position: eventPosition{id: "button", position: "0_0"}}
		if !candidate.matches(snapshot, candidate.position) {
			t.Fatal("unchanged native binding did not match")
		}
		changed := snapshot.clone()
		if action.Type == profile.TypeTextActionType {
			changed.bindings[0].Action.Text = "2"
		} else {
			changed.bindings[0].Action.Key = "changed"
		}
		if candidate.matches(changed, candidate.position) || equalProfileActions(&action, &changed.bindings[0].Action) {
			t.Fatal("changed native payload retained pending action or missed reload difference")
		}
	}
}

func TestRuntimeNativeUnavailableStartupAndLifecycleAreNonfatal(t *testing.T) {
	for _, state := range []nativeinput.BackendState{nativeinput.BackendUnsupported, nativeinput.BackendInitializationFailed, nativeinput.BackendReady} {
		t.Run(string(state), func(t *testing.T) {
			configurationPath := filepath.Join(t.TempDir(), "valid.toml")
			if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
				t.Fatal(err)
			}
			r, err := New(Config{SocketPath: filepath.Join(runtimeSocketTestDirectory(t), "runtime.sock"), InstanceID: runtimeTestInstanceID, ConfigPath: configurationPath, TransportFactory: &recordingFactory{transport: newRuntimeFakeTransport()}})
			if err != nil {
				t.Fatal(err)
			}
			native := newFakeRuntimeNativeWorker()
			native.status.BackendState, native.status.Permission, native.status.Ready = state, nativeinput.PermissionNotGranted, false
			calls := 0
			r.nativeFactory = func() nativeWorker { calls++; return native }
			r.executionFactory = func() (executionWorker, error) { return newFakeExecutionWorker(), nil }
			native.onClose = func() {
				if !r.mu.TryLock() {
					t.Error("native close held runtime state lock")
					return
				}
				r.mu.Unlock()
			}
			if err := r.Start(); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = r.Close() })
			if err := r.Start(); err != nil {
				t.Fatal(err)
			}
			service := runtimeIPCInputService{runtime: r}
			if status := service.Status(); status.BackendState != string(state) || status.Ready {
				t.Fatalf("status=%#v", status)
			}
			doctor := service.Doctor()
			if len(doctor.Checks) != 4 || doctor.Checks[0].State != "ready" || doctor.Checks[2].State != "ready" || native.permissionCalls != 0 {
				t.Fatalf("doctor=%#v permission calls=%d", doctor, native.permissionCalls)
			}
			if _, err := service.RequestPermission(context.Background()); err != nil {
				t.Fatal(err)
			}
			if native.permissionCalls != 1 {
				t.Fatal("explicit request did not reach runtime worker")
			}
			if err := r.Close(); err != nil {
				t.Fatal(err)
			}
			if err := r.Close(); err != nil {
				t.Fatal(err)
			}
			if calls != 1 || native.closes != 1 {
				t.Fatalf("factory=%d closes=%d", calls, native.closes)
			}
			if _, err := service.RequestPermission(context.Background()); !errors.Is(err, ipc.ErrShuttingDown) {
				t.Fatalf("closed request=%v", err)
			}
		})
	}
}

type fakeMergedCommandWorker struct {
	*fakeExecutionWorker
	history []execution.Summary
}

func (worker *fakeMergedCommandWorker) ListSummaries(limit int) ([]execution.Summary, error) {
	return slices.Clone(worker.history[:min(limit, len(worker.history))]), nil
}

func TestRuntimeMergedNativeHistoryBoundOrderAndLookup(t *testing.T) {
	now := time.Date(2026, 9, 18, 0, 0, 0, 0, time.UTC)
	command := &fakeMergedCommandWorker{fakeExecutionWorker: newFakeExecutionWorker()}
	native := newFakeRuntimeNativeWorker()
	for index := range execution.HistoryLimit {
		command.history = append(command.history, execution.Summary{ID: fmt.Sprintf("c-%02d", index), SubmittedAt: now.Add(time.Duration(index) * time.Second)})
		native.history = append(native.history, execution.Record{ActionType: "type_text", ID: fmt.Sprintf("n-%02d", index), SubmittedAt: now.Add(time.Duration(index) * time.Second)})
	}
	r := &Runtime{executionWorker: command, nativeWorker: native}
	history := runtimeExecutionHistory{runtime: r}
	items, err := history.ListSummaries(execution.HistoryLimit)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != execution.HistoryLimit || items[0].ID != "c-31" || items[1].ID != "n-31" || items[31].ID != "n-16" {
		t.Fatalf("merged order=%#v", items)
	}
	items[0].ID = "mutated"
	if command.history[31].ID != "c-31" {
		t.Fatal("merge mutated worker history")
	}
	if record, ok := history.Get("n-31"); !ok || record.ActionType != "type_text" {
		t.Fatalf("native lookup=%#v %t", record, ok)
	}
	command.requests = append(command.requests, execution.Request{ProfileID: "default", PositionID: "button"})
	if record, ok := history.Get("record-1"); !ok || record.ProfileID != "default" {
		t.Fatalf("command lookup=%#v %t", record, ok)
	}
	if _, err := history.ListSummaries(execution.HistoryLimit + 1); !errors.Is(err, execution.ErrInvalidRequest) {
		t.Fatalf("over-limit=%v", err)
	}
}

func TestRuntimeReadyNativeStatusHasSafeDoctorDetail(t *testing.T) {
	native := newFakeRuntimeNativeWorker()
	native.status.Detail = ""
	doctor := (runtimeIPCInputService{runtime: &Runtime{nativeWorker: native}}).Doctor()
	if doctor.Checks[3].Detail == "" || doctor.Input.Detail == "" || doctor.Checks[3].State != "ready" {
		t.Fatalf("ready doctor=%#v", doctor)
	}
}
