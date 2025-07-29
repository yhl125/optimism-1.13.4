package wrappers

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/ethereum-optimism/optimism/kurtosis-devnet/pkg/kurtosis/api/interfaces"
	"github.com/kurtosis-tech/kurtosis/api/golang/core/kurtosis_core_rpc_api_bindings"
	"github.com/kurtosis-tech/kurtosis/api/golang/core/lib/enclaves"
	"github.com/kurtosis-tech/kurtosis/api/golang/core/lib/services"
	"github.com/kurtosis-tech/kurtosis/api/golang/core/lib/starlark_run_config"
	"github.com/kurtosis-tech/kurtosis/api/golang/engine/kurtosis_engine_rpc_api_bindings"
	"github.com/kurtosis-tech/kurtosis/api/golang/engine/lib/kurtosis_context"
)

// Wrapper types to implement our interfaces
type KurtosisContextWrapper struct {
	*kurtosis_context.KurtosisContext
}

type EnclaveContextWrapper struct {
	*enclaves.EnclaveContext
}

type ServiceContextWrapper struct {
	*services.ServiceContext
}

type EnclaveInfoWrapper struct {
	*kurtosis_engine_rpc_api_bindings.EnclaveInfo
}

// mostly a no-op, to force the values to be typed as interfaces
func convertPortSpecMap(ports map[string]*services.PortSpec) map[string]interfaces.PortSpec {
	wrappedPorts := make(map[string]interfaces.PortSpec)
	for name, port := range ports {
		wrappedPorts[name] = port
	}
	return wrappedPorts
}

func (w *ServiceContextWrapper) GetPublicPorts() map[string]interfaces.PortSpec {
	return convertPortSpecMap(w.ServiceContext.GetPublicPorts())
}

func (w *ServiceContextWrapper) GetPrivatePorts() map[string]interfaces.PortSpec {
	return convertPortSpecMap(w.ServiceContext.GetPrivatePorts())
}

type starlarkRunResponseLineWrapper struct {
	*kurtosis_core_rpc_api_bindings.StarlarkRunResponseLine
}

type starlarkErrorWrapper struct {
	*kurtosis_core_rpc_api_bindings.StarlarkError
}

type starlarkRunProgressWrapper struct {
	*kurtosis_core_rpc_api_bindings.StarlarkRunProgress
}

type starlarkInstructionWrapper struct {
	*kurtosis_core_rpc_api_bindings.StarlarkInstruction
}

type starlarkRunFinishedEventWrapper struct {
	*kurtosis_core_rpc_api_bindings.StarlarkRunFinishedEvent
}

type starlarkWarningWrapper struct {
	*kurtosis_core_rpc_api_bindings.StarlarkWarning
}

type starlarkInfoWrapper struct {
	*kurtosis_core_rpc_api_bindings.StarlarkInfo
}

type starlarkInstructionResultWrapper struct {
	*kurtosis_core_rpc_api_bindings.StarlarkInstructionResult
}

type EnclaveNameAndUuidWrapper struct {
	*kurtosis_engine_rpc_api_bindings.EnclaveNameAndUuid
}

func (w KurtosisContextWrapper) CreateEnclave(ctx context.Context, name string) (interfaces.EnclaveContext, error) {
	enclaveCtx, err := w.KurtosisContext.CreateEnclave(ctx, name)
	if err != nil {
		return nil, err
	}
	return &EnclaveContextWrapper{enclaveCtx}, nil
}

func (w KurtosisContextWrapper) GetEnclave(ctx context.Context, name string) (interfaces.EnclaveContext, error) {
	enclaveCtx, err := w.KurtosisContext.GetEnclaveContext(ctx, name)
	if err != nil {
		return nil, err
	}
	return &EnclaveContextWrapper{enclaveCtx}, nil
}

func (w *EnclaveContextWrapper) GetService(serviceIdentifier string) (interfaces.ServiceContext, error) {
	svcCtx, err := w.EnclaveContext.GetServiceContext(serviceIdentifier)
	if err != nil {
		return nil, err
	}
	return &ServiceContextWrapper{svcCtx}, nil
}

func (w KurtosisContextWrapper) GetEnclaveStatus(ctx context.Context, enclave string) (interfaces.EnclaveStatus, error) {
	enclaveInfo, err := w.KurtosisContext.GetEnclave(ctx, enclave)
	if err != nil {
		return "", err
	}
	status := enclaveInfo.GetContainersStatus()
	switch status {
	case kurtosis_engine_rpc_api_bindings.EnclaveContainersStatus_EnclaveContainersStatus_EMPTY:
		return interfaces.EnclaveStatusEmpty, nil
	case kurtosis_engine_rpc_api_bindings.EnclaveContainersStatus_EnclaveContainersStatus_RUNNING:
		return interfaces.EnclaveStatusRunning, nil
	case kurtosis_engine_rpc_api_bindings.EnclaveContainersStatus_EnclaveContainersStatus_STOPPED:
		return interfaces.EnclaveStatusStopped, nil
	default:
		return "", fmt.Errorf("unknown enclave status: %v", status)
	}
}

func (w KurtosisContextWrapper) DestroyEnclave(ctx context.Context, name string) error {
	return w.KurtosisContext.DestroyEnclave(ctx, name)
}

func (w KurtosisContextWrapper) Clean(ctx context.Context, destroyAll bool) ([]interfaces.EnclaveNameAndUuid, error) {
	deleted, err := w.KurtosisContext.Clean(ctx, destroyAll)
	if err != nil {
		return nil, err
	}

	result := make([]interfaces.EnclaveNameAndUuid, len(deleted))
	for i, nameAndUuid := range deleted {
		result[i] = &EnclaveNameAndUuidWrapper{nameAndUuid}
	}
	return result, nil
}

func (w *EnclaveContextWrapper) RunStarlarkPackage(ctx context.Context, pkg string, serializedParams *starlark_run_config.StarlarkRunConfig) (<-chan interfaces.StarlarkResponse, string, error) {
	runner := w.EnclaveContext.RunStarlarkPackage
	if strings.HasPrefix(pkg, "github.com/") {
		runner = w.EnclaveContext.RunStarlarkRemotePackage
	}

	stream, cancel, err := runner(ctx, pkg, serializedParams)
	if err != nil {
		return nil, "", err
	}

	// Convert the stream
	wrappedStream := make(chan interfaces.StarlarkResponse)
	go func() {
		defer close(wrappedStream)
		defer cancel()
		for line := range stream {
			wrappedStream <- &starlarkRunResponseLineWrapper{line}
		}
	}()

	return wrappedStream, "", nil
}

func (w *EnclaveContextWrapper) RunStarlarkScript(ctx context.Context, script string, serializedParams *starlark_run_config.StarlarkRunConfig) error {
	// TODO: we should probably collect some data from the result and extend the error.
	_, err := w.EnclaveContext.RunStarlarkScriptBlocking(ctx, script, serializedParams)
	return err
}

func (w *starlarkRunResponseLineWrapper) GetError() interfaces.StarlarkError {
	if err := w.StarlarkRunResponseLine.GetError(); err != nil {
		return &starlarkErrorWrapper{err}
	}
	return nil
}

func (w *starlarkRunResponseLineWrapper) GetProgressInfo() interfaces.ProgressInfo {
	if progress := w.StarlarkRunResponseLine.GetProgressInfo(); progress != nil {
		return &starlarkRunProgressWrapper{progress}
	}
	return nil
}

func (w *starlarkRunResponseLineWrapper) GetInstruction() interfaces.Instruction {
	if instruction := w.StarlarkRunResponseLine.GetInstruction(); instruction != nil {
		return &starlarkInstructionWrapper{instruction}
	}
	return nil
}

func (w *starlarkRunResponseLineWrapper) GetRunFinishedEvent() interfaces.RunFinishedEvent {
	if event := w.StarlarkRunResponseLine.GetRunFinishedEvent(); event != nil {
		return &starlarkRunFinishedEventWrapper{event}
	}
	return nil
}

func (w *starlarkRunResponseLineWrapper) GetWarning() interfaces.Warning {
	if warning := w.StarlarkRunResponseLine.GetWarning(); warning != nil {
		return &starlarkWarningWrapper{warning}
	}
	return nil
}

func (w *starlarkRunResponseLineWrapper) GetInfo() interfaces.Info {
	if info := w.StarlarkRunResponseLine.GetInfo(); info != nil {
		return &starlarkInfoWrapper{info}
	}
	return nil
}

func (w *starlarkRunResponseLineWrapper) GetInstructionResult() interfaces.InstructionResult {
	if result := w.StarlarkRunResponseLine.GetInstructionResult(); result != nil {
		return &starlarkInstructionResultWrapper{result}
	}
	return nil
}

func (w *starlarkRunProgressWrapper) GetCurrentStepInfo() []string {
	return w.StarlarkRunProgress.CurrentStepInfo
}

func (w *starlarkInstructionWrapper) GetDescription() string {
	return w.StarlarkInstruction.Description
}

func (w *starlarkRunFinishedEventWrapper) GetIsRunSuccessful() bool {
	return w.StarlarkRunFinishedEvent.IsRunSuccessful
}

func (w *starlarkErrorWrapper) GetInterpretationError() error {
	if err := w.StarlarkError.GetInterpretationError(); err != nil {
		return errors.New(err.GetErrorMessage())
	}
	return nil
}

func (w *starlarkErrorWrapper) GetValidationError() error {
	if err := w.StarlarkError.GetValidationError(); err != nil {
		return errors.New(err.GetErrorMessage())
	}
	return nil
}

func (w *starlarkErrorWrapper) GetExecutionError() error {
	if err := w.StarlarkError.GetExecutionError(); err != nil {
		return errors.New(err.GetErrorMessage())
	}
	return nil
}

func (w *starlarkWarningWrapper) GetMessage() string {
	return w.StarlarkWarning.WarningMessage
}

func (w *starlarkInfoWrapper) GetMessage() string {
	return w.StarlarkInfo.InfoMessage
}

func (w *starlarkInstructionResultWrapper) GetSerializedInstructionResult() string {
	return w.StarlarkInstructionResult.SerializedInstructionResult
}
