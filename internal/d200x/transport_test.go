package d200x

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/go-ctap/hid"
)

func matchingDeviceInfo() *hid.DeviceInfo {
	return &hid.DeviceInfo{
		Path:           "/private/hidraw/d200x-serial-private",
		VendorID:       VendorID,
		ProductID:      ProductID,
		SerialNbr:      "serial-private",
		ProductStr:     "D200X",
		UsagePage:      TargetUsagePage,
		Usage:          TargetUsage,
		InterfaceNbr:   InterfaceNumber,
		InstanceID:     "instance-private",
		ParentDeviceID: "parent-private",
	}
}

func TestCandidateSelectionRequiresExactInterfaceAndUsage(t *testing.T) {
	base := matchingDeviceInfo()
	candidate, ok := CandidateFromDeviceInfo(base)
	if !ok || !candidate.IsEligible() {
		t.Fatalf("matching device was rejected: %+v ok=%t", candidate, ok)
	}
	for name, mutate := range map[string]func(*hid.DeviceInfo){
		"vendor":     func(info *hid.DeviceInfo) { info.VendorID++ },
		"product":    func(info *hid.DeviceInfo) { info.ProductID++ },
		"interface":  func(info *hid.DeviceInfo) { info.InterfaceNbr++ },
		"usage page": func(info *hid.DeviceInfo) { info.UsagePage++ },
		"usage":      func(info *hid.DeviceInfo) { info.Usage++ },
		"path":       func(info *hid.DeviceInfo) { info.Path = "" },
	} {
		t.Run(name, func(t *testing.T) {
			info := *base
			mutate(&info)
			if _, ok := CandidateFromDeviceInfo(&info); ok {
				t.Fatal("nonmatching HID interface was accepted")
			}
		})
	}

	if _, err := SelectSingle(nil); !hasProtocolKind(err, ErrorNoMatchingDevice) {
		t.Fatalf("zero candidates error = %v", err)
	}
	if _, err := SelectSingle([]Candidate{NewCandidate("/private/path", VendorID, ProductID, InterfaceNumber+1)}); !hasProtocolKind(err, ErrorIneligibleDevice) {
		t.Fatalf("one ineligible candidate error = %v", err)
	}
	selected, err := SelectSingle([]Candidate{candidate})
	if err != nil || selected.PathHash != candidate.PathHash {
		t.Fatalf("one eligible candidate: selected=%+v err=%v", selected, err)
	}
	second := NewCandidate("/private/another-path", VendorID, ProductID, InterfaceNumber)
	if _, err := SelectSingle([]Candidate{candidate, second}); !hasProtocolKind(err, ErrorAmbiguousDeviceSelection) {
		t.Fatalf("ambiguous candidates error = %v", err)
	}
}

func TestCandidateFormattingNeverIncludesRawIdentity(t *testing.T) {
	info := matchingDeviceInfo()
	candidate, ok := CandidateFromDeviceInfo(info)
	if !ok {
		t.Fatal("matching device was rejected")
	}
	for format, rendered := range map[string]string{
		"string":  candidate.String(),
		"default": fmt.Sprintf("%v", candidate),
		"verbose": fmt.Sprintf("%+v", candidate),
		"go":      fmt.Sprintf("%#v", candidate),
	} {
		for _, raw := range []string{info.Path, info.SerialNbr, info.InstanceID, info.ParentDeviceID} {
			if strings.Contains(rendered, raw) {
				t.Errorf("%s formatting leaked %q: %s", format, raw, rendered)
			}
		}
	}
	if candidate.PathHash == info.Path || candidate.InstanceHash == info.InstanceID || candidate.ParentHash == info.ParentDeviceID {
		t.Fatal("candidate identity fields were not opaque")
	}
}

func TestSanitizedErrorsDoNotExposeOrUnwrapUpstreamCause(t *testing.T) {
	raw := errors.New("hidraw=/private/path serial=private-secret")
	for name, sanitize := range map[string]func(string, error) error{
		"hid":     sanitizeHIDError,
		"adapter": sanitizeAdapterError,
	} {
		t.Run(name, func(t *testing.T) {
			err := sanitize("operation", raw)
			if err == nil || strings.Contains(err.Error(), raw.Error()) || errors.Is(err, raw) {
				t.Fatalf("sanitized error leaked upstream cause: %v", err)
			}
			if errors.Unwrap(err) != nil {
				t.Fatalf("sanitized error unwrap = %v, want nil", errors.Unwrap(err))
			}
			for _, rendered := range []string{fmt.Sprintf("%v", err), fmt.Sprintf("%+v", err)} {
				if strings.Contains(rendered, "private-secret") || strings.Contains(rendered, "/private/path") {
					t.Fatalf("formatted sanitized error leaked identity: %s", rendered)
				}
			}
		})
	}
	contextErr := sanitizeAdapterError("read", context.Canceled)
	if !errors.Is(contextErr, context.Canceled) || strings.Contains(contextErr.Error(), "context") && !strings.Contains(contextErr.Error(), "canceled") {
		t.Fatalf("context cancellation was not retained safely: %v", contextErr)
	}
}
