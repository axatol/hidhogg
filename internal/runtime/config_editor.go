package runtime

import (
	"context"
	"encoding/hex"
	"errors"
	"io"
	"os"

	appconfig "hidhogg/internal/config"
	"hidhogg/internal/configedit"
	"hidhogg/internal/configstore"
	"hidhogg/internal/ipc"
)

type runtimeIPCConfigEditorService struct {
	runtime *Runtime
	apply   func(string, configstore.Digest, func([]byte) ([]byte, error)) (configstore.Result, error)
}

func (service runtimeIPCConfigEditorService) Snapshot(ctx context.Context) (ipc.ConfigEditorSnapshot, error) {
	source, err := service.readSource(ctx)
	if err != nil {
		return ipc.ConfigEditorSnapshot{}, err
	}
	configuration, err := appconfig.Decode(source)
	if err != nil {
		return ipc.ConfigEditorSnapshot{}, ipc.ErrEditInvalid
	}
	profileService, ok := service.runtime.ProfileService().(*RuntimeProfileService)
	if !ok || profileService == nil {
		return ipc.ConfigEditorSnapshot{}, ipc.ErrShuttingDown
	}
	effective := profileService.effective.Load()
	if effective == nil || effective.revision == 0 || effective.currentID == "" {
		return ipc.ConfigEditorSnapshot{}, ipc.ErrShuttingDown
	}
	profileIDs := make([]string, 0, len(configuration.Profiles))
	containsCurrent := false
	for _, configuredProfile := range configuration.Profiles {
		profileIDs = append(profileIDs, configuredProfile.ID)
		containsCurrent = containsCurrent || configuredProfile.ID == effective.currentID
	}
	if !containsCurrent {
		return ipc.ConfigEditorSnapshot{}, ipc.ErrStaleSource
	}
	return ipc.ConfigEditorSnapshot{
		SourceDigest:     editorSourceDigest(source),
		Revision:         effective.revision,
		DefaultProfileID: configuration.DefaultProfileID,
		CurrentProfileID: effective.currentID,
		ProfileIDs:       profileIDs,
	}, nil
}

func (service runtimeIPCConfigEditorService) GetProfile(ctx context.Context, sourceDigest, profileID string) (ipc.ConfigEditorProfile, error) {
	source, err := service.readSource(ctx)
	if err != nil {
		return ipc.ConfigEditorProfile{}, err
	}
	if !validEditorDigest(sourceDigest) {
		return ipc.ConfigEditorProfile{}, ipc.ErrEditInvalid
	}
	actualDigest := editorSourceDigest(source)
	if actualDigest != sourceDigest {
		return ipc.ConfigEditorProfile{}, ipc.ErrStaleSource
	}
	configuration, err := appconfig.Decode(source)
	if err != nil {
		return ipc.ConfigEditorProfile{}, ipc.ErrEditInvalid
	}
	for _, configuredProfile := range configuration.Profiles {
		if configuredProfile.ID == profileID {
			return ipc.ConfigEditorProfile{
				SourceDigest: actualDigest,
				ProfileID:    configuredProfile.ID,
				Label:        configuredProfile.Label,
			}, nil
		}
	}
	return ipc.ConfigEditorProfile{}, ipc.ErrEditInvalid
}

func (service runtimeIPCConfigEditorService) ListPositions(ctx context.Context, sourceDigest, profileID string) (ipc.ConfigEditorPositions, error) {
	source, err := service.readSource(ctx)
	if err != nil {
		return ipc.ConfigEditorPositions{}, err
	}
	if !validEditorDigest(sourceDigest) {
		return ipc.ConfigEditorPositions{}, ipc.ErrEditInvalid
	}
	actualDigest := editorSourceDigest(source)
	if actualDigest != sourceDigest {
		return ipc.ConfigEditorPositions{}, ipc.ErrStaleSource
	}
	positions, err := configedit.ListProfilePositions(source, profileID)
	if err != nil {
		return ipc.ConfigEditorPositions{}, ipc.ErrEditInvalid
	}
	result := ipc.ConfigEditorPositions{
		SourceDigest: actualDigest,
		ProfileID:    profileID,
		Positions:    make([]ipc.ConfigEditorPosition, len(positions)),
	}
	for index, position := range positions {
		result.Positions[index] = ipc.ConfigEditorPosition{ID: position.ID, Position: position.Position}
	}
	return result, nil
}

func (service runtimeIPCConfigEditorService) GetPositionLabel(ctx context.Context, sourceDigest, profileID, positionID string) (ipc.ConfigEditorPositionLabel, error) {
	source, err := service.readSource(ctx)
	if err != nil {
		return ipc.ConfigEditorPositionLabel{}, err
	}
	if !validEditorDigest(sourceDigest) {
		return ipc.ConfigEditorPositionLabel{}, ipc.ErrEditInvalid
	}
	actualDigest := editorSourceDigest(source)
	if actualDigest != sourceDigest {
		return ipc.ConfigEditorPositionLabel{}, ipc.ErrStaleSource
	}
	label, err := configedit.GetPositionLabel(source, profileID, positionID)
	if err != nil {
		return ipc.ConfigEditorPositionLabel{}, ipc.ErrEditInvalid
	}
	return ipc.ConfigEditorPositionLabel{
		SourceDigest: actualDigest,
		ProfileID:    profileID,
		PositionID:   positionID,
		Label:        label,
	}, nil
}

func (service runtimeIPCConfigEditorService) SetProfileLabel(ctx context.Context, expectedDigest, profileID, label string) (ipc.ConfigEditorLabelResult, error) {
	result, err := service.mutateProfile(ctx, expectedDigest, func(source []byte, _ string) ([]byte, error) {
		return configedit.UpdateProfileLabel(source, profileID, label)
	})
	return ipc.ConfigEditorLabelResult(result), err
}

func (service runtimeIPCConfigEditorService) SetPositionLabel(ctx context.Context, expectedDigest, profileID, positionID, label string) (ipc.ConfigEditorPositionLabelResult, error) {
	result, err := service.mutateProfile(ctx, expectedDigest, func(source []byte, _ string) ([]byte, error) {
		return configedit.UpdatePositionLabel(source, profileID, positionID, label)
	})
	return ipc.ConfigEditorPositionLabelResult(result), err
}

func (service runtimeIPCConfigEditorService) CreateProfile(ctx context.Context, expectedDigest, sourceID, newID, label string) (ipc.ConfigEditorMutationResult, error) {
	return service.mutateProfile(ctx, expectedDigest, func(source []byte, currentID string) ([]byte, error) {
		if sourceID == "" {
			sourceID = currentID
		}
		return configedit.CloneProfile(source, sourceID, newID, label)
	})
}

func (service runtimeIPCConfigEditorService) DeleteProfile(ctx context.Context, expectedDigest, targetID string) (ipc.ConfigEditorMutationResult, error) {
	return service.mutateProfile(ctx, expectedDigest, func(source []byte, currentID string) ([]byte, error) {
		return configedit.DeleteProfile(source, targetID, currentID)
	})
}

func (service runtimeIPCConfigEditorService) mutateProfile(ctx context.Context, expectedDigest string, mutate func([]byte, string) ([]byte, error)) (ipc.ConfigEditorMutationResult, error) {
	runtime := service.runtime
	if runtime == nil {
		return ipc.ConfigEditorMutationResult{}, ipc.ErrShuttingDown
	}
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return ipc.ConfigEditorMutationResult{}, err
	}
	digest, err := parseEditorDigest(expectedDigest)
	if err != nil {
		return ipc.ConfigEditorMutationResult{}, ipc.ErrEditInvalid
	}
	if err := runtime.reload.begin(); err != nil {
		return ipc.ConfigEditorMutationResult{}, reloadAdmissionIPCError(err)
	}
	finished := false
	defer func() {
		if !finished {
			runtime.finishEditorAdmissionPreservingStatus()
		}
	}()

	path, err := service.configurationPath()
	if err != nil {
		return ipc.ConfigEditorMutationResult{}, err
	}
	profileService, ok := runtime.ProfileService().(*RuntimeProfileService)
	if !ok || profileService == nil {
		return ipc.ConfigEditorMutationResult{}, ipc.ErrShuttingDown
	}
	initialRevision := profileService.revision()
	if initialRevision == 0 {
		return ipc.ConfigEditorMutationResult{}, ipc.ErrShuttingDown
	}
	apply := service.apply
	if apply == nil {
		apply = configstore.Apply
	}
	var fileResult configstore.Result
	var storeErr error
	var contextErr error
	buildCandidate := func(currentID string) (reloadCandidate, error) {
		if err := ctx.Err(); err != nil {
			contextErr = err
			return reloadCandidate{}, err
		}
		fileResult, storeErr = apply(path, digest, func(source []byte) ([]byte, error) {
			if err := ctx.Err(); err != nil {
				contextErr = err
				return nil, err
			}
			return mutate(source, currentID)
		})
		switch fileResult.Outcome {
		case configstore.OutcomeUnchanged:
			if storeErr != nil {
				return reloadCandidate{}, storeErr
			}
			current := profileService.effective.Load()
			if current == nil {
				return reloadCandidate{}, ErrReloadClosed
			}
			return current.candidate(), nil
		case configstore.OutcomeCommitted, configstore.OutcomeUncertain:
			return buildReloadCandidateFromBytes(fileResult.Bytes, currentID)
		default:
			if contextErr != nil {
				return reloadCandidate{}, contextErr
			}
			if storeErr != nil {
				return reloadCandidate{}, storeErr
			}
			return reloadCandidate{}, ipc.ErrFileCommitFailed
		}
	}

	reloadResult, reloadErr := runtime.reloadStartedWithCandidateBuilderAndStatus(
		context.WithoutCancel(ctx),
		buildCandidate,
		func() bool {
			return fileResult.Outcome != configstore.OutcomeCommitted && fileResult.Outcome != configstore.OutcomeUncertain
		},
	)
	finished = true
	if fileResult.Outcome != configstore.OutcomeCommitted && fileResult.Outcome != configstore.OutcomeUncertain {
		if contextErr != nil {
			return ipc.ConfigEditorMutationResult{}, contextErr
		}
		if storeErr != nil {
			return ipc.ConfigEditorMutationResult{}, configEditorStoreError(storeErr)
		}
		if reloadErr != nil {
			return ipc.ConfigEditorMutationResult{}, classifyReloadIPCError(reloadErr)
		}
	}

	fileCommit := ipc.EditorFileCommitUnchanged
	sourceDigest := expectedDigest
	switch fileResult.Outcome {
	case configstore.OutcomeUnchanged:
		fileCommit = ipc.EditorFileCommitUnchanged
	case configstore.OutcomeCommitted:
		fileCommit = ipc.EditorFileCommitCommitted
		sourceDigest = editorDigestString(fileResult.Digest)
	case configstore.OutcomeUncertain:
		fileCommit = ipc.EditorFileCommitUncertain
		sourceDigest = editorDigestString(fileResult.Digest)
	default:
		return ipc.ConfigEditorMutationResult{}, ipc.ErrFileCommitFailed
	}
	revision := reloadResult.Revision
	if revision == 0 {
		revision = initialRevision
	}
	effect := reloadResult.Effect
	if effect == "" {
		effect = reloadEffectUnchanged
	}
	reason := configEditorReloadReason(reloadErr)
	return ipc.ConfigEditorMutationResult{
		SourceDigest:  sourceDigest,
		FileCommit:    fileCommit,
		ReloadOutcome: configEditorReloadOutcome(reloadResult, reloadErr),
		Revision:      revision,
		Effect:        string(effect),
		Reason:        string(reason),
	}, nil
}

func (service runtimeIPCConfigEditorService) readSource(ctx context.Context) ([]byte, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	path, err := service.configurationPath()
	if err != nil {
		return nil, err
	}
	before, err := os.Lstat(path)
	if err != nil {
		return nil, errors.New("configuration source is unavailable")
	}
	if !before.Mode().IsRegular() {
		return nil, errors.New("configuration source is unavailable")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, errors.New("configuration source is unavailable")
	}
	opened, err := file.Stat()
	if err != nil || !opened.Mode().IsRegular() || !os.SameFile(before, opened) {
		_ = file.Close()
		return nil, errors.New("configuration source is unavailable")
	}
	source, readErr := io.ReadAll(file)
	closeErr := file.Close()
	if readErr != nil || closeErr != nil {
		return nil, errors.New("configuration source is unavailable")
	}
	return source, nil
}

func (service runtimeIPCConfigEditorService) configurationPath() (string, error) {
	if service.runtime == nil {
		return "", ipc.ErrShuttingDown
	}
	service.runtime.mu.Lock()
	defer service.runtime.mu.Unlock()
	if service.runtime.closed {
		return "", ipc.ErrShuttingDown
	}
	if service.runtime.config.ConfigPath == "" {
		return "", errors.New("configuration source is unavailable")
	}
	return service.runtime.config.ConfigPath, nil
}

func editorSourceDigest(source []byte) string {
	return editorDigestString(configstore.Hash(source))
}

func editorDigestString(digest configstore.Digest) string {
	return hex.EncodeToString(digest[:])
}

func validEditorDigest(value string) bool {
	if len(value) != len(configstore.Digest{})*2 {
		return false
	}
	decoded, err := hex.DecodeString(value)
	return err == nil && hex.EncodeToString(decoded) == value
}

func parseEditorDigest(value string) (configstore.Digest, error) {
	var digest configstore.Digest
	if !validEditorDigest(value) {
		return digest, errors.New("source digest is invalid")
	}
	decoded, _ := hex.DecodeString(value)
	copy(digest[:], decoded)
	return digest, nil
}

func configEditorStoreError(err error) error {
	code, ok := configstore.ErrorCodeOf(err)
	if !ok {
		return ipc.ErrFileCommitFailed
	}
	switch code {
	case configstore.ErrorCodeStale:
		return ipc.ErrStaleSource
	case configstore.ErrorCodeMutation, configstore.ErrorCodeInvalidConfiguration:
		return ipc.ErrEditInvalid
	default:
		return ipc.ErrFileCommitFailed
	}
}

func configEditorReloadOutcome(result ReloadResult, err error) string {
	switch {
	case err == nil && result.Changed:
		return ipc.EditorReloadChanged
	case err == nil:
		return ipc.EditorReloadUnchanged
	case errors.Is(err, ErrProfileStateUncertain):
		return ipc.EditorReloadUncertain
	case errors.Is(err, ErrReloadClosed), errors.Is(err, ErrProfileServiceClosed), errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return ipc.EditorReloadNotAttempted
	default:
		return ipc.EditorReloadRejected
	}
}

func configEditorReloadReason(err error) ReloadReason {
	switch {
	case err == nil:
		return ReloadReasonNone
	case errors.Is(err, ErrProfileStateUncertain):
		return ReloadReasonDeviceWriteFailed
	case errors.Is(err, ErrReloadSettingsPending):
		return ReloadReasonSettingsPending
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return ReloadReasonCanceled
	case errors.Is(err, ErrReloadClosed), errors.Is(err, ErrProfileServiceClosed):
		return ReloadReasonClosed
	default:
		return ReloadReasonCandidateRejected
	}
}

func reloadAdmissionIPCError(err error) error {
	switch {
	case errors.Is(err, ErrReloadBusy):
		return ipc.ErrBusy
	case errors.Is(err, ErrReloadClosed):
		return ipc.ErrShuttingDown
	default:
		return ipc.ErrBusy
	}
}

func (runtime *Runtime) finishEditorAdmissionPreservingStatus() {
	if runtime.reload.finishPreservingStatus() {
		runtime.signalAutomaticReload()
	}
}
