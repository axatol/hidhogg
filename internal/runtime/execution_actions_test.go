package runtime

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/d200x"
	"hidhogg/internal/execution"
	"hidhogg/internal/profile"
)

func TestExecuteActionRoutesCompletedPressWithOriginatingIdentity(t *testing.T) {
	current := testProfile("default", "Default", "Default")
	current.Values[0].Action = &profile.Action{
		Type:           profile.ExecuteActionType,
		Gesture:        profile.ReleaseGesture,
		Executable:     "/controlled/helper",
		Arguments:      []string{"one", "two words"},
		TimeoutSeconds: 17,
	}
	catalog, err := profile.NewCatalog("default", []profile.Profile{current})
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewProfileService(ProfileServiceOptions{Catalog: catalog, Sender: &profilePageSender{}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	worker := newFakeExecutionWorker()
	controller := newProfileActionController(service, service.CurrentEventPositions, worker)

	press := actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed)
	release := actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased)
	if err := controller.observe(context.Background(), press); err != nil {
		t.Fatalf("press: %v", err)
	}
	if len(worker.requestsSnapshot()) != 0 {
		t.Fatal("execute action was submitted before release")
	}
	if err := controller.observe(context.Background(), release); err != nil {
		t.Fatalf("release: %v", err)
	}
	requests := worker.requestsSnapshot()
	if len(requests) != 1 {
		t.Fatalf("execution requests = %d, want one", len(requests))
	}
	want := execution.Request{
		ProfileID:  "default",
		PositionID: "Default-0_0",
		Executable: "/controlled/helper",
		Arguments:  []string{"one", "two words"},
		Timeout:    17 * time.Second,
	}
	if !equalExecutionRequest(requests[0], want) {
		t.Fatalf("execution request = %#v, want %#v", requests[0], want)
	}
	if err := controller.observe(context.Background(), release); err != nil {
		t.Fatalf("duplicate release: %v", err)
	}
	if len(worker.requestsSnapshot()) != 1 {
		t.Fatal("duplicate release retried execution")
	}
}

func TestExecuteActionPressRunsOnInitialDownOnceAndIgnoresRelease(t *testing.T) {
	current := testProfile("default", "Default", "Default")
	current.Values[0].Action = &profile.Action{
		Type:           profile.ExecuteActionType,
		Gesture:        profile.PressGesture,
		Executable:     "/controlled/helper",
		Arguments:      []string{"one"},
		TimeoutSeconds: 3,
	}
	catalog, err := profile.NewCatalog("default", []profile.Profile{current})
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewProfileService(ProfileServiceOptions{Catalog: catalog, Sender: &profilePageSender{}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	worker := newFakeExecutionWorker()
	controller := newProfileActionController(service, service.CurrentEventPositions, worker)
	press := actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed)
	release := actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased)
	for _, event := range []d200x.InputEvent{press, press, release, release} {
		if err := controller.observe(context.Background(), event); err != nil {
			t.Fatalf("observe %#v: %v", event, err)
		}
	}
	requests := worker.requestsSnapshot()
	if len(requests) != 1 {
		t.Fatalf("execution requests = %d, want one", len(requests))
	}
	if requests[0].PositionID != "Default-0_0" || !slices.Equal(requests[0].Arguments, []string{"one"}) {
		t.Fatalf("execution request = %#v", requests[0])
	}
}

func TestProfileActionPressSwitchReleaseDoesNotRunNewBinding(t *testing.T) {
	current := testProfile("default", "Default", "Default")
	alternate := testProfile("alternate", "Alternate", "Alternate")
	current.Values[0].Action = &profile.Action{
		Type:      profile.ActivateProfileType,
		Gesture:   profile.PressGesture,
		ProfileID: "alternate",
	}
	alternate.Values[0].Action = &profile.Action{
		Type:      profile.ActivateProfileType,
		Gesture:   profile.PressGesture,
		ProfileID: "default",
	}
	catalog, err := profile.NewCatalog("default", []profile.Profile{current, alternate})
	if err != nil {
		t.Fatal(err)
	}
	sender := &profilePageSender{}
	service, err := NewProfileService(ProfileServiceOptions{Catalog: catalog, Sender: sender})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	controller := newProfileActionController(service, service.CurrentEventPositions)
	press := actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed)
	release := actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased)
	if err := controller.observe(context.Background(), press); err != nil {
		t.Fatal(err)
	}
	if got, _ := service.CurrentProfileID(); got != "alternate" || sender.callCount() != 1 {
		t.Fatalf("initial press profile/write = %q/%d", got, sender.callCount())
	}
	if err := controller.observe(context.Background(), press); err != nil {
		t.Fatal(err)
	}
	if err := controller.observe(context.Background(), release); err != nil {
		t.Fatal(err)
	}
	if got, _ := service.CurrentProfileID(); got != "alternate" || sender.callCount() != 1 {
		t.Fatalf("held-key release changed profile/write = %q/%d", got, sender.callCount())
	}
	if err := controller.observe(context.Background(), press); err != nil {
		t.Fatal(err)
	}
	if got, _ := service.CurrentProfileID(); got != "default" || sender.callCount() != 2 {
		t.Fatalf("post-release press profile/write = %q/%d", got, sender.callCount())
	}
}

func TestProfileActionReleaseTracksMultipleKeysAndRejectsOrphans(t *testing.T) {
	current := testProfile("default", "Default", "Default")
	for index := range []int{0, 1} {
		current.Values[index].Action = &profile.Action{
			Type:           profile.ExecuteActionType,
			Gesture:        profile.ReleaseGesture,
			Executable:     "/controlled/helper",
			Arguments:      []string{string(rune('a' + index))},
			TimeoutSeconds: 3,
		}
	}
	catalog, err := profile.NewCatalog("default", []profile.Profile{current})
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewProfileService(ProfileServiceOptions{Catalog: catalog, Sender: &profilePageSender{}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	worker := newFakeExecutionWorker()
	controller := newProfileActionController(service, service.CurrentEventPositions, worker)
	button := func(wire byte, action d200x.InputAction) d200x.InputEvent {
		return actionTestInput(wire, d200x.InputMarkerButton, action)
	}
	for _, event := range []d200x.InputEvent{
		button(0, d200x.InputActionReleased),
		button(0, d200x.InputActionPressed),
		button(1, d200x.InputActionReleased),
		button(1, d200x.InputActionPressed),
		button(0, d200x.InputActionPressed),
		button(1, d200x.InputActionReleased),
		button(0, d200x.InputActionReleased),
	} {
		if err := controller.observe(context.Background(), event); err != nil {
			t.Fatalf("observe %#v: %v", event, err)
		}
	}
	requests := worker.requestsSnapshot()
	if len(requests) != 2 {
		t.Fatalf("execution requests = %d, want two", len(requests))
	}
	if requests[0].PositionID != "Default-1_0" || requests[1].PositionID != "Default-0_0" {
		t.Fatalf("execution positions = %#v", requests)
	}
}

func TestExecuteActionClonesArgumentsAndTreatsBusyAsHistory(t *testing.T) {
	worker := newFakeExecutionWorker()
	worker.recordState = execution.StateRejectedBusy
	controller := &profileActionController{service: &actionProfileServiceStub{current: testProfile("default", "Default", "Default")}, executor: worker}
	activation := &profileActionActivation{
		snapshot:   profileActionSnapshot{profileID: "default"},
		positionID: "Default-0_0",
		binding: profile.Binding{Action: profile.Action{
			Type: profile.ExecuteActionType, Gesture: profile.ReleaseGesture,
			Executable: "/controlled/helper", Arguments: []string{"owned"}, TimeoutSeconds: 3,
		}},
	}
	if err := controller.activate(context.Background(), activation); err != nil {
		t.Fatalf("busy admission: %v", err)
	}
	activation.binding.Action.Arguments[0] = "mutated"
	requests := worker.requestsSnapshot()
	if len(requests) != 1 || !slices.Equal(requests[0].Arguments, []string{"owned"}) {
		t.Fatalf("request arguments were not cloned: %#v", requests)
	}
}

func TestExecuteActionAdmissionFailureDoesNotRetry(t *testing.T) {
	current := testProfile("default", "Default", "Default")
	current.Values[0].Action = &profile.Action{
		Type: profile.ExecuteActionType, Gesture: profile.ReleaseGesture,
		Executable: "/controlled/helper", Arguments: []string{}, TimeoutSeconds: 10,
	}
	catalog, err := profile.NewCatalog("default", []profile.Profile{current})
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewProfileService(ProfileServiceOptions{Catalog: catalog, Sender: &profilePageSender{}})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	worker := newFakeExecutionWorker()
	worker.submitErr = execution.ErrClosed
	controller := newProfileActionController(service, service.CurrentEventPositions, worker)
	press := actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed)
	release := actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased)
	if err := controller.observe(context.Background(), press); err != nil {
		t.Fatal(err)
	}
	if err := controller.observe(context.Background(), release); !errors.Is(err, execution.ErrClosed) {
		t.Fatalf("admission failure = %v, want ErrClosed", err)
	}
	worker.submitErr = nil
	if err := controller.observe(context.Background(), release); err != nil {
		t.Fatalf("duplicate release: %v", err)
	}
	if worker.submitCount() != 1 {
		t.Fatalf("execution admission attempts = %d, want one", worker.submitCount())
	}
}

func TestRunningExecuteActionDoesNotBlockInputIdleOrProfileWork(t *testing.T) {
	current := testProfile("default", "Default", "Default")
	current.Values[0].Action = &profile.Action{
		Type: profile.ExecuteActionType, Gesture: profile.ReleaseGesture,
		Executable: "/controlled/helper", Arguments: []string{}, TimeoutSeconds: 10,
	}
	alternate := testProfile("alternate", "Alternate", "Alternate")
	alternate.Values[0].Action = nil
	catalog, err := profile.NewCatalog("default", []profile.Profile{current, alternate})
	if err != nil {
		t.Fatal(err)
	}
	pageSender := &profilePageSender{}
	service, err := NewProfileService(ProfileServiceOptions{Catalog: catalog, Sender: pageSender})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	worker := newFakeExecutionWorker()
	frameSender := &policyRecordingSender{}
	var output synchronizedWriter
	plan := devicePlan{brightness: 73, idleTimeout: time.Minute, positionsFn: service.CurrentEventPositions}
	controller := &idlePolicyController{
		clock: realClock{}, sender: frameSender, plan: plan, stdout: &output,
		actions: newProfileActionController(service, plan.eventPositions, worker),
	}
	for _, event := range []d200x.InputEvent{
		actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed),
		actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased),
	} {
		if err := controller.handleInput(context.Background(), inputObservation{event: event, observedAt: time.Now()}); err != nil {
			t.Fatalf("execute gesture: %v", err)
		}
	}
	if len(worker.requestsSnapshot()) != 1 {
		t.Fatal("execute action did not remain represented as running")
	}
	if err := controller.handleInput(context.Background(), inputObservation{
		event: actionTestInput(1, d200x.InputMarkerEncoder, d200x.InputActionRotatedRight), observedAt: time.Now(),
	}); err != nil {
		t.Fatalf("input while child running: %v", err)
	}
	if err := controller.keepalive(context.Background()); err != nil {
		t.Fatalf("keepalive while child running: %v", err)
	}
	if err := controller.dim(context.Background()); err != nil {
		t.Fatalf("idle dim while child running: %v", err)
	}
	if _, err := service.ActivateProfile(context.Background(), "alternate"); err != nil {
		t.Fatalf("profile activation while child running: %v", err)
	}
	if got := stringsCount(output.String(), `"event":"input"`); got != 3 {
		t.Fatalf("input emissions while child running = %d, want three", got)
	}
}

func TestRuntimeOwnsOneExecutionWorkerGenerationAndClosesAdmission(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "valid.toml")
	if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	worker := newFakeExecutionWorker()
	var factoryCalls int
	runtimeProcess, err := New(Config{
		SocketPath:       filepath.Join(runtimeSocketTestDirectory(t), "runtime.sock"),
		InstanceID:       runtimeTestInstanceID,
		ConfigPath:       configurationPath,
		TransportFactory: &recordingFactory{transport: newRuntimeFakeTransport()},
	})
	if err != nil {
		t.Fatal(err)
	}
	runtimeProcess.executionFactory = func() (executionWorker, error) {
		factoryCalls++
		return worker, nil
	}
	if err := runtimeProcess.Start(); err != nil {
		if strings.Contains(err.Error(), "start IPC server failed") {
			t.Skipf("Unix socket creation unavailable in this environment: %v", err)
		}
		t.Fatal(err)
	}
	if err := runtimeProcess.Start(); err != nil {
		t.Fatal(err)
	}
	if factoryCalls != 1 {
		t.Fatalf("execution worker generations = %d, want one", factoryCalls)
	}
	if err := runtimeProcess.Close(); err != nil {
		t.Fatal(err)
	}
	if worker.closeCount() != 1 {
		t.Fatalf("execution worker closes = %d, want one", worker.closeCount())
	}
	if _, err := worker.Submit(execution.Request{}); !errors.Is(err, execution.ErrClosed) {
		t.Fatalf("admission after runtime close = %v, want ErrClosed", err)
	}
}

func TestRuntimeCloseClosesExecutionAdmissionOnce(t *testing.T) {
	worker := newFakeExecutionWorker()
	runtimeProcess := &Runtime{executionWorker: worker}
	if err := runtimeProcess.Close(); err != nil {
		t.Fatal(err)
	}
	if err := runtimeProcess.Close(); err != nil {
		t.Fatal(err)
	}
	if worker.closeCount() != 1 {
		t.Fatalf("execution worker closes = %d, want one", worker.closeCount())
	}
	if _, err := worker.Submit(execution.Request{}); !errors.Is(err, execution.ErrClosed) {
		t.Fatalf("admission after runtime close = %v, want ErrClosed", err)
	}
}

func TestRuntimeExecutionHistoryAdapterTracksOwnedGeneration(t *testing.T) {
	worker := newFakeExecutionWorker()
	request := execution.Request{ProfileID: "default", PositionID: "tile-0_0"}
	if _, err := worker.Submit(request); err != nil {
		t.Fatal(err)
	}
	runtimeProcess := &Runtime{executionWorker: worker}
	history := runtimeExecutionHistory{runtime: runtimeProcess}
	summaries, err := history.ListSummaries(1)
	if err != nil || len(summaries) != 1 || summaries[0].ProfileID != request.ProfileID || summaries[0].PositionID != request.PositionID {
		t.Fatalf("history summaries = %#v, error = %v", summaries, err)
	}
	record, ok := history.Get(summaries[0].ID)
	if !ok || record.ProfileID != request.ProfileID || record.PositionID != request.PositionID {
		t.Fatalf("history record = %#v/%t", record, ok)
	}
	if err := runtimeProcess.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := history.ListSummaries(1); !errors.Is(err, execution.ErrClosed) {
		t.Fatalf("history after close = %v, want ErrClosed", err)
	}
}

func TestRuntimeCloseSanitizesUnconfirmedExecutionReap(t *testing.T) {
	worker := newFakeExecutionWorker()
	worker.closeErr = fmt.Errorf("%w: /secret/child", execution.ErrReapUnconfirmed)
	terminal := make(chan error, 1)
	runtimeProcess := &Runtime{
		executionWorker: worker,
		config:          Config{Terminal: func(err error) { terminal <- err }},
	}
	err := runtimeProcess.Close()
	if !errors.Is(err, errExecutionSupervisionFailed) || strings.Contains(err.Error(), "secret") {
		t.Fatalf("runtime close error = %v", err)
	}
	if terminalErr := runtimeProcess.terminalError(); !errors.Is(terminalErr, errExecutionSupervisionFailed) {
		t.Fatalf("terminal state = %v", terminalErr)
	}
	select {
	case callbackErr := <-terminal:
		if !errors.Is(callbackErr, errExecutionSupervisionFailed) || strings.Contains(callbackErr.Error(), "secret") {
			t.Fatalf("terminal callback = %v", callbackErr)
		}
	default:
		t.Fatal("terminal callback was not invoked")
	}
}

func TestRuntimeExecutionFaultIsSanitizedAndTerminal(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "valid.toml")
	if err := os.WriteFile(configurationPath, runtimeTestConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	worker := newFakeExecutionWorker()
	transport := newRuntimeFakeTransport()
	terminal := make(chan error, 1)
	runtimeProcess, err := New(Config{
		SocketPath: filepath.Join(runtimeSocketTestDirectory(t), "runtime.sock"), InstanceID: runtimeTestInstanceID,
		ConfigPath: configurationPath, TransportFactory: &recordingFactory{transport: transport},
		Terminal: func(err error) { terminal <- err },
	})
	if err != nil {
		t.Fatal(err)
	}
	runtimeProcess.executionFactory = func() (executionWorker, error) { return worker, nil }
	runDone := make(chan error, 1)
	go func() { runDone <- runtimeProcess.Run(context.Background()) }()
	runtimeProcess.mu.Lock()
	server := runtimeProcess.server
	runtimeProcess.mu.Unlock()
	select {
	case <-server.ServingReady():
	case err := <-runDone:
		if strings.Contains(fmt.Sprint(err), "start IPC server failed") {
			t.Skipf("Unix socket creation unavailable in this environment: %v", err)
		}
		t.Fatalf("runtime exited before serving: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("runtime did not become ready")
	}
	worker.faults <- errors.New("/secret/child-reap-detail")
	select {
	case err := <-runDone:
		if !errors.Is(err, errExecutionSupervisionFailed) || strings.Contains(err.Error(), "secret") {
			t.Fatalf("runtime execution fault = %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("runtime did not stop after execution fault")
	}
	select {
	case err := <-terminal:
		if !errors.Is(err, errExecutionSupervisionFailed) || strings.Contains(err.Error(), "secret") {
			t.Fatalf("terminal callback = %v", err)
		}
	default:
		t.Fatal("terminal callback was not invoked")
	}
	if worker.closeCount() != 1 || !transport.wasClosed() {
		t.Fatalf("fault cleanup worker closes/device closed = %d/%t", worker.closeCount(), transport.wasClosed())
	}
}

type fakeExecutionWorker struct {
	mu          sync.Mutex
	requests    []execution.Request
	recordState execution.State
	submitErr   error
	submits     int
	closed      bool
	closes      int
	closeErr    error
	faults      chan error
}

func newFakeExecutionWorker() *fakeExecutionWorker {
	return &fakeExecutionWorker{recordState: execution.StateRunning, faults: make(chan error, 1)}
}

func (worker *fakeExecutionWorker) Submit(request execution.Request) (execution.Record, error) {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	worker.submits++
	if worker.submitErr != nil {
		return execution.Record{}, worker.submitErr
	}
	if worker.closed {
		return execution.Record{}, execution.ErrClosed
	}
	worker.requests = append(worker.requests, request)
	return execution.Record{State: worker.recordState}, nil
}

func (worker *fakeExecutionWorker) submitCount() int {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	return worker.submits
}

func (worker *fakeExecutionWorker) Faults() <-chan error { return worker.faults }

func (worker *fakeExecutionWorker) ListSummaries(limit int) ([]execution.Summary, error) {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	if worker.closed {
		return nil, execution.ErrClosed
	}
	count := min(limit, len(worker.requests))
	summaries := make([]execution.Summary, count)
	for index := range count {
		request := worker.requests[len(worker.requests)-1-index]
		summaries[index] = execution.Summary{ID: fmt.Sprintf("record-%d", len(worker.requests)-index), ProfileID: request.ProfileID, PositionID: request.PositionID, State: worker.recordState}
	}
	return summaries, nil
}

func (worker *fakeExecutionWorker) Get(id string) (execution.Record, bool) {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	for index, request := range worker.requests {
		if id == fmt.Sprintf("record-%d", index+1) {
			return execution.Record{ID: id, ProfileID: request.ProfileID, PositionID: request.PositionID, State: worker.recordState}, true
		}
	}
	return execution.Record{}, false
}

func (worker *fakeExecutionWorker) Close() error {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	if !worker.closed {
		worker.closed = true
		worker.closes++
	}
	return worker.closeErr
}

func (worker *fakeExecutionWorker) requestsSnapshot() []execution.Request {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	requests := make([]execution.Request, len(worker.requests))
	for index, request := range worker.requests {
		request.Arguments = slices.Clone(request.Arguments)
		requests[index] = request
	}
	return requests
}

func (worker *fakeExecutionWorker) closeCount() int {
	worker.mu.Lock()
	defer worker.mu.Unlock()
	return worker.closes
}

func equalExecutionRequest(left, right execution.Request) bool {
	return left.ProfileID == right.ProfileID && left.PositionID == right.PositionID &&
		left.Executable == right.Executable && slices.Equal(left.Arguments, right.Arguments) && left.Timeout == right.Timeout
}
