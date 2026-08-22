package d200x

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sync"

	"github.com/go-ctap/hid"
)

// Candidate deliberately omits serial-number data. The path is retained only
// inside the process so that a selected interface can be opened again.
type Candidate struct {
	VendorID        uint16
	ProductID       uint16
	InterfaceNumber int
	UsagePage       uint16
	Usage           uint16
	InstanceHash    string
	ParentHash      string
	PathHash        string
	Product         string
	path            string
}

func NewCandidate(path string, vendorID, productID uint16, interfaceNumber int) Candidate {
	return Candidate{
		VendorID:        vendorID,
		ProductID:       productID,
		InterfaceNumber: interfaceNumber,
		UsagePage:       TargetUsagePage,
		Usage:           TargetUsage,
		PathHash:        opaqueIdentifierHash(path),
		path:            path,
	}
}

func (c Candidate) IsD200X() bool {
	return c.VendorID == VendorID && c.ProductID == ProductID
}

func (c Candidate) IsEligible() bool {
	return c.IsD200X() &&
		c.InterfaceNumber == InterfaceNumber &&
		c.UsagePage == TargetUsagePage &&
		c.Usage == TargetUsage &&
		c.path != ""
}

func (c Candidate) Summary() string {
	return fmt.Sprintf(
		"vid=0x%04x pid=0x%04x interface=%d usage-page=0x%04x usage=0x%04x instance-hash=%s parent-hash=%s path-hash=%s",
		c.VendorID,
		c.ProductID,
		c.InterfaceNumber,
		c.UsagePage,
		c.Usage,
		c.InstanceHash,
		c.ParentHash,
		c.PathHash,
	)
}

func CandidateFromDeviceInfo(info *hid.DeviceInfo) (Candidate, bool) {
	if info == nil ||
		info.VendorID != VendorID ||
		info.ProductID != ProductID ||
		info.InterfaceNbr != InterfaceNumber ||
		info.UsagePage != TargetUsagePage ||
		info.Usage != TargetUsage ||
		info.Path == "" {
		return Candidate{}, false
	}
	return Candidate{
		VendorID:        info.VendorID,
		ProductID:       info.ProductID,
		InterfaceNumber: info.InterfaceNbr,
		UsagePage:       info.UsagePage,
		Usage:           info.Usage,
		InstanceHash:    opaqueIdentifierHash(info.InstanceID),
		ParentHash:      opaqueIdentifierHash(info.ParentDeviceID),
		PathHash:        opaqueIdentifierHash(info.Path),
		Product:         info.ProductStr,
		path:            info.Path,
	}, true
}

func opaqueIdentifierHash(value string) string {
	if value == "" {
		return "none"
	}
	digest := sha256.Sum256([]byte(value))
	return hex.EncodeToString(digest[:6])
}

type Transport interface {
	Read(context.Context, []byte) (int, error)
	Write(context.Context, []byte) (int, error)
	Close() error
}

type TransportFactory interface {
	Enumerate(context.Context) ([]Candidate, error)
	Open(context.Context, Candidate) (Transport, error)
}

type HIDFactory struct{}

func NewHIDFactory() HIDFactory {
	return HIDFactory{}
}

func (HIDFactory) Enumerate(ctx context.Context) ([]Candidate, error) {
	return enumerateCandidates(ctx,
		hid.WithVendorID(VendorID),
		hid.WithProductID(ProductID),
		hid.WithInterfaceNumber(InterfaceNumber),
	)
}

func enumerateCandidates(ctx context.Context, options ...hid.EnumerateOption) ([]Candidate, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	var candidates []Candidate
	for info, err := range hid.Enumerate(options...) {
		if err != nil {
			return nil, fmt.Errorf("enumerate D200X HID: %w", err)
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if candidate, ok := CandidateFromDeviceInfo(info); ok {
			candidates = append(candidates, candidate)
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return candidates, nil
}

func (HIDFactory) Open(ctx context.Context, candidate Candidate) (Transport, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if !candidate.IsEligible() {
		return nil, &ProtocolError{Kind: ErrorIneligibleDevice}
	}
	current, err := enumerateCandidates(ctx,
		hid.WithPath(candidate.path),
		hid.WithVendorID(VendorID),
		hid.WithProductID(ProductID),
		hid.WithInterfaceNumber(InterfaceNumber),
	)
	if err != nil {
		return nil, err
	}
	if len(current) == 0 {
		return nil, &ProtocolError{Kind: ErrorNoMatchingDevice}
	}
	if len(current) > 1 {
		return nil, &ProtocolError{Kind: ErrorAmbiguousDeviceSelection, Count: len(current)}
	}
	device, err := hid.OpenPath(candidate.path)
	if err != nil {
		return nil, fmt.Errorf("open matching D200X HID: %w", err)
	}
	return &hidTransport{device: device}, nil
}

type ConnectionEventType string

const (
	ConnectionConnected    ConnectionEventType = "connected"
	ConnectionDisconnected ConnectionEventType = "disconnected"
)

type ConnectionEvent struct {
	Type      ConnectionEventType
	Candidate Candidate
}

type Watcher interface {
	Snapshot() []Candidate
	Listen() <-chan ConnectionEvent
	Close() error
}

// Watch filters go-ctap/hid events before they leave the adapter. The public
// watcher therefore cannot expose serial-number metadata or interface 1.
func (HIDFactory) Watch() (Watcher, error) {
	native, err := hid.Watch()
	if err != nil {
		return nil, err
	}
	return newHIDWatcher(native), nil
}

func newHIDWatcher(native hid.Watcher) *hidWatcher {
	initial := make([]Candidate, 0, len(native.Snapshot().Devices))
	for _, snapshot := range native.Snapshot().Devices {
		if candidate, ok := CandidateFromDeviceInfo(snapshot.DeviceInfo); ok {
			initial = append(initial, candidate)
		}
	}
	watcher := &hidWatcher{
		native:  native,
		initial: initial,
		events:  make(chan ConnectionEvent),
		done:    make(chan struct{}),
		stopped: make(chan struct{}),
	}
	go watcher.forward()
	return watcher
}

type hidWatcher struct {
	native  hid.Watcher
	initial []Candidate
	events  chan ConnectionEvent
	done    chan struct{}
	stopped chan struct{}

	closeOnce sync.Once
	closeErr  error
}

func (w *hidWatcher) Snapshot() []Candidate {
	return append([]Candidate(nil), w.initial...)
}

func (w *hidWatcher) Listen() <-chan ConnectionEvent {
	return w.events
}

func (w *hidWatcher) Close() error {
	w.closeOnce.Do(func() {
		close(w.done)
		w.closeErr = w.native.Close()
		<-w.stopped
	})
	return w.closeErr
}

func (w *hidWatcher) forward() {
	defer close(w.stopped)
	defer close(w.events)
	for event := range w.native.Listen() {
		candidate, ok := CandidateFromDeviceInfo(event.DeviceInfo)
		if !ok {
			continue
		}
		var eventType ConnectionEventType
		switch event.Type {
		case hid.DeviceEventConnected:
			eventType = ConnectionConnected
		case hid.DeviceEventDisconnected:
			eventType = ConnectionDisconnected
		default:
			continue
		}
		select {
		case w.events <- ConnectionEvent{Type: eventType, Candidate: candidate}:
		case <-w.done:
			return
		}
	}
}

type hidTransport struct {
	device *hid.Device
}

func (t *hidTransport) Read(ctx context.Context, report []byte) (int, error) {
	return t.device.Read(ctx, report)
}

func (t *hidTransport) Write(ctx context.Context, report []byte) (int, error) {
	return t.device.Write(ctx, report)
}

func (t *hidTransport) Close() error {
	return t.device.Close()
}

func SelectSingle(candidates []Candidate) (Candidate, error) {
	switch len(candidates) {
	case 0:
		return Candidate{}, &ProtocolError{Kind: ErrorNoMatchingDevice}
	case 1:
		if !candidates[0].IsEligible() {
			return Candidate{}, &ProtocolError{Kind: ErrorIneligibleDevice}
		}
		return candidates[0], nil
	default:
		return Candidate{}, &ProtocolError{
			Kind:  ErrorAmbiguousDeviceSelection,
			Count: len(candidates),
		}
	}
}
