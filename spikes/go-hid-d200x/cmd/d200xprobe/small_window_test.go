package main

import (
	"bytes"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	d200x "hidhogg/spikes/go-hid-d200x"
)

func TestSmallWindowWithoutParametersRemainsEmpty(t *testing.T) {
	frame, err := buildActionFrame("small-window-refresh", optionalString{})
	if err != nil {
		t.Fatal(err)
	}
	if frame.Command != d200x.CommandSmallWindowRefresh || len(frame.Payload) != 0 {
		t.Fatalf("frame = %#v, want empty 0x0006 frame", frame)
	}
}

func TestSmallWindowPresetsUseOneClockSnapshotAndExactPayloads(t *testing.T) {
	snapshot := time.Date(2026, time.August, 29, 20, 18, 53, 0, time.FixedZone("fixture", 10*60*60))
	fixtures := []struct {
		name    string
		payload string
		calls   int
	}{
		{name: "metrics", payload: "0|1|1|20:18:53|1|24H|", calls: 1},
		{name: "dial-time", payload: "1|0|0|20:18:53|0|24H|", calls: 1},
		{name: "background", payload: "2|", calls: 0},
		{name: "date-time-weekday", payload: "200|0|0|20:18:53|0|24H|2026/08/29 Sat", calls: 1},
		{name: "time-weekday", payload: "201|0|0|20:18:53|0|24H|Sat", calls: 1},
		{name: "date-time", payload: "202|0|0|20:18:53|0|24H|2026/08/29", calls: 1},
		{name: "time", payload: "203|0|0|20:18:53|0|24H|", calls: 1},
	}

	for _, fixture := range fixtures {
		clockCalls := 0
		now := func() time.Time {
			clockCalls++
			return snapshot.Add(time.Duration(clockCalls-1) * 24 * time.Hour)
		}
		var frame d200x.Frame
		var err error
		if fixture.name == "metrics" {
			frame, _, err = buildActionFrameWithClockAndRandom(
				"small-window-refresh",
				optionalString{present: true, value: fixture.name},
				now,
				func() (int, error) { return 1, nil },
			)
		} else {
			frame, err = buildActionFrameWithClock(
				"small-window-refresh",
				optionalString{present: true, value: fixture.name},
				now,
			)
		}
		if err != nil {
			t.Fatalf("%s: %v", fixture.name, err)
		}
		if string(frame.Payload) != fixture.payload {
			t.Fatalf("%s payload=%q, want %q", fixture.name, frame.Payload, fixture.payload)
		}
		if clockCalls != fixture.calls {
			t.Fatalf("%s clock calls=%d, want %d", fixture.name, clockCalls, fixture.calls)
		}
	}
}

func TestMetricsPresetUsesIndependentValuesAndOneSourceCallPerMetric(t *testing.T) {
	clockCalls := 0
	sourceValues := []int{7, 42, 98}
	sourceCalls := 0
	frame, metrics, err := buildActionFrameWithClockAndRandom(
		"small-window-refresh",
		optionalString{present: true, value: "metrics"},
		func() time.Time {
			clockCalls++
			return time.Date(2026, time.August, 29, 20, 18, 53, 0, time.UTC)
		},
		func() (int, error) {
			sourceCalls++
			value := sourceValues[sourceCalls-1]
			return value, nil
		},
	)
	if err != nil {
		t.Fatal(err)
	}
	if clockCalls != 1 || sourceCalls != 3 {
		t.Fatalf("clock calls=%d source calls=%d", clockCalls, sourceCalls)
	}
	if metrics == nil || *metrics != (syntheticMetricValues{cpu: 7, ram: 42, gpu: 98}) {
		t.Fatalf("metrics=%#v", metrics)
	}
	if frame.Command != d200x.CommandSmallWindowRefresh || string(frame.Payload) != "0|7|42|20:18:53|98|24H|" {
		t.Fatalf("frame=%#v", frame)
	}
}

func TestMetricsPresetRejectsOutOfRangeSourceValuesWithoutRetry(t *testing.T) {
	for _, invalid := range []int{0, -1, syntheticMetricMaximum + 1, 1000} {
		sourceCalls := 0
		frame, metrics, err := buildActionFrameWithClockAndRandom(
			"small-window-refresh",
			optionalString{present: true, value: "metrics"},
			func() time.Time { return time.Date(2026, time.August, 29, 20, 18, 53, 0, time.UTC) },
			func() (int, error) {
				sourceCalls++
				return invalid, nil
			},
		)
		if err == nil || frame.Command != 0 || len(frame.Payload) != 0 || metrics != nil {
			t.Fatalf("invalid=%d frame=%#v metrics=%#v err=%v", invalid, frame, metrics, err)
		}
		if sourceCalls != 1 {
			t.Fatalf("invalid=%d source calls=%d, want one", invalid, sourceCalls)
		}
	}
}

func TestMetricsPresetReportsRandomnessFailureWithoutLeakingCause(t *testing.T) {
	failure := errors.New("entropy fixture must not be printed")
	frame, metrics, err := buildActionFrameWithClockAndRandom(
		"small-window-refresh",
		optionalString{present: true, value: "metrics"},
		func() time.Time { return time.Date(2026, time.August, 29, 20, 18, 53, 0, time.UTC) },
		func() (int, error) { return 0, failure },
	)
	if err == nil || !errors.Is(err, failure) || frame.Command != 0 || len(frame.Payload) != 0 || metrics != nil {
		t.Fatalf("frame=%#v metrics=%#v err=%v", frame, metrics, err)
	}
	if err.Error() != "metrics randomness source failed" {
		t.Fatalf("error=%q", err)
	}
}

func TestMetricsPresetStopsImmediatelyWhenLaterSourceCallFails(t *testing.T) {
	for _, failAt := range []int{2, 3} {
		t.Run("source-call-"+strconv.Itoa(failAt), func(t *testing.T) {
			sourceCalls := 0
			frame, metrics, err := buildActionFrameWithClockAndRandom(
				"small-window-refresh",
				optionalString{present: true, value: "metrics"},
				func() time.Time { return time.Date(2026, time.August, 29, 20, 18, 53, 0, time.UTC) },
				func() (int, error) {
					sourceCalls++
					if sourceCalls == failAt {
						return 0, errors.New("injected source failure")
					}
					return sourceCalls * 10, nil
				},
			)
			if err == nil || frame.Command != 0 || len(frame.Payload) != 0 || metrics != nil {
				t.Fatalf("frame=%#v metrics=%#v err=%v", frame, metrics, err)
			}
			if sourceCalls != failAt {
				t.Fatalf("source calls=%d, want immediate stop at %d", sourceCalls, failAt)
			}
		})
	}
}

func TestMetricsPresetRandomFailureStopsBeforeHIDAndOutput(t *testing.T) {
	factory := newProbeFactory()
	var stdout, stderr bytes.Buffer
	if code := runWithClockAndRandom(
		[]string{"--action", "small-window-refresh", "--parameters", "metrics"},
		factory,
		&stdout,
		&stderr,
		nil,
		func() time.Time { return time.Date(2026, time.August, 29, 20, 18, 53, 0, time.UTC) },
		func() (int, error) { return 0, errors.New("random source unavailable") },
	); code != 2 {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if factory.enumerateCalls != 0 || factory.openCalls != 0 || len(factory.transport.writes) != 0 {
		t.Fatalf("random failure touched HID: enumerate=%d open=%d writes=%d", factory.enumerateCalls, factory.openCalls, len(factory.transport.writes))
	}
	if stdout.Len() != 0 || strings.Contains(stderr.String(), "random source unavailable") {
		t.Fatalf("stdout=%q stderr=%q", stdout.String(), stderr.String())
	}
}

func TestMetricsPresetLaterRandomFailureStopsBeforeHID(t *testing.T) {
	for _, failAt := range []int{2, 3} {
		t.Run("source-call-"+strconv.Itoa(failAt), func(t *testing.T) {
			factory := newProbeFactory()
			var stdout, stderr bytes.Buffer
			sourceCalls := 0
			if code := runWithClockAndRandom(
				[]string{"--action", "small-window-refresh", "--parameters", "metrics"},
				factory,
				&stdout,
				&stderr,
				nil,
				func() time.Time { return time.Date(2026, time.August, 29, 20, 18, 53, 0, time.UTC) },
				func() (int, error) {
					sourceCalls++
					if sourceCalls == failAt {
						return 0, errors.New("later source failure")
					}
					return sourceCalls * 10, nil
				},
			); code != 2 {
				t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
			}
			if sourceCalls != failAt {
				t.Fatalf("source calls=%d, want immediate stop at %d", sourceCalls, failAt)
			}
			if factory.enumerateCalls != 0 || factory.openCalls != 0 || len(factory.transport.writes) != 0 {
				t.Fatalf("random failure touched HID: enumerate=%d open=%d writes=%d", factory.enumerateCalls, factory.openCalls, len(factory.transport.writes))
			}
			if stdout.Len() != 0 || strings.Contains(stderr.String(), "later source failure") {
				t.Fatalf("stdout=%q stderr=%q", stdout.String(), stderr.String())
			}
		})
	}
}

func TestMetricsPresetReportsValuesOnlyAfterOneSuccessfulWrite(t *testing.T) {
	factory := newProbeFactory()
	var stdout, stderr bytes.Buffer
	if code := runWithClockAndRandom(
		[]string{"--action", "small-window-refresh", "--parameters", "metrics"},
		factory,
		&stdout,
		&stderr,
		nil,
		func() time.Time { return time.Date(2026, time.August, 29, 20, 18, 53, 0, time.UTC) },
		sequenceMetricSource([]int{7, 42, 98}),
	); code != 0 {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if factory.enumerateCalls != 1 || factory.openCalls != 1 || len(factory.transport.writes) != 1 {
		t.Fatalf("enumerate=%d open=%d writes=%d", factory.enumerateCalls, factory.openCalls, len(factory.transport.writes))
	}
	frame, err := d200x.DecodeFrame(factory.transport.writes)
	if err != nil {
		t.Fatal(err)
	}
	if string(frame.Payload) != "0|7|42|20:18:53|98|24H|" {
		t.Fatalf("payload=%q", frame.Payload)
	}
	output := stdout.String()
	if !strings.Contains(output, "synthetic metrics cpu=7 ram=42 gpu=98") || len(output) > 256 {
		t.Fatalf("output=%q length=%d", output, len(output))
	}
}

func TestMetricsPresetDoesNotReportValuesAfterFailedWrite(t *testing.T) {
	factory := newProbeFactory()
	factory.transport.writeErr = errors.New("transport unavailable")
	var stdout, stderr bytes.Buffer
	if code := runWithClockAndRandom(
		[]string{"--action", "small-window-refresh", "--parameters", "metrics"},
		factory,
		&stdout,
		&stderr,
		nil,
		func() time.Time { return time.Date(2026, time.August, 29, 20, 18, 53, 0, time.UTC) },
		sequenceMetricSource([]int{7, 42, 98}),
	); code != 1 {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if len(factory.transport.writes) != 1 || stdout.Len() != 0 {
		t.Fatalf("writes=%d stdout=%q stderr=%q", len(factory.transport.writes), stdout.String(), stderr.String())
	}
}

func sequenceMetricSource(values []int) metricRandomSource {
	index := 0
	return func() (int, error) {
		value := values[index]
		index++
		return value, nil
	}
}

func TestSmallWindowPresetRefusalsDoNotEnumerate(t *testing.T) {
	for _, preset := range []string{"Metrics", " metrics", "metrics ", "02", "unknown"} {
		factory := newProbeFactory()
		var stdout, stderr bytes.Buffer
		if code := runWithClock(
			[]string{"--action", "small-window-refresh", "--parameters", preset},
			factory,
			&stdout,
			&stderr,
			nil,
			func() time.Time { return time.Date(2026, time.August, 29, 20, 18, 53, 0, time.UTC) },
		); code != 2 {
			t.Fatalf("preset %q code=%d stdout=%q stderr=%q", preset, code, stdout.String(), stderr.String())
		}
		if factory.enumerateCalls != 0 || factory.openCalls != 0 || len(factory.transport.writes) != 0 {
			t.Fatalf("preset %q touched HID: enumerate=%d open=%d writes=%d", preset, factory.enumerateCalls, factory.openCalls, len(factory.transport.writes))
		}
	}
}

func TestSmallWindowPresetSendsOneLogicalFrame(t *testing.T) {
	factory := newProbeFactory()
	var stdout, stderr bytes.Buffer
	if code := runWithClock(
		[]string{"--action", "small-window-refresh", "--parameters", "date-time-weekday"},
		factory,
		&stdout,
		&stderr,
		nil,
		func() time.Time { return time.Date(2026, time.August, 29, 20, 18, 53, 0, time.UTC) },
	); code != 0 {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if factory.enumerateCalls != 1 || factory.openCalls != 1 || len(factory.transport.writes) != 1 {
		t.Fatalf("enumerate=%d open=%d writes=%d", factory.enumerateCalls, factory.openCalls, len(factory.transport.writes))
	}
	frame, err := d200x.DecodeFrame(factory.transport.writes)
	if err != nil {
		t.Fatal(err)
	}
	if frame.Command != d200x.CommandSmallWindowRefresh || string(frame.Payload) != "200|0|0|20:18:53|0|24H|2026/08/29 Sat" {
		t.Fatalf("frame=%#v", frame)
	}
}

func TestSmallWindowCapturedPayloadsRemainExact(t *testing.T) {
	fixtures := []struct {
		name    string
		json    string
		payload string
	}{
		{
			name:    "system statistics",
			json:    `{"mode":0,"cpu":24,"ram":80,"time":"20:18:53","gpu":17,"format":"12H"}`,
			payload: "0|24|80|20:18:53|17|12H|",
		},
		{
			name:    "dial time",
			json:    `{"mode":1,"cpu":17,"ram":74,"time":"20:35:47","gpu":20,"format":"12H"}`,
			payload: "1|17|74|20:35:47|20|12H|",
		},
		{
			name:    "background",
			json:    `{"mode":2}`,
			payload: "2|",
		},
		{
			name:    "date time weekday",
			json:    `{"mode":200,"cpu":16,"ram":72,"time":"20:50:26","gpu":7,"format":"12H","date":"2026/08/12","weekday":"Wed"}`,
			payload: "200|16|72|20:50:26|7|12H|2026/08/12 Wed",
		},
		{
			name:    "time weekday",
			json:    `{"mode":201,"cpu":16,"ram":73,"time":"20:48:02","gpu":7,"format":"12H","weekday":"Wed"}`,
			payload: "201|16|73|20:48:02|7|12H|Wed",
		},
		{
			name:    "time date",
			json:    `{"mode":202,"cpu":15,"ram":71,"time":"20:42:41","gpu":8,"format":"12H","date":"2026/08/12"}`,
			payload: "202|15|71|20:42:41|8|12H|2026/08/12",
		},
		{
			name:    "time",
			json:    `{"mode":203,"cpu":15,"ram":72,"time":"20:39:23","gpu":8,"format":"12H"}`,
			payload: "203|15|72|20:39:23|8|12H|",
		},
	}

	for _, fixture := range fixtures {
		frame, err := buildActionFrame("small-window-refresh", optionalString{present: true, value: fixture.json})
		if err != nil {
			t.Fatalf("%s: %v", fixture.name, err)
		}
		if frame.Command != d200x.CommandSmallWindowRefresh || string(frame.Payload) != fixture.payload {
			t.Fatalf("%s: command=0x%04x payload=%q, want %q", fixture.name, uint16(frame.Command), frame.Payload, fixture.payload)
		}
	}
}

func TestSmallWindowParametersRejectStrictShapeAndValues(t *testing.T) {
	validCommon := `"cpu":16,"ram":72,"time":"20:50:26","gpu":7,"format":"12H"`
	invalid := []struct {
		name string
		json string
	}{
		{"missing mode", `{` + validCommon + `}`},
		{"unsupported mode", `{"mode":3,` + validCommon + `}`},
		{"legacy knob mode", `{"mode":100,` + validCommon + `}`},
		{"background with context", `{"mode":2,` + validCommon + `}`},
		{"system statistics with date", `{"mode":0,` + validCommon + `,"date":"2026/08/12"}`},
		{"system statistics with weekday", `{"mode":0,` + validCommon + `,"weekday":"Wed"}`},
		{"date time weekday missing date", `{"mode":200,` + validCommon + `,"weekday":"Wed"}`},
		{"date time weekday missing weekday", `{"mode":200,` + validCommon + `,"date":"2026/08/12"}`},
		{"time weekday with date", `{"mode":201,` + validCommon + `,"date":"2026/08/12","weekday":"Wed"}`},
		{"time date with weekday", `{"mode":202,` + validCommon + `,"date":"2026/08/12","weekday":"Wed"}`},
		{"time with date", `{"mode":203,` + validCommon + `,"date":"2026/08/12"}`},
		{"unknown field", `{"mode":0,` + validCommon + `,"secret":"do-not-echo"}`},
		{"duplicate field", `{"mode":0,"mode":0,` + validCommon + `}`},
		{"trailing JSON", `{"mode":0,` + validCommon + `}{}`},
		{"mode string", `{"mode":"0",` + validCommon + `}`},
		{"cpu float", `{"mode":0,"cpu":16.0,"ram":72,"time":"20:50:26","gpu":7,"format":"12H"}`},
		{"ram string", `{"mode":0,"cpu":16,"ram":"72","time":"20:50:26","gpu":7,"format":"12H"}`},
		{"gpu boolean", `{"mode":0,"cpu":16,"ram":72,"time":"20:50:26","gpu":true,"format":"12H"}`},
		{"null metric", `{"mode":0,"cpu":null,"ram":72,"time":"20:50:26","gpu":7,"format":"12H"}`},
		{"time wrong shape", `{"mode":0,"cpu":16,"ram":72,"time":205026,"gpu":7,"format":"12H"}`},
		{"format wrong value", `{"mode":0,"cpu":16,"ram":72,"time":"20:50:26","gpu":7,"format":"12h"}`},
		{"date wrong shape", `{"mode":202,` + validCommon + `,"date":"2026-08-12"}`},
		{"weekday wrong shape", `{"mode":201,` + validCommon + `,"weekday":"Wednesday"}`},
	}

	for _, testCase := range invalid {
		if _, err := parseSmallWindowParameters(testCase.json); err == nil {
			t.Errorf("%s accepted", testCase.name)
		}
	}
}

func TestSmallWindowParameterValidationBoundaries(t *testing.T) {
	valid := func(cpu, ram, gpu int, clock, date, weekday string) string {
		return `{"mode":200,"cpu":` + itoaForTest(cpu) + `,"ram":` + itoaForTest(ram) + `,"time":"23:59:59","gpu":` + itoaForTest(gpu) + `,"format":"` + clock + `","date":"` + date + `","weekday":"` + weekday + `"}`
	}
	validCases := []string{
		valid(0, 0, 0, "12H", "0000/01/01", "Aaa"),
		valid(100, 100, 100, "24H", "9999/12/31", "zzz"),
	}
	for _, raw := range validCases {
		if _, err := parseSmallWindowParameters(raw); err != nil {
			t.Errorf("valid boundary rejected: %v", err)
		}
	}

	invalidCases := []string{
		valid(-1, 0, 0, "12H", "2026/08/12", "Wed"),
		valid(0, 101, 0, "12H", "2026/08/12", "Wed"),
		valid(0, 0, 101, "12H", "2026/08/12", "Wed"),
		valid(0, 0, 0, "12H", "2026/00/12", "Wed"),
		valid(0, 0, 0, "12H", "2026/13/12", "Wed"),
		valid(0, 0, 0, "12H", "2026/08/00", "Wed"),
		valid(0, 0, 0, "12H", "2026/08/32", "Wed"),
		valid(0, 0, 0, "12H", "2026/08/12", "W3d"),
		valid(0, 0, 0, "12H", "2026/08/12", "Wed!"),
		valid(0, 0, 0, "12H", "2026/08/12", "Wéé"),
		`{"mode":200,"cpu":0,"ram":0,"time":"24:00:00","gpu":0,"format":"12H","date":"2026/08/12","weekday":"Wed"}`,
		`{"mode":200,"cpu":0,"ram":0,"time":"23:60:00","gpu":0,"format":"12H","date":"2026/08/12","weekday":"Wed"}`,
		`{"mode":200,"cpu":0,"ram":0,"time":"23:59:60","gpu":0,"format":"12H","date":"2026/08/12","weekday":"Wed"}`,
	}
	for _, raw := range invalidCases {
		if _, err := parseSmallWindowParameters(raw); err == nil {
			t.Errorf("invalid boundary accepted: %s", raw)
		}
	}
}

func TestSmallWindowInvalidJSONDoesNotEchoParametersOrEnumerate(t *testing.T) {
	raw := `{"mode":0,"cpu":null,"ram":72,"time":"20:50:26","gpu":7,"format":"12H","secret":"redacted-value"}`
	factory := newProbeFactory()
	var stdout, stderr bytes.Buffer
	if code := run([]string{"--action", "small-window-refresh", "--parameters", raw}, factory, &stdout, &stderr); code != 2 {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if factory.enumerateCalls != 0 || factory.openCalls != 0 || len(factory.transport.writes) != 0 {
		t.Fatalf("invalid parameters touched HID: enumerate=%d open=%d writes=%d", factory.enumerateCalls, factory.openCalls, len(factory.transport.writes))
	}
	if strings.Contains(stdout.String()+stderr.String(), raw) || strings.Contains(stdout.String()+stderr.String(), "redacted-value") {
		t.Fatalf("invalid parameters were echoed: stdout=%q stderr=%q", stdout.String(), stderr.String())
	}
}

func TestSmallWindowParameterizedActionSendsOneLogicalFrame(t *testing.T) {
	raw := `{"mode":202,"cpu":15,"ram":71,"time":"20:42:41","gpu":8,"format":"12H","date":"2026/08/12"}`
	factory := newProbeFactory()
	var stdout, stderr bytes.Buffer
	if code := run([]string{"--action", "small-window-refresh", "--parameters", raw}, factory, &stdout, &stderr); code != 0 {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
	}
	if factory.enumerateCalls != 1 || factory.openCalls != 1 || len(factory.transport.writes) != 1 {
		t.Fatalf("enumerate=%d open=%d writes=%d", factory.enumerateCalls, factory.openCalls, len(factory.transport.writes))
	}
	frame, err := d200x.DecodeFrame(factory.transport.writes)
	if err != nil {
		t.Fatal(err)
	}
	if frame.Command != d200x.CommandSmallWindowRefresh || string(frame.Payload) != "202|15|71|20:42:41|8|12H|2026/08/12" {
		t.Fatalf("frame=%#v", frame)
	}
}

func itoaForTest(value int) string {
	return strconv.Itoa(value)
}
