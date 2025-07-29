package devtest

import (
	"context"
	"log/slog"

	"go.opentelemetry.io/otel/trace"

	"github.com/ethereum/go-ethereum/log"

	"github.com/ethereum-optimism/optimism/op-service/log/logfilter"
	"github.com/ethereum-optimism/optimism/op-service/testreq"
)

// CommonT is a subset of testing.T, extended with a few common utils.
// This interface should not be used directly. Instead, use T in test-scope, or P when operating at package level.
//
// This CommonT interface is minimal enough such that it can be implemented by tooling,
// and a *testing.T can be used with minimal wrapping.
type CommonT interface {
	Error(args ...any)
	Errorf(format string, args ...any)
	Fail()
	FailNow()
	SkipNow()

	TempDir() string
	Cleanup(fn func())
	Log(args ...any)
	Logf(format string, args ...any)
	Helper()
	Name() string

	Logger() log.Logger
	Tracer() trace.Tracer
	Ctx() context.Context
	Require() *testreq.Assertions
}

type testScopeCtxKeyType struct{}

// testScopeCtxKey is a key added to the test-context to identify the test-scope.
var testScopeCtxKey = testScopeCtxKeyType{}

// testScopeValue wraps a string to implement slog.LogValuer for context handling
type testScopeValue string

func (t testScopeValue) LogValue() slog.Value {
	return slog.StringValue(string(t))
}

// TestScope retrieves the test-scope from the context
func TestScope(ctx context.Context) string {
	scope := ctx.Value(testScopeCtxKey)
	if scope == nil {
		return ""
	}
	if scopeVal, ok := scope.(testScopeValue); ok {
		return string(scopeVal)
	}
	return ""
}

// AddTestScope combines the sub-scope with the test-scope of the context,
// and returns a context with the updated scope value.
func AddTestScope(ctx context.Context, scope string) context.Context {
	prev := TestScope(ctx)
	newScope := testScopeValue(prev + "/" + scope)
	ctx = logfilter.AddLogAttrToContext(ctx, "scope", newScope)
	return context.WithValue(ctx, testScopeCtxKey, newScope)
}
