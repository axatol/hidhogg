package runtime

import (
	"context"
	"errors"
	"testing"
	"time"

	"hidhogg/internal/d200x"
	"hidhogg/internal/profile"
)

func TestReadInputObservationsAttributesTransitionAtReception(t *testing.T) {
	fixture := newInputReaderFixture(t, &profilePageSender{})
	<-fixture.transport.readStarted

	activationDone := make(chan error, 1)
	go func() {
		_, err := fixture.service.ActivateProfile(context.Background(), "alternate")
		activationDone <- err
	}()
	select {
	case err := <-activationDone:
		if err != nil {
			t.Fatalf("profile activation: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("profile activation did not complete")
	}
	generation, active := fixture.gate.snapshot()
	if active {
		t.Fatal("profile transition remained active after activation")
	}

	fixture.transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionPressed))
	close(fixture.transport.readGate)
	observation := receiveInputObservation(t, fixture.observations)
	if observation.transitionSuppressed {
		t.Fatal("press received after transition completion was suppressed")
	}
	if observation.transitionGeneration != generation {
		t.Fatalf("observation generation = %d, want %d", observation.transitionGeneration, generation)
	}
	if err := fixture.controller.handleInput(context.Background(), observation); err != nil {
		t.Fatalf("handle post-transition press: %v", err)
	}
	if got := fixture.output.String(); got == "" || !containsAll(got, `"event":"input"`, `"id":"0_0"`, `"action":"pressed"`) {
		t.Fatalf("post-transition press output = %q", got)
	}
	if _, held := fixture.controller.actions.held[profileActionKey{marker: d200x.InputMarkerButton, wireIndex: 0}]; !held {
		t.Fatal("post-transition press did not update physical latch")
	}
}

func TestReadInputObservationsSubmitsFirstPressAfterCompletedTransition(t *testing.T) {
	service := newInputReaderExecuteService(t, &profilePageSender{})
	worker := newFakeExecutionWorker()
	fixture := newInputReaderFixtureWithService(t, service, worker)
	<-fixture.transport.readStarted

	activationDone := make(chan error, 1)
	go func() {
		_, err := fixture.service.ActivateProfile(context.Background(), "alternate")
		activationDone <- err
	}()
	select {
	case err := <-activationDone:
		if err != nil {
			t.Fatalf("profile activation: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("profile activation did not complete")
	}

	fixture.transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionPressed))
	close(fixture.transport.readGate)
	press := receiveInputObservation(t, fixture.observations)
	if press.transitionSuppressed {
		t.Fatal("first press after transition completion was suppressed")
	}
	if err := fixture.controller.handleInput(context.Background(), press); err != nil {
		t.Fatalf("handle first post-transition press: %v", err)
	}
	requests := worker.requestsSnapshot()
	if len(requests) != 1 {
		t.Fatalf("first post-transition press submissions = %d, want one", len(requests))
	}
	if requests[0].ProfileID != "alternate" || requests[0].PositionID != "0_0" || requests[0].Executable != "/controlled/helper" {
		t.Fatalf("first post-transition request = %#v", requests[0])
	}

	fixture.transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionPressed))
	duplicatePress := receiveInputObservation(t, fixture.observations)
	if err := fixture.controller.handleInput(context.Background(), duplicatePress); err != nil {
		t.Fatalf("handle duplicate press: %v", err)
	}
	if got := len(worker.requestsSnapshot()); got != 1 {
		t.Fatalf("duplicate press submissions = %d, want one", got)
	}

	fixture.transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionReleased))
	release := receiveInputObservation(t, fixture.observations)
	if err := fixture.controller.handleInput(context.Background(), release); err != nil {
		t.Fatalf("handle matching release: %v", err)
	}
	if got := len(worker.requestsSnapshot()); got != 1 {
		t.Fatalf("matching release submissions = %d, want one", got)
	}

	fixture.transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionPressed))
	nextPress := receiveInputObservation(t, fixture.observations)
	if err := fixture.controller.handleInput(context.Background(), nextPress); err != nil {
		t.Fatalf("handle fresh press after release: %v", err)
	}
	if got := len(worker.requestsSnapshot()); got != 2 {
		t.Fatalf("fresh press submissions = %d, want two", got)
	}
}

func TestReadInputObservationsSuppressesEventsReceivedDuringTransition(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	fixture := newInputReaderFixture(t, &profilePageSender{
		blockStarted: started,
		blockRelease: release,
	})
	released := false
	t.Cleanup(func() {
		if !released {
			close(release)
		}
	})
	<-fixture.transport.readStarted

	activationDone := make(chan error, 1)
	go func() {
		_, err := fixture.service.ActivateProfile(context.Background(), "alternate")
		activationDone <- err
	}()
	select {
	case <-started:
	case err := <-activationDone:
		t.Fatalf("profile activation completed before transition observation: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("profile transition did not reach blocked sender")
	}
	if _, active := fixture.gate.snapshot(); !active {
		t.Fatal("profile transition was not active at blocked sender")
	}

	fixture.transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionPressed))
	close(fixture.transport.readGate)
	press := receiveInputObservation(t, fixture.observations)
	if !press.transitionSuppressed {
		t.Fatal("press received during transition was not suppressed")
	}
	if err := fixture.controller.handleInput(context.Background(), press); err != nil {
		t.Fatalf("handle transition press: %v", err)
	}
	if got := fixture.output.String(); got != "" {
		t.Fatalf("transition press output = %q", got)
	}
	if _, held := fixture.controller.actions.held[profileActionKey{marker: d200x.InputMarkerButton, wireIndex: 0}]; !held {
		t.Fatal("suppressed press did not reconcile physical latch")
	}

	fixture.transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionReleased))
	releaseObservation := receiveInputObservation(t, fixture.observations)
	if !releaseObservation.transitionSuppressed {
		t.Fatal("release received during transition was not suppressed")
	}
	if err := fixture.controller.handleInput(context.Background(), releaseObservation); err != nil {
		t.Fatalf("handle transition release: %v", err)
	}
	if got := fixture.output.String(); got != "" {
		t.Fatalf("transition release output = %q", got)
	}
	if _, held := fixture.controller.actions.held[profileActionKey{marker: d200x.InputMarkerButton, wireIndex: 0}]; held {
		t.Fatal("suppressed release did not clear physical latch")
	}

	close(release)
	released = true
	select {
	case err := <-activationDone:
		if err != nil {
			t.Fatalf("profile activation: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("profile activation did not complete after release")
	}
	fixture.transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionPressed))
	postTransition := receiveInputObservation(t, fixture.observations)
	if postTransition.transitionSuppressed {
		t.Fatal("press received after transition completion was suppressed")
	}
	if err := fixture.controller.handleInput(context.Background(), postTransition); err != nil {
		t.Fatalf("handle post-transition press: %v", err)
	}
	if got := fixture.output.String(); got == "" || !containsAll(got, `"event":"input"`, `"action":"pressed"`) {
		t.Fatalf("post-transition press output = %q", got)
	}
}

func TestReadInputObservationsRejectsObservationDeliveredAcrossTransition(t *testing.T) {
	fixture := newInputReaderFixture(t, &profilePageSender{})
	<-fixture.transport.readStarted

	fixture.transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionPressed))
	close(fixture.transport.readGate)
	press := receiveInputObservation(t, fixture.observations)
	fixture.transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionReleased))
	release := receiveInputObservation(t, fixture.observations)
	oldGeneration, active := fixture.gate.snapshot()
	if active {
		t.Fatal("profile transition unexpectedly active before queued observations")
	}
	if press.transitionSuppressed || release.transitionSuppressed {
		t.Fatal("observations were suppressed before transition")
	}
	if press.transitionGeneration != oldGeneration || release.transitionGeneration != oldGeneration {
		t.Fatalf("queued observation generations = %d/%d, want %d", press.transitionGeneration, release.transitionGeneration, oldGeneration)
	}

	fixture.gate.begin()
	fixture.gate.end()
	if err := fixture.controller.handleInput(context.Background(), press); err != nil {
		t.Fatalf("handle queued press: %v", err)
	}
	if err := fixture.controller.handleInput(context.Background(), release); err != nil {
		t.Fatalf("handle queued release: %v", err)
	}
	if got := fixture.output.String(); got != "" {
		t.Fatalf("queued observations crossed transition: %q", got)
	}
	if len(fixture.controller.actions.held) != 0 {
		t.Fatalf("queued observations left physical latch = %#v", fixture.controller.actions.held)
	}

	fixture.transport.queueFrame(actionRuntimeInputFrame(0, d200x.InputMarkerButton, d200x.InputActionPressed))
	postTransition := receiveInputObservation(t, fixture.observations)
	if postTransition.transitionSuppressed || postTransition.transitionGeneration == oldGeneration {
		t.Fatalf("post-transition observation = %+v", postTransition)
	}
	if err := fixture.controller.handleInput(context.Background(), postTransition); err != nil {
		t.Fatalf("handle fresh post-transition press: %v", err)
	}
	if got := fixture.output.String(); got == "" || !containsAll(got, `"event":"input"`, `"action":"pressed"`) {
		t.Fatalf("fresh post-transition press output = %q", got)
	}
}

type inputReaderFixture struct {
	runtime      *Runtime
	transport    *runtimeFakeTransport
	session      *d200x.Session
	service      *RuntimeProfileService
	gate         *profileTransitionGate
	controller   *idlePolicyController
	observations chan inputObservation
	output       *synchronizedWriter
	readerDone   chan error
	cancel       context.CancelFunc
}

func newInputReaderFixture(t *testing.T, sender *profilePageSender) *inputReaderFixture {
	t.Helper()
	service := newTestProfileService(t, sender, nil)
	return newInputReaderFixtureWithService(t, service)
}

func newInputReaderFixtureWithService(t *testing.T, service *RuntimeProfileService, executors ...executionSubmitter) *inputReaderFixture {
	t.Helper()
	transport := newRuntimeFakeTransport()
	transport.readStarted = make(chan struct{})
	transport.readGate = make(chan struct{})
	session := d200x.NewSession(&recordingFactory{transport: transport})
	candidate := d200x.NewCandidate("opaque-input-reader-test", d200x.VendorID, d200x.ProductID, d200x.InterfaceNumber)
	if err := session.Open(context.Background(), candidate); err != nil {
		t.Fatalf("session open: %v", err)
	}
	output := &synchronizedWriter{}
	plan := devicePlan{positionsFn: service.CurrentEventPositions}
	controller := &idlePolicyController{
		clock:      realClock{},
		sender:     &policyRecordingSender{},
		plan:       plan,
		stdout:     output,
		actions:    newProfileActionController(service, plan.eventPositions, executors...),
		transition: service.profileTransitionGate(),
	}
	ctx, cancel := context.WithCancel(context.Background())
	observations := make(chan inputObservation)
	runtimeProcess := &Runtime{
		clock:          realClock{},
		session:        session,
		profileService: service,
	}
	readerDone := make(chan error, 1)
	go func() {
		readerDone <- runtimeProcess.readInputObservations(ctx, observations)
	}()
	fixture := &inputReaderFixture{
		runtime:      runtimeProcess,
		transport:    transport,
		session:      session,
		service:      service,
		gate:         service.profileTransitionGate(),
		controller:   controller,
		observations: observations,
		output:       output,
		readerDone:   readerDone,
		cancel:       cancel,
	}
	t.Cleanup(func() {
		cancel()
		select {
		case <-transport.readGate:
		default:
			close(transport.readGate)
		}
		select {
		case err := <-readerDone:
			if err != nil {
				t.Errorf("input reader: %v", err)
			}
		case <-time.After(2 * time.Second):
			t.Error("input reader did not stop")
		}
		if err := session.Close(); err != nil && !errors.Is(err, context.Canceled) {
			t.Errorf("session close: %v", err)
		}
	})
	return fixture
}

func newInputReaderExecuteService(t *testing.T, sender *profilePageSender) *RuntimeProfileService {
	t.Helper()
	current := testProfile("default", "Default", "Default")
	target := testProfile("alternate", "Alternate", "Alternate")
	target.Values[0].Action = &profile.Action{
		Type:           profile.ExecuteActionType,
		Gesture:        profile.PressGesture,
		Executable:     "/controlled/helper",
		Arguments:      []string{"from-reader"},
		TimeoutSeconds: 3,
	}
	catalog, err := profile.NewCatalog("default", []profile.Profile{current, target})
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewProfileService(ProfileServiceOptions{Catalog: catalog, Sender: sender})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	return service
}

func receiveInputObservation(t *testing.T, observations <-chan inputObservation) inputObservation {
	t.Helper()
	select {
	case observation, ok := <-observations:
		if !ok {
			t.Fatal("input reader closed observation channel")
		}
		return observation
	case <-time.After(2 * time.Second):
		t.Fatal("input observation was not delivered")
		return inputObservation{}
	}
}
