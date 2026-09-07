package runtime

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/d200x"
	"hidhogg/internal/ipc"
	"hidhogg/internal/profile"
)

func TestProfileServiceCurrentAndUnknownActivationDoNotWrite(t *testing.T) {
	sender := &profilePageSender{}
	service := newTestProfileService(t, sender, nil)

	result, err := service.ActivateProfile(context.Background(), "default")
	if err != nil {
		t.Fatalf("current activation error = %v", err)
	}
	if result.ProfileID != "default" || result.Changed {
		t.Fatalf("current activation result = %+v", result)
	}
	if _, err := service.ActivateProfile(context.Background(), "missing"); !errors.Is(err, ErrUnknownProfile) {
		t.Fatalf("unknown activation error = %v", err)
	}
	if got := sender.callCount(); got != 0 {
		t.Fatalf("page writes = %d, want 0", got)
	}
}

func TestProfileServiceCommitsPageAndBindingsOnlyAfterSend(t *testing.T) {
	sender := &profilePageSender{}
	service := newTestProfileService(t, sender, nil)

	result, err := service.ActivateProfile(context.Background(), "alternate")
	if err != nil {
		t.Fatalf("alternate activation error = %v", err)
	}
	if result.ProfileID != "alternate" || !result.Changed {
		t.Fatalf("alternate activation result = %+v", result)
	}
	call := sender.callsSnapshot()[0]
	if len(call.page.Positions) != d200x.DisplayPositionCount {
		t.Fatalf("sent page positions = %d, want %d", len(call.page.Positions), d200x.DisplayPositionCount)
	}
	if call.page.Positions[0].Label != "Alternate 0_0" {
		t.Fatalf("sent page first label = %q", call.page.Positions[0].Label)
	}
	liveCalls := sender.liveCallsSnapshot()
	if len(liveCalls) != 1 {
		t.Fatalf("live update calls = %d, want one", len(liveCalls))
	}
	update := liveCalls[0]
	if update.Page().Positions[0].Label != "Alternate 0_0" {
		t.Fatalf("live update first label = %q", update.Page().Positions[0].Label)
	}
	if update.Frame().Command != d200x.CommandCompleteDisplayUpload || len(update.Archive().Data) == 0 {
		t.Fatal("live update was not prebuilt typed full-page data")
	}
	if got, ok := service.CurrentProfileID(); !ok || got != "alternate" {
		t.Fatalf("current profile = %q/%t", got, ok)
	}
	bindings := service.CurrentBindings()
	if len(bindings) != 1 || bindings[0].Position != "0_0" || bindings[0].Action.ProfileID != "default" {
		t.Fatalf("current bindings = %#v", bindings)
	}
}

func TestProfileServiceVerboseTransitionLogIsBoundedAndPayloadFree(t *testing.T) {
	var output synchronizedWriter
	catalog := testProfileCatalog(t)
	service, err := NewProfileService(ProfileServiceOptions{
		Catalog: catalog,
		Sender:  &profilePageSender{},
		Verbose: true,
		Logger:  &output,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	if _, err := service.ActivateProfile(context.Background(), "alternate"); err != nil {
		t.Fatal(err)
	}
	log := output.String()
	for _, phase := range []string{"started", "prepared", "committed", "ended"} {
		if !strings.Contains(log, "phase="+phase) {
			t.Fatalf("transition log omitted phase %q: %q", phase, log)
		}
	}
	if len(log) > 4*512 || strings.Contains(log, "PK") {
		t.Fatalf("transition log was unbounded or contained archive bytes: %q", log)
	}
}

func TestProfileServiceUsesOneCanonicalFullPageUpdateAfterStartup(t *testing.T) {
	transport := newRuntimeFakeTransport()
	session := d200x.NewSession(&recordingFactory{transport: transport})
	candidate := d200x.NewCandidate("opaque-profile-test", d200x.VendorID, d200x.ProductID, d200x.InterfaceNumber)
	if err := session.Open(context.Background(), candidate); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = session.Close() })
	catalog := testProfileCatalog(t)
	initial, _ := catalog.Default()
	page, err := pageForProfile(initial)
	if err != nil {
		t.Fatal(err)
	}
	if err := session.SendPage(context.Background(), page, 73); err != nil {
		t.Fatal(err)
	}
	service, err := NewProfileService(ProfileServiceOptions{
		Catalog:          catalog,
		Sender:           session,
		InitialProfileID: initial.ID,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	if _, err := service.ActivateProfile(context.Background(), "alternate"); err != nil {
		t.Fatal(err)
	}
	commands, err := commandsFromReports(transport.writesSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	wantStartup := []d200x.Command{
		d200x.CommandCompleteDisplayUpload,
		d200x.CommandBrightness,
		d200x.CommandUnlockScreen,
		d200x.CommandEnableInputStream,
	}
	if len(commands) < len(wantStartup) || !equalCommands(commands[:len(wantStartup)], wantStartup) {
		t.Fatalf("startup commands = %v, want prefix %v", commands, wantStartup)
	}
	if got := countRuntimeCommand(commands, d200x.CommandCompleteDisplayUpload); got != 2 {
		t.Fatalf("complete-display-upload count = %d, want startup plus one live update", got)
	}
	if got := countRuntimeCommand(commands, d200x.CommandPartialDisplayUpload); got != 0 {
		t.Fatalf("partial-display-upload count = %d, want zero", got)
	}
	for _, command := range []d200x.Command{
		d200x.CommandBrightness,
		d200x.CommandUnlockScreen,
		d200x.CommandEnableInputStream,
	} {
		if got := countRuntimeCommand(commands, command); got != 1 {
			t.Fatalf("activation auxiliary command %s count = %d, want startup only", command, got)
		}
	}
}

func TestProfileServicePacketFailureStopsFullPageWriteAndRetainsPriorLogicalState(t *testing.T) {
	transport := newRuntimeFakeTransport()
	session := d200x.NewSession(&recordingFactory{transport: transport})
	candidate := d200x.NewCandidate("opaque-packet-failure", d200x.VendorID, d200x.ProductID, d200x.InterfaceNumber)
	if err := session.Open(context.Background(), candidate); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = session.Close() })
	catalog := testProfileCatalog(t)
	initial, _ := catalog.Default()
	page, err := pageForProfile(initial)
	if err != nil {
		t.Fatal(err)
	}
	if err := session.SendPage(context.Background(), page, 73); err != nil {
		t.Fatal(err)
	}
	startupWrites := transport.writeCount()
	target, _ := catalog.Lookup("alternate")
	page, err = pageForProfile(target)
	if err != nil {
		t.Fatal(err)
	}
	update, err := d200x.BuildLivePageUpdate(page)
	if err != nil {
		t.Fatal(err)
	}
	reports, err := d200x.EncodeFrame(update.Frame())
	if err != nil {
		t.Fatal(err)
	}
	failOffset := 2
	if len(reports) < failOffset {
		failOffset = len(reports)
	}
	failure := errors.New("injected full-page packet failure")
	transport.mu.Lock()
	transport.failAt = startupWrites + failOffset
	transport.failErr = failure
	transport.mu.Unlock()
	var terminalCalls, cancelCalls int
	service, err := NewProfileService(ProfileServiceOptions{
		Catalog:          catalog,
		Sender:           session,
		InitialProfileID: initial.ID,
		Terminal: func(error) {
			terminalCalls++
		},
		Cancel: func() {
			cancelCalls++
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	if _, err := service.ActivateProfile(context.Background(), "alternate"); err == nil {
		t.Fatal("packet failure returned nil")
	}
	if got := transport.writeCount(); got != startupWrites+failOffset {
		t.Fatalf("writes after failed packet = %d, want exactly failed report %d", got, startupWrites+failOffset)
	}
	if got, ok := service.CurrentProfileID(); !ok || got != initial.ID {
		t.Fatalf("logical profile after packet failure = %q/%t, want %q", got, ok, initial.ID)
	}
	if !service.Uncertain() {
		t.Fatal("packet failure did not mark physical state uncertain")
	}
	if terminalCalls != 1 || cancelCalls != 1 {
		t.Fatalf("terminal/cancel callbacks = %d/%d, want one each", terminalCalls, cancelCalls)
	}
	if _, active := session.Current(); active {
		t.Fatal("session remained active after packet failure")
	}
	beforeRetry := transport.writeCount()
	if _, err := service.ActivateProfile(context.Background(), "alternate"); !errors.Is(err, ErrProfileStateUncertain) {
		t.Fatalf("retry error = %v, want uncertain state", err)
	}
	if got := transport.writeCount(); got != beforeRetry {
		t.Fatalf("writes after rejected retry = %d, want %d", got, beforeRetry)
	}
}

func TestProfileServiceSendFailureEntersUncertainStateAndStops(t *testing.T) {
	writeErr := errors.New("injected page failure")
	var terminalCalls int
	var terminalErr error
	var terminalMu sync.Mutex
	sender := &profilePageSender{err: writeErr}
	service := newTestProfileService(t, sender, func(err error) {
		terminalMu.Lock()
		terminalCalls++
		terminalErr = err
		terminalMu.Unlock()
	})

	if _, err := service.ActivateProfile(context.Background(), "alternate"); !errors.Is(err, writeErr) {
		t.Fatalf("failed activation error = %v", err)
	}
	if !service.Uncertain() {
		t.Fatal("service did not enter uncertain state")
	}
	if got, _ := service.CurrentProfileID(); got != "default" {
		t.Fatalf("failed activation committed profile %q", got)
	}
	if _, err := service.ActivateProfile(context.Background(), "alternate"); !errors.Is(err, ErrProfileStateUncertain) {
		t.Fatalf("post-failure activation error = %v", err)
	}
	if got := sender.callCount(); got != 1 {
		t.Fatalf("page writes after uncertain state = %d, want 1", got)
	}
	terminalMu.Lock()
	defer terminalMu.Unlock()
	if terminalCalls != 1 || !errors.Is(terminalErr, writeErr) {
		t.Fatalf("terminal callback = %d/%v", terminalCalls, terminalErr)
	}
}

func TestProfileServiceFailureRejectsQueuedAndFutureActivationsAndCancelsOnce(t *testing.T) {
	writeErr := errors.New("injected page failure")
	started := make(chan struct{})
	release := make(chan struct{})
	var terminalCalls int
	var cancelCalls int
	var callbackMu sync.Mutex
	sender := &profilePageSender{
		err:          writeErr,
		blockStarted: started,
		blockRelease: release,
	}
	service, err := NewProfileService(ProfileServiceOptions{
		Catalog: testProfileCatalog(t),
		Sender:  sender,
		Terminal: func(error) {
			callbackMu.Lock()
			terminalCalls++
			callbackMu.Unlock()
		},
		Cancel: func() {
			callbackMu.Lock()
			cancelCalls++
			callbackMu.Unlock()
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })

	firstDone := make(chan error, 1)
	go func() {
		_, err := service.ActivateProfile(context.Background(), "alternate")
		firstDone <- err
	}()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("first activation did not reach the blocked sender")
	}
	queued := make([]profileActivationRequest, profileActivationCapacity)
	for index := range queued {
		queued[index] = profileActivationRequest{
			ctx:       context.Background(),
			profileID: "default",
			result:    make(chan profileActivationResponse, 1),
		}
		service.requests <- queued[index]
	}
	close(release)

	if err := <-firstDone; !errors.Is(err, writeErr) {
		t.Fatalf("failed activation error = %v", err)
	}
	for index := range queued {
		select {
		case response := <-queued[index].result:
			if !errors.Is(response.err, ErrProfileStateUncertain) {
				t.Fatalf("queued activation %d error = %v", index, response.err)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("queued activation %d did not complete", index)
		}
	}
	if _, err := service.ActivateProfile(context.Background(), "default"); !errors.Is(err, ErrProfileStateUncertain) {
		t.Fatalf("future activation error = %v", err)
	}
	callbackMu.Lock()
	defer callbackMu.Unlock()
	if terminalCalls != 1 || cancelCalls != 1 {
		t.Fatalf("terminal/cancel callbacks = %d/%d, want exactly once", terminalCalls, cancelCalls)
	}
}

func TestProfileServiceSaturatedCapacityRejectsBlockedSender(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	sender := &profilePageSender{blockStarted: started, blockRelease: release}
	service := newTestProfileService(t, sender, nil)

	firstDone := make(chan error, 1)
	go func() {
		_, err := service.ActivateProfile(context.Background(), "alternate")
		firstDone <- err
	}()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("first activation did not reach the blocked sender")
	}
	queued := make([]profileActivationRequest, profileActivationCapacity)
	for index := range queued {
		queued[index] = profileActivationRequest{
			ctx:       context.Background(),
			profileID: "missing",
			result:    make(chan profileActivationResponse, 1),
		}
		service.requests <- queued[index]
	}
	select {
	case service.requests <- profileActivationRequest{result: make(chan profileActivationResponse, 1)}:
		t.Fatal("activation queue accepted a ninth request")
	default:
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := service.ActivateProfile(ctx, "missing"); !errors.Is(err, context.Canceled) {
		t.Fatalf("saturated activation error = %v, want cancellation", err)
	}
	close(release)
	if err := <-firstDone; err != nil {
		t.Fatalf("first activation error = %v", err)
	}
	for index := range queued {
		select {
		case response := <-queued[index].result:
			if !errors.Is(response.err, ErrUnknownProfile) {
				t.Fatalf("queued activation %d error = %v", index, response.err)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("queued activation %d did not complete", index)
		}
	}
}

func TestProfileServiceSerializesConcurrentActivations(t *testing.T) {
	sender := &profilePageSender{}
	service := newTestProfileService(t, sender, nil)

	const requestCount = 16
	results := make(chan error, requestCount)
	var wait sync.WaitGroup
	for index := 0; index < requestCount; index++ {
		profileID := "alternate"
		if index%2 == 1 {
			profileID = "default"
		}
		wait.Add(1)
		go func(id string) {
			defer wait.Done()
			_, err := service.ActivateProfile(context.Background(), id)
			results <- err
		}(profileID)
	}
	wait.Wait()
	close(results)
	for err := range results {
		if err != nil {
			t.Fatalf("concurrent activation error = %v", err)
		}
	}
	if sender.maxConcurrentValue() != 1 {
		t.Fatalf("maximum concurrent page sends = %d, want 1", sender.maxConcurrentValue())
	}
}

func TestProfileServiceCurrentEventPositionsFollowCommittedProfile(t *testing.T) {
	sender := &profilePageSender{}
	service := newTestProfileService(t, sender, nil)
	plan := devicePlan{positionsFn: service.CurrentEventPositions}
	first := d200x.InputEvent{WireIndex: 0, Marker: d200x.InputMarkerButton, Action: d200x.InputActionPressed}
	var output synchronizedWriter
	if err := writeInputEvent(&output, plan, first); err != nil {
		t.Fatal(err)
	}
	if got := output.String(); !containsAll(got, `"id":"Default-0_0"`, `"position":"0_0"`) {
		t.Fatalf("default event = %q", got)
	}
	if _, err := service.ActivateProfile(context.Background(), "alternate"); err != nil {
		t.Fatal(err)
	}
	if err := writeInputEvent(&output, plan, first); err != nil {
		t.Fatal(err)
	}
	if got := output.String(); !containsAll(got, `"id":"Alternate-0_0"`, `"position":"0_0"`) {
		t.Fatalf("alternate event = %q", got)
	}
}

func TestRuntimeIPCProfileAdapterListsDefaultAndCurrentInOrder(t *testing.T) {
	service := newTestProfileService(t, &profilePageSender{}, nil)
	runtimeProcess := &Runtime{profileService: service, defaultProfileID: "default"}
	adapter := runtimeIPCProfileService{runtime: runtimeProcess}
	summaries := adapter.ListProfiles()
	if len(summaries) != 2 {
		t.Fatalf("profile summaries = %#v", summaries)
	}
	if summaries[0].ID != "default" || !summaries[0].IsDefault || !summaries[0].IsCurrent {
		t.Fatalf("default summary = %#v", summaries[0])
	}
	if summaries[1].ID != "alternate" || summaries[1].IsDefault || summaries[1].IsCurrent {
		t.Fatalf("alternate summary = %#v", summaries[1])
	}
	result, err := adapter.ActivateProfile(context.Background(), "alternate")
	if err != nil || result.ProfileID != "alternate" || !result.Changed {
		t.Fatalf("alternate activation = %#v, %v", result, err)
	}
	summaries = adapter.ListProfiles()
	if summaries[0].IsCurrent || !summaries[1].IsCurrent {
		t.Fatalf("current flags after activation = %#v", summaries)
	}
}

func TestRuntimeIPCProfileAdapterMapsServiceErrors(t *testing.T) {
	writeErr := errors.New("injected write failure")
	service := newTestProfileService(t, &profilePageSender{err: writeErr}, nil)
	runtimeProcess := &Runtime{profileService: service, defaultProfileID: "default"}
	adapter := runtimeIPCProfileService{runtime: runtimeProcess}
	if _, err := adapter.ActivateProfile(context.Background(), "missing"); !errors.Is(err, ipc.ErrProfileNotFound) {
		t.Fatalf("unknown profile error = %v", err)
	}
	if _, err := adapter.ActivateProfile(context.Background(), "alternate"); !errors.Is(err, ipc.ErrDeviceWriteFailed) {
		t.Fatalf("write failure error = %v", err)
	}
	if _, err := adapter.ActivateProfile(context.Background(), "default"); !errors.Is(err, ipc.ErrDeviceWriteFailed) {
		t.Fatalf("uncertain follow-up error = %v", err)
	}
	closed := runtimeIPCProfileService{runtime: &Runtime{}}
	if _, err := closed.ActivateProfile(context.Background(), "default"); !errors.Is(err, ipc.ErrShuttingDown) {
		t.Fatalf("closed runtime error = %v", err)
	}
}

func newTestProfileService(t *testing.T, sender *profilePageSender, terminal func(error)) *RuntimeProfileService {
	t.Helper()
	catalog, err := profile.NewCatalog("default", []profile.Profile{
		testProfile("default", "Default", "Default"),
		testProfile("alternate", "Alternate", "Alternate"),
	})
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewProfileService(ProfileServiceOptions{
		Catalog:  catalog,
		Sender:   sender,
		Terminal: terminal,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	return service
}

func testProfile(id, label, prefix string) profile.Profile {
	values := make([]profile.Value, 0, len(d200x.SupportedPositions()))
	for _, spec := range d200x.SupportedPositions() {
		values = append(values, profile.Value{
			ID:         prefix + "-" + spec.Name,
			Position:   spec.Name,
			Label:      prefix + " " + spec.Name,
			Background: "#102030",
		})
	}
	target := "alternate"
	if id == "alternate" {
		target = "default"
	}
	values[0].Action = &profile.Action{Type: profile.ActivateProfileType, Gesture: profile.PressGesture, ProfileID: target}
	return profile.Profile{ID: id, Label: label, Values: values}
}

type profilePageCall struct {
	page       d200x.Page
	brightness int
}

type profilePageSender struct {
	mu            sync.Mutex
	calls         []profilePageCall
	liveCalls     []d200x.LivePageUpdate
	concurrent    int
	maxConcurrent int
	err           error
	blockStarted  chan struct{}
	blockRelease  <-chan struct{}
	blockOnce     sync.Once
}

func (sender *profilePageSender) SendPage(_ context.Context, page d200x.Page, brightness int) error {
	return sender.record(page, brightness)
}

func (sender *profilePageSender) SendLivePageUpdate(_ context.Context, update d200x.LivePageUpdate) error {
	sender.mu.Lock()
	sender.liveCalls = append(sender.liveCalls, update)
	sender.mu.Unlock()
	return sender.record(update.Page(), 0)
}

func (sender *profilePageSender) record(page d200x.Page, brightness int) error {
	sender.mu.Lock()
	sender.concurrent++
	if sender.concurrent > sender.maxConcurrent {
		sender.maxConcurrent = sender.concurrent
	}
	sender.calls = append(sender.calls, profilePageCall{page: page, brightness: brightness})
	err := sender.err
	blockStarted := sender.blockStarted
	blockRelease := sender.blockRelease
	shouldBlock := blockStarted != nil && blockRelease != nil
	sender.mu.Unlock()
	if shouldBlock {
		sender.blockOnce.Do(func() { close(blockStarted) })
		<-blockRelease
	}
	sender.mu.Lock()
	sender.concurrent--
	sender.mu.Unlock()
	return err
}

func testProfileCatalog(t *testing.T) profile.Catalog {
	t.Helper()
	catalog, err := profile.NewCatalog("default", []profile.Profile{
		testProfile("default", "Default", "Default"),
		testProfile("alternate", "Alternate", "Alternate"),
	})
	if err != nil {
		t.Fatal(err)
	}
	return catalog
}

func (sender *profilePageSender) callCount() int {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	return len(sender.calls)
}

func (sender *profilePageSender) callsSnapshot() []profilePageCall {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	owned := make([]profilePageCall, len(sender.calls))
	copy(owned, sender.calls)
	return owned
}

func (sender *profilePageSender) liveCallsSnapshot() []d200x.LivePageUpdate {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	owned := make([]d200x.LivePageUpdate, len(sender.liveCalls))
	copy(owned, sender.liveCalls)
	return owned
}

func (sender *profilePageSender) maxConcurrentValue() int {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	return sender.maxConcurrent
}

func containsAll(value string, fragments ...string) bool {
	for _, fragment := range fragments {
		if !strings.Contains(value, fragment) {
			return false
		}
	}
	return true
}

var _ PageSender = (*profilePageSender)(nil)
