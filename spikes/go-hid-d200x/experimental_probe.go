package d200x

import "context"

type ExperimentalProbeWriter struct {
	session *Session
}

func NewExperimentalProbeWriter(session *Session) ExperimentalProbeWriter {
	return ExperimentalProbeWriter{session: session}
}

func (w ExperimentalProbeWriter) SendExperimentalFrame(ctx context.Context, frame Frame) error {
	if w.session == nil {
		return &ProtocolError{Kind: ErrorSessionClosed}
	}
	if !isExperimentalProbeCommand(frame.Command) {
		return &ProtocolError{Kind: ErrorUnsafeOutboundCommand, Command: frame.Command}
	}
	return w.session.sendFrame(ctx, frame)
}

func isExperimentalProbeCommand(command Command) bool {
	switch command {
	case CommandCompleteDisplayUpload,
		CommandEnableInputStream,
		CommandObservedHostLock,
		CommandSmallWindowRefresh,
		CommandBrightness,
		CommandLabelStyle,
		CommandPartialDisplayUpload,
		CommandLockScreen,
		CommandUnlockScreen,
		CommandInputEvent,
		CommandAcknowledgement,
		CommandDeviceInformation:
		return true
	default:
		return false
	}
}
