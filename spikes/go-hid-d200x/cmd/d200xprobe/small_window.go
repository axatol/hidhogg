package main

import (
	"bytes"
	cryptorand "crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"strings"
	"time"

	d200x "hidhogg/spikes/go-hid-d200x"
)

const (
	smallWindowModeSystemStatistics = 0
	smallWindowModeDialTime         = 1
	smallWindowModeBackground       = 2
	smallWindowModeDateTimeWeekday  = 200
	smallWindowModeTimeWeekday      = 201
	smallWindowModeTimeDate         = 202
	smallWindowModeTime             = 203
)

var smallWindowPresetModes = map[string]int{
	"metrics":           smallWindowModeSystemStatistics,
	"dial-time":         smallWindowModeDialTime,
	"background":        smallWindowModeBackground,
	"date-time-weekday": smallWindowModeDateTimeWeekday,
	"time-weekday":      smallWindowModeTimeWeekday,
	"date-time":         smallWindowModeTimeDate,
	"time":              smallWindowModeTime,
}

type smallWindowParameters struct {
	mode       int
	cpu        int
	ram        int
	gpu        int
	time       string
	format     string
	date       string
	weekday    string
	hasCPU     bool
	hasRAM     bool
	hasGPU     bool
	hasTime    bool
	hasFormat  bool
	hasDate    bool
	hasWeekday bool
}

const syntheticMetricMaximum = 99

type metricRandomSource func() (int, error)

type syntheticMetricValues struct {
	cpu int
	ram int
	gpu int
}

type metricRandomnessError struct {
	cause error
}

func (errorValue *metricRandomnessError) Error() string {
	return "metrics randomness source failed"
}

func (errorValue *metricRandomnessError) Unwrap() error {
	return errorValue.cause
}

func secureSyntheticMetricValue() (int, error) {
	value, err := cryptorand.Int(cryptorand.Reader, big.NewInt(syntheticMetricMaximum))
	if err != nil {
		return 0, err
	}
	return int(value.Int64()) + 1, nil
}

func readSyntheticMetric(source metricRandomSource) (int, error) {
	if source == nil {
		return 0, &metricRandomnessError{cause: errors.New("source is nil")}
	}
	value, err := source()
	if err != nil {
		return 0, &metricRandomnessError{cause: err}
	}
	if value < 1 || value > syntheticMetricMaximum {
		return 0, &metricRandomnessError{cause: fmt.Errorf("value outside 1..%d", syntheticMetricMaximum)}
	}
	return value, nil
}

func generateSyntheticMetricValues(source metricRandomSource) (syntheticMetricValues, error) {
	cpu, err := readSyntheticMetric(source)
	if err != nil {
		return syntheticMetricValues{}, err
	}
	ram, err := readSyntheticMetric(source)
	if err != nil {
		return syntheticMetricValues{}, err
	}
	gpu, err := readSyntheticMetric(source)
	if err != nil {
		return syntheticMetricValues{}, err
	}
	return syntheticMetricValues{cpu: cpu, ram: ram, gpu: gpu}, nil
}

func parseSmallWindowParameters(raw string) (d200x.Frame, error) {
	return parseSmallWindowParametersWithClock(raw, time.Now)
}

func parseSmallWindowParametersWithClock(raw string, now func() time.Time) (d200x.Frame, error) {
	frame, _, err := parseSmallWindowParametersWithClockAndRandom(raw, now, secureSyntheticMetricValue)
	return frame, err
}

func parseSmallWindowParametersWithClockAndRandom(raw string, now func() time.Time, source metricRandomSource) (d200x.Frame, *syntheticMetricValues, error) {
	if mode, ok := smallWindowPresetModes[raw]; ok {
		return buildSmallWindowPresetFrameWithRandom(mode, now, source)
	}
	frame, err := parseSmallWindowJSONParameters(raw)
	return frame, nil, err
}

func buildSmallWindowPresetFrame(mode int, now func() time.Time) (d200x.Frame, error) {
	frame, _, err := buildSmallWindowPresetFrameWithRandom(mode, now, secureSyntheticMetricValue)
	return frame, err
}

func buildSmallWindowPresetFrameWithRandom(mode int, now func() time.Time, source metricRandomSource) (d200x.Frame, *syntheticMetricValues, error) {
	parameters := smallWindowParameters{
		mode: mode,
		cpu:  0,
		ram:  0,
		gpu:  0,
	}
	if mode == smallWindowModeBackground {
		frame, err := encodeSmallWindowFrame(parameters)
		return frame, nil, err
	}
	if now == nil {
		now = time.Now
	}

	snapshot := now()
	parameters.time = snapshot.Format("15:04:05")
	parameters.format = "24H"
	parameters.hasCPU = true
	parameters.hasRAM = true
	parameters.hasGPU = true
	parameters.hasTime = true
	parameters.hasFormat = true
	var metrics *syntheticMetricValues
	if mode == smallWindowModeSystemStatistics {
		values, err := generateSyntheticMetricValues(source)
		if err != nil {
			return d200x.Frame{}, nil, err
		}
		parameters.cpu = values.cpu
		parameters.ram = values.ram
		parameters.gpu = values.gpu
		metrics = &values
	}
	switch mode {
	case smallWindowModeDateTimeWeekday:
		parameters.date = snapshot.Format("2006/01/02")
		parameters.weekday = snapshot.Format("Mon")
		parameters.hasDate = true
		parameters.hasWeekday = true
	case smallWindowModeTimeWeekday:
		parameters.weekday = snapshot.Format("Mon")
		parameters.hasWeekday = true
	case smallWindowModeTimeDate:
		parameters.date = snapshot.Format("2006/01/02")
		parameters.hasDate = true
	}
	frame, err := encodeSmallWindowFrame(parameters)
	return frame, metrics, err
}

func encodeSmallWindowFrame(parameters smallWindowParameters) (d200x.Frame, error) {
	payload, err := encodeSmallWindowPayload(parameters)
	if err != nil {
		return d200x.Frame{}, err
	}
	return d200x.NewFrame(d200x.CommandSmallWindowRefresh, []byte(payload)), nil
}

func parseSmallWindowJSONParameters(raw string) (d200x.Frame, error) {
	parameters, err := decodeSmallWindowParameters(raw)
	if err != nil {
		return d200x.Frame{}, err
	}
	return encodeSmallWindowFrame(parameters)
}

func decodeSmallWindowParameters(raw string) (smallWindowParameters, error) {
	decoder := json.NewDecoder(strings.NewReader(raw))
	fields, err := decodeObjectFields(decoder)
	if err != nil {
		return smallWindowParameters{}, err
	}
	if err := requireJSONEOF(decoder); err != nil {
		return smallWindowParameters{}, err
	}

	parameters := smallWindowParameters{}
	if err := decodeRequiredField(fields, "mode", &parameters.mode); err != nil {
		return smallWindowParameters{}, err
	}

	for name, destination := range map[string]*int{
		"cpu": &parameters.cpu,
		"ram": &parameters.ram,
		"gpu": &parameters.gpu,
	} {
		value, ok := fields[name]
		if !ok {
			continue
		}
		if err := decodeExactJSON(value, destination); err != nil {
			return smallWindowParameters{}, err
		}
		switch name {
		case "cpu":
			parameters.hasCPU = true
		case "ram":
			parameters.hasRAM = true
		case "gpu":
			parameters.hasGPU = true
		}
	}
	for name, destination := range map[string]*string{
		"time":    &parameters.time,
		"format":  &parameters.format,
		"date":    &parameters.date,
		"weekday": &parameters.weekday,
	} {
		value, ok := fields[name]
		if !ok {
			continue
		}
		if err := decodeExactJSON(value, destination); err != nil {
			return smallWindowParameters{}, err
		}
		switch name {
		case "time":
			parameters.hasTime = true
		case "format":
			parameters.hasFormat = true
		case "date":
			parameters.hasDate = true
		case "weekday":
			parameters.hasWeekday = true
		}
	}

	for name := range fields {
		switch name {
		case "mode", "cpu", "ram", "gpu", "time", "format", "date", "weekday":
		default:
			return smallWindowParameters{}, errors.New("small-window parameters contain an unknown field")
		}
	}
	return parameters, validateSmallWindowParameters(parameters)
}

func decodeObjectFields(decoder *json.Decoder) (map[string]json.RawMessage, error) {
	first, err := decoder.Token()
	if err != nil {
		return nil, errors.New("small-window parameters must be a JSON object")
	}
	delimiter, ok := first.(json.Delim)
	if !ok || delimiter != '{' {
		return nil, errors.New("small-window parameters must be a JSON object")
	}

	fields := make(map[string]json.RawMessage)
	for decoder.More() {
		keyToken, err := decoder.Token()
		if err != nil {
			return nil, errors.New("small-window parameters are malformed JSON")
		}
		key, ok := keyToken.(string)
		if !ok {
			return nil, errors.New("small-window parameter names must be strings")
		}
		if _, duplicate := fields[key]; duplicate {
			return nil, errors.New("small-window parameters contain a duplicate field")
		}
		var value json.RawMessage
		if err := decoder.Decode(&value); err != nil {
			return nil, errors.New("small-window parameters are malformed JSON")
		}
		fields[key] = value
	}
	closing, err := decoder.Token()
	if err != nil || closing != json.Delim('}') {
		return nil, errors.New("small-window parameters are malformed JSON")
	}
	return fields, nil
}

func requireJSONEOF(decoder *json.Decoder) error {
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return errors.New("small-window parameters contain trailing JSON")
	}
	return nil
}

func decodeRequiredField(fields map[string]json.RawMessage, name string, destination any) error {
	value, ok := fields[name]
	if !ok {
		return errors.New("small-window parameters are missing a required field")
	}
	if err := decodeExactJSON(value, destination); err != nil {
		return err
	}
	return nil
}

func decodeExactJSON(raw json.RawMessage, destination any) error {
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return errors.New("small-window parameter has a noncanonical JSON type")
	}
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	if err := decoder.Decode(destination); err != nil {
		return errors.New("small-window parameter has a noncanonical JSON type")
	}
	if err := requireJSONEOF(decoder); err != nil {
		return errors.New("small-window parameter has trailing JSON")
	}
	return nil
}

func validateSmallWindowParameters(parameters smallWindowParameters) error {
	switch parameters.mode {
	case smallWindowModeBackground:
		if hasContextFields(parameters) {
			return errors.New("background small-window mode forbids context fields")
		}
		return nil
	case smallWindowModeSystemStatistics,
		smallWindowModeDialTime,
		smallWindowModeDateTimeWeekday,
		smallWindowModeTimeWeekday,
		smallWindowModeTimeDate,
		smallWindowModeTime:
		if err := validateCommonSmallWindowFields(parameters); err != nil {
			return err
		}
		return validateModeSpecificSmallWindowFields(parameters)
	default:
		return errors.New("small-window mode is unsupported")
	}
}

func hasContextFields(parameters smallWindowParameters) bool {
	return parameters.hasCPU || parameters.hasRAM || parameters.hasGPU ||
		parameters.hasTime || parameters.hasFormat || parameters.hasDate || parameters.hasWeekday
}

func validateCommonSmallWindowFields(parameters smallWindowParameters) error {
	if !parameters.hasCPU || !parameters.hasRAM || !parameters.hasGPU ||
		!parameters.hasTime || !parameters.hasFormat {
		return errors.New("small-window mode is missing required context fields")
	}
	for _, metric := range []int{parameters.cpu, parameters.ram, parameters.gpu} {
		if metric < 0 || metric > 100 {
			return errors.New("small-window metrics must be between 0 and 100")
		}
	}
	if !isSmallWindowTime(parameters.time) {
		return errors.New("small-window time must be a valid 24-hour HH:mm:ss value")
	}
	if parameters.format != "12H" && parameters.format != "24H" {
		return errors.New("small-window format must be exactly 12H or 24H")
	}
	return nil
}

func validateModeSpecificSmallWindowFields(parameters smallWindowParameters) error {
	switch parameters.mode {
	case smallWindowModeDateTimeWeekday:
		if !parameters.hasDate || !parameters.hasWeekday {
			return errors.New("date-time-weekday mode requires date and weekday")
		}
		if !isSmallWindowDate(parameters.date) {
			return errors.New("small-window date must be YYYY/MM/DD with bounded month and day")
		}
		if !isSmallWindowWeekday(parameters.weekday) {
			return errors.New("small-window weekday must be exactly three ASCII letters")
		}
	case smallWindowModeTimeWeekday:
		if !parameters.hasWeekday || parameters.hasDate {
			return errors.New("time-weekday mode requires weekday and forbids date")
		}
		if !isSmallWindowWeekday(parameters.weekday) {
			return errors.New("small-window weekday must be exactly three ASCII letters")
		}
	case smallWindowModeTimeDate:
		if !parameters.hasDate || parameters.hasWeekday {
			return errors.New("time-date mode requires date and forbids weekday")
		}
		if !isSmallWindowDate(parameters.date) {
			return errors.New("small-window date must be YYYY/MM/DD with bounded month and day")
		}
	case smallWindowModeSystemStatistics, smallWindowModeDialTime, smallWindowModeTime:
		if parameters.hasDate || parameters.hasWeekday {
			return errors.New("this small-window mode forbids date and weekday")
		}
	}
	return nil
}

func isSmallWindowTime(value string) bool {
	bytes := []byte(value)
	if len(bytes) != 8 || bytes[2] != ':' || bytes[5] != ':' {
		return false
	}
	for index, character := range bytes {
		if index == 2 || index == 5 {
			continue
		}
		if character < '0' || character > '9' {
			return false
		}
	}
	hour := int(bytes[0]-'0')*10 + int(bytes[1]-'0')
	minute := int(bytes[3]-'0')*10 + int(bytes[4]-'0')
	second := int(bytes[6]-'0')*10 + int(bytes[7]-'0')
	return hour <= 23 && minute <= 59 && second <= 59
}

func isSmallWindowDate(value string) bool {
	bytes := []byte(value)
	if len(bytes) != 10 || bytes[4] != '/' || bytes[7] != '/' {
		return false
	}
	for index, character := range bytes {
		if index == 4 || index == 7 {
			continue
		}
		if character < '0' || character > '9' {
			return false
		}
	}
	month := int(bytes[5]-'0')*10 + int(bytes[6]-'0')
	day := int(bytes[8]-'0')*10 + int(bytes[9]-'0')
	return month >= 1 && month <= 12 && day >= 1 && day <= 31
}

func isSmallWindowWeekday(value string) bool {
	bytes := []byte(value)
	if len(bytes) != 3 {
		return false
	}
	for _, character := range bytes {
		if !((character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z')) {
			return false
		}
	}
	return true
}

func encodeSmallWindowPayload(parameters smallWindowParameters) (string, error) {
	if err := validateSmallWindowParameters(parameters); err != nil {
		return "", err
	}
	if parameters.mode == smallWindowModeBackground {
		return "2|", nil
	}

	suffix := ""
	switch parameters.mode {
	case smallWindowModeDateTimeWeekday:
		suffix = parameters.date + " " + parameters.weekday
	case smallWindowModeTimeWeekday:
		suffix = parameters.weekday
	case smallWindowModeTimeDate:
		suffix = parameters.date
	}
	return fmt.Sprintf(
		"%d|%d|%d|%s|%d|%s|%s",
		parameters.mode,
		parameters.cpu,
		parameters.ram,
		parameters.time,
		parameters.gpu,
		parameters.format,
		suffix,
	), nil
}
