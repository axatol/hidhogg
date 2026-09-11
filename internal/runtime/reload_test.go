package runtime

import (
	"bytes"
	"context"
	"errors"
	"os"
	"slices"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/d200x"
	"hidhogg/internal/execution"
)

func TestRuntimeReloadPublishesRevisionedSnapshot(t *testing.T) {
	base := reloadTestConfiguration()
	sender := &profilePageSender{}
	runtimeProcess, path := newReloadTestRuntime(t, base, sender, nil)

	status := runtimeProcess.ReloadStatus()
	if status.Revision != 1 || status.Active || status.State != ReloadStateIdle || status.Outcome != ReloadOutcomeReady || status.Reason != ReloadReasonNone {
		t.Fatalf("initial status = %+v", status)
	}
	result, err := runtimeProcess.Reload(context.Background())
	if err != nil || result.Changed || result.Revision != 1 || result.Effect != reloadEffectUnchanged {
		t.Fatalf("unchanged reload = %+v, %v", result, err)
	}

	actionOnly := bytes.Replace(base, []byte("background = \"#102030\"\n\n"), []byte("background = \"#102030\"\n\n[profiles.positions.action]\ntype = \"activate_profile\"\ngesture = \"press\"\nprofile_id = \"alternate\"\n\n"), 1)
	writeReloadTestFile(t, path, actionOnly)
	result, err = runtimeProcess.Reload(context.Background())
	if err != nil || !result.Changed || result.Revision != 2 || result.Effect != reloadEffectActionOnly || result.DisplayUpdated {
		t.Fatalf("action reload = %+v, %v", result, err)
	}
	if sender.callCount() != 0 || len(runtimeProcess.CurrentBindings()) != 1 {
		t.Fatalf("action reload writes/bindings = %d/%d", sender.callCount(), len(runtimeProcess.CurrentBindings()))
	}

	display := bytes.Replace(actionOnly, []byte("label = \"default 0\""), []byte("label = \"changed 0\""), 1)
	writeReloadTestFile(t, path, display)
	result, err = runtimeProcess.Reload(context.Background())
	if err != nil || !result.Changed || result.Revision != 3 || !result.DisplayUpdated {
		t.Fatalf("display reload = %+v, %v", result, err)
	}
	if sender.callCount() != 1 {
		t.Fatalf("display writes = %d, want 1", sender.callCount())
	}
}

func TestRuntimeReloadCommitsSettingsThroughPolicyOwner(t *testing.T) {
	base := reloadTestConfiguration()
	sender := &profilePageSender{}
	runtimeProcess, path := newReloadTestRuntime(t, base, sender, nil)
	applier := &reloadSettingsApplierStub{}
	runtimeProcess.profileService.settings = applier
	changed := bytes.Replace(base, []byte("brightness = 73"), []byte("brightness = 74"), 1)
	writeReloadTestFile(t, path, changed)

	result, err := runtimeProcess.Reload(context.Background())
	if err != nil || result.Revision != 2 || !result.Changed || !result.BrightnessChanged {
		t.Fatalf("settings reload = %+v, %v", result, err)
	}
	if sender.callCount() != 0 || applier.callCount() != 1 || runtimeProcess.profileService.effectiveSettings().brightness != 74 {
		t.Fatalf("settings writes/status = %d/%+v", sender.callCount(), runtimeProcess.ReloadStatus())
	}
}

func TestRuntimeReloadInvalidCandidateRetainsReadySnapshot(t *testing.T) {
	sender := &profilePageSender{}
	runtimeProcess, path := newReloadTestRuntime(t, reloadTestConfiguration(), sender, nil)
	writeReloadTestFile(t, path, []byte("schema_version = 2\n"))
	result, err := runtimeProcess.Reload(context.Background())
	if err == nil || result.Revision != 1 || result.Changed {
		t.Fatalf("invalid reload = %+v, %v", result, err)
	}
	status := runtimeProcess.ReloadStatus()
	if status.Revision != 1 || status.Active || status.Outcome != ReloadOutcomeRejected || runtimeProcess.profileService.Uncertain() {
		t.Fatalf("status after invalid reload = %+v", status)
	}
	if sender.callCount() != 0 {
		t.Fatalf("invalid reload writes = %d", sender.callCount())
	}
}

func TestRuntimeReloadSettingsPrewriteCancellationRetainsSnapshot(t *testing.T) {
	base := reloadTestConfiguration()
	sender := &profilePageSender{}
	runtimeProcess, path := newReloadTestRuntime(t, base, sender, nil)
	runtimeProcess.profileService.settings = &reloadSettingsApplierStub{err: context.Canceled}
	changed := bytes.Replace(base, []byte("brightness = 73"), []byte("brightness = 74"), 1)
	writeReloadTestFile(t, path, changed)
	result, err := runtimeProcess.Reload(context.Background())
	if !errors.Is(err, context.Canceled) || result.Changed || result.Revision != 1 {
		t.Fatalf("prewrite cancellation = %+v, %v", result, err)
	}
	if sender.callCount() != 0 || runtimeProcess.profileService.Uncertain() || runtimeProcess.profileService.effectiveSettings().brightness != 73 {
		t.Fatalf("prewrite cancellation mutated state: writes=%d uncertain=%t settings=%+v", sender.callCount(), runtimeProcess.profileService.Uncertain(), runtimeProcess.profileService.effectiveSettings())
	}
}

func TestRuntimeReloadCombinedSettingsFailureRetainsSnapshotAndFailStops(t *testing.T) {
	base := reloadTestConfiguration()
	terminal := make(chan error, 1)
	sender := &profilePageSender{}
	runtimeProcess, path := newReloadTestRuntime(t, base, sender, func(err error) { terminal <- err })
	runtimeProcess.profileService.settings = &reloadSettingsApplierStub{
		result: idleSettingsApplyResult{writeAttempted: true},
		err:    errors.New("injected settings write failure"),
	}
	changed := bytes.Replace(base, []byte("brightness = 73"), []byte("brightness = 74"), 1)
	changed = bytes.Replace(changed, []byte("label = \"default 0\""), []byte("label = \"changed 0\""), 1)
	writeReloadTestFile(t, path, changed)
	result, err := runtimeProcess.Reload(context.Background())
	if err == nil || !errors.Is(err, ErrProfileStateUncertain) || result.Changed || result.Revision != 1 || sender.callCount() != 1 {
		t.Fatalf("combined failed reload = %+v, %v, page writes=%d", result, err, sender.callCount())
	}
	if !runtimeProcess.profileService.Uncertain() || runtimeProcess.profileService.effectiveSettings().brightness != 73 {
		t.Fatalf("combined failure published state")
	}
	select {
	case <-terminal:
	default:
		t.Fatal("combined write failure did not signal terminal")
	}
}

func TestRuntimeReloadUnblocksWhenSettingsBridgeClosesAfterDelivery(t *testing.T) {
	base := reloadTestConfiguration()
	sender := &profilePageSender{}
	runtimeProcess, path := newReloadTestRuntime(t, base, sender, nil)
	bridge := newIdleSettingsBridge()
	bridge.activate()
	runtimeProcess.profileService.settings = bridge
	changed := bytes.Replace(base, []byte("brightness = 73"), []byte("brightness = 74"), 1)
	writeReloadTestFile(t, path, changed)
	done := make(chan profileReloadResponse, 1)
	go func() {
		result, err := runtimeProcess.Reload(context.Background())
		done <- profileReloadResponse{result: result, err: err}
	}()
	request := <-bridge.requests
	bridge.close()
	response := <-done
	if !errors.Is(response.err, ErrReloadSettingsPending) || response.result.Changed || response.result.Revision != 1 {
		t.Fatalf("reload after settings shutdown = %+v", response)
	}
	if request.state.claim() || runtimeProcess.profileService.Uncertain() {
		t.Fatalf("shutdown request remained claimable or made runtime uncertain")
	}
	result, err := runtimeProcess.ActivateProfile(context.Background(), "default")
	if err != nil || result.Changed {
		t.Fatalf("coordinator did not recover after shutdown: %+v, %v", result, err)
	}
}

func TestRuntimeReloadLeavesExistingExecutionRecordUntouched(t *testing.T) {
	worker := newFakeExecutionWorker()
	sender := &profilePageSender{}
	runtimeProcess, path := newReloadTestRuntime(t, reloadTestConfiguration(), sender, nil)
	runtimeProcess.executionWorker = worker
	before, err := worker.Submit(execution.Request{ProfileID: "default", PositionID: "tile-0_0", Executable: "/bin/echo"})
	if err != nil {
		t.Fatal(err)
	}
	changed := bytes.Replace(reloadTestConfiguration(), []byte("label = \"alternate\""), []byte("label = \"renamed\""), 1)
	writeReloadTestFile(t, path, changed)
	if _, err := runtimeProcess.Reload(context.Background()); err != nil {
		t.Fatal(err)
	}
	after, ok := worker.Get("record-1")
	if !ok || before.State != after.State || after.ProfileID != "default" || after.PositionID != "tile-0_0" {
		t.Fatalf("execution record changed across reload: before=%+v after=%+v ok=%t", before, after, ok)
	}
	if worker.closeCount() != 0 {
		t.Fatalf("reload closed execution worker %d times", worker.closeCount())
	}
}

func TestRuntimeReloadResetsPartialGesture(t *testing.T) {
	base := reloadTestConfiguration()
	withAction := bytes.Replace(base, []byte("background = \"#102030\"\n\n"), []byte("background = \"#102030\"\n\n[profiles.positions.action]\ntype = \"activate_profile\"\ngesture = \"press\"\nprofile_id = \"alternate\"\n\n"), 1)
	sender := &profilePageSender{}
	runtimeProcess, path := newReloadTestRuntime(t, withAction, sender, nil)
	service := runtimeProcess.profileService
	controller := newProfileActionController(service, service.CurrentEventPositions)
	press := actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed)
	release := actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased)
	if err := controller.observe(context.Background(), press); err != nil {
		t.Fatal(err)
	}

	writeReloadTestFile(t, path, runtimeTestConfiguration())
	result, err := runtimeProcess.Reload(context.Background())
	if err != nil || result.CurrentProfileFallback || result.Revision != 2 {
		t.Fatalf("gesture-reset reload = %+v, %v", result, err)
	}
	if err := controller.observe(context.Background(), release); err != nil {
		t.Fatal(err)
	}
	if currentID, _ := runtimeProcess.CurrentProfileID(); currentID != "default" {
		t.Fatalf("current profile = %q", currentID)
	}
	if sender.callCount() != 1 {
		t.Fatalf("fallback/release writes = %d, want reload only", sender.callCount())
	}
}

func TestRuntimeReloadFallsBackWhenActiveProfileIsRemoved(t *testing.T) {
	sender := &profilePageSender{}
	runtimeProcess, path := newReloadTestRuntime(t, reloadTestConfiguration(), sender, nil)
	if _, err := runtimeProcess.ActivateProfile(context.Background(), "alternate"); err != nil {
		t.Fatal(err)
	}
	writeReloadTestFile(t, path, runtimeTestConfiguration())
	result, err := runtimeProcess.Reload(context.Background())
	if err != nil || !result.CurrentProfileFallback || result.Revision != 2 {
		t.Fatalf("fallback reload = %+v, %v", result, err)
	}
	if currentID, _ := runtimeProcess.CurrentProfileID(); currentID != "default" {
		t.Fatalf("current profile = %q", currentID)
	}
	if sender.callCount() != 2 {
		t.Fatalf("activation plus fallback writes = %d, want 2", sender.callCount())
	}
}

func TestRuntimeReloadBusyAndShutdownAdmission(t *testing.T) {
	runtimeProcess, _ := newReloadTestRuntime(t, reloadTestConfiguration(), &profilePageSender{}, nil)
	started := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	runtimeProcess.reloadBuilder = func(path, currentID string) (reloadCandidate, error) {
		once.Do(func() { close(started) })
		<-release
		return buildReloadCandidate(path, currentID)
	}
	done := make(chan error, 1)
	go func() {
		_, err := runtimeProcess.Reload(context.Background())
		done <- err
	}()
	<-started
	if _, err := runtimeProcess.Reload(context.Background()); !errors.Is(err, ErrReloadBusy) {
		t.Fatalf("concurrent reload error = %v", err)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if err := runtimeProcess.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := runtimeProcess.Reload(context.Background()); !errors.Is(err, ErrReloadClosed) {
		t.Fatalf("reload after close = %v", err)
	}
}

func TestRuntimeReloadCancellationAfterPreparationIsNonterminal(t *testing.T) {
	sender := &profilePageSender{}
	runtimeProcess, _ := newReloadTestRuntime(t, reloadTestConfiguration(), sender, nil)
	changed := bytes.Replace(reloadTestConfiguration(), []byte("label = \"default 0\""), []byte("label = \"changed 0\""), 1)
	changedPath := writeReloadConfiguration(t, changed)
	ctx, cancel := context.WithCancel(context.Background())
	runtimeProcess.reloadBuilder = func(_ string, currentID string) (reloadCandidate, error) {
		candidate, err := buildReloadCandidate(changedPath, currentID)
		cancel()
		return candidate, err
	}
	result, err := runtimeProcess.Reload(ctx)
	if !errors.Is(err, context.Canceled) || result.Revision != 1 || result.Changed {
		t.Fatalf("canceled reload = %+v, %v", result, err)
	}
	if sender.callCount() != 0 || runtimeProcess.profileService.Uncertain() {
		t.Fatalf("canceled reload writes/uncertain = %d/%t", sender.callCount(), runtimeProcess.profileService.Uncertain())
	}
}

func TestRuntimeReloadAndActivationShareOneTotalOrder(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	sender := &profilePageSender{blockStarted: started, blockRelease: release}
	runtimeProcess, path := newReloadTestRuntime(t, reloadTestConfiguration(), sender, nil)
	activationDone := make(chan error, 1)
	go func() {
		_, err := runtimeProcess.ActivateProfile(context.Background(), "alternate")
		activationDone <- err
	}()
	<-started
	changed := bytes.Replace(reloadTestConfiguration(), []byte("label = \"alternate 0\""), []byte("label = \"changed alternate 0\""), 1)
	writeReloadTestFile(t, path, changed)
	reloadDone := make(chan profileReloadResponse, 1)
	go func() {
		result, err := runtimeProcess.Reload(context.Background())
		reloadDone <- profileReloadResponse{result: result, err: err}
	}()
	select {
	case response := <-reloadDone:
		t.Fatalf("reload overtook active activation: %+v", response)
	default:
	}
	close(release)
	if err := <-activationDone; err != nil {
		t.Fatal(err)
	}
	response := <-reloadDone
	if response.err != nil || !response.result.Changed || response.result.Revision != 2 {
		t.Fatalf("ordered reload = %+v", response)
	}
	current, ok := runtimeProcess.CurrentProfile()
	if !ok || current.ID != "alternate" || current.Values[0].Label != "changed alternate 0" {
		t.Fatalf("committed current profile = %#v, %t", current, ok)
	}
	if sender.callCount() != 2 || sender.maxConcurrentValue() != 1 {
		t.Fatalf("writes/max concurrency = %d/%d", sender.callCount(), sender.maxConcurrentValue())
	}
}

func TestRuntimeReloadCombinedPageAndSettingsCommitOnceInOrder(t *testing.T) {
	base := reloadTestConfiguration()
	path := writeReloadConfiguration(t, base)
	initial := buildReloadCandidateForTest(t, base, "default")
	sender := &reloadCombinedSender{}
	bridge := newIdleSettingsBridge()
	service, err := NewProfileService(ProfileServiceOptions{
		Catalog:          initial.Catalog(),
		Sender:           sender,
		InitialProfileID: initial.CurrentProfileID(),
		initialSnapshot:  &initial,
		settingsApplier:  bridge,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	clock := newPolicyFakeClock(time.Unix(1200, 0))
	controller := &idlePolicyController{
		clock:      clock,
		sender:     sender,
		plan:       devicePlan{brightness: 73},
		actions:    &profileActionController{},
		transition: service.profileTransitionGate(),
		settings:   bridge.requests,
		state: idlePolicyState{
			lastActivity: clock.Now(),
			keepaliveAt:  clock.Now().Add(keepaliveInterval),
		},
	}
	ctx, cancel := context.WithCancel(context.Background())
	policyDone := make(chan error, 1)
	bridge.activate()
	go func() { policyDone <- controller.run(ctx) }()
	defer func() {
		cancel()
		_ = <-policyDone
		bridge.deactivate()
	}()
	runtimeProcess := &Runtime{
		config:         Config{ConfigPath: path},
		profileService: service,
		reloadBuilder:  buildReloadCandidate,
		reload:         reloadAdmission{outcome: ReloadOutcomeReady, reason: ReloadReasonNone},
	}
	changed := bytes.Replace(base, []byte("brightness = 73"), []byte("brightness = 74"), 1)
	changed = bytes.Replace(changed, []byte("label = \"default 0\""), []byte("label = \"changed 0\""), 1)
	writeReloadTestFile(t, path, changed)
	result, err := runtimeProcess.Reload(context.Background())
	if err != nil || !result.Changed || result.Revision != 2 || !result.DisplayUpdated || !result.BrightnessChanged {
		t.Fatalf("combined reload = %+v, %v", result, err)
	}
	if got := sender.operationsSnapshot(); !slices.Equal(got, []string{"page", "brightness:74"}) {
		t.Fatalf("combined operations = %v", got)
	}
	if service.effectiveSettings().brightness != 74 || controller.plan.brightness != 74 {
		t.Fatalf("committed settings snapshot/policy = %+v/%+v", service.effectiveSettings(), controller.plan)
	}
}

func TestRuntimeReloadWriteFailureRetainsSnapshotAndSignalsTerminal(t *testing.T) {
	terminal := make(chan error, 1)
	sender := &profilePageSender{err: errors.New("injected write failure")}
	runtimeProcess, path := newReloadTestRuntime(t, reloadTestConfiguration(), sender, func(err error) { terminal <- err })
	changed := bytes.Replace(reloadTestConfiguration(), []byte("label = \"default 0\""), []byte("label = \"changed 0\""), 1)
	writeReloadTestFile(t, path, changed)

	result, err := runtimeProcess.Reload(context.Background())
	if err == nil || !errors.Is(err, ErrProfileStateUncertain) || result.Revision != 1 || result.Changed {
		t.Fatalf("failed reload = %+v, %v", result, err)
	}
	if !runtimeProcess.profileService.Uncertain() || runtimeProcess.ReloadStatus().Revision != 1 {
		t.Fatalf("failure did not preserve revision/uncertain state")
	}
	select {
	case <-terminal:
	default:
		t.Fatal("terminal callback was not invoked")
	}
}

func newReloadTestRuntime(t *testing.T, data []byte, sender *profilePageSender, terminal func(error)) (*Runtime, string) {
	t.Helper()
	path := writeReloadConfiguration(t, data)
	candidate := buildReloadCandidateForTest(t, data, "default")
	service, err := NewProfileService(ProfileServiceOptions{
		Catalog:          candidate.Catalog(),
		Sender:           sender,
		InitialProfileID: candidate.CurrentProfileID(),
		initialSnapshot:  &candidate,
		Terminal:         terminal,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	return &Runtime{
		config:         Config{ConfigPath: path},
		profileService: service,
		reloadBuilder:  buildReloadCandidate,
		reload:         reloadAdmission{outcome: ReloadOutcomeReady, reason: ReloadReasonNone},
	}, path
}

func writeReloadTestFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

type reloadSettingsApplierStub struct {
	mu     sync.Mutex
	calls  []reloadSettings
	result idleSettingsApplyResult
	err    error
}

type reloadCombinedSender struct {
	mu         sync.Mutex
	operations []string
}

func (sender *reloadCombinedSender) SendLivePageUpdate(context.Context, d200x.LivePageUpdate) error {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	sender.operations = append(sender.operations, "page")
	return nil
}

func (sender *reloadCombinedSender) SendFrame(_ context.Context, frame d200x.Frame) error {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	sender.operations = append(sender.operations, "brightness:"+string(frame.Payload))
	return nil
}

func (sender *reloadCombinedSender) operationsSnapshot() []string {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	return slices.Clone(sender.operations)
}

func (applier *reloadSettingsApplierStub) ApplySettings(_ context.Context, settings reloadSettings) (idleSettingsApplyResult, error) {
	applier.mu.Lock()
	defer applier.mu.Unlock()
	applier.calls = append(applier.calls, settings)
	return applier.result, applier.err
}

func (applier *reloadSettingsApplierStub) callCount() int {
	applier.mu.Lock()
	defer applier.mu.Unlock()
	return len(applier.calls)
}
