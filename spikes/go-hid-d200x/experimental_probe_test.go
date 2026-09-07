package d200x

import (
	"context"
	"errors"
	"testing"
)

func TestExperimentalProbeWriterHasClosedKnownCommandAllowlist(t *testing.T) {
	candidate := NewCandidate("probe", VendorID, ProductID, InterfaceNumber)
	transport := &fakeTransport{}
	factory := &fakeFactory{transports: map[string]Transport{candidate.path: transport}}
	session := NewSession(factory)
	if err := session.Replace(context.Background(), candidate); err != nil {
		t.Fatal(err)
	}
	writer := NewExperimentalProbeWriter(session)
	for _, command := range []Command{
		CommandCompleteDisplayUpload, CommandEnableInputStream, CommandObservedHostLock,
		CommandSmallWindowRefresh, CommandBrightness, CommandLabelStyle,
		CommandPartialDisplayUpload, CommandLockScreen, CommandUnlockScreen,
		CommandInputEvent, CommandAcknowledgement, CommandDeviceInformation,
	} {
		if err := writer.SendExperimentalFrame(context.Background(), NewFrame(command, nil)); err != nil {
			t.Fatalf("command %s: %v", command, err)
		}
	}
	writesBeforeUnknown := len(transport.writes)
	err := writer.SendExperimentalFrame(context.Background(), NewFrame(Command(0xbeef), nil))
	var protocolErr *ProtocolError
	if !errors.As(err, &protocolErr) || protocolErr.Kind != ErrorUnsafeOutboundCommand {
		t.Fatalf("unknown command error = %#v", err)
	}
	if len(transport.writes) != writesBeforeUnknown {
		t.Fatal("unknown experimental command wrote a report")
	}
}

func TestProductionLikeSessionRefusalRemainsUnchanged(t *testing.T) {
	candidate := NewCandidate("probe", VendorID, ProductID, InterfaceNumber)
	transport := &fakeTransport{}
	factory := &fakeFactory{transports: map[string]Transport{candidate.path: transport}}
	session := NewSession(factory)
	if err := session.Replace(context.Background(), candidate); err != nil {
		t.Fatal(err)
	}
	err := session.SendFrame(context.Background(), NewFrame(CommandObservedHostLock, nil))
	var protocolErr *ProtocolError
	if !errors.As(err, &protocolErr) || protocolErr.Kind != ErrorUnsafeOutboundCommand {
		t.Fatalf("production-like refusal error = %#v", err)
	}
	if len(transport.writes) != 0 {
		t.Fatal("production-like session wrote experimental command")
	}
}
