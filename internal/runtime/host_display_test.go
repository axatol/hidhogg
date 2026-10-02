package runtime

import (
	"bytes"
	"context"
	"errors"
	goruntime "runtime"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/d200x"
	"hidhogg/internal/notification"
)

func TestHostDisplayStateIsIdempotentAndSuppressesDarkInput(t *testing.T) {
	clock := newPolicyFakeClock(time.Unix(2_000, 0))
	frames := &policyRecordingSender{}
	wake := &hostWakeRecorder{}
	source := newHostWakeSource(t, 73)
	var output bytes.Buffer
	controller := &idlePolicyController{
		clock:       clock,
		sender:      frames,
		plan:        devicePlan{brightness: 73, idleTimeout: time.Minute},
		stdout:      &output,
		hostManaged: true,
		wakeSender:  wake,
		wakeSource:  source,
		state: idlePolicyState{
			displayAwake: true,
			lastActivity: clock.Now(),
			idleDeadline: clock.Now().Add(time.Minute),
		},
	}

	result, attempted, err := controller.applyHostDisplayState(context.Background(), false)
	if err != nil || !attempted || !result.changed || result.displayAwake {
		t.Fatalf("sleep result = %+v, attempted=%t, err=%v", result, attempted, err)
	}
	if got := frames.commands(); !equalCommands(got, []d200x.Command{d200x.CommandBrightness}) || string(frames.payloads()[0]) != "0" {
		t.Fatalf("sleep frames = %v payloads=%q", got, frames.payloads())
	}
	if duplicate, attempted, err := controller.applyHostDisplayState(context.Background(), false); err != nil || attempted || duplicate.changed {
		t.Fatalf("duplicate sleep = %+v, attempted=%t, err=%v", duplicate, attempted, err)
	}

	for _, event := range []d200x.InputEvent{
		policyInput(0, d200x.InputMarkerButton, d200x.InputActionPressed),
		policyInput(0, d200x.InputMarkerButton, d200x.InputActionReleased),
		policyInput(0, d200x.InputMarker(0x7f), d200x.InputActionPressed),
	} {
		if _, err := controller.handleInputState(context.Background(), inputObservation{event: event, observedAt: clock.Now()}); err != nil {
			t.Fatal(err)
		}
	}
	if output.Len() != 0 || len(frames.commands()) != 1 {
		t.Fatalf("dark input produced output=%q frames=%v", output.String(), frames.commands())
	}
	if _, err := controller.handleInputState(context.Background(), inputObservation{
		event:      policyInput(4, d200x.InputMarkerEncoder, d200x.InputActionRotatedLeft),
		observedAt: clock.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	if got := frames.commands(); !equalCommands(got, []d200x.Command{d200x.CommandBrightness, d200x.CommandBrightness}) || string(frames.payloads()[1]) != "0" {
		t.Fatalf("dark encoder reassert frames = %v payloads=%q", got, frames.payloads())
	}
	if written, err := controller.tryKeepalive(context.Background()); err != nil || !written {
		t.Fatalf("dark keepalive = written %t, err=%v", written, err)
	}
	if got := frames.commands(); !equalCommands(got, []d200x.Command{d200x.CommandBrightness, d200x.CommandBrightness, d200x.CommandEnableInputStream}) {
		t.Fatalf("dark keepalive frames = %v", got)
	}

	if _, err := controller.applySettings(context.Background(), reloadSettings{brightness: 88, idleTimeout: 30 * time.Second}); err != nil {
		t.Fatal(err)
	}
	source.setBrightness(88)
	clock.advance(5 * time.Second)
	result, attempted, err = controller.applyHostDisplayState(context.Background(), true)
	if err != nil || !attempted || !result.changed || !result.displayAwake {
		t.Fatalf("wake result = %+v, attempted=%t, err=%v", result, attempted, err)
	}
	if wake.calls() != 1 || wake.brightness() != 88 {
		t.Fatalf("wake calls/brightness = %d/%d", wake.calls(), wake.brightness())
	}
	if controller.state.lastActivity != clock.Now() || controller.state.idleDeadline != clock.Now().Add(30*time.Second) {
		t.Fatalf("wake idle state = %+v", controller.state)
	}
	if duplicate, attempted, err := controller.applyHostDisplayState(context.Background(), true); err != nil || attempted || duplicate.changed {
		t.Fatalf("duplicate wake = %+v, attempted=%t, err=%v", duplicate, attempted, err)
	}
}

func TestHostDisplayRequestDefersWithoutBlockingTransitionSettings(t *testing.T) {
	clock := newPolicyFakeClock(time.Unix(2_500, 0))
	settings := make(chan idleSettingsRequest)
	hostState := make(chan hostDisplayStateRequest)
	gate := &profileTransitionGate{}
	gate.begin()
	sender := &policyRecordingSender{}
	controller := &idlePolicyController{
		clock:       clock,
		sender:      sender,
		input:       make(chan inputObservation),
		stdout:      &bytes.Buffer{},
		transition:  gate,
		settings:    settings,
		hostState:   hostState,
		hostManaged: true,
		state: idlePolicyState{
			displayAwake: true,
			keepaliveAt:  clock.Now().Add(keepaliveInterval),
		},
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- controller.run(ctx) }()

	hostResult := make(chan hostDisplayStateResponse, 1)
	hostState <- hostDisplayStateRequest{ctx: ctx, displayAwake: false, result: hostResult, state: &idleSettingsRequestState{}}
	settingsResult := make(chan idleSettingsResponse, 1)
	settings <- idleSettingsRequest{ctx: ctx, settings: reloadSettings{brightness: 88}, result: settingsResult, state: &idleSettingsRequestState{}}
	select {
	case response := <-settingsResult:
		if response.err != nil {
			t.Fatal(response.err)
		}
		if response.result.writeAttempted {
			t.Fatal("pending host sleep allowed reload brightness write")
		}
	case <-time.After(time.Second):
		t.Fatal("transition settings were blocked by pending host state")
	}
	select {
	case response := <-hostResult:
		t.Fatalf("host state applied before transition completed: %+v", response)
	default:
	}
	if got := sender.commands(); len(got) != 0 {
		t.Fatalf("frames before pending sleep committed = %v", got)
	}
	gate.end()
	select {
	case response := <-hostResult:
		if response.err != nil || !response.result.changed {
			t.Fatalf("deferred host response = %+v", response)
		}
	case <-time.After(time.Second):
		t.Fatal("host state did not resume after transition")
	}
	if got := sender.commands(); !equalCommands(got, []d200x.Command{d200x.CommandBrightness}) || string(sender.payloads()[0]) != "0" {
		t.Fatalf("pending sleep/reload frames = %v payloads=%q", got, sender.payloads())
	}
	if controller.plan.brightness != 88 {
		t.Fatalf("committed reload brightness = %d, want 88", controller.plan.brightness)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestHostDisplayOffAdmissionPrecedesSimultaneousReloadBrightness(t *testing.T) {
	bridge := newHostDisplayStateBridge()
	bridge.activate()
	defer bridge.close()
	sender := &policyRecordingSender{}
	controller := &idlePolicyController{
		clock:             realClock{},
		sender:            sender,
		plan:              devicePlan{brightness: 73},
		hostManaged:       true,
		hostOffPending:    bridge.hostOffPending,
		hostWriteBoundary: bridge.hostWriteBoundary,
		state:             idlePolicyState{displayAwake: true},
	}
	hostDone := make(chan hostDisplayStateResponse, 1)
	go func() {
		result, err := bridge.set(context.Background(), false)
		hostDone <- hostDisplayStateResponse{result: result, err: err}
	}()
	deadline := time.Now().Add(time.Second)
	for !bridge.hostOffPending() {
		if time.Now().After(deadline) {
			t.Fatal("host-off request was not admitted")
		}
		goruntime.Gosched()
	}
	settingsResult, err := controller.applySettings(context.Background(), reloadSettings{brightness: 88, idleTimeout: time.Minute})
	if err != nil || settingsResult.writeAttempted {
		t.Fatalf("simultaneous reload settings = %+v, err=%v", settingsResult, err)
	}
	if got := sender.commands(); len(got) != 0 {
		t.Fatalf("reload brightened after host-off admission: %v", got)
	}
	request := <-bridge.requests
	if _, deferred, err := controller.handleHostStateRequest(context.Background(), request, nil); err != nil || deferred {
		t.Fatalf("admitted host-off handling = deferred=%t err=%v", deferred, err)
	}
	response := <-hostDone
	if response.err != nil || !response.result.changed {
		t.Fatalf("host-off response = %+v", response)
	}
	if got := sender.commands(); !equalCommands(got, []d200x.Command{d200x.CommandBrightness}) || string(sender.payloads()[0]) != "0" {
		t.Fatalf("simultaneous host-off/reload frames = %v payloads=%q", got, sender.payloads())
	}
	if controller.plan.brightness != 88 {
		t.Fatalf("reload target brightness = %d, want 88", controller.plan.brightness)
	}
}

func TestHostDisplayOffAdmissionSurvivesCancellation(t *testing.T) {
	for _, timing := range []struct {
		name                string
		cancelAfterDelivery bool
	}{
		{name: "before delivery"},
		{name: "before policy claim", cancelAfterDelivery: true},
	} {
		t.Run(timing.name, func(t *testing.T) {
			testHostDisplayOffAdmissionSurvivesCancellation(t, timing.cancelAfterDelivery)
		})
	}
}

func testHostDisplayOffAdmissionSurvivesCancellation(t *testing.T, cancelAfterDelivery bool) {
	t.Helper()
	bridge := newHostDisplayStateBridge()
	bridge.activate()
	defer bridge.close()
	sender := &policyRecordingSender{}
	controller := &idlePolicyController{
		clock:             realClock{},
		sender:            sender,
		plan:              devicePlan{brightness: 73},
		hostManaged:       true,
		hostOffPending:    bridge.hostOffPending,
		hostWriteBoundary: bridge.hostWriteBoundary,
		state:             idlePolicyState{displayAwake: true},
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	hostDone := make(chan hostDisplayStateResponse, 1)
	go func() {
		result, err := bridge.set(ctx, false)
		hostDone <- hostDisplayStateResponse{result: result, err: err}
	}()
	deadline := time.Now().Add(time.Second)
	for !bridge.hostOffPending() {
		if time.Now().After(deadline) {
			t.Fatal("host-off request was not admitted")
		}
		goruntime.Gosched()
	}

	settingsResult, err := controller.applySettings(context.Background(), reloadSettings{brightness: 88, idleTimeout: time.Minute})
	if err != nil || settingsResult.writeAttempted {
		t.Fatalf("reload during admitted host-off = %+v, err=%v", settingsResult, err)
	}
	if controller.plan.brightness != 88 || len(sender.commands()) != 0 {
		t.Fatalf("deferred reload state = plan brightness %d, frames %v", controller.plan.brightness, sender.commands())
	}

	var request hostDisplayStateRequest
	if cancelAfterDelivery {
		request = <-bridge.requests
		cancel()
	} else {
		cancel()
		select {
		case request = <-bridge.requests:
		case response := <-hostDone:
			t.Fatalf("admitted host-off canceled before delivery: %+v", response)
		case <-time.After(time.Second):
			t.Fatal("admitted host-off was not delivered after client cancellation")
		}
	}
	if err := request.ctx.Err(); err != nil {
		t.Fatalf("admitted host-off operation context was canceled: %v", err)
	}
	if _, deferred, err := controller.handleHostStateRequest(context.Background(), request, nil); err != nil || deferred {
		t.Fatalf("admitted host-off handling = deferred %t, err %v", deferred, err)
	}
	response := <-hostDone
	if response.err != nil || !response.result.changed || response.result.displayAwake {
		t.Fatalf("admitted host-off response = %+v", response)
	}
	if !equalCommands(sender.commands(), []d200x.Command{d200x.CommandBrightness}) || string(sender.payloads()[0]) != "0" {
		t.Fatalf("admitted host-off frames = %v payloads=%q", sender.commands(), sender.payloads())
	}
	if controller.plan.brightness != 88 || controller.state.displayAwake || !controller.state.dimmed {
		t.Fatalf("runtime policy after admitted host-off = plan %+v state %+v", controller.plan, controller.state)
	}
}

func TestHostDisplayOffAdmissionWaitsForInFlightReloadWrite(t *testing.T) {
	bridge := newHostDisplayStateBridge()
	bridge.activate()
	defer bridge.close()
	sender := &hostDisplayBoundarySender{
		started: make(chan struct{}),
		release: make(chan struct{}),
	}
	controller := &idlePolicyController{
		clock:             realClock{},
		sender:            sender,
		plan:              devicePlan{brightness: 73},
		hostManaged:       true,
		hostOffPending:    bridge.hostOffPending,
		hostWriteBoundary: bridge.hostWriteBoundary,
		state:             idlePolicyState{displayAwake: true},
	}
	settingsDone := make(chan idleSettingsResponse, 1)
	go func() {
		result, err := controller.applySettings(context.Background(), reloadSettings{brightness: 88})
		settingsDone <- idleSettingsResponse{result: result, err: err}
	}()
	<-sender.started
	hostDone := make(chan hostDisplayStateResponse, 1)
	go func() {
		result, err := bridge.set(context.Background(), false)
		hostDone <- hostDisplayStateResponse{result: result, err: err}
	}()
	deadline := time.Now().Add(time.Second)
	for bridge.requestMu.TryLock() {
		bridge.requestMu.Unlock()
		if time.Now().After(deadline) {
			t.Fatal("host-off request did not reach admission boundary")
		}
		goruntime.Gosched()
	}
	close(sender.release)
	response := <-settingsDone
	if response.err != nil || !response.result.writeAttempted {
		t.Fatalf("in-flight reload response = %+v", response)
	}
	deadline = time.Now().Add(time.Second)
	for !bridge.hostOffPending() {
		if time.Now().After(deadline) {
			t.Fatal("host-off request was not admitted after reload write")
		}
		goruntime.Gosched()
	}
	request := <-bridge.requests
	if _, deferred, err := controller.handleHostStateRequest(context.Background(), request, nil); err != nil || deferred {
		t.Fatalf("host-off handling = deferred=%t err=%v", deferred, err)
	}
	if response := <-hostDone; response.err != nil || !response.result.changed {
		t.Fatalf("host-off response = %+v", response)
	}
}

func TestHostDisplayWakePreservesCurrentNotificationOverlay(t *testing.T) {
	sender := &profilePageSender{}
	service := newNotificationTestService(t, sender, realClock{}, 0)
	if _, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "awake-overlay"}); err != nil {
		t.Fatal(err)
	}
	liveCalls := sender.liveCallsSnapshot()
	if len(liveCalls) != 1 {
		t.Fatalf("notification live calls = %d, want 1", len(liveCalls))
	}
	written := liveCalls[0].Archive().Data
	update, brightness, err := service.hostDisplayWakeState()
	if err != nil {
		t.Fatal(err)
	}
	if brightness != service.effectiveSettings().brightness {
		t.Fatalf("wake brightness = %d, want %d", brightness, service.effectiveSettings().brightness)
	}
	if !bytes.Equal(update.Archive().Data, written) {
		t.Fatal("wake redraw omitted the current notification overlay")
	}
}

func TestHostDisplayWakeUsesEffectiveDarkReloadActivationAndOverlay(t *testing.T) {
	base := reloadTestConfiguration()
	base = bytes.Replace(base, []byte("label = \"alternate 0\"\nbackground = \"#102030\""), []byte("label = \"alternate 0\"\nbackground = \"#102030\"\nnotification_sources = [\"source\"]"), 1)
	initial := buildReloadCandidateForTest(t, base, "default")
	sender := &hostDisplayIntegrationSender{}
	settings := newIdleSettingsBridge()
	service, err := NewProfileService(ProfileServiceOptions{
		Catalog:          initial.Catalog(),
		Sender:           sender,
		InitialProfileID: initial.CurrentProfileID(),
		initialSnapshot:  &initial,
		settingsApplier:  settings,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	clock := newPolicyFakeClock(time.Unix(2_750, 0))
	controller := &idlePolicyController{
		clock:       clock,
		sender:      sender,
		plan:        devicePlan{brightness: 73, idleTimeout: time.Minute},
		input:       make(chan inputObservation),
		stdout:      &bytes.Buffer{},
		transition:  service.profileTransitionGate(),
		settings:    settings.requests,
		wakeSender:  sender,
		wakeSource:  service,
		hostManaged: true,
		state: idlePolicyState{
			displayAwake: true,
			lastActivity: clock.Now(),
			idleDeadline: clock.Now().Add(time.Minute),
			keepaliveAt:  clock.Now().Add(keepaliveInterval),
		},
	}
	if result, attempted, err := controller.applyHostDisplayState(context.Background(), false); err != nil || !attempted || !result.changed {
		t.Fatalf("dark transition = %+v, attempted=%t, err=%v", result, attempted, err)
	}

	policyContext, cancelPolicy := context.WithCancel(context.Background())
	policyDone := make(chan error, 1)
	settings.activate()
	go func() { policyDone <- controller.run(policyContext) }()
	changed := bytes.Replace(base, []byte("brightness = 73"), []byte("brightness = 88"), 1)
	changed = bytes.Replace(changed, []byte("label = \"alternate 0\""), []byte("label = \"reloaded alternate 0\""), 1)
	reloadResult, err := service.reload(context.Background(), func(currentID string) (reloadCandidate, error) {
		return buildReloadCandidateFromBytes(changed, currentID)
	})
	if err != nil || !reloadResult.Changed || !reloadResult.BrightnessChanged {
		t.Fatalf("dark reload = %+v, err=%v", reloadResult, err)
	}
	cancelPolicy()
	if err := <-policyDone; err != nil {
		t.Fatal(err)
	}
	settings.deactivate()
	if controller.plan.brightness != 88 || !controller.state.dimmed || controller.state.displayAwake {
		t.Fatalf("dark reload policy state = plan=%+v state=%+v", controller.plan, controller.state)
	}
	frames := sender.framesSnapshot()
	if len(frames) != 1 || frames[0].Command != d200x.CommandBrightness || string(frames[0].Payload) != "0" {
		t.Fatalf("dark reload physical frames = %+v, want only brightness zero", frames)
	}

	activation, err := service.ActivateProfile(context.Background(), "alternate")
	if err != nil || !activation.Changed {
		t.Fatalf("dark activation = %+v, err=%v", activation, err)
	}
	if _, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "wake-overlay"}); err != nil {
		t.Fatal(err)
	}
	liveUpdates := sender.liveUpdatesSnapshot()
	if len(liveUpdates) != 2 {
		t.Fatalf("dark activation/overlay updates = %d, want 2", len(liveUpdates))
	}
	current, ok := service.CurrentProfile()
	if !ok || current.ID != "alternate" || current.Values[0].Label != "reloaded alternate 0" {
		t.Fatalf("effective profile = %#v, available=%t", current, ok)
	}

	clock.advance(10 * time.Second)
	wakeResult, attempted, err := controller.applyHostDisplayState(context.Background(), true)
	if err != nil || !attempted || !wakeResult.changed {
		t.Fatalf("wake transition = %+v, attempted=%t, err=%v", wakeResult, attempted, err)
	}
	wakeUpdate, wakeBrightness, wakeCalls := sender.wakeSnapshot()
	if wakeCalls != 1 || wakeBrightness != 88 {
		t.Fatalf("wake calls/brightness = %d/%d, want 1/88", wakeCalls, wakeBrightness)
	}
	if !bytes.Equal(wakeUpdate.Archive().Data, liveUpdates[len(liveUpdates)-1].Archive().Data) {
		t.Fatal("wake transaction did not use the latest effective overlay page")
	}
	if got := notificationPageLabel(wakeUpdate.Page(), "0_0"); got != "wake-overlay" {
		t.Fatalf("wake page label = %q, want overlay", got)
	}
}

func TestHostDisplayAttemptedWriteFailureIsFailStop(t *testing.T) {
	controller := &idlePolicyController{
		clock:       newPolicyFakeClock(time.Unix(3_000, 0)),
		sender:      &policyRecordingSender{failCommand: d200x.CommandBrightness, failErr: errors.New("synthetic")},
		hostManaged: true,
		state:       idlePolicyState{displayAwake: true},
	}
	result, attempted, err := controller.applyHostDisplayState(context.Background(), false)
	if err == nil || !attempted || result.changed || !controller.state.displayAwake {
		t.Fatalf("failed sleep = %+v, attempted=%t, err=%v state=%+v", result, attempted, err, controller.state)
	}
}

func TestHostDisplayDarkEncoderReassertFailureIsFailStop(t *testing.T) {
	controller := &idlePolicyController{
		sender:      &policyRecordingSender{failCommand: d200x.CommandBrightness, failErr: errors.New("synthetic")},
		hostManaged: true,
		state:       idlePolicyState{displayAwake: false, dimmed: true},
	}
	_, err := controller.handleInputState(context.Background(), inputObservation{
		event: policyInput(4, d200x.InputMarkerEncoder, d200x.InputActionRotatedRight),
	})
	if err == nil {
		t.Fatal("failed dark encoder brightness reassert returned nil")
	}
	if got := controller.sender.(*policyRecordingSender).commands(); !equalCommands(got, []d200x.Command{d200x.CommandBrightness}) {
		t.Fatalf("failed dark encoder reassert retried: %v", got)
	}
}

func TestHostDisplayBridgeShutdownAfterDeliveryUnblocks(t *testing.T) {
	bridge := newHostDisplayStateBridge()
	bridge.activate()
	done := make(chan error, 1)
	go func() {
		_, err := bridge.set(context.Background(), false)
		done <- err
	}()
	request := <-bridge.requests
	bridge.close()
	if err := <-done; !errors.Is(err, errHostDisplayStatePending) {
		t.Fatalf("set after delivered shutdown = %v", err)
	}
	request.state.mu.Lock()
	aborted := request.state.aborted
	claimed := request.state.claimed
	request.state.mu.Unlock()
	if !aborted || claimed {
		t.Fatalf("shutdown request state = aborted %t, claimed %t", aborted, claimed)
	}
}

func TestHostDisplayBridgeCancelBeforeDeliveryReleasesOffIntent(t *testing.T) {
	bridge := newHostDisplayStateBridge()
	bridge.activate()
	defer bridge.close()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := bridge.set(ctx, false); !errors.Is(err, context.Canceled) {
		t.Fatalf("set before delivery = %v", err)
	}
	if bridge.hostOffPending() {
		t.Fatal("canceled host-off intent remained pending")
	}
}

func TestHostDisplayBridgeShutdownWaitsForClaimedResult(t *testing.T) {
	bridge := newHostDisplayStateBridge()
	bridge.activate()
	done := make(chan hostDisplayStateResponse, 1)
	go func() {
		result, err := bridge.set(context.Background(), false)
		done <- hostDisplayStateResponse{result: result, err: err}
	}()
	request := <-bridge.requests
	if !request.state.claim() {
		t.Fatal("host display request was not claimable")
	}
	bridge.close()
	select {
	case response := <-done:
		t.Fatalf("claimed request returned before definitive result: %+v", response)
	default:
	}
	want := hostDisplayStateResult{displayAwake: false, changed: true}
	request.result <- hostDisplayStateResponse{result: want}
	if response := <-done; response.err != nil || response.result != want {
		t.Fatalf("claimed request result = %+v", response)
	}
}

type hostWakeSource struct {
	mu         sync.Mutex
	update     d200x.LivePageUpdate
	brightness int
}

func newHostWakeSource(t *testing.T, brightness int) *hostWakeSource {
	t.Helper()
	page, err := pageForProfile(testProfile("default", "Default", "default"))
	if err != nil {
		t.Fatal(err)
	}
	update, err := d200x.BuildLivePageUpdate(page)
	if err != nil {
		t.Fatal(err)
	}
	return &hostWakeSource{update: update, brightness: brightness}
}

func (source *hostWakeSource) hostDisplayWakeState() (d200x.LivePageUpdate, int, error) {
	source.mu.Lock()
	defer source.mu.Unlock()
	return source.update, source.brightness, nil
}

func (source *hostWakeSource) setBrightness(brightness int) {
	source.mu.Lock()
	source.brightness = brightness
	source.mu.Unlock()
}

type hostWakeRecorder struct {
	mu              sync.Mutex
	updates         []d200x.LivePageUpdate
	brightnessValue int
}

type hostDisplayIntegrationSender struct {
	mu             sync.Mutex
	frames         []d200x.Frame
	liveUpdates    []d200x.LivePageUpdate
	wakeUpdate     d200x.LivePageUpdate
	wakeBrightness int
	wakeCalls      int
}

type hostDisplayBoundarySender struct {
	started chan struct{}
	release chan struct{}
	once    sync.Once
}

func (sender *hostDisplayBoundarySender) SendFrame(context.Context, d200x.Frame) error {
	sender.once.Do(func() {
		close(sender.started)
		<-sender.release
	})
	return nil
}

func (sender *hostDisplayIntegrationSender) SendFrame(_ context.Context, frame d200x.Frame) error {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	sender.frames = append(sender.frames, d200x.NewFrame(frame.Command, frame.Payload))
	return nil
}

func (sender *hostDisplayIntegrationSender) SendLivePageUpdate(_ context.Context, update d200x.LivePageUpdate) error {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	sender.liveUpdates = append(sender.liveUpdates, update)
	return nil
}

func (sender *hostDisplayIntegrationSender) SendStartupPageUpdate(_ context.Context, update d200x.LivePageUpdate, brightness int) error {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	sender.wakeUpdate = update
	sender.wakeBrightness = brightness
	sender.wakeCalls++
	return nil
}

func (sender *hostDisplayIntegrationSender) liveUpdatesSnapshot() []d200x.LivePageUpdate {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	return append([]d200x.LivePageUpdate(nil), sender.liveUpdates...)
}

func (sender *hostDisplayIntegrationSender) framesSnapshot() []d200x.Frame {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	frames := make([]d200x.Frame, len(sender.frames))
	for index, frame := range sender.frames {
		frames[index] = d200x.NewFrame(frame.Command, frame.Payload)
	}
	return frames
}

func (sender *hostDisplayIntegrationSender) wakeSnapshot() (d200x.LivePageUpdate, int, int) {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	return sender.wakeUpdate, sender.wakeBrightness, sender.wakeCalls
}

func (sender *hostWakeRecorder) SendStartupPageUpdate(_ context.Context, update d200x.LivePageUpdate, brightness int) error {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	sender.updates = append(sender.updates, update)
	sender.brightnessValue = brightness
	return nil
}

func (sender *hostWakeRecorder) calls() int {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	return len(sender.updates)
}

func (sender *hostWakeRecorder) brightness() int {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	return sender.brightnessValue
}
