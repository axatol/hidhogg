package runtime

import (
	"bytes"
	"context"
	"errors"
	"os"
	"reflect"
	"testing"
	"time"

	appconfig "hidhogg/internal/config"
	"hidhogg/internal/configstore"
	"hidhogg/internal/ipc"
)

type configEditorMutationResponse struct {
	result ipc.ConfigEditorMutationResult
	err    error
}

func TestRuntimeConfigEditorCreateUsesCurrentAndDeleteCurrentRefusesAfterActivation(t *testing.T) {
	source := runtimeMultiProfileConfiguration()
	runtimeProcess, path, editor := newRuntimeProfileLifecycleFixture(t, source)
	activation, err := runtimeProcess.profileService.ActivateProfile(context.Background(), "alternate")
	if err != nil || activation.ProfileID != "alternate" || !activation.Changed {
		t.Fatalf("activate before clone = %+v, %v", activation, err)
	}

	created, err := editor.CreateProfile(context.Background(), editorSourceDigest(source), "", "clone", "Clone current")
	if err != nil {
		t.Fatal(err)
	}
	if created.FileCommit != ipc.EditorFileCommitCommitted || created.ReloadOutcome != ipc.EditorReloadChanged || created.Revision != 2 {
		t.Fatalf("create result = %+v", created)
	}
	committedSource, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	configuration, err := appconfig.Decode(committedSource)
	if err != nil {
		t.Fatal(err)
	}
	if len(configuration.Profiles) != 3 || configuration.Profiles[2].ID != "clone" || configuration.Profiles[2].Label != "Clone current" || !reflect.DeepEqual(configuration.Profiles[1].Positions, configuration.Profiles[2].Positions) {
		t.Fatalf("clone did not copy the coordinator's current profile: %+v", configuration.Profiles[2])
	}
	if created.SourceDigest != editorSourceDigest(committedSource) {
		t.Fatal("create result digest does not match committed source")
	}
	if current, ok := runtimeProcess.profileService.CurrentProfileID(); !ok || current != "alternate" {
		t.Fatalf("create changed current profile to %q", current)
	}

	currentDigest := editorSourceDigest(committedSource)
	if _, err := editor.DeleteProfile(context.Background(), currentDigest, "alternate"); !errors.Is(err, ipc.ErrEditInvalid) {
		t.Fatalf("delete-current error = %v", err)
	}
	if _, err := editor.DeleteProfile(context.Background(), currentDigest, "default"); !errors.Is(err, ipc.ErrEditInvalid) {
		t.Fatalf("delete-default error = %v", err)
	}
	afterRefusals, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(afterRefusals, committedSource) {
		t.Fatal("refused lifecycle operation changed the source")
	}
}

func TestRuntimeConfigEditorDeleteSerializesBeforeActivationAndDrainsWatcherDirty(t *testing.T) {
	source := runtimeMultiProfileConfiguration()
	runtimeProcess, path, editor := newRuntimeProfileLifecycleFixture(t, source)
	applyFinished := make(chan struct{})
	applyRelease := make(chan struct{})
	editor.apply = func(path string, expected configstore.Digest, mutate func([]byte) ([]byte, error)) (configstore.Result, error) {
		result, err := configstore.Apply(path, expected, mutate)
		if result.Outcome == configstore.OutcomeCommitted || result.Outcome == configstore.OutcomeUncertain {
			close(applyFinished)
			<-applyRelease
		}
		return result, err
	}
	deleteDone := make(chan configEditorMutationResponse, 1)
	go func() {
		result, err := editor.DeleteProfile(context.Background(), editorSourceDigest(source), "alternate")
		deleteDone <- configEditorMutationResponse{result: result, err: err}
	}()
	select {
	case <-applyFinished:
	case <-time.After(2 * time.Second):
		t.Fatal("delete did not reach its committed callback")
	}
	if runtimeProcess.reload.beginAutomatic() {
		t.Fatal("automatic reload acquired admission during lifecycle commit")
	}
	activationDone := make(chan error, 1)
	go func() {
		_, err := runtimeProcess.profileService.ActivateProfile(context.Background(), "alternate")
		activationDone <- err
	}()
	waitForRuntime(t, func() bool { return len(runtimeProcess.profileService.requests) > 0 })
	close(applyRelease)
	select {
	case deleted := <-deleteDone:
		if deleted.err != nil {
			t.Fatal(deleted.err)
		}
		if deleted.result.FileCommit != ipc.EditorFileCommitCommitted || deleted.result.ReloadOutcome != ipc.EditorReloadChanged || deleted.result.Revision != 2 {
			t.Fatalf("delete result = %+v", deleted.result)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("delete did not complete after callback release")
	}
	select {
	case err := <-activationDone:
		if !errors.Is(err, ErrUnknownProfile) {
			t.Fatalf("queued activation error = %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("queued activation did not complete")
	}
	remaining, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	configuration, err := appconfig.Decode(remaining)
	if err != nil {
		t.Fatal(err)
	}
	if len(configuration.Profiles) != 1 || configuration.Profiles[0].ID != "default" {
		t.Fatalf("remaining profiles = %+v", configuration.Profiles)
	}
	runtimeProcess.reload.mu.Lock()
	dirty := runtimeProcess.reload.dirty
	runtimeProcess.reload.mu.Unlock()
	if dirty {
		t.Fatal("lifecycle completion did not drain the watcher dirty bit")
	}
	select {
	case <-runtimeProcess.automaticReload:
	default:
		t.Fatal("lifecycle completion did not signal the pending automatic reload")
	}
}

func TestRuntimeConfigEditorLifecycleRejectsStaleAndActionReferencedDeletes(t *testing.T) {
	t.Run("stale digest", func(t *testing.T) {
		source := runtimeMultiProfileConfiguration()
		runtimeProcess, path, editor := newRuntimeProfileLifecycleFixture(t, source)
		external := bytes.Replace(source, []byte("label = \"default\"\n"), []byte("label = \"external\"\n"), 1)
		if bytes.Equal(source, external) {
			t.Fatal("stale test fixture was not changed")
		}
		if err := os.WriteFile(path, external, 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := editor.CreateProfile(context.Background(), editorSourceDigest(source), "", "clone", "Clone")
		if !errors.Is(err, ipc.ErrStaleSource) {
			t.Fatalf("stale create error = %v", err)
		}
		current, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(current, external) {
			t.Fatal("stale create changed the external source")
		}
		status := runtimeProcess.ReloadStatus()
		if status.Outcome != ReloadOutcomeReady || status.Reason != ReloadReasonNone || status.Active {
			t.Fatalf("stale create changed reload status: %+v", status)
		}
	})

	t.Run("action dependency", func(t *testing.T) {
		source := bytes.Replace(
			runtimeMultiProfileConfiguration(),
			[]byte("[profiles.\"default\".positions.\"0_0\"]\nlabel = \"default 0\"\nbackground = \"#102030\"\n\n"),
			[]byte("[profiles.\"default\".positions.\"0_0\"]\nlabel = \"default 0\"\nbackground = \"#102030\"\n\n[profiles.\"default\".positions.\"0_0\".action]\ntype = \"activate_profile\"\ngesture = \"release\"\nprofile_id = \"alternate\"\n\n"),
			1,
		)
		if _, err := appconfig.Decode(source); err != nil {
			t.Fatalf("action fixture is invalid: %v", err)
		}
		runtimeProcess, path, editor := newRuntimeProfileLifecycleFixture(t, source)
		_, err := editor.DeleteProfile(context.Background(), editorSourceDigest(source), "alternate")
		if !errors.Is(err, ipc.ErrEditInvalid) {
			t.Fatalf("action-referenced delete error = %v", err)
		}
		current, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(current, source) {
			t.Fatal("action-referenced delete changed the source")
		}
		if status := runtimeProcess.ReloadStatus(); status.Outcome != ReloadOutcomeReady || status.Reason != ReloadReasonNone {
			t.Fatalf("action-refusal changed reload status: %+v", status)
		}
	})
}

func TestRuntimeConfigEditorLifecycleCancellationBoundary(t *testing.T) {
	t.Run("cancelled before mutation", func(t *testing.T) {
		source := runtimeMultiProfileConfiguration()
		runtimeProcess, path, editor := newRuntimeProfileLifecycleFixture(t, source)
		started := make(chan struct{})
		release := make(chan struct{})
		editor.apply = func(path string, expected configstore.Digest, mutate func([]byte) ([]byte, error)) (configstore.Result, error) {
			close(started)
			<-release
			return configstore.Apply(path, expected, mutate)
		}
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan error, 1)
		go func() {
			_, err := editor.CreateProfile(ctx, editorSourceDigest(source), "", "clone", "Clone")
			done <- err
		}()
		select {
		case <-started:
		case <-time.After(2 * time.Second):
			t.Fatal("create did not reach the pre-commit boundary")
		}
		cancel()
		close(release)
		select {
		case err := <-done:
			if !errors.Is(err, context.Canceled) {
				t.Fatalf("cancelled create error = %v", err)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("cancelled create did not stop")
		}
		current, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(current, source) {
			t.Fatal("pre-commit cancellation changed the source")
		}
		status := runtimeProcess.ReloadStatus()
		if status.Outcome != ReloadOutcomeReady || status.Reason != ReloadReasonNone || status.Active {
			t.Fatalf("pre-commit cancellation changed reload status: %+v", status)
		}
	})

	t.Run("cancelled after rename", func(t *testing.T) {
		source := runtimeMultiProfileConfiguration()
		runtimeProcess, path, editor := newRuntimeProfileLifecycleFixture(t, source)
		committed := make(chan struct{})
		release := make(chan struct{})
		editor.apply = func(path string, expected configstore.Digest, mutate func([]byte) ([]byte, error)) (configstore.Result, error) {
			result, err := configstore.Apply(path, expected, mutate)
			if result.Outcome == configstore.OutcomeCommitted {
				close(committed)
				<-release
			}
			return result, err
		}
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		done := make(chan configEditorMutationResponse, 1)
		go func() {
			result, err := editor.CreateProfile(ctx, editorSourceDigest(source), "", "clone", "Clone")
			done <- configEditorMutationResponse{result: result, err: err}
		}()
		select {
		case <-committed:
		case <-time.After(2 * time.Second):
			t.Fatal("create did not commit before cancellation")
		}
		cancel()
		close(release)
		select {
		case result := <-done:
			if result.err != nil {
				t.Fatal(result.err)
			}
			if result.result.FileCommit != ipc.EditorFileCommitCommitted || result.result.ReloadOutcome != ipc.EditorReloadChanged {
				t.Fatalf("post-commit cancellation result = %+v", result.result)
			}
		case <-time.After(2 * time.Second):
			t.Fatal("post-commit reload did not complete after cancellation")
		}
		if runtimeProcess.profileService.revision() != 2 {
			t.Fatalf("runtime revision after post-commit cancellation = %d", runtimeProcess.profileService.revision())
		}
		current, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		configuration, err := appconfig.Decode(current)
		if err != nil {
			t.Fatal(err)
		}
		if len(configuration.Profiles) != 3 {
			t.Fatalf("profile count after post-commit cancellation = %d", len(configuration.Profiles))
		}
	})
}

func TestRuntimeConfigEditorLifecycleSeparatesCommitAndReloadOutcomes(t *testing.T) {
	t.Run("reload rejection", func(t *testing.T) {
		source := runtimeMultiProfileConfiguration()
		path := writeReloadConfiguration(t, source)
		initial, err := buildReloadCandidateFromBytes(source, "default")
		if err != nil {
			t.Fatal(err)
		}
		initial.settings.brightness--
		profileService, err := NewProfileService(ProfileServiceOptions{
			Catalog:          initial.Catalog(),
			Sender:           &profilePageSender{},
			InitialProfileID: initial.CurrentProfileID(),
			initialSnapshot:  &initial,
			settingsApplier:  &reloadSettingsApplierStub{err: ErrReloadSettingsPending},
		})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = profileService.Close() })
		runtimeProcess := &Runtime{
			config:          Config{ConfigPath: path},
			profileService:  profileService,
			automaticReload: make(chan struct{}, 1),
			reload:          reloadAdmission{outcome: ReloadOutcomeReady, reason: ReloadReasonNone},
		}
		editor := runtimeIPCConfigEditorService{runtime: runtimeProcess}
		automaticAcquired := false
		editor.apply = func(path string, expected configstore.Digest, mutate func([]byte) ([]byte, error)) (configstore.Result, error) {
			result, err := configstore.Apply(path, expected, mutate)
			if result.Outcome == configstore.OutcomeCommitted || result.Outcome == configstore.OutcomeUncertain {
				automaticAcquired = runtimeProcess.reload.beginAutomatic()
			}
			return result, err
		}
		result, err := editor.CreateProfile(context.Background(), editorSourceDigest(source), "", "clone", "Clone")
		if err != nil {
			t.Fatal(err)
		}
		if result.FileCommit != ipc.EditorFileCommitCommitted || result.ReloadOutcome != ipc.EditorReloadRejected || result.Reason != string(ReloadReasonSettingsPending) || result.Revision != 1 {
			t.Fatalf("committed/rejected result = %+v", result)
		}
		if automaticAcquired {
			t.Fatal("automatic reload acquired admission during the lifecycle mutation")
		}
		committedSource, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		configuration, err := appconfig.Decode(committedSource)
		if err != nil {
			t.Fatal(err)
		}
		if len(configuration.Profiles) != 3 || result.SourceDigest != editorSourceDigest(committedSource) || len(profileService.ListProfiles()) != 2 {
			t.Fatalf("commit/reload separation was lost: profiles=%d runtime=%d result=%+v", len(configuration.Profiles), len(profileService.ListProfiles()), result)
		}
		if result.Reason != string(ReloadReasonSettingsPending) {
			t.Fatalf("dirty watcher changed the edit's reload reason: %+v", result)
		}
		runtimeProcess.reload.mu.Lock()
		dirty := runtimeProcess.reload.dirty
		runtimeProcess.reload.mu.Unlock()
		if dirty {
			t.Fatal("committed rejected edit did not drain the watcher dirty bit")
		}
		select {
		case <-runtimeProcess.automaticReload:
		default:
			t.Fatal("committed rejected edit did not signal the pending automatic reload")
		}
	})

	t.Run("uncertain file commit", func(t *testing.T) {
		source := runtimeMultiProfileConfiguration()
		runtimeProcess, path, editor := newRuntimeProfileLifecycleFixture(t, source)
		editor.apply = func(path string, expected configstore.Digest, mutate func([]byte) ([]byte, error)) (configstore.Result, error) {
			result, err := configstore.Apply(path, expected, mutate)
			if err != nil {
				return result, err
			}
			result.Outcome = configstore.OutcomeUncertain
			return result, errors.New("simulated directory sync uncertainty")
		}
		result, err := editor.CreateProfile(context.Background(), editorSourceDigest(source), "", "clone", "Clone")
		if err != nil {
			t.Fatal(err)
		}
		if result.FileCommit != ipc.EditorFileCommitUncertain || result.ReloadOutcome != ipc.EditorReloadChanged || result.Revision != 2 {
			t.Fatalf("uncertain commit/reload result = %+v", result)
		}
		committedSource, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if result.SourceDigest != editorSourceDigest(committedSource) || len(runtimeProcess.profileService.ListProfiles()) != 3 {
			t.Fatal("uncertain file result was not reloaded from its exact bytes")
		}
	})
}

func TestConfigEditorReloadProjectionUsesAttemptError(t *testing.T) {
	tests := []struct {
		name        string
		err         error
		result      ReloadResult
		wantOutcome string
		wantReason  ReloadReason
	}{
		{
			name:        "changed",
			result:      ReloadResult{Changed: true},
			wantOutcome: ipc.EditorReloadChanged,
			wantReason:  ReloadReasonNone,
		},
		{
			name:        "settings rejected",
			err:         ErrReloadSettingsPending,
			wantOutcome: ipc.EditorReloadRejected,
			wantReason:  ReloadReasonSettingsPending,
		},
		{
			name:        "uncertain device transition",
			err:         uncertainReloadError(errors.New("device failure")),
			wantOutcome: ipc.EditorReloadUncertain,
			wantReason:  ReloadReasonDeviceWriteFailed,
		},
		{
			name:        "candidate rejected",
			err:         errors.New("candidate rejected"),
			wantOutcome: ipc.EditorReloadRejected,
			wantReason:  ReloadReasonCandidateRejected,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := configEditorReloadOutcome(test.result, test.err); got != test.wantOutcome {
				t.Fatalf("reload outcome = %q, want %q", got, test.wantOutcome)
			}
			if got := configEditorReloadReason(test.err); got != test.wantReason {
				t.Fatalf("reload reason = %q, want %q", got, test.wantReason)
			}
		})
	}
}

func newRuntimeProfileLifecycleFixture(t *testing.T, source []byte) (*Runtime, string, runtimeIPCConfigEditorService) {
	t.Helper()
	runtimeProcess, path := newReloadTestRuntime(t, source, &profilePageSender{}, nil)
	runtimeProcess.automaticReload = make(chan struct{}, 1)
	return runtimeProcess, path, runtimeIPCConfigEditorService{runtime: runtimeProcess}
}
