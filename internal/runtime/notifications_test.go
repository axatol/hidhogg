package runtime

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/d200x"
	"hidhogg/internal/notification"
	"hidhogg/internal/profile"
)

func TestNotificationEmitCompositionReplacementAndClear(t *testing.T) {
	sender := &profilePageSender{}
	service := newNotificationTestService(t, sender, nil, 0, 13)
	base, ok := service.CurrentProfile()
	if !ok {
		t.Fatal("current profile is unavailable")
	}
	baseLabels := make(map[string]string, len(base.Values))
	for _, value := range base.Values {
		baseLabels[value.Position] = value.Label
	}

	first, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "same"})
	if err != nil {
		t.Fatalf("first emit: %v", err)
	}
	if first.MatchedCount != 2 || !notification.ValidNotificationID(first.NotificationID) {
		t.Fatalf("first result = %+v", first)
	}
	if got := len(service.CurrentNotifications()); got != 2 {
		t.Fatalf("active notifications = %d, want 2", got)
	}
	if got := len(sender.liveCallsSnapshot()); got != 1 {
		t.Fatalf("first live writes = %d, want 1", got)
	}
	firstPage := sender.liveCallsSnapshot()[0].Page()
	for _, position := range []string{"0_0", "3_2"} {
		if got := notificationPageLabel(firstPage, position); got != "same" {
			t.Fatalf("first %s label = %q, want same", position, got)
		}
	}

	second, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "same"})
	if err != nil {
		t.Fatalf("identical replacement: %v", err)
	}
	if second.NotificationID == first.NotificationID || second.MatchedCount != 2 {
		t.Fatalf("identical replacement result = %+v", second)
	}
	if got := len(sender.liveCallsSnapshot()); got != 1 {
		t.Fatalf("identical replacement writes = %d, want one", got)
	}
	if current, ok := service.CurrentNotificationAt(0); !ok || current.NotificationID != second.NotificationID {
		t.Fatalf("current square notification = %+v/%t", current, ok)
	}
	if current, ok := service.CurrentNotificationAt(13); !ok || current.NotificationID != second.NotificationID {
		t.Fatalf("current wide notification = %+v/%t", current, ok)
	}

	zero, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "unmatched", Text: "ignored"})
	if err != nil {
		t.Fatalf("zero-match emit: %v", err)
	}
	if zero.MatchedCount != 0 || len(service.CurrentNotifications()) != 2 || len(sender.liveCallsSnapshot()) != 1 {
		t.Fatalf("zero-match result/state = %+v/%d/%d", zero, len(service.CurrentNotifications()), len(sender.liveCallsSnapshot()))
	}

	cleared, err := service.ClearNotification(context.Background(), first.NotificationID)
	if err != nil {
		t.Fatalf("stale clear: %v", err)
	}
	if cleared.ClearedCount != 0 || len(sender.liveCallsSnapshot()) != 1 {
		t.Fatalf("stale clear result/writes = %+v/%d", cleared, len(sender.liveCallsSnapshot()))
	}
	cleared, err = service.ClearNotification(context.Background(), second.NotificationID)
	if err != nil {
		t.Fatalf("current clear: %v", err)
	}
	if cleared.ClearedCount != 2 || len(service.CurrentNotifications()) != 0 {
		t.Fatalf("current clear result/state = %+v/%d", cleared, len(service.CurrentNotifications()))
	}
	lastPage := sender.liveCallsSnapshot()[1].Page()
	for position, label := range baseLabels {
		if got := notificationPageLabel(lastPage, position); got != label {
			t.Fatalf("restored %s label = %q, want %q", position, got, label)
		}
	}
}

func TestNotificationTTLUsesCommitDeadlineEqualityAndRearms(t *testing.T) {
	clock := newPolicyFakeClock(time.Unix(2000, 0))
	sender := &profilePageSender{}
	service := newNotificationTestService(t, sender, clock, 0)
	ttl := 5
	first, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "first", TTLSeconds: &ttl})
	if err != nil {
		t.Fatalf("first emit: %v", err)
	}
	waitForNotificationLiveCalls(t, sender, 1)
	deadline := clock.Now().Add(5 * time.Second)
	if got := service.effective.Load().notifications.overlays[0].Deadline; !got.Equal(deadline) {
		t.Fatalf("first deadline = %v, want %v", got, deadline)
	}

	clock.advance(2 * time.Second)
	second, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "second", TTLSeconds: &ttl})
	if err != nil {
		t.Fatalf("replacement emit: %v", err)
	}
	if second.NotificationID == first.NotificationID {
		t.Fatal("replacement reused notification ID")
	}
	replacementDeadline := clock.Now().Add(5 * time.Second)
	if got := service.effective.Load().notifications.overlays[0].Deadline; !got.Equal(replacementDeadline) {
		t.Fatalf("replacement deadline = %v, want %v", got, replacementDeadline)
	}

	clock.advance(3 * time.Second)
	time.Sleep(time.Millisecond)
	if got := len(service.CurrentNotifications()); got != 1 {
		t.Fatalf("notification expired before replacement deadline: %d", got)
	}
	if got := len(sender.liveCallsSnapshot()); got != 2 {
		t.Fatalf("writes before replacement deadline = %d, want 2", got)
	}
	clock.advance(2 * time.Second)
	waitForNotificationLiveCalls(t, sender, 3)
	if got := len(service.CurrentNotifications()); got != 0 {
		t.Fatalf("notifications after equality expiry = %d", got)
	}
	if got := sender.liveCallsSnapshot()[2].Page().Positions[0].Label; got != "Default 0_0" {
		t.Fatalf("expiry restored label = %q", got)
	}
}

func TestNotificationReadViewsAreDefensiveCopies(t *testing.T) {
	service := newNotificationTestService(t, &profilePageSender{}, nil, 0)
	if _, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "stable"}); err != nil {
		t.Fatal(err)
	}
	instances := service.CurrentNotifications()
	if len(instances) != 1 {
		t.Fatalf("instances = %d, want one", len(instances))
	}
	instances[0].Text = "mutated"
	instances[0].NotificationID = "mutated"
	instances = append(instances, NotificationInstance{Text: "extra"})
	current, ok := service.CurrentNotificationAt(0)
	if !ok || current.Text != "stable" || current.NotificationID == "mutated" {
		t.Fatalf("current notification after caller mutation = %+v/%t", current, ok)
	}
}

func newNotificationTestService(t *testing.T, sender *profilePageSender, clock Clock, sourcePositions ...int) *RuntimeProfileService {
	t.Helper()
	current := testProfile("default", "Default", "Default")
	for _, index := range sourcePositions {
		current.Values[index].NotificationSources = []string{"source"}
	}
	alternate := testProfile("alternate", "Alternate", "Alternate")
	catalog, err := profile.NewCatalog("default", []profile.Profile{current, alternate})
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewProfileService(ProfileServiceOptions{Catalog: catalog, Sender: sender, Clock: clock})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	return service
}

func notificationPageLabel(page d200x.Page, position string) string {
	for _, value := range page.Positions {
		if value.Position == position {
			return value.Label
		}
	}
	return ""
}

func waitForNotificationLiveCalls(t *testing.T, sender *profilePageSender, count int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if len(sender.liveCallsSnapshot()) >= count {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("sender has fewer than %d live calls: %d", count, len(sender.liveCallsSnapshot()))
}

func waitForNotificationQueue(t *testing.T, service *RuntimeProfileService, count int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if len(service.notifications) >= count {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("notification queue has fewer than %d requests: %d", count, len(service.notifications))
}

func TestNotificationQueueBusyAndQueuedCancellation(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	sender := &profilePageSender{blockStarted: started, blockRelease: release}
	service := newNotificationTestService(t, sender, nil, 0)
	firstDone := make(chan error, 1)
	go func() {
		_, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "first"})
		firstDone <- err
	}()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("first notification did not reach sender")
	}

	queued := make([]<-chan error, notificationAdmissionCapacity)
	queuedContexts := make([]context.Context, notificationAdmissionCapacity)
	cancels := make([]context.CancelFunc, notificationAdmissionCapacity)
	for index := range queued {
		ctx, cancel := context.WithCancel(context.Background())
		queuedContexts[index] = ctx
		cancels[index] = cancel
		done := make(chan error, 1)
		queued[index] = done
		go func(index int, ctx context.Context, done chan<- error) {
			_, err := service.EmitNotification(ctx, notification.EmitRequest{Source: "source", Text: "queued" + string(rune('a'+index))})
			done <- err
		}(index, ctx, done)
	}
	waitForNotificationQueue(t, service, notificationAdmissionCapacity)
	if _, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "busy"}); !errors.Is(err, notification.ErrBusy) {
		t.Fatalf("ninth queued emit error = %v, want ErrBusy", err)
	}
	cancels[0]()
	if err := <-queued[0]; !errors.Is(err, context.Canceled) {
		t.Fatalf("queued cancellation error = %v, want context.Canceled", err)
	}
	close(release)
	if err := <-firstDone; err != nil {
		t.Fatalf("first notification error = %v", err)
	}
	for index := 1; index < len(queued); index++ {
		if err := <-queued[index]; err != nil {
			t.Fatalf("queued notification %d error = %v", index, err)
		}
	}
	for index, ctx := range queuedContexts {
		if ctx.Err() != nil && index != 0 {
			t.Fatalf("unexpected queued context cancellation at %d: %v", index, ctx.Err())
		}
	}
	for _, cancel := range cancels {
		cancel()
	}
}

func TestNotificationCancellationBeforeWriteDoesNotCommit(t *testing.T) {
	sender := &profilePageSender{}
	service := newNotificationTestService(t, sender, nil, 0)
	snapshot := service.effective.Load()
	prospective := snapshot.notifications.clone()
	prospective.overlays[0] = &notificationOverlay{
		NotificationID: "00000000-0000-0000-0000-000000000001",
		Source:         "source",
		Text:           "canceled",
		PositionID:     snapshot.current.Values[0].ID,
		Position:       snapshot.current.Values[0].Position,
	}
	update, err := buildNotificationUpdate(snapshot.current, prospective)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	committed := false
	if _, err := service.sendNotificationUpdate(ctx, snapshot, update, func([]byte) { committed = true }); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled pre-write error = %v, want context.Canceled", err)
	}
	if committed || len(sender.liveCallsSnapshot()) != 0 || len(service.CurrentNotifications()) != 0 {
		t.Fatalf("canceled pre-write mutated state: committed=%t writes=%d active=%d", committed, len(sender.liveCallsSnapshot()), len(service.CurrentNotifications()))
	}
}

func TestNotificationLateCancellationPublishesSuccessfulWrite(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	sender := &profilePageSender{blockStarted: started, blockRelease: release}
	service := newNotificationTestService(t, sender, nil, 0)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := service.EmitNotification(ctx, notification.EmitRequest{Source: "source", Text: "committed"})
		done <- err
	}()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("notification did not reach sender")
	}
	cancel()
	close(release)
	select {
	case err := <-done:
		if err != nil && !errors.Is(err, context.Canceled) {
			t.Fatalf("late-canceled emit error = %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("late-canceled emit did not return")
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && len(service.CurrentNotifications()) == 0 {
		time.Sleep(time.Millisecond)
	}
	if got := len(service.CurrentNotifications()); got != 1 {
		t.Fatalf("late-canceled successful write active notifications = %d, want one", got)
	}
}

func TestNotificationWriteFailureDrainsQueueAndStopsAdmission(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	writeErr := errors.New("notification write failed")
	sender := &profilePageSender{err: writeErr, blockStarted: started, blockRelease: release}
	service := newNotificationTestService(t, sender, nil, 0)
	firstDone := make(chan error, 1)
	go func() {
		_, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "failure"})
		firstDone <- err
	}()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("failure notification did not reach sender")
	}
	queued := make([]<-chan error, notificationAdmissionCapacity)
	for index := range queued {
		done := make(chan error, 1)
		queued[index] = done
		go func(done chan<- error) {
			_, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "queued"})
			done <- err
		}(done)
	}
	waitForNotificationQueue(t, service, notificationAdmissionCapacity)
	close(release)
	if err := <-firstDone; !errors.Is(err, notification.ErrUncertain) {
		t.Fatalf("failed active emit error = %v, want ErrUncertain", err)
	}
	for index, done := range queued {
		if err := <-done; !errors.Is(err, notification.ErrUncertain) {
			t.Fatalf("queued failure %d error = %v, want ErrUncertain", index, err)
		}
	}
	if _, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "future"}); !errors.Is(err, notification.ErrUncertain) {
		t.Fatalf("future emit error = %v, want ErrUncertain", err)
	}
	if !service.Uncertain() || len(sender.liveCallsSnapshot()) != 1 {
		t.Fatalf("failure state = uncertain:%t writes:%d", service.Uncertain(), len(sender.liveCallsSnapshot()))
	}
}

func TestNotificationCloseResolvesQueueAndStopsExpiry(t *testing.T) {
	clock := newPolicyFakeClock(time.Unix(3000, 0))
	started := make(chan struct{})
	release := make(chan struct{})
	sender := &profilePageSender{blockStarted: started, blockRelease: release}
	service := newNotificationTestService(t, sender, clock, 0)
	ttl := 60
	firstDone := make(chan error, 1)
	go func() {
		_, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "close", TTLSeconds: &ttl})
		firstDone <- err
	}()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("close test did not reach sender")
	}
	queued := make([]<-chan error, notificationAdmissionCapacity)
	for index := range queued {
		done := make(chan error, 1)
		queued[index] = done
		go func(done chan<- error) {
			_, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "queued"})
			done <- err
		}(done)
	}
	waitForNotificationQueue(t, service, notificationAdmissionCapacity)
	closeDone := make(chan error, 1)
	go func() { closeDone <- service.Close() }()
	select {
	case <-service.stop:
	case <-time.After(2 * time.Second):
		t.Fatal("service stop was not signaled")
	}
	close(release)
	if err := <-firstDone; err != nil && !errors.Is(err, notification.ErrClosed) {
		t.Fatalf("active close emit error = %v", err)
	}
	if err := <-closeDone; err != nil {
		t.Fatalf("service close error = %v", err)
	}
	if got := len(sender.liveCallsSnapshot()); got != 1 {
		t.Fatalf("successful active writes = %d, want one", got)
	}
	if got := len(service.CurrentNotifications()); got != 1 {
		t.Fatalf("active overlay after close = %d, want one", got)
	}
	for index, done := range queued {
		if err := <-done; !errors.Is(err, notification.ErrClosed) {
			t.Fatalf("queued close %d error = %v, want ErrClosed", index, err)
		}
	}
	writes := len(sender.liveCallsSnapshot())
	clock.advance(2 * time.Minute)
	time.Sleep(time.Millisecond)
	if got := len(sender.liveCallsSnapshot()); got != writes {
		t.Fatalf("writes after closed timer = %d, want %d", got, writes)
	}
}

func TestNotificationRequestStateCancelClaimIsIdempotent(t *testing.T) {
	state := newNotificationRequestState()
	var wait sync.WaitGroup
	for index := 0; index < 256; index++ {
		wait.Add(1)
		go func(index int) {
			defer wait.Done()
			if index%2 == 0 {
				state.cancel()
				return
			}
			state.claim(context.Background())
		}(index)
	}
	wait.Wait()
	state.cancel()
	state.claim(context.Background())
}

func TestNotificationLifecyclePreservesAndClearsAtProfileBoundaries(t *testing.T) {
	sender := &profilePageSender{}
	service := newNotificationTestService(t, sender, nil, 0)
	if _, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "retained"}); err != nil {
		t.Fatal(err)
	}
	if _, err := service.ActivateProfile(context.Background(), "default"); err != nil {
		t.Fatalf("same-profile activation: %v", err)
	}
	if got := len(service.CurrentNotifications()); got != 1 {
		t.Fatalf("same-profile activation notifications = %d, want one", got)
	}
	unchanged := service.effective.Load().candidate()
	result, err := service.reload(context.Background(), func(string) (reloadCandidate, error) { return unchanged, nil })
	if err != nil || result.Changed {
		t.Fatalf("unchanged reload = %+v, %v", result, err)
	}
	if got := len(service.CurrentNotifications()); got != 1 {
		t.Fatalf("unchanged reload notifications = %d, want one", got)
	}
	result, err = service.reload(context.Background(), func(string) (reloadCandidate, error) { return reloadCandidate{}, errors.New("rejected candidate") })
	if err == nil || result.Changed {
		t.Fatalf("rejected reload = %+v, %v", result, err)
	}
	if got := len(service.CurrentNotifications()); got != 1 {
		t.Fatalf("rejected reload notifications = %d, want one", got)
	}
	if _, err := service.ActivateProfile(context.Background(), "alternate"); err != nil {
		t.Fatalf("different-profile activation: %v", err)
	}
	if got := len(service.CurrentNotifications()); got != 0 {
		t.Fatalf("different-profile activation notifications = %d, want zero", got)
	}
}

func TestNotificationChangedActionOnlyAndSourceReloadRestoresBaseline(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*profile.Profile)
		check  func(*testing.T, ReloadResult)
	}{
		{
			name: "action-only",
			mutate: func(current *profile.Profile) {
				current.Values[0].Action = &profile.Action{Type: profile.ActivateProfileType, Gesture: profile.PressGesture, ProfileID: "alternate"}
			},
			check: func(t *testing.T, result ReloadResult) {
				if !result.ActionChanged || result.DisplayChanged || !result.DisplayUpdated {
					t.Fatalf("action-only reload = %+v", result)
				}
			},
		},
		{
			name: "source-only",
			mutate: func(current *profile.Profile) {
				current.Values[0].NotificationSources = []string{"replacement"}
			},
			check: func(t *testing.T, result ReloadResult) {
				if result.ActionChanged || result.DisplayChanged || !result.CatalogChanged || !result.DisplayUpdated {
					t.Fatalf("source-only reload = %+v", result)
				}
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			sender := &profilePageSender{}
			service := newNotificationTestService(t, sender, nil, 0)
			if _, err := service.EmitNotification(context.Background(), notification.EmitRequest{Source: "source", Text: "overlay"}); err != nil {
				t.Fatal(err)
			}
			candidate := notificationChangedCandidate(t, service, test.mutate)
			result, err := service.reload(context.Background(), func(string) (reloadCandidate, error) { return candidate, nil })
			if err != nil {
				t.Fatalf("reload: %v", err)
			}
			test.check(t, result)
			if got := len(service.CurrentNotifications()); got != 0 {
				t.Fatalf("notifications after %s reload = %d, want zero", test.name, got)
			}
			calls := sender.liveCallsSnapshot()
			if got := len(calls); got != 2 {
				t.Fatalf("%s reload live writes = %d, want overlay plus baseline", test.name, got)
			}
			if got := calls[1].Page().Positions[0].Label; got != "Default 0_0" {
				t.Fatalf("%s restored baseline label = %q", test.name, got)
			}
		})
	}
}

func notificationChangedCandidate(t *testing.T, service *RuntimeProfileService, mutate func(*profile.Profile)) reloadCandidate {
	t.Helper()
	candidate := service.effective.Load().candidate()
	current := candidate.CurrentProfile()
	mutate(&current)
	profiles := candidate.Catalog().Profiles()
	for index := range profiles {
		if profiles[index].ID == current.ID {
			profiles[index] = current
		}
	}
	catalog, err := profile.NewCatalog(candidate.DefaultProfileID(), profiles)
	if err != nil {
		t.Fatal(err)
	}
	candidate.catalog = catalog
	candidate.currentProfile = current
	page, err := pageForProfile(current)
	if err != nil {
		t.Fatal(err)
	}
	update, err := d200x.BuildLivePageUpdate(page)
	if err != nil {
		t.Fatal(err)
	}
	candidate.livePageUpdate = update
	candidate.page = update.Page()
	candidate.renderedPage = update.Archive().Data
	return candidate
}
