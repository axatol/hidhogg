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

func TestHIDOpenPathFailureKeepsSafeCodeAcrossSanitizers(t *testing.T) {
	raw := errors.New("hidraw=/private/hidraw/device serial=private-serial")
	failure := NewHIDOpenPathFailure(raw)
	if failure == nil {
		t.Fatal("non-nil cause produced a nil failure")
	}
	want := HIDOpenPathFailureCode + ": open selected D200X HID path failed"
	if failure.Error() != want {
		t.Fatalf("HID open path failure = %q, want %q", failure, want)
	}
	if errors.Unwrap(failure) != nil || errors.Is(failure, raw) {
		t.Fatalf("HID open path failure exposed its cause through Unwrap: %v", failure)
	}
	for _, rendered := range []string{
		fmt.Sprintf("%v", failure),
		fmt.Sprintf("%+v", failure),
		fmt.Sprintf("%#v", failure),
	} {
		if strings.Contains(rendered, "/private/hidraw/device") || strings.Contains(rendered, "private-serial") {
			t.Fatalf("formatted HID open path failure leaked its cause: %q", rendered)
		}
	}

	for name, sanitize := range map[string]func(string, error) error{
		"hid":     sanitizeHIDError,
		"adapter": sanitizeAdapterError,
	} {
		t.Run(name, func(t *testing.T) {
			sanitized := sanitize("open D200X HID", failure)
			var preserved *HIDOpenPathFailure
			if !errors.As(sanitized, &preserved) || sanitized.Error() != want {
				t.Fatalf("sanitized failure = %v, want preserved code %q", sanitized, want)
			}
		})
	}
	if NewHIDOpenPathFailure(nil) != nil {
		t.Fatal("nil cause produced a HID open path failure")
	}
}

func TestHIDOpenPathFailurePreservesContextClassification(t *testing.T) {
	for _, test := range []struct {
		cause error
		want  error
	}{
		{cause: context.Canceled, want: context.Canceled},
		{cause: context.DeadlineExceeded, want: context.DeadlineExceeded},
	} {
		failure := NewHIDOpenPathFailure(test.cause)
		if !errors.Is(failure, test.want) || !strings.HasPrefix(failure.Error(), HIDOpenPathFailureCode+": ") {
			t.Fatalf("HID open path failure = %v, want safe code and %v classification", failure, test.want)
		}
	}
}
