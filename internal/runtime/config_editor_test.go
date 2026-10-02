package runtime

import (
	"bytes"
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"

	appconfig "hidhogg/internal/config"
	"hidhogg/internal/configstore"
	"hidhogg/internal/ipc"
)

func TestRuntimeConfigEditorSnapshotLabelGetAndNoop(t *testing.T) {
	source := reloadTestConfiguration()
	runtimeProcess, path := newReloadTestRuntime(t, source, &profilePageSender{}, nil)
	runtimeProcess.automaticReload = make(chan struct{}, 1)
	editor := runtimeIPCConfigEditorService{runtime: runtimeProcess}

	snapshot, err := editor.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.SourceDigest != editorSourceDigest(source) || snapshot.Revision != 1 || snapshot.DefaultProfileID != "default" || snapshot.CurrentProfileID != "default" || !reflect.DeepEqual(snapshot.ProfileIDs, []string{"default", "alternate"}) {
		t.Fatalf("editor snapshot = %+v", snapshot)
	}

	profile, err := editor.GetProfile(context.Background(), snapshot.SourceDigest, "default")
	if err != nil {
		t.Fatal(err)
	}
	if profile.SourceDigest != snapshot.SourceDigest || profile.ProfileID != "default" || profile.Label != "default" {
		t.Fatalf("editor profile = %+v", profile)
	}

	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	runtimeProcess.reload.mu.Lock()
	runtimeProcess.reload.outcome = ReloadOutcomeRejected
	runtimeProcess.reload.reason = ReloadReasonCandidateRejected
	runtimeProcess.reload.mu.Unlock()

	applyStarted := make(chan struct{})
	applyRelease := make(chan struct{})
	editor.apply = func(path string, expected configstore.Digest, mutate func([]byte) ([]byte, error)) (configstore.Result, error) {
		result, err := configstore.Apply(path, expected, mutate)
		close(applyStarted)
		<-applyRelease
		return result, err
	}
	setDone := make(chan struct {
		result ipc.ConfigEditorLabelResult
		err    error
	}, 1)
	go func() {
		result, err := editor.SetProfileLabel(context.Background(), snapshot.SourceDigest, "default", "default")
		setDone <- struct {
			result ipc.ConfigEditorLabelResult
			err    error
		}{result: result, err: err}
	}()
	<-applyStarted
	if runtimeProcess.reload.beginAutomatic() {
		t.Fatal("automatic reload unexpectedly acquired admission during editor write")
	}
	close(applyRelease)
	noOp := <-setDone
	if noOp.err != nil {
		t.Fatal(noOp.err)
	}
	if noOp.result.FileCommit != ipc.EditorFileCommitUnchanged || noOp.result.ReloadOutcome != ipc.EditorReloadUnchanged || noOp.result.Revision != snapshot.Revision || noOp.result.Effect != string(reloadEffectUnchanged) || noOp.result.Reason != string(ReloadReasonNone) {
		t.Fatalf("no-op label result = %+v", noOp.result)
	}
	after, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, after) {
		t.Fatal("no-op label update replaced the source inode")
	}
	currentSource, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(currentSource, source) {
		t.Fatal("no-op label update changed source bytes")
	}
	status := runtimeProcess.ReloadStatus()
	if status.Active || status.Outcome != ReloadOutcomeRejected || status.Reason != ReloadReasonCandidateRejected {
		t.Fatalf("no-op label update changed reload status: %+v", status)
	}
	runtimeProcess.reload.mu.Lock()
	dirty := runtimeProcess.reload.dirty
	runtimeProcess.reload.mu.Unlock()
	if dirty {
		t.Fatal("editor admission did not drain the watcher dirty bit")
	}
	select {
	case <-runtimeProcess.automaticReload:
	default:
		t.Fatal("editor admission did not signal the pending automatic reload")
	}

	editor.apply = nil
	committed, err := editor.SetProfileLabel(context.Background(), snapshot.SourceDigest, "default", "Renamed")
	if err != nil {
		t.Fatal(err)
	}
	if committed.FileCommit != ipc.EditorFileCommitCommitted || committed.ReloadOutcome != ipc.EditorReloadChanged || committed.SourceDigest == snapshot.SourceDigest || committed.Revision != 2 || committed.Reason != string(ReloadReasonNone) {
		t.Fatalf("committed label result = %+v", committed)
	}
	updatedSource, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if committed.SourceDigest != editorSourceDigest(updatedSource) {
		t.Fatal("label result digest does not match committed source")
	}
	updated, err := appconfig.Decode(updatedSource)
	if err != nil {
		t.Fatal(err)
	}
	if updated.Profiles[0].Label != "Renamed" {
		t.Fatalf("committed profile label = %q", updated.Profiles[0].Label)
	}
}

func TestRuntimeConfigEditorRejectsStaleDigestWithoutChangingStatus(t *testing.T) {
	source := reloadTestConfiguration()
	runtimeProcess, path := newReloadTestRuntime(t, source, &profilePageSender{}, nil)
	editor := runtimeIPCConfigEditorService{runtime: runtimeProcess}
	snapshot, err := editor.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	external := bytes.Replace(source, []byte("label = \"default\"\n"), []byte("label = \"external\"\n"), 1)
	if bytes.Equal(external, source) {
		t.Fatal("test source did not contain the expected profile label")
	}
	if err := os.WriteFile(path, external, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := editor.SetProfileLabel(context.Background(), snapshot.SourceDigest, "default", "local"); !errors.Is(err, ipc.ErrStaleSource) {
		t.Fatalf("stale label error = %v", err)
	}
	current, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(current, external) {
		t.Fatal("stale label update changed the external source")
	}
	status := runtimeProcess.ReloadStatus()
	if status.Active || status.Outcome != ReloadOutcomeReady || status.Reason != ReloadReasonNone {
		t.Fatalf("stale label update changed reload status: %+v", status)
	}
}

func TestRuntimeConfigEditorSeparatesCommittedFileFromRejectedReload(t *testing.T) {
	source := reloadTestConfiguration()
	path := writeReloadConfiguration(t, source)
	initial, err := buildReloadCandidateFromBytes(source, "default")
	if err != nil {
		t.Fatal(err)
	}
	initial.settings.brightness--
	settings := &reloadSettingsApplierStub{err: ErrReloadSettingsPending}
	profileService, err := NewProfileService(ProfileServiceOptions{
		Catalog:          initial.Catalog(),
		Sender:           &profilePageSender{},
		InitialProfileID: initial.CurrentProfileID(),
		initialSnapshot:  &initial,
		settingsApplier:  settings,
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
	snapshot, err := editor.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	result, err := editor.SetProfileLabel(context.Background(), snapshot.SourceDigest, "default", "Committed only")
	if err != nil {
		t.Fatal(err)
	}
	if result.FileCommit != ipc.EditorFileCommitCommitted || result.ReloadOutcome != ipc.EditorReloadRejected || result.Revision != 1 || result.Reason != string(ReloadReasonSettingsPending) {
		t.Fatalf("separate file/reload result = %+v", result)
	}
	committedSource, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	configuration, err := appconfig.Decode(committedSource)
	if err != nil {
		t.Fatal(err)
	}
	if configuration.Profiles[0].Label != "Committed only" || result.SourceDigest != editorSourceDigest(committedSource) {
		t.Fatalf("committed file/result digest mismatch: label=%q result=%+v", configuration.Profiles[0].Label, result)
	}
	active, ok := profileService.CurrentProfile()
	if !ok || active.Label != "default" || profileService.revision() != 1 {
		t.Fatalf("rejected runtime candidate was committed: profile=%+v revision=%d", active, profileService.revision())
	}
}

func TestRuntimeConfigEditorReportsUncertainFileCommitAndReloadsBytes(t *testing.T) {
	source := reloadTestConfiguration()
	runtimeProcess, path := newReloadTestRuntime(t, source, &profilePageSender{}, nil)
	editor := runtimeIPCConfigEditorService{
		runtime: runtimeProcess,
		apply: func(path string, expected configstore.Digest, mutate func([]byte) ([]byte, error)) (configstore.Result, error) {
			result, err := configstore.Apply(path, expected, mutate)
			if err != nil {
				return result, err
			}
			result.Outcome = configstore.OutcomeUncertain
			return result, errors.New("simulated parent-directory sync failure")
		},
	}
	snapshot, err := editor.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	result, err := editor.SetProfileLabel(context.Background(), snapshot.SourceDigest, "default", "Durability uncertain")
	if err != nil {
		t.Fatal(err)
	}
	if result.FileCommit != ipc.EditorFileCommitUncertain || result.ReloadOutcome != ipc.EditorReloadChanged || result.Revision != 2 {
		t.Fatalf("uncertain file/reload result = %+v", result)
	}
	committedSource, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if result.SourceDigest != editorSourceDigest(committedSource) {
		t.Fatal("uncertain commit digest does not match visible source")
	}
	active, ok := runtimeProcess.profileService.CurrentProfile()
	if !ok || active.Label != "Durability uncertain" {
		t.Fatalf("exact committed bytes were not reloaded: %+v", active)
	}
}

func TestRuntimeConfigEditorPositionLabelReadCommitAndNoOp(t *testing.T) {
	source := reloadTestConfiguration()
	runtimeProcess, path := newReloadTestRuntime(t, source, &profilePageSender{}, nil)
	runtimeProcess.automaticReload = make(chan struct{}, 1)
	editor := runtimeIPCConfigEditorService{runtime: runtimeProcess}
	snapshot, err := editor.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	positions, err := editor.ListPositions(context.Background(), snapshot.SourceDigest, "default")
	if err != nil {
		t.Fatal(err)
	}
	if positions.SourceDigest != snapshot.SourceDigest || positions.ProfileID != "default" || len(positions.Positions) != appconfig.RequiredPositionCount {
		t.Fatalf("position list = %+v", positions)
	}
	if positions.Positions[0].ID != "0_0" || positions.Positions[0].Position != "0_0" {
		t.Fatalf("first position reference = %+v", positions.Positions[0])
	}
	positionLabel, err := editor.GetPositionLabel(context.Background(), snapshot.SourceDigest, "default", "0_0")
	if err != nil || positionLabel.SourceDigest != snapshot.SourceDigest || positionLabel.ProfileID != "default" || positionLabel.PositionID != "0_0" || positionLabel.Label != "default 0" {
		t.Fatalf("position label = %+v, err = %v", positionLabel, err)
	}

	before, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	runtimeProcess.reload.mu.Lock()
	runtimeProcess.reload.outcome = ReloadOutcomeRejected
	runtimeProcess.reload.reason = ReloadReasonCandidateRejected
	runtimeProcess.reload.mu.Unlock()
	noOp, err := editor.SetPositionLabel(context.Background(), snapshot.SourceDigest, "default", "0_0", "default 0")
	if err != nil {
		t.Fatal(err)
	}
	if noOp.FileCommit != ipc.EditorFileCommitUnchanged || noOp.ReloadOutcome != ipc.EditorReloadUnchanged || noOp.Revision != snapshot.Revision || noOp.Effect != string(reloadEffectUnchanged) || noOp.Reason != string(ReloadReasonNone) {
		t.Fatalf("position label no-op = %+v", noOp)
	}
	afterNoOp, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !os.SameFile(before, afterNoOp) {
		t.Fatal("position label no-op replaced the source inode")
	}
	if status := runtimeProcess.ReloadStatus(); status.Active || status.Outcome != ReloadOutcomeRejected || status.Reason != ReloadReasonCandidateRejected {
		t.Fatalf("position label no-op changed reload status: %+v", status)
	}

	committed, err := editor.SetPositionLabel(context.Background(), snapshot.SourceDigest, "default", "0_0", "Clock online")
	if err != nil {
		t.Fatal(err)
	}
	if committed.FileCommit != ipc.EditorFileCommitCommitted || committed.ReloadOutcome != ipc.EditorReloadChanged || committed.Revision != 2 || committed.SourceDigest == snapshot.SourceDigest {
		t.Fatalf("position label commit = %+v", committed)
	}
	committedSource, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if committed.SourceDigest != editorSourceDigest(committedSource) {
		t.Fatal("position label result digest does not match the committed source")
	}
	active, ok := runtimeProcess.profileService.CurrentProfile()
	if !ok || active.Values[0].Label != "Clock online" {
		t.Fatalf("position label was not reloaded into the active profile: %+v", active)
	}
	if _, err := editor.GetPositionLabel(context.Background(), snapshot.SourceDigest, "default", "0_0"); !errors.Is(err, ipc.ErrStaleSource) {
		t.Fatalf("old digest position read error = %v", err)
	}
}

func TestRuntimeConfigEditorLabelSettersReloadAfterPostCommitCancellation(t *testing.T) {
	tests := []struct {
		name  string
		set   func(runtimeIPCConfigEditorService, context.Context, string) (ipc.ConfigEditorMutationResult, error)
		check func(*RuntimeProfileService) bool
	}{
		{
			name: "profile label",
			set: func(editor runtimeIPCConfigEditorService, ctx context.Context, digest string) (ipc.ConfigEditorMutationResult, error) {
				return editor.SetProfileLabel(ctx, digest, "default", "Committed after cancellation")
			},
			check: func(service *RuntimeProfileService) bool {
				active, ok := service.CurrentProfile()
				return ok && active.Label == "Committed after cancellation"
			},
		},
		{
			name: "position label",
			set: func(editor runtimeIPCConfigEditorService, ctx context.Context, digest string) (ipc.ConfigEditorMutationResult, error) {
				return editor.SetPositionLabel(ctx, digest, "default", "0_0", "Position committed after cancellation")
			},
			check: func(service *RuntimeProfileService) bool {
				active, ok := service.CurrentProfile()
				return ok && active.Values[0].Label == "Position committed after cancellation"
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			source := reloadTestConfiguration()
			runtimeProcess, path := newReloadTestRuntime(t, source, &profilePageSender{}, nil)
			editor := runtimeIPCConfigEditorService{runtime: runtimeProcess}
			snapshot, err := editor.Snapshot(context.Background())
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			editor.apply = func(path string, expected configstore.Digest, mutate func([]byte) ([]byte, error)) (configstore.Result, error) {
				result, err := configstore.Apply(path, expected, mutate)
				if result.Outcome == configstore.OutcomeCommitted || result.Outcome == configstore.OutcomeUncertain {
					cancel()
				}
				return result, err
			}

			result, err := test.set(editor, ctx, snapshot.SourceDigest)
			if err != nil {
				t.Fatalf("mutation returned after commit cancellation: %v", err)
			}
			if ctx.Err() != context.Canceled {
				t.Fatalf("mutation context error = %v, want cancellation", ctx.Err())
			}
			if result.FileCommit != ipc.EditorFileCommitCommitted || result.ReloadOutcome != ipc.EditorReloadChanged || result.Revision != 2 {
				t.Fatalf("post-commit cancellation result = %+v", result)
			}
			if !test.check(runtimeProcess.profileService) {
				t.Fatal("committed configuration was not applied after caller cancellation")
			}
			committedSource, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if result.SourceDigest != editorSourceDigest(committedSource) {
				t.Fatal("post-commit cancellation result digest does not match committed source")
			}
		})
	}
}

func TestRuntimeConfigEditorReloadsAfterIPCDisconnectFollowingCommit(t *testing.T) {
	const testTimeout = 5 * time.Second

	source := reloadTestConfiguration()
	runtimeProcess, path := newReloadTestRuntime(t, source, &profilePageSender{}, nil)
	editor := runtimeIPCConfigEditorService{runtime: runtimeProcess}
	snapshot, err := editor.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}

	commitReached := make(chan configstore.Result, 1)
	releaseReload := make(chan struct{})
	var releaseOnce sync.Once
	release := func() { releaseOnce.Do(func() { close(releaseReload) }) }
	defer release()
	editor.apply = func(path string, expected configstore.Digest, mutate func([]byte) ([]byte, error)) (configstore.Result, error) {
		result, err := configstore.Apply(path, expected, mutate)
		if result.Outcome == configstore.OutcomeCommitted || result.Outcome == configstore.OutcomeUncertain {
			commitReached <- result
			<-releaseReload
		}
		return result, err
	}

	observed := &runtimeIPCEditorContextObserver{
		ConfigEditorService: editor,
		positionSetContext:  make(chan context.Context, 1),
		positionSetDone:     make(chan runtimeIPCEditorSetResult, 1),
	}
	socketPath := filepath.Join(runtimeSocketTestDirectory(t), "e.sock")
	server, err := ipc.NewServer(ipc.ServerConfig{
		SocketPath:          socketPath,
		InstanceID:          "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
		ConfigEditorService: observed,
		PeerVerifier:        func(net.Conn) error { return nil },
	})
	if err != nil {
		t.Fatal(err)
	}
	serverContext, cancelServer := context.WithCancel(context.Background())
	serverDone := make(chan error, 1)
	var connection net.Conn
	defer func() {
		release()
		if connection != nil {
			_ = connection.Close()
		}
		cancelServer()
		select {
		case err := <-serverDone:
			if err != nil {
				t.Errorf("IPC server returned error: %v", err)
			}
		case <-time.After(testTimeout):
			t.Error("IPC server did not stop")
		}
	}()
	go func() { serverDone <- server.Serve(serverContext) }()
	select {
	case <-server.ServingReady():
	case <-time.After(testTimeout):
		t.Fatal("IPC server did not start")
	}

	connection, err = net.Dial("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	request, err := ipc.EncodeRequest(ipc.Request{
		ProtocolVersion: ipc.ProtocolVersion,
		RequestID:       "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
		Method:          ipc.MethodConfigEditorPositionLabelSet,
		InstanceID:      "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
		ExpectedDigest:  snapshot.SourceDigest,
		ProfileID:       "default",
		PositionID:      "0_0",
		Label:           "Committed after socket close",
	})
	if err != nil {
		t.Fatal(err)
	}
	for len(request) > 0 {
		written, writeErr := connection.Write(request)
		if writeErr != nil {
			t.Fatal(writeErr)
		}
		if written == 0 {
			t.Fatal("IPC request write made no progress")
		}
		request = request[written:]
	}

	var mutationContext context.Context
	select {
	case mutationContext = <-observed.positionSetContext:
	case <-time.After(testTimeout):
		t.Fatal("position-label mutation did not reach the runtime")
	}
	select {
	case result := <-commitReached:
		if result.Outcome != configstore.OutcomeCommitted {
			t.Fatalf("file commit outcome = %v, want committed", result.Outcome)
		}
	case <-time.After(testTimeout):
		t.Fatal("position-label mutation did not commit")
	}
	if err := connection.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-mutationContext.Done():
	case <-time.After(testTimeout):
		t.Fatal("socket close did not cancel the runtime mutation context")
	}
	release()

	var mutationResult runtimeIPCEditorSetResult
	select {
	case mutationResult = <-observed.positionSetDone:
	case <-time.After(testTimeout):
		t.Fatal("runtime mutation did not finish after socket disconnect")
	}
	if mutationResult.err != nil {
		t.Fatalf("mutation returned error after committed disconnect: %v", mutationResult.err)
	}
	if mutationResult.result.FileCommit != ipc.EditorFileCommitCommitted || mutationResult.result.ReloadOutcome != ipc.EditorReloadChanged || mutationResult.result.Revision != 2 {
		t.Fatalf("post-disconnect mutation result = %+v", mutationResult.result)
	}
	active, ok := runtimeProcess.profileService.CurrentProfile()
	if !ok || active.Values[0].Label != "Committed after socket close" {
		t.Fatalf("committed source was not reloaded after disconnect: %+v", active)
	}
	committedSource, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if mutationResult.result.SourceDigest != editorSourceDigest(committedSource) {
		t.Fatal("post-disconnect mutation digest does not match committed source")
	}
}

type runtimeIPCEditorSetResult struct {
	result ipc.ConfigEditorPositionLabelResult
	err    error
}

type runtimeIPCEditorContextObserver struct {
	ipc.ConfigEditorService
	positionSetContext chan context.Context
	positionSetDone    chan runtimeIPCEditorSetResult
}

func (observer *runtimeIPCEditorContextObserver) SetPositionLabel(ctx context.Context, digest, profileID, positionID, label string) (ipc.ConfigEditorPositionLabelResult, error) {
	observer.positionSetContext <- ctx
	result, err := observer.ConfigEditorService.SetPositionLabel(ctx, digest, profileID, positionID, label)
	observer.positionSetDone <- runtimeIPCEditorSetResult{result: result, err: err}
	return result, err
}
