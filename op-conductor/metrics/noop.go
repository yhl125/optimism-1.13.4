package metrics

import opmetrics "github.com/ethereum-optimism/optimism/op-service/metrics"

type NoopMetricsImpl struct {
	opmetrics.NoopRPCMetrics
}

var NoopMetrics Metricer = new(NoopMetricsImpl)

func (*NoopMetricsImpl) RecordInfo(version string)                                       {}
func (*NoopMetricsImpl) RecordUp()                                                       {}
func (*NoopMetricsImpl) RecordStateChange(leader bool, healthy bool, active bool)        {}
func (*NoopMetricsImpl) RecordLeaderTransfer(success bool)                               {}
func (*NoopMetricsImpl) RecordStartSequencer(success bool)                               {}
func (*NoopMetricsImpl) RecordStopSequencer(success bool)                                {}
func (*NoopMetricsImpl) RecordHealthCheck(success bool, err error)                       {}
func (*NoopMetricsImpl) RecordLoopExecutionTime(duration float64)                        {}
func (*NoopMetricsImpl) RecordRollupBoostConnectionAttempts(success bool, source string) {}
func (*NoopMetricsImpl) RecordWebSocketClientCount(count int)                            {}
