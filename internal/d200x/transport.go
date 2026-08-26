package d200x

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"

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

type sanitizedError struct {
	message string
	unwrap  error
}

func (e *sanitizedError) Error() string {
	if e == nil {
		return ""
	}
	return e.message
}

func (e *sanitizedError) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.unwrap
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

func (c Candidate) String() string {
	return c.Summary()
}

func (c Candidate) GoString() string {
	return c.Summary()
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
		hid.WithUsagePage(TargetUsagePage),
		hid.WithUsage(TargetUsage),
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
			return nil, sanitizeHIDError("enumerate D200X HID", err)
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
		hid.WithVendorID(VendorID),
		hid.WithProductID(ProductID),
		hid.WithInterfaceNumber(InterfaceNumber),
		hid.WithUsagePage(TargetUsagePage),
		hid.WithUsage(TargetUsage),
	)
	if err != nil {
		return nil, err
	}
	selected, err := SelectSingle(current)
	if err != nil {
		return nil, err
	}
	if selected.path != candidate.path {
		return nil, &ProtocolError{Kind: ErrorNoMatchingDevice}
	}
	device, err := hid.OpenPath(candidate.path)
	if err != nil {
		return nil, sanitizeHIDError("open matching D200X HID", err)
	}
	return &hidTransport{device: device}, nil
}

type hidTransport struct {
	device *hid.Device
}

func (t *hidTransport) Read(ctx context.Context, report []byte) (int, error) {
	if t == nil || t.device == nil {
		return 0, errors.New("read D200X HID: transport is not initialized")
	}
	n, err := t.device.Read(normalizeTransportContext(ctx), report)
	if err != nil {
		return n, sanitizeHIDError("read D200X HID", err)
	}
	return n, nil
}

func (t *hidTransport) Write(ctx context.Context, report []byte) (int, error) {
	if t == nil || t.device == nil {
		return 0, errors.New("write D200X HID: transport is not initialized")
	}
	n, err := t.device.Write(normalizeTransportContext(ctx), report)
	if err != nil {
		return n, sanitizeHIDError("write D200X HID", err)
	}
	return n, nil
}

func (t *hidTransport) Close() error {
	if t == nil || t.device == nil {
		return nil
	}
	return sanitizeHIDError("close D200X HID", t.device.Close())
}

func SelectSingle(candidates []Candidate) (Candidate, error) {
	eligible := make([]Candidate, 0, len(candidates))
	for _, candidate := range candidates {
		if candidate.IsEligible() {
			eligible = append(eligible, candidate)
		}
	}
	switch len(eligible) {
	case 0:
		if len(candidates) == 1 {
			return Candidate{}, &ProtocolError{Kind: ErrorIneligibleDevice}
		}
		return Candidate{}, &ProtocolError{Kind: ErrorNoMatchingDevice}
	case 1:
		return eligible[0], nil
	default:
		return Candidate{}, &ProtocolError{
			Kind:  ErrorAmbiguousDeviceSelection,
			Count: len(eligible),
		}
	}
}

func sanitizeHIDError(operation string, err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, context.Canceled) {
		return &sanitizedError{message: operation + ": context canceled", unwrap: context.Canceled}
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return &sanitizedError{message: operation + ": deadline exceeded", unwrap: context.DeadlineExceeded}
	}
	return &sanitizedError{message: operation + " failed"}
}

func sanitizeAdapterError(operation string, err error) error {
	if err == nil {
		return nil
	}
	var protocolErr *ProtocolError
	if errors.As(err, &protocolErr) {
		return protocolErr
	}
	if errors.Is(err, context.Canceled) {
		return &sanitizedError{message: operation + ": context canceled", unwrap: context.Canceled}
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return &sanitizedError{message: operation + ": deadline exceeded", unwrap: context.DeadlineExceeded}
	}
	return &sanitizedError{message: operation + " failed"}
}

func normalizeTransportContext(ctx context.Context) context.Context {
	if ctx == nil {
		return context.Background()
	}
	return ctx
}
