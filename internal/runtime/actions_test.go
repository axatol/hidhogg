package runtime

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/d200x"
	"hidhogg/internal/profile"
)

func TestProfileActionActivatesExactlyOnceAndUsesNewBindings(t *testing.T) {
	sender := &profilePageSender{}
	service := newTestProfileService(t, sender, nil)
	controller := newProfileActionController(service, service.CurrentEventPositions)

	if err := controller.observe(context.Background(), actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed)); err != nil {
		t.Fatalf("press: %v", err)
	}
	if err := controller.observe(context.Background(), actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased)); err != nil {
		t.Fatalf("release: %v", err)
	}
	if got := sender.callCount(); got != 1 {
		t.Fatalf("activation writes = %d, want one", got)
	}
	if got, ok := service.CurrentProfileID(); !ok || got != "alternate" {
		t.Fatalf("current profile after action = %q/%t, want alternate", got, ok)
	}

	if err := controller.observe(context.Background(), actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased)); err != nil {
		t.Fatalf("duplicate release: %v", err)
	}
	if got := sender.callCount(); got != 1 {
		t.Fatalf("duplicate release writes = %d, want one", got)
	}

	if err := controller.observe(context.Background(), actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed)); err != nil {
		t.Fatalf("post-transition press: %v", err)
	}
	if err := controller.observe(context.Background(), actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased)); err != nil {
		t.Fatalf("post-transition release: %v", err)
	}
	if got := sender.callCount(); got != 2 {
		t.Fatalf("post-transition activation writes = %d, want two total", got)
	}
	if got, ok := service.CurrentProfileID(); !ok || got != "default" {
		t.Fatalf("current profile after reverse action = %q/%t, want default", got, ok)
	}
}

func TestProfileActionRequiresSuccessfulActiveEmission(t *testing.T) {
	sender := &profilePageSender{}
	service := newTestProfileService(t, sender, nil)
	plan := devicePlan{positionsFn: service.CurrentEventPositions}
	var output bytes.Buffer
	controller := &idlePolicyController{
		clock:   realClock{},
		sender:  &policyRecordingSender{},
		plan:    plan,
		stdout:  &output,
		actions: newProfileActionController(service, plan.eventPositions),
	}

	if err := controller.handleInput(context.Background(), inputObservation{event: actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed)}); err != nil {
		t.Fatalf("active press: %v", err)
	}
	if got := sender.callCount(); got != 0 {
		t.Fatalf("activation on press = %d, want zero", got)
	}
	if output.Len() == 0 {
		t.Fatal("active press was not emitted")
	}
	if err := controller.handleInput(context.Background(), inputObservation{event: actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased)}); err != nil {
		t.Fatalf("active release: %v", err)
	}
	if got := sender.callCount(); got != 1 {
		t.Fatalf("activation after emitted pair = %d, want one", got)
	}

	failingOutput := &actionFailingWriter{}
	failingController := &idlePolicyController{
		clock:   realClock{},
		sender:  &policyRecordingSender{},
		plan:    plan,
		stdout:  failingOutput,
		actions: newProfileActionController(service, plan.eventPositions),
	}
	if err := failingController.handleInput(context.Background(), inputObservation{event: actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed)}); err == nil {
		t.Fatal("failed active emission returned nil")
	}
	if got := sender.callCount(); got != 1 {
		t.Fatalf("activation after failed emission = %d, want one total", got)
	}
}

func TestProfileActionRejectsIncompleteAndUnsupportedGestures(t *testing.T) {
	tests := []struct {
		name       string
		events     []d200x.InputEvent
		wantWrites int
	}{
		{name: "release only", events: []d200x.InputEvent{
			actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased),
		}},
		{name: "duplicate press", wantWrites: 1, events: []d200x.InputEvent{
			actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed),
			actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed),
			actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased),
		}},
		{name: "mismatched wire", events: []d200x.InputEvent{
			actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed),
			actionTestInput(1, d200x.InputMarkerButton, d200x.InputActionReleased),
		}},
		{name: "mismatched marker", events: []d200x.InputEvent{
			actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed),
			actionTestInput(0, d200x.InputMarkerEncoder, d200x.InputActionReleased),
		}},
		{name: "encoder rotation", events: []d200x.InputEvent{
			actionTestInput(0, d200x.InputMarkerEncoder, d200x.InputActionRotatedRight),
		}},
		{name: "rotation cancels press", events: []d200x.InputEvent{
			actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed),
			actionTestInput(0, d200x.InputMarkerEncoder, d200x.InputActionRotatedLeft),
			actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased),
		}},
		{name: "unknown input", events: []d200x.InputEvent{
			actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed),
			actionTestInput(0, d200x.InputMarker(0x7f), d200x.InputActionPressed),
			actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased),
		}},
		{name: "unsupported gesture", events: []d200x.InputEvent{
			actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed),
			actionTestInput(0, d200x.InputMarkerButton, d200x.InputAction(0x7f)),
			actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased),
		}},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			sender := &profilePageSender{}
			service := newTestProfileService(t, sender, nil)
			controller := newProfileActionController(service, service.CurrentEventPositions)
			for _, event := range test.events {
				if err := controller.observe(context.Background(), event); err != nil {
					t.Fatalf("observe %#v: %v", event, err)
				}
			}
			if got := sender.callCount(); got != test.wantWrites {
				t.Fatalf("activation writes = %d, want %d", got, test.wantWrites)
			}
		})
	}
}

func TestProfileActionDuplicateReleaseDoesNotRetry(t *testing.T) {
	sender := &profilePageSender{}
	service := newTestProfileService(t, sender, nil)
	controller := newProfileActionController(service, service.CurrentEventPositions)
	pair := []d200x.InputEvent{
		actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed),
		actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased),
	}
	for _, event := range pair {
		if err := controller.observe(context.Background(), event); err != nil {
			t.Fatalf("valid pair: %v", err)
		}
	}
	if err := controller.observe(context.Background(), pair[1]); err != nil {
		t.Fatalf("duplicate release: %v", err)
	}
	if got := sender.callCount(); got != 1 {
		t.Fatalf("writes after duplicate release = %d, want one", got)
	}
}

func TestProfileActionWakeConsumedPairDoesNotActivate(t *testing.T) {
	pageSender := &profilePageSender{}
	frameSender := &policyRecordingSender{}
	service := newTestProfileService(t, pageSender, nil)
	sender := &actionPolicySender{page: pageSender, frame: frameSender}
	plan := devicePlan{brightness: 57, positionsFn: service.CurrentEventPositions}
	var output bytes.Buffer
	controller := &idlePolicyController{
		clock:   realClock{},
		sender:  sender,
		plan:    plan,
		stdout:  &output,
		actions: newProfileActionController(service, plan.eventPositions),
		state:   idlePolicyState{dimmed: true},
	}

	for _, event := range []d200x.InputEvent{
		actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed),
		actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased),
	} {
		if err := controller.handleInput(context.Background(), inputObservation{event: event}); err != nil {
			t.Fatalf("wake event %#v: %v", event, err)
		}
	}
	if got := pageSender.callCount(); got != 0 {
		t.Fatalf("wake activation writes = %d, want zero", got)
	}
	if got := frameSender.commands(); !equalCommands(got, []d200x.Command{d200x.CommandBrightness}) {
		t.Fatalf("wake writes = %v", got)
	}
	if output.Len() != 0 {
		t.Fatalf("wake pair was emitted: %q", output.String())
	}

	for _, event := range []d200x.InputEvent{
		actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed),
		actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased),
	} {
		if err := controller.handleInput(context.Background(), inputObservation{event: event}); err != nil {
			t.Fatalf("active event %#v: %v", event, err)
		}
	}
	if got := pageSender.callCount(); got != 1 {
		t.Fatalf("active post-wake writes = %d, want one", got)
	}
}

func TestProfileActionCurrentTargetIsZeroWrite(t *testing.T) {
	current := testProfile("default", "Default", "Default")
	current.Values[0].Action.ProfileID = "default"
	catalog, err := profile.NewCatalog("default", []profile.Profile{current})
	if err != nil {
		t.Fatal(err)
	}
	sender := &profilePageSender{}
	service, err := NewProfileService(ProfileServiceOptions{
		Catalog:          catalog,
		Sender:           sender,
		InitialProfileID: "default",
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	controller := newProfileActionController(service, service.CurrentEventPositions)
	for _, event := range []d200x.InputEvent{
		actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed),
		actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased),
	} {
		if err := controller.observe(context.Background(), event); err != nil {
			t.Fatalf("current-target event %#v: %v", event, err)
		}
	}
	if got := sender.callCount(); got != 0 {
		t.Fatalf("current-target writes = %d, want zero", got)
	}
}

func TestProfileActionSnapshotChangeMidGestureDoesNotActivate(t *testing.T) {
	sender := &profilePageSender{}
	service := newTestProfileService(t, sender, nil)
	controller := newProfileActionController(service, service.CurrentEventPositions)
	if err := controller.observe(context.Background(), actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed)); err != nil {
		t.Fatalf("press: %v", err)
	}
	if _, err := service.ActivateProfile(context.Background(), "alternate"); err != nil {
		t.Fatalf("mid-gesture profile transition: %v", err)
	}
	if err := controller.observe(context.Background(), actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased)); err != nil {
		t.Fatalf("release after transition: %v", err)
	}
	if got := sender.callCount(); got != 1 {
		t.Fatalf("writes after mid-gesture transition = %d, want one", got)
	}
	if got, ok := service.CurrentProfileID(); !ok || got != "alternate" {
		t.Fatalf("profile after rejected stale gesture = %q/%t", got, ok)
	}
}

func TestProfileActionConditionalActivationSerializesWithIPC(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	sender := &profilePageSender{blockStarted: started, blockRelease: release}
	service := newTestProfileService(t, sender, nil)
	controller := newProfileActionController(service, service.CurrentEventPositions)
	if err := controller.observe(context.Background(), actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed)); err != nil {
		t.Fatalf("press: %v", err)
	}

	ipcDone := make(chan error, 1)
	go func() {
		_, err := service.ActivateProfile(context.Background(), "alternate")
		ipcDone <- err
	}()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("IPC activation did not reach sender")
	}
	if len(controller.pending) != 0 {
		t.Fatal("release candidate survived activation start")
	}

	actionDone := make(chan error, 1)
	go func() {
		actionDone <- controller.observe(context.Background(), actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased))
	}()
	select {
	case err := <-actionDone:
		t.Fatalf("conditional action completed before IPC transition: %v", err)
	case <-time.After(10 * time.Millisecond):
	}
	close(release)
	if err := <-ipcDone; err != nil {
		t.Fatalf("IPC activation: %v", err)
	}
	if err := <-actionDone; err != nil {
		t.Fatalf("stale conditional action: %v", err)
	}
	if got := sender.callCount(); got != 1 {
		t.Fatalf("serialized writes = %d, want one IPC write", got)
	}
}

func TestProfileActionErrorsDoNotRetry(t *testing.T) {
	tests := []struct {
		name string
		err  error
	}{
		{name: "busy", err: context.DeadlineExceeded},
		{name: "shutdown", err: ErrProfileServiceClosed},
		{name: "uncertain", err: ErrProfileStateUncertain},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			service := &actionProfileServiceStub{
				current: testProfile("default", "Default", "Default"),
				err:     test.err,
			}
			controller := newProfileActionController(service, func() map[byte]eventPosition {
				current, _ := service.CurrentProfile()
				return eventPositionsForProfile(current)
			})
			if err := controller.observe(context.Background(), actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed)); err != nil {
				t.Fatalf("press: %v", err)
			}
			if err := controller.observe(context.Background(), actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased)); !errors.Is(err, test.err) {
				t.Fatalf("release error = %v, want %v", err, test.err)
			}
			if got := service.activationCount(); got != 1 {
				t.Fatalf("activation calls = %d, want one", got)
			}
			if err := controller.observe(context.Background(), actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased)); err != nil {
				t.Fatalf("duplicate release: %v", err)
			}
			if got := service.activationCount(); got != 1 {
				t.Fatalf("activation retries = %d, want one", got)
			}
		})
	}
}

func TestRuntimeRunProfileActionFakeTransportFlow(t *testing.T) {
	configurationPath := filepath.Join(t.TempDir(), "profiles.toml")
	if err := os.WriteFile(configurationPath, runtimeActionConfiguration(), 0o600); err != nil {
		t.Fatal(err)
	}
	socketPath := filepath.Join(runtimeSocketTestDirectory(t), "runtime.sock")
	transport := newRuntimeFakeTransport()
	factory := &recordingFactory{transport: transport}
	policyClock := newPolicyFakeClock(time.Unix(1000, 0))
	var output synchronizedWriter
	runtimeProcess, err := New(Config{
		SocketPath:       socketPath,
		InstanceID:       runtimeTestInstanceID,
		ConfigPath:       configurationPath,
		Clock:            policyClock,
		TransportFactory: factory,
		Stdout:           &output,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = runtimeProcess.Close() })
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	runDone := make(chan error, 1)
	go func() { runDone <- runtimeProcess.Run(ctx) }()
	runtimeProcess.mu.Lock()
	server := runtimeProcess.server
	runtimeProcess.mu.Unlock()
	if server == nil {
		t.Fatal("runtime did not create IPC server")
	}
	select {
	case <-server.ServingReady():
	case err := <-runDone:
		t.Fatalf("runtime exited before serving: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("runtime did not become ready")
	}
	waitForPolicyTimers(t, policyClock, 2)
	waitForRuntime(t, func() bool {
		commands, err := commandsFromReports(transport.writesSnapshot())
		return err == nil && runtimeCommandsEqual(commands, runtimeStartupCommandSequence())
	})

	transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionPressed))
	transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionReleased))
	waitForRuntime(t, func() bool {
		profileID, ok := runtimeProcess.CurrentProfileID()
		return ok && profileID == "alternate"
	})
	wantAfterFirstTransition := runtimeLiveCommandSequence(1)
	waitForRuntime(t, func() bool {
		commands, err := commandsFromReports(transport.writesSnapshot())
		return err == nil && runtimeCommandsEqual(commands, wantAfterFirstTransition)
	})
	commands, err := commandsFromReports(transport.writesSnapshot())
	if err != nil {
		t.Fatalf("decode writes after first transition: %v", err)
	}
	assertRuntimeCommandSequence(t, commands, wantAfterFirstTransition)
	if got := stringsCount(output.String(), `"event":"input"`); got != 2 {
		t.Fatalf("first active gesture output count = %d, want two: %q", got, output.String())
	}
	if got := stringsCount(output.String(), `"id":"default-0_0"`); got != 2 {
		t.Fatalf("first active gesture binding output count = %d, want two: %q", got, output.String())
	}

	policyClock.advance(5 * time.Second)
	wantAfterDim := append(append([]d200x.Command(nil), wantAfterFirstTransition...), d200x.CommandBrightness)
	waitForRuntime(t, func() bool {
		commands, err := commandsFromReports(transport.writesSnapshot())
		return err == nil && runtimeCommandsEqual(commands, wantAfterDim)
	})
	transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionPressed))
	transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionReleased))
	wantAfterWake := append(append([]d200x.Command(nil), wantAfterDim...), d200x.CommandBrightness)
	waitForRuntime(t, func() bool {
		commands, err := commandsFromReports(transport.writesSnapshot())
		return err == nil && runtimeCommandsEqual(commands, wantAfterWake)
	})
	if got, ok := runtimeProcess.CurrentProfileID(); !ok || got != "alternate" {
		t.Fatalf("profile after wake pair = %q/%t, want alternate", got, ok)
	}
	if got := stringsCount(output.String(), `"event":"input"`); got != 2 {
		t.Fatalf("wake pair was emitted: %q", output.String())
	}
	commands, err = commandsFromReports(transport.writesSnapshot())
	if err != nil {
		t.Fatalf("decode writes after wake: %v", err)
	}
	assertRuntimeCommandSequence(t, commands, wantAfterWake)

	transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionPressed))
	transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionReleased))
	waitForRuntime(t, func() bool {
		profileID, ok := runtimeProcess.CurrentProfileID()
		return ok && profileID == "default"
	})
	wantAfterSecondTransition := append(append([]d200x.Command(nil), wantAfterWake...), runtimeLiveCommandSequence(1)[len(runtimeStartupCommandSequence()):]...)
	waitForRuntime(t, func() bool {
		commands, err := commandsFromReports(transport.writesSnapshot())
		return err == nil && runtimeCommandsEqual(commands, wantAfterSecondTransition)
	})
	commands, err = commandsFromReports(transport.writesSnapshot())
	if err != nil {
		t.Fatalf("decode writes after second transition: %v", err)
	}
	assertRuntimeCommandSequence(t, commands, wantAfterSecondTransition)
	if got := stringsCount(output.String(), `"event":"input"`); got != 4 {
		t.Fatalf("active gesture output count after wake = %d, want four: %q", got, output.String())
	}
	if got := stringsCount(output.String(), `"id":"alternate-0_0"`); got != 2 {
		t.Fatalf("post-transition binding output count = %d, want two: %q", got, output.String())
	}
	bindings := runtimeProcess.CurrentBindings()
	if len(bindings) != 1 || bindings[0].Position != "0_0" || bindings[0].Action.ProfileID != "alternate" {
		t.Fatalf("post-transition bindings = %#v", bindings)
	}

	cancel()
	select {
	case err := <-runDone:
		if err != nil {
			t.Fatalf("runtime cancellation: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("runtime did not shut down")
	}
	if !transport.wasClosed() {
		t.Fatal("runtime did not close fake transport")
	}
	if _, err := os.Lstat(socketPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("IPC socket after shutdown: %v", err)
	}
}

func runtimeActionConfiguration() []byte {
	var builder strings.Builder
	builder.WriteString("schema_version = 3\nadapter = \"ulanzi.d200x\"\nbrightness = 73\nidle_timeout_seconds = 5\ndefault_profile_id = \"default\"\n\n")
	for _, profileID := range []string{"default", "alternate"} {
		target := "alternate"
		if profileID == "alternate" {
			target = "default"
		}
		fmt.Fprintf(&builder, "[[profiles]]\nid = \"%s\"\nlabel = \"%s\"\n\n", profileID, profileID)
		for index, spec := range d200x.SupportedPositions() {
			fmt.Fprintf(&builder, "[[profiles.positions]]\nid = \"%s-%s\"\nposition = \"%s\"\nlabel = \"%s %d\"\nbackground = \"#102030\"\n", profileID, spec.Name, spec.Name, profileID, index)
			if index == 0 {
				fmt.Fprintf(&builder, "\n[profiles.positions.action]\ntype = \"activate_profile\"\ngesture = \"release\"\nprofile_id = \"%s\"\n", target)
			}
			builder.WriteString("\n")
		}
	}
	return []byte(builder.String())
}

func actionRuntimeInputFrame(wireIndex byte, marker d200x.InputMarker, action d200x.InputAction) d200x.Frame {
	return d200x.NewFrame(d200x.CommandInputEvent, []byte{1, wireIndex, byte(marker), byte(action)})
}

func actionTestInput(wireIndex byte, marker d200x.InputMarker, action d200x.InputAction) d200x.InputEvent {
	return d200x.InputEvent{WireIndex: wireIndex, Marker: marker, Action: action}
}

type actionFailingWriter struct{}

func (*actionFailingWriter) Write([]byte) (int, error) {
	return 0, errors.New("injected output failure")
}

type actionPolicySender struct {
	page  *profilePageSender
	frame *policyRecordingSender
}

func (sender *actionPolicySender) SendPage(ctx context.Context, page d200x.Page, brightness int) error {
	return sender.page.SendPage(ctx, page, brightness)
}

func (sender *actionPolicySender) SendFrame(ctx context.Context, frame d200x.Frame) error {
	return sender.frame.SendFrame(ctx, frame)
}

type actionProfileServiceStub struct {
	mu          sync.Mutex
	current     profile.Profile
	err         error
	activations int
}

func (service *actionProfileServiceStub) ListProfiles() []profile.Profile {
	service.mu.Lock()
	defer service.mu.Unlock()
	return []profile.Profile{cloneRuntimeProfile(service.current)}
}

func (service *actionProfileServiceStub) CurrentProfile() (profile.Profile, bool) {
	service.mu.Lock()
	defer service.mu.Unlock()
	return cloneRuntimeProfile(service.current), service.current.ID != ""
}

func (service *actionProfileServiceStub) CurrentProfileID() (string, bool) {
	service.mu.Lock()
	defer service.mu.Unlock()
	return service.current.ID, service.current.ID != ""
}

func (service *actionProfileServiceStub) CurrentBindings() []profile.Binding {
	service.mu.Lock()
	defer service.mu.Unlock()
	return service.current.Bindings()
}

func (service *actionProfileServiceStub) ActivateProfile(_ context.Context, profileID string) (ActivationResult, error) {
	service.mu.Lock()
	defer service.mu.Unlock()
	service.activations++
	return ActivationResult{ProfileID: profileID}, service.err
}

func (service *actionProfileServiceStub) activationCount() int {
	service.mu.Lock()
	defer service.mu.Unlock()
	return service.activations
}

var _ ProfileService = (*actionProfileServiceStub)(nil)
var _ PageSender = (*actionPolicySender)(nil)
var _ frameSender = (*actionPolicySender)(nil)
