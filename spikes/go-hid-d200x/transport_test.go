package d200x

import (
	"sync"
	"testing"

	"github.com/go-ctap/hid"
)

type fakeNativeWatcher struct {
	snapshot hid.Snapshot
	events   chan hid.DeviceEvent
	once     sync.Once
}

func (w *fakeNativeWatcher) Snapshot() hid.Snapshot {
	return w.snapshot
}

func (w *fakeNativeWatcher) Listen() <-chan hid.DeviceEvent {
	return w.events
}

func (w *fakeNativeWatcher) Close() error {
	w.once.Do(func() { close(w.events) })
	return nil
}

func TestHIDWatcherFiltersSnapshotAndEventsWithoutSerialMetadata(t *testing.T) {
	matching := &hid.DeviceInfo{Path: "matching", VendorID: VendorID, ProductID: ProductID, InterfaceNbr: InterfaceNumber, UsagePage: TargetUsagePage, Usage: TargetUsage, SerialNbr: "not-exposed"}
	keyboard := &hid.DeviceInfo{Path: "keyboard", VendorID: VendorID, ProductID: ProductID, InterfaceNbr: InterfaceNumber, UsagePage: 0x0001, Usage: 0x0006}
	other := &hid.DeviceInfo{Path: "other", VendorID: 0x1234, ProductID: ProductID, InterfaceNbr: InterfaceNumber}
	native := &fakeNativeWatcher{
		snapshot: hid.Snapshot{Devices: []hid.DeviceSnapshot{
			{DeviceInfo: matching},
			{DeviceInfo: keyboard},
			{DeviceInfo: other},
		}},
		events: make(chan hid.DeviceEvent, 3),
	}
	watcher := newHIDWatcher(native)

	snapshot := watcher.Snapshot()
	if len(snapshot) != 1 || !snapshot[0].IsEligible() || snapshot[0].path != matching.Path {
		t.Fatalf("filtered snapshot = %#v", snapshot)
	}
	native.events <- hid.DeviceEvent{Type: hid.DeviceEventConnected, DeviceInfo: matching}
	native.events <- hid.DeviceEvent{Type: hid.DeviceEventConnected, DeviceInfo: keyboard}
	native.events <- hid.DeviceEvent{Type: hid.DeviceEventConnected, DeviceInfo: other}
	if err := native.Close(); err != nil {
		t.Fatal(err)
	}

	event, ok := <-watcher.Listen()
	if !ok || event.Type != ConnectionConnected || event.Candidate.path != matching.Path {
		t.Fatalf("filtered event = %#v, ok=%v", event, ok)
	}
	for extra := range watcher.Listen() {
		t.Fatalf("unexpected nonmatching event = %#v", extra)
	}
	if err := watcher.Close(); err != nil {
		t.Fatal(err)
	}
	if _, ok := <-watcher.Listen(); ok {
		t.Fatal("watcher channel remained open")
	}
}
