package testlog

import (
	"context"
	"log/slog"
	"strings"

	"github.com/ethereum/go-ethereum/log"

	"github.com/ethereum-optimism/optimism/op-service/logmods"
)

// CapturedAttributes forms a chain of inherited attributes, to traverse on captured log records.
type CapturedAttributes struct {
	Parent     *CapturedAttributes
	Attributes []slog.Attr
}

// Attrs calls f on each Attr in the [CapturedAttributes].
// Iteration stops if f returns false.
func (r *CapturedAttributes) Attrs(f func(slog.Attr) bool) {
	for _, a := range r.Attributes {
		if !f(a) {
			return
		}
	}
	if r.Parent != nil {
		r.Parent.Attrs(f)
	}
}

// CapturedRecord is a wrapped around a regular log-record,
// to preserve the inherited attributes context, without mutating the record or reordering attributes.
type CapturedRecord struct {
	Parent *CapturedAttributes
	*slog.Record
}

// Attrs calls f on each Attr in the [CapturedRecord].
// Iteration stops if f returns false.
func (r *CapturedRecord) Attrs(f func(slog.Attr) bool) {
	searching := true
	r.Record.Attrs(func(a slog.Attr) bool {
		searching = f(a)
		return searching
	})
	if !searching { // if we found it already, then don't traverse the remainder
		return
	}
	if r.Parent != nil {
		r.Parent.Attrs(f)
	}
}

// CapturingHandler provides a log handler that captures all log records and optionally forwards them to a delegate.
// Note that it is not thread safe.
type CapturingHandler struct {
	handler slog.Handler
	Logs    *[]*CapturedRecord // shared among derived CapturingHandlers
	// attrs are inherited log record attributes, from a logger that this CapturingHandler may be derived from
	attrs *CapturedAttributes
}

var _ logmods.Handler = (*CapturingHandler)(nil)

func WrapCaptureLogger(h slog.Handler) slog.Handler {
	return &CapturingHandler{handler: h, Logs: new([]*CapturedRecord)}
}

func CaptureLogger(t Testing, level slog.Level) (_ log.Logger, ch *CapturingHandler) {
	logger := LoggerWithHandlerMod(t, level, WrapCaptureLogger)
	out, ok := logmods.FindHandler[*CapturingHandler](logger.Handler())
	if !ok {
		panic("failed to get attached log-capturing handler")
	}
	return logger, out
}

func (c *CapturingHandler) Unwrap() slog.Handler {
	return c.handler
}

func (c *CapturingHandler) Handle(ctx context.Context, r slog.Record) error {
	*c.Logs = append(*c.Logs, &CapturedRecord{
		Parent: c.attrs,
		Record: &r,
	})
	return c.handler.Handle(ctx, r)
}

func (c *CapturingHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return &CapturingHandler{
		handler: c.handler.WithAttrs(attrs),
		Logs:    c.Logs,
		attrs: &CapturedAttributes{
			Parent:     c.attrs,
			Attributes: attrs,
		},
	}
}

func (c *CapturingHandler) WithGroup(name string) slog.Handler {
	return &CapturingHandler{
		handler: c.handler.WithGroup(name),
		Logs:    c.Logs,
	}
}

func (c *CapturingHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return c.handler.Enabled(ctx, level)
}

func (c *CapturingHandler) Clear() {
	*c.Logs = (*c.Logs)[:0] // reuse slice
}

func NewLevelFilter(level slog.Level) LogFilter {
	return func(r *CapturedRecord) bool {
		return r.Record.Level == level
	}
}

func NewAttributesFilter(key, value string) LogFilter {
	return func(r *CapturedRecord) bool {
		found := false
		r.Attrs(func(a slog.Attr) bool {
			if a.Key == key && a.Value.String() == value {
				found = true
				return false
			}
			return true // try next
		})
		return found
	}
}

func NewAttributesContainsFilter(key, value string) LogFilter {
	return func(r *CapturedRecord) bool {
		found := false
		r.Attrs(func(a slog.Attr) bool {
			if a.Key == key && strings.Contains(a.Value.String(), value) {
				found = true
				return false
			}
			return true // try next
		})
		return found
	}
}

func NewMessageFilter(message string) LogFilter {
	return func(r *CapturedRecord) bool {
		return r.Record.Message == message
	}
}

func NewMessageContainsFilter(message string) LogFilter {
	return func(r *CapturedRecord) bool {
		return strings.Contains(r.Record.Message, message)
	}
}

func NewErrContainsFilter(errMessage string) LogFilter {
	return func(r *CapturedRecord) bool {
		found := false
		r.Attrs(func(a slog.Attr) bool {
			if a.Key != "err" {
				return true
			}
			if err, ok := a.Value.Any().(error); ok && strings.Contains(err.Error(), errMessage) {
				found = true
				return false
			}
			return true
		})
		return found
	}
}

type LogFilter func(record *CapturedRecord) bool

func (c *CapturingHandler) FindLog(filters ...LogFilter) *CapturedRecord {
	for _, record := range *c.Logs {
		match := true
		for _, filter := range filters {
			if !filter(record) {
				match = false
				break
			}
		}
		if match {
			return record
		}
	}
	return nil
}

func (c *CapturingHandler) FindLogs(filters ...LogFilter) []*CapturedRecord {
	var logs []*CapturedRecord
	for _, record := range *c.Logs {
		match := true
		for _, filter := range filters {
			if !filter(record) {
				match = false
				break
			}
		}
		if match {
			logs = append(logs, record)
		}
	}
	return logs
}

func (h *CapturedRecord) AttrValue(name string) (v any) {
	h.Attrs(func(a slog.Attr) bool {
		if a.Key == name {
			v = a.Value.Any()
			return false
		}
		return true // try next
	})
	return
}

var _ slog.Handler = (*CapturingHandler)(nil)

type Capturer interface {
	slog.Handler
	Clear()
	FindLog(filters ...LogFilter) *CapturedRecord
	FindLogs(filters ...LogFilter) []*CapturedRecord
}

var _ Capturer = (*CapturingHandler)(nil)
