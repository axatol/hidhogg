package runtime

import (
	"bytes"
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"hidhogg/internal/d200x"
)

func TestIdlePolicyUsesAbsoluteKeepaliveAndDimsAfterDeadline(t *testing.T) {
	clock := newPolicyFakeClock(time.Unix(100, 0))
	sender := &policyRecordingSender{}
	input := make(chan inputObservation, 4)
	var output bytes.Buffer
	plan := devicePlan{brightness: 73, idleTimeout: 100 * time.Second}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- runIdlePolicy(ctx, clock, sender, plan, clock.Now(), input, &output)
	}()
	waitForPolicyTimers(t, clock, 2)

	clock.advance(50 * time.Second)
	waitForPolicyCommands(t, sender, 1)
	if got := sender.commands(); !equalCommands(got, []d200x.Command{d200x.CommandEnableInputStream}) {
		t.Fatalf("commands at first boundary = %v", got)
	}

	clock.advance(50 * time.Second)
	waitForPolicyCommands(t, sender, 2)
	if got := sender.commands(); !equalCommands(got, []d200x.Command{d200x.CommandEnableInputStream, d200x.CommandEnableInputStream, d200x.CommandBrightness}) {
		t.Fatalf("commands at simultaneous boundary = %v", got)
	}
	if payload := sender.payloads()[2]; string(payload) != "0" {
		t.Fatalf("idle brightness payload = %q, want 0", payload)
	}

	clock.advance(100 * time.Second)
	waitForPolicyCommands(t, sender, 4)
	if got := sender.commands(); !equalCommands(got, []d200x.Command{d200x.CommandEnableInputStream, d200x.CommandEnableInputStream, d200x.CommandBrightness, d200x.CommandEnableInputStream}) {
		t.Fatalf("commands after skipped boundary = %v", got)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("policy shutdown: %v", err)
	}
}

func TestIdlePolicySkipsMissedKeepaliveBoundaryWithoutCatchUp(t *testing.T) {
	clock := newPolicyFakeClock(time.Unix(150, 0))
	sender := &policyRecordingSender{}
	input := make(chan inputObservation)
	var output bytes.Buffer
	startupAt := clock.Now().Add(-75 * time.Second)
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- runIdlePolicy(ctx, clock, sender, devicePlan{}, startupAt, input, &output)
	}()
	waitForPolicyTimers(t, clock, 1)
	time.Sleep(time.Millisecond)
	if got := sender.commands(); len(got) != 0 {
		t.Fatalf("missed boundary was caught up immediately: %v", got)
	}
	clock.advance(25 * time.Second)
	waitForPolicyCommands(t, sender, 1)
	if got := sender.commands(); !equalCommands(got, []d200x.Command{d200x.CommandEnableInputStream}) {
		t.Fatalf("first future boundary = %v", got)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("policy shutdown: %v", err)
	}
}

func TestIdlePolicyInputAtDeadlineWinsAndWakeGestureIsConsumed(t *testing.T) {
	clock := newPolicyFakeClock(time.Unix(200, 0))
	sender := &policyRecordingSender{}
	input := make(chan inputObservation, 8)
	var output synchronizedWriter
	plan := devicePlan{
		brightness:  61,
		idleTimeout: 10 * time.Second,
		positions:   map[byte]eventPosition{2: {id: "button", position: "2_0"}},
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- runIdlePolicy(ctx, clock, sender, plan, clock.Now(), input, &output)
	}()
	waitForPolicyTimers(t, clock, 2)

	deadline := clock.Now().Add(10 * time.Second)
	input <- inputObservation{event: policyInput(2, d200x.InputMarkerButton, d200x.InputActionPressed), observedAt: deadline}
	clock.advance(10 * time.Second)
	time.Sleep(time.Millisecond)
	if got := sender.commands(); len(got) != 0 {
		t.Fatalf("input at deadline dimmed before handling: %v", got)
	}
	if output.String() == "" {
		t.Fatal("input at deadline was not dispatched")
	}

	clock.advance(10 * time.Second)
	waitForPolicyCommands(t, sender, 1)
	if payload := sender.payloads()[0]; string(payload) != "0" {
		t.Fatalf("idle payload = %q, want 0", payload)
	}

	input <- inputObservation{event: policyInput(2, d200x.InputMarkerButton, d200x.InputActionPressed), observedAt: clock.Now()}
	waitForPolicyCommands(t, sender, 2)
	input <- inputObservation{event: policyInput(7, d200x.InputMarkerEncoder, d200x.InputActionRotatedRight), observedAt: clock.Now()}
	waitForPolicyCommands(t, sender, 2)
	input <- inputObservation{event: policyInput(2, d200x.InputMarkerButton, d200x.InputActionReleased), observedAt: clock.Now()}
	time.Sleep(time.Millisecond)
	if got := sender.commands(); len(got) != 2 {
		t.Fatalf("matching release caused another restore: %v", got)
	}
	if stringsCount(output.String(), `"wire_index":7`) != 1 {
		t.Fatalf("unrelated encoder event was suppressed: %q", output.String())
	}

	input <- inputObservation{event: policyInput(2, d200x.InputMarkerButton, d200x.InputActionPressed), observedAt: clock.Now()}
	waitForOutput(t, &output, `"wire_index":2`, 2)
	input <- inputObservation{event: policyInput(2, d200x.InputMarkerButton, d200x.InputActionReleased), observedAt: clock.Now()}
	time.Sleep(time.Millisecond)
	if stringsCount(output.String(), `"wire_index":2`) != 3 {
		t.Fatalf("same-key new press did not clear stale suppression: %q", output.String())
	}

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("policy shutdown: %v", err)
	}
}

func TestIdlePolicyUnknownInputDoesNotWakeOrReset(t *testing.T) {
	clock := newPolicyFakeClock(time.Unix(300, 0))
	sender := &policyRecordingSender{}
	input := make(chan inputObservation, 4)
	var output synchronizedWriter
	plan := devicePlan{brightness: 42, idleTimeout: 5 * time.Second}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- runIdlePolicy(ctx, clock, sender, plan, clock.Now(), input, &output)
	}()
	waitForPolicyTimers(t, clock, 2)
	input <- inputObservation{event: policyInput(0, d200x.InputMarker(0x7f), d200x.InputActionPressed), observedAt: clock.Now()}
	waitForOutput(t, &output, `"action":"pressed"`, 1)
	clock.advance(5 * time.Second)
	waitForPolicyCommands(t, sender, 1)
	if got := sender.commands(); !equalCommands(got, []d200x.Command{d200x.CommandBrightness}) {
		t.Fatalf("unknown event reset or restored policy: %v", got)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("policy shutdown: %v", err)
	}
}

func TestIdlePolicyEncoderButtonGesturesWakeAndConsume(t *testing.T) {
	clock := newPolicyFakeClock(time.Unix(500, 0))
	sender := &policyRecordingSender{}
	var output synchronizedWriter
	plan := devicePlan{
		brightness:  57,
		idleTimeout: 20 * time.Second,
		positions:   map[byte]eventPosition{4: {id: "encoder", position: "4_0"}},
	}
	controller := &idlePolicyController{
		clock:  clock,
		sender: sender,
		plan:   plan,
		stdout: &output,
		state:  idlePolicyState{dimmed: true},
	}
	observedAt := clock.Now()
	if err := controller.handleInput(context.Background(), inputObservation{
		event:      policyInput(4, d200x.InputMarkerEncoder, d200x.InputActionPressed),
		observedAt: observedAt,
	}); err != nil {
		t.Fatalf("encoder press wake: %v", err)
	}
	if got := sender.commands(); !equalCommands(got, []d200x.Command{d200x.CommandBrightness}) {
		t.Fatalf("encoder press writes = %v", got)
	}
	if payload := sender.payloads()[0]; string(payload) != "57" {
		t.Fatalf("encoder restore payload = %q, want 57", payload)
	}
	if output.String() != "" {
		t.Fatalf("encoder press was not consumed: %q", output.String())
	}
	if controller.state.suppressedKey == nil || controller.state.suppressedKey.marker != d200x.InputMarkerEncoder || controller.state.suppressedKey.wireIndex != 4 {
		t.Fatalf("encoder suppression key = %+v", controller.state.suppressedKey)
	}
	if err := controller.handleInput(context.Background(), inputObservation{
		event:      policyInput(4, d200x.InputMarkerEncoder, d200x.InputActionReleased),
		observedAt: clock.Now(),
	}); err != nil {
		t.Fatalf("encoder release consume: %v", err)
	}
	if output.String() != "" || controller.state.suppressedKey != nil {
		t.Fatalf("encoder release was not consumed: output=%q suppression=%+v", output.String(), controller.state.suppressedKey)
	}

	standalone := &idlePolicyController{
		clock:  clock,
		sender: &policyRecordingSender{},
		plan:   plan,
		stdout: &output,
		state:  idlePolicyState{dimmed: true},
	}
	if err := standalone.handleInput(context.Background(), inputObservation{
		event:      policyInput(4, d200x.InputMarkerEncoder, d200x.InputActionReleased),
		observedAt: clock.Now(),
	}); err != nil {
		t.Fatalf("standalone encoder release wake: %v", err)
	}
	if standalone.state.dimmed || standalone.state.suppressedKey != nil {
		t.Fatalf("standalone encoder release state = %+v", standalone.state)
	}
}

func TestIdlePolicyActiveEncoderButtonGesturesResetIdle(t *testing.T) {
	clock := newPolicyFakeClock(time.Unix(600, 0))
	sender := &policyRecordingSender{}
	var output synchronizedWriter
	plan := devicePlan{
		brightness:  57,
		idleTimeout: 20 * time.Second,
		positions:   map[byte]eventPosition{4: {id: "encoder", position: "4_0"}},
	}
	controller := &idlePolicyController{
		clock:  clock,
		sender: sender,
		plan:   plan,
		stdout: &output,
		state:  idlePolicyState{idleDeadline: clock.Now().Add(time.Second)},
	}
	pressAt := clock.Now().Add(2 * time.Second)
	if err := controller.handleInput(context.Background(), inputObservation{
		event:      policyInput(4, d200x.InputMarkerEncoder, d200x.InputActionPressed),
		observedAt: pressAt,
	}); err != nil {
		t.Fatalf("active encoder press: %v", err)
	}
	releaseAt := pressAt.Add(time.Second)
	if err := controller.handleInput(context.Background(), inputObservation{
		event:      policyInput(4, d200x.InputMarkerEncoder, d200x.InputActionReleased),
		observedAt: releaseAt,
	}); err != nil {
		t.Fatalf("active encoder release: %v", err)
	}
	if stringsCount(output.String(), `"wire_index":4`) != 2 {
		t.Fatalf("active encoder events were suppressed: %q", output.String())
	}
	if want := releaseAt.Add(plan.idleTimeout); !controller.state.idleDeadline.Equal(want) {
		t.Fatalf("active encoder deadline = %v, want %v", controller.state.idleDeadline, want)
	}
}

func TestIdlePolicySuppressionRequiresMatchingMarkerAndWire(t *testing.T) {
	clock := newPolicyFakeClock(time.Unix(700, 0))
	sender := &policyRecordingSender{}
	var output synchronizedWriter
	plan := devicePlan{
		brightness:  57,
		idleTimeout: 20 * time.Second,
		positions: map[byte]eventPosition{
			4: {id: "encoder", position: "4_0"},
		},
	}
	controller := &idlePolicyController{
		clock:  clock,
		sender: sender,
		plan:   plan,
		stdout: &output,
		state:  idlePolicyState{dimmed: true},
	}
	if err := controller.handleInput(context.Background(), inputObservation{event: policyInput(4, d200x.InputMarkerEncoder, d200x.InputActionPressed), observedAt: clock.Now()}); err != nil {
		t.Fatalf("encoder wake: %v", err)
	}
	if err := controller.handleInput(context.Background(), inputObservation{event: policyInput(4, d200x.InputMarkerButton, d200x.InputActionReleased), observedAt: clock.Now()}); err != nil {
		t.Fatalf("button collision: %v", err)
	}
	if stringsCount(output.String(), `"wire_index":4`) != 1 {
		t.Fatalf("cross-marker release was suppressed: %q", output.String())
	}
	if controller.state.suppressedKey == nil || controller.state.suppressedKey.marker != d200x.InputMarkerEncoder {
		t.Fatalf("cross-marker event changed suppression: %+v", controller.state.suppressedKey)
	}
	if err := controller.handleInput(context.Background(), inputObservation{event: policyInput(4, d200x.InputMarkerEncoder, d200x.InputActionReleased), observedAt: clock.Now()}); err != nil {
		t.Fatalf("matching encoder release: %v", err)
	}
	if stringsCount(output.String(), `"wire_index":4`) != 1 {
		t.Fatalf("matching encoder release was dispatched: %q", output.String())
	}
}

func TestIdlePolicySameEncoderPressClearsStaleSuppression(t *testing.T) {
	clock := newPolicyFakeClock(time.Unix(800, 0))
	sender := &policyRecordingSender{}
	var output synchronizedWriter
	plan := devicePlan{brightness: 57, idleTimeout: 20 * time.Second, positions: map[byte]eventPosition{4: {id: "encoder", position: "4_0"}}}
	controller := &idlePolicyController{
		clock:  clock,
		sender: sender,
		plan:   plan,
		stdout: &output,
		state:  idlePolicyState{dimmed: true},
	}
	if err := controller.handleInput(context.Background(), inputObservation{event: policyInput(4, d200x.InputMarkerEncoder, d200x.InputActionPressed), observedAt: clock.Now()}); err != nil {
		t.Fatalf("encoder wake: %v", err)
	}
	if err := controller.handleInput(context.Background(), inputObservation{event: policyInput(4, d200x.InputMarkerEncoder, d200x.InputActionPressed), observedAt: clock.Now()}); err != nil {
		t.Fatalf("same encoder press: %v", err)
	}
	if err := controller.handleInput(context.Background(), inputObservation{event: policyInput(4, d200x.InputMarkerEncoder, d200x.InputActionReleased), observedAt: clock.Now()}); err != nil {
		t.Fatalf("encoder release after stale clear: %v", err)
	}
	if stringsCount(output.String(), `"wire_index":4`) != 2 {
		t.Fatalf("same-marker press did not clear suppression: %q", output.String())
	}
	if controller.state.suppressedKey != nil {
		t.Fatalf("suppression remained after same-marker press: %+v", controller.state.suppressedKey)
	}
}

func TestIdlePolicyDiscardsInputsAcrossLiveProfileTransition(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	pageSender := &profilePageSender{blockStarted: started, blockRelease: release}
	service := newTestProfileService(t, pageSender, nil)
	clock := newPolicyFakeClock(time.Unix(900, 0))
	var output synchronizedWriter
	plan := devicePlan{brightness: 73, positionsFn: service.CurrentEventPositions}
	controller := &idlePolicyController{
		clock:      clock,
		sender:     &policyRecordingSender{},
		plan:       plan,
		stdout:     &output,
		actions:    newProfileActionController(service, plan.eventPositions),
		transition: service.profileTransitionGate(),
	}
	if err := controller.handleInput(context.Background(), inputObservation{
		event:      actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionPressed),
		observedAt: clock.Now(),
	}); err != nil {
		t.Fatalf("pre-transition press: %v", err)
	}
	before := output.String()
	oldGeneration, _ := controller.transition.snapshot()
	activationDone := make(chan error, 1)
	go func() {
		_, err := service.ActivateProfile(context.Background(), "alternate")
		activationDone <- err
	}()
	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("activation did not reach live sender")
	}
	if controller.actions.candidate != nil {
		t.Fatal("press candidate survived transition start")
	}
	if err := controller.handleInput(context.Background(), inputObservation{
		event:      actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased),
		observedAt: clock.Now(),
	}); err != nil {
		t.Fatalf("transition release: %v", err)
	}
	if output.String() != before {
		t.Fatalf("input during transition was emitted: before=%q after=%q", before, output.String())
	}
	close(release)
	if err := <-activationDone; err != nil {
		t.Fatalf("activation: %v", err)
	}
	if err := controller.handleInput(context.Background(), inputObservation{
		event:                actionTestInput(0, d200x.InputMarkerButton, d200x.InputActionReleased),
		observedAt:           clock.Now(),
		transitionTagged:     true,
		transitionGeneration: oldGeneration,
	}); err != nil {
		t.Fatalf("queued transition input: %v", err)
	}
	if output.String() != before {
		t.Fatalf("queued transition input was emitted: %q", output.String())
	}
}

func TestIdlePolicyRestoreFailureConsumesNothingAndDoesNotRetry(t *testing.T) {
	clock := newPolicyFakeClock(time.Unix(900, 0))
	sender := &policyRecordingSender{failPayload: "57", failErr: errors.New("uncertain")}
	var output synchronizedWriter
	plan := devicePlan{brightness: 57, idleTimeout: 20 * time.Second, positions: map[byte]eventPosition{4: {id: "encoder", position: "4_0"}}}
	controller := &idlePolicyController{
		clock:  clock,
		sender: sender,
		plan:   plan,
		stdout: &output,
		state:  idlePolicyState{dimmed: true},
	}
	err := controller.handleInput(context.Background(), inputObservation{event: policyInput(4, d200x.InputMarkerEncoder, d200x.InputActionPressed), observedAt: clock.Now()})
	if err == nil {
		t.Fatal("restore failure did not stop policy")
	}
	if got := sender.commands(); !equalCommands(got, []d200x.Command{d200x.CommandBrightness}) {
		t.Fatalf("restore retries = %v", got)
	}
	if output.String() != "" || !controller.state.dimmed {
		t.Fatalf("failed restore consumed or changed state: output=%q state=%+v", output.String(), controller.state)
	}
}

func TestIdlePolicyWriteFailureStopsWithoutRetry(t *testing.T) {
	for _, test := range []struct {
		name       string
		at         time.Duration
		brightness int
		want       d200x.Command
	}{
		{name: "keepalive", at: 50 * time.Second, want: d200x.CommandEnableInputStream},
		{name: "dim", at: 5 * time.Second, brightness: 0, want: d200x.CommandBrightness},
	} {
		t.Run(test.name, func(t *testing.T) {
			clock := newPolicyFakeClock(time.Unix(400, 0))
			sender := &policyRecordingSender{failCommand: test.want, failErr: errors.New("uncertain")}
			input := make(chan inputObservation, 1)
			var output bytes.Buffer
			plan := devicePlan{brightness: 73, idleTimeout: test.at}
			if test.name == "keepalive" {
				plan.idleTimeout = 0
			}
			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan error, 1)
			go func() {
				done <- runIdlePolicy(ctx, clock, sender, plan, clock.Now(), input, &output)
			}()
			if test.name == "dim" {
				waitForPolicyTimers(t, clock, 2)
			} else {
				waitForPolicyTimers(t, clock, 1)
			}
			clock.advance(test.at)
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("uncertain write did not stop policy")
				}
			case <-time.After(time.Second):
				t.Fatal("policy did not stop after uncertain write")
			}
			cancel()
			if got := sender.commands(); !equalCommands(got, []d200x.Command{test.want}) {
				t.Fatalf("commands after failure = %v, want one %s", got, test.want)
			}
		})
	}
}

func TestIdlePolicyAppliesReloadSettingsFromLatestActivity(t *testing.T) {
	start := time.Unix(1000, 0)
	tests := []struct {
		name       string
		state      idlePolicyState
		settings   reloadSettings
		wantFrames int
		wantValue  string
		wantDimmed bool
		wantDue    time.Time
	}{
		{
			name:       "awake brightness writes once",
			state:      idlePolicyState{lastActivity: start, idleDeadline: start.Add(time.Minute)},
			settings:   reloadSettings{brightness: 74, idleTimeout: time.Minute},
			wantFrames: 1,
			wantValue:  "74",
			wantDue:    start.Add(time.Minute),
		},
		{
			name:       "dimmed brightness stages restore target",
			state:      idlePolicyState{dimmed: true, lastActivity: start, idleDeadline: start.Add(time.Minute)},
			settings:   reloadSettings{brightness: 74, idleTimeout: time.Minute},
			wantDimmed: true,
			wantDue:    start.Add(time.Minute),
		},
		{
			name:       "shortened elapsed timeout dims promptly",
			state:      idlePolicyState{lastActivity: start.Add(-time.Minute), idleDeadline: start},
			settings:   reloadSettings{brightness: 73, idleTimeout: 30 * time.Second},
			wantFrames: 1,
			wantValue:  "0",
			wantDimmed: true,
			wantDue:    start.Add(-30 * time.Second),
		},
		{
			name:     "lengthened timeout preserves activity origin",
			state:    idlePolicyState{lastActivity: start.Add(-20 * time.Second), idleDeadline: start.Add(40 * time.Second)},
			settings: reloadSettings{brightness: 73, idleTimeout: 2 * time.Minute},
			wantDue:  start.Add(100 * time.Second),
		},
		{
			name:       "zero timeout restores dimmed display",
			state:      idlePolicyState{dimmed: true, lastActivity: start.Add(-time.Minute)},
			settings:   reloadSettings{brightness: 81},
			wantFrames: 1,
			wantValue:  "81",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			clock := newPolicyFakeClock(start)
			sender := &policyRecordingSender{}
			controller := &idlePolicyController{
				clock:   clock,
				sender:  sender,
				plan:    devicePlan{brightness: 73, idleTimeout: time.Minute},
				actions: &profileActionController{},
				state:   test.state,
			}
			result, err := controller.applySettings(context.Background(), test.settings)
			if err != nil {
				t.Fatal(err)
			}
			if result.writeAttempted != (test.wantFrames == 1) || len(sender.payloads()) != test.wantFrames {
				t.Fatalf("write result/frames = %+v/%d", result, len(sender.payloads()))
			}
			if test.wantFrames == 1 && string(sender.payloads()[0]) != test.wantValue {
				t.Fatalf("brightness payload = %q, want %q", sender.payloads()[0], test.wantValue)
			}
			if controller.state.dimmed != test.wantDimmed || !controller.state.idleDeadline.Equal(test.wantDue) {
				t.Fatalf("state = %+v, want dimmed=%t deadline=%v", controller.state, test.wantDimmed, test.wantDue)
			}
			if controller.plan.brightness != test.settings.brightness || controller.plan.idleTimeout != test.settings.idleTimeout {
				t.Fatalf("plan = %+v", controller.plan)
			}
		})
	}
}

func TestIdlePolicyReloadWriteFailureRetainsPolicyState(t *testing.T) {
	start := time.Unix(1100, 0)
	sender := &policyRecordingSender{failPayload: "74", failErr: errors.New("uncertain")}
	controller := &idlePolicyController{
		clock:  newPolicyFakeClock(start),
		sender: sender,
		plan:   devicePlan{brightness: 73, idleTimeout: time.Minute},
		state:  idlePolicyState{lastActivity: start, idleDeadline: start.Add(time.Minute)},
	}
	result, err := controller.applySettings(context.Background(), reloadSettings{brightness: 74, idleTimeout: time.Minute})
	if err == nil || !result.writeAttempted {
		t.Fatalf("failed settings result = %+v, %v", result, err)
	}
	if controller.plan.brightness != 73 || controller.plan.idleTimeout != time.Minute || controller.state.dimmed || !controller.state.idleDeadline.Equal(start.Add(time.Minute)) {
		t.Fatalf("policy mutated after failed write: plan=%+v state=%+v", controller.plan, controller.state)
	}
}

func TestIdlePolicyReloadTimeoutUsesRecordedInputActivity(t *testing.T) {
	start := time.Unix(1150, 0)
	clock := newPolicyFakeClock(start)
	clock.advance(10 * time.Second)
	activityAt := clock.Now()
	controller := &idlePolicyController{
		clock:   clock,
		sender:  &policyRecordingSender{},
		plan:    devicePlan{brightness: 73, idleTimeout: time.Minute, positions: map[byte]eventPosition{0: {id: "tile", position: "0_0"}}},
		stdout:  &synchronizedWriter{},
		actions: &profileActionController{},
		state:   idlePolicyState{lastActivity: start, idleDeadline: start.Add(time.Minute)},
	}
	if err := controller.handleInput(context.Background(), inputObservation{
		event:      policyInput(0, d200x.InputMarkerButton, d200x.InputActionPressed),
		observedAt: activityAt,
	}); err != nil {
		t.Fatal(err)
	}
	clock.advance(10 * time.Second)
	if _, err := controller.applySettings(context.Background(), reloadSettings{brightness: 73, idleTimeout: 2 * time.Minute}); err != nil {
		t.Fatal(err)
	}
	if want := activityAt.Add(2 * time.Minute); !controller.state.idleDeadline.Equal(want) {
		t.Fatalf("reload deadline = %v, want activity-derived %v", controller.state.idleDeadline, want)
	}
}

func TestIdlePolicyZeroTimeoutRestorePreservesKeepaliveDeadline(t *testing.T) {
	start := time.Unix(1175, 0)
	keepaliveAt := start.Add(17 * time.Second)
	controller := &idlePolicyController{
		clock:   newPolicyFakeClock(start),
		sender:  &policyRecordingSender{},
		plan:    devicePlan{brightness: 73, idleTimeout: time.Minute},
		actions: &profileActionController{},
		state: idlePolicyState{
			dimmed:       true,
			lastActivity: start.Add(-time.Minute),
			keepaliveAt:  keepaliveAt,
		},
	}
	if _, err := controller.applySettings(context.Background(), reloadSettings{brightness: 81}); err != nil {
		t.Fatal(err)
	}
	if !controller.state.keepaliveAt.Equal(keepaliveAt) {
		t.Fatalf("zero-timeout restore changed keepalive from %v to %v", keepaliveAt, controller.state.keepaliveAt)
	}
}

func TestIdlePolicyDueWritesCannotCrossTransitionBegin(t *testing.T) {
	start := time.Unix(1180, 0)
	gate := &profileTransitionGate{}
	sender := &policyRecordingSender{}
	controller := &idlePolicyController{
		clock:      newPolicyFakeClock(start),
		sender:     sender,
		plan:       devicePlan{brightness: 73, idleTimeout: time.Second},
		actions:    &profileActionController{},
		transition: gate,
		state: idlePolicyState{
			lastActivity: start.Add(-time.Second),
			idleDeadline: start,
			keepaliveAt:  start,
		},
	}
	gate.mu.Lock()
	keepaliveDone := make(chan bool, 1)
	go func() {
		written, _ := controller.tryKeepalive(context.Background())
		keepaliveDone <- written
	}()
	gate.generation++
	gate.active = true
	gate.activeDone = make(chan struct{})
	gate.mu.Unlock()
	if written := <-keepaliveDone; written {
		t.Fatal("due keepalive crossed transition begin")
	}
	written, err := controller.tryDim(context.Background())
	if err != nil || written {
		t.Fatalf("due dim during transition = written %t, error %v", written, err)
	}
	if got := sender.commands(); len(got) != 0 {
		t.Fatalf("writes during transition = %v", got)
	}
	gate.end()
	if written, err := controller.tryKeepalive(context.Background()); err != nil || !written {
		t.Fatalf("deferred keepalive = written %t, error %v", written, err)
	}
	if written, err := controller.tryDim(context.Background()); err != nil || !written {
		t.Fatalf("deferred dim = written %t, error %v", written, err)
	}
	if got := sender.commands(); !equalCommands(got, []d200x.Command{d200x.CommandEnableInputStream, d200x.CommandBrightness}) {
		t.Fatalf("post-transition writes = %v", got)
	}
}

func TestIdleSettingsBridgeShutdownAfterDeliveryUnblocks(t *testing.T) {
	bridge := newIdleSettingsBridge()
	bridge.activate()
	done := make(chan error, 1)
	go func() {
		_, err := bridge.ApplySettings(context.Background(), reloadSettings{brightness: 74})
		done <- err
	}()
	request := <-bridge.requests
	bridge.close()
	if err := <-done; !errors.Is(err, ErrReloadSettingsPending) {
		t.Fatalf("ApplySettings after delivered shutdown = %v", err)
	}
	if request.state.claim() {
		t.Fatal("shutdown-aborted settings request remained claimable")
	}
}

func policyInput(wire byte, marker d200x.InputMarker, action d200x.InputAction) d200x.InputEvent {
	return d200x.InputEvent{WireIndex: wire, Marker: marker, Action: action}
}

func equalCommands(got, want []d200x.Command) bool {
	if len(got) != len(want) {
		return false
	}
	for index := range want {
		if got[index] != want[index] {
			return false
		}
	}
	return true
}

type policyRecordingSender struct {
	mu          sync.Mutex
	frames      []d200x.Frame
	failCommand d200x.Command
	failPayload string
	failErr     error
}

func (sender *policyRecordingSender) SendFrame(_ context.Context, frame d200x.Frame) error {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	sender.frames = append(sender.frames, d200x.NewFrame(frame.Command, frame.Payload))
	if frame.Command == sender.failCommand || string(frame.Payload) == sender.failPayload && sender.failPayload != "" {
		return sender.failErr
	}
	return nil
}

func (sender *policyRecordingSender) commands() []d200x.Command {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	commands := make([]d200x.Command, len(sender.frames))
	for index, frame := range sender.frames {
		commands[index] = frame.Command
	}
	return commands
}

func (sender *policyRecordingSender) payloads() [][]byte {
	sender.mu.Lock()
	defer sender.mu.Unlock()
	payloads := make([][]byte, len(sender.frames))
	for index, frame := range sender.frames {
		payloads[index] = frame.PayloadCopy()
	}
	return payloads
}

type policyFakeClock struct {
	mu     sync.Mutex
	now    time.Time
	timers []*policyFakeTimer
}

func newPolicyFakeClock(now time.Time) *policyFakeClock {
	return &policyFakeClock{now: now}
}

func (clock *policyFakeClock) Now() time.Time {
	clock.mu.Lock()
	defer clock.mu.Unlock()
	return clock.now
}

func (clock *policyFakeClock) NewTimer(duration time.Duration) Timer {
	clock.mu.Lock()
	defer clock.mu.Unlock()
	timer := &policyFakeTimer{clock: clock, deadline: clock.now.Add(duration), channel: make(chan time.Time, 1)}
	clock.timers = append(clock.timers, timer)
	if duration <= 0 {
		timer.channel <- clock.now
	}
	return timer
}

func (clock *policyFakeClock) advance(duration time.Duration) {
	clock.mu.Lock()
	clock.now = clock.now.Add(duration)
	for _, timer := range clock.timers {
		if timer.stopped || timer.deadline.After(clock.now) {
			continue
		}
		select {
		case timer.channel <- clock.now:
		default:
		}
	}
	clock.mu.Unlock()
}

type policyFakeTimer struct {
	clock    *policyFakeClock
	deadline time.Time
	channel  chan time.Time
	stopped  bool
}

func (timer *policyFakeTimer) C() <-chan time.Time {
	return timer.channel
}

func (timer *policyFakeTimer) Stop() bool {
	timer.clock.mu.Lock()
	defer timer.clock.mu.Unlock()
	if timer.stopped {
		return false
	}
	timer.stopped = true
	return true
}

func waitForPolicyTimers(t *testing.T, clock *policyFakeClock, count int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		clock.mu.Lock()
		got := len(clock.timers)
		clock.mu.Unlock()
		if got >= count {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("fake clock has fewer than %d timers", count)
}

func waitForPolicyCommands(t *testing.T, sender *policyRecordingSender, count int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if len(sender.commands()) >= count {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("sender has fewer than %d commands: %v", count, sender.commands())
}

func waitForOutput(t *testing.T, output *synchronizedWriter, marker string, minimum int) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if stringsCount(output.String(), marker) >= minimum {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("output did not contain %q %d times: %q", marker, minimum, output.String())
}

func stringsCount(value, substring string) int {
	return bytes.Count([]byte(value), []byte(substring))
}

var _ Clock = (*policyFakeClock)(nil)
var _ Timer = (*policyFakeTimer)(nil)
var _ frameSender = (*policyRecordingSender)(nil)
