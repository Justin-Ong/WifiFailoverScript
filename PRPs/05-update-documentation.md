# PRP 05: Update Documentation

**Status: Completed**

## Goal

Update `README.md` to reflect all changes made in PRPs 01–04. The document must accurately describe the new CDF prediction engine, cluster detection, relative degradation thresholds, and data pipeline fixes.

## Prerequisites

- PRPs 01–04 must all be completed

## Context

- `README.md` is the comprehensive project documentation
- It describes configuration parameters, architecture, prediction engine, failover logic, and state variables
- All sections need updating to reflect the new system

## Tasks

### 1. Update Configuration table

Replace removed parameters and add new ones. The following parameters are gone:
- `$safetyMarginPct` — replaced by `$swapProbThreshold`
- `$emaAlpha` — removed entirely
- `$degradationLookaheadPct` — replaced by `$degradationProbThreshold`
- `$jitterThreshold` — replaced by `$jitterMultiplier` and `$minJitterThreshold`
- `$minStableInterval` — renamed to `$minStableIntervalFloor` (now adaptive)

New parameters to add:
| Parameter | Default | Description |
|---|---|---|
| `$swapProbThreshold` | `0.65` | CDF probability triggering predictive swap |
| `$degradationProbThreshold` | `0.40` | Lower swap probability threshold when degradation detected |
| `$returnHoldPctile` | `0.90` | Stay on secondary until elapsed time exceeds this percentile of intervals |
| `$maxHoldTime` | `180s` | Hard ceiling on secondary hold time |
| `$predictionWindowSize` | `20` | Number of recent intervals for CDF calculation (0 = all) |
| `$minStableIntervalFloor` | `8s` | Absolute floor for adaptive bounce filter |
| `$clusterGapThreshold` | `120s` | Disconnects closer than this are part of the same cluster |
| `$clusterHoldMultiplier` | `2.0` | Return hold time multiplier during clusters |
| `$clusterCooldownInterval` | `300s` | Post-cluster heightened alertness period |
| `$baselineWindowSize` | `100` | Sliding window for long-term latency baseline |
| `$jitterMultiplier` | `2.5` | Degradation when current jitter exceeds baseline × this |
| `$minJitterThreshold` | `15ms` | Absolute floor for jitter degradation threshold |

### 2. Rewrite "Prediction Engine" section

Replace the entire section. The new content should cover:

**Data Model** — same as before (tracks intervals between primary healthy→failure). Mention the adaptive `$minStableIntervalFloor` and `Get-MinStableInterval`.

**Empirical CDF** — replace the EMA subsection. Explain:
- `Get-DisconnectProbability($elapsed)` returns the fraction of historical intervals ≤ elapsed time
- Uses the most recent `$predictionWindowSize` intervals (recency bias without smoothing fragility)
- No smoothing constant; inherently outlier-resistant (one extreme value shifts the CDF by 1/N at the tail)

**Prediction Timing** — replace the old swap/return timing formulas:
- Swap when `P(disconnect) >= $swapProbThreshold` (or `$degradationProbThreshold` if degraded)
- Return when elapsed time exceeds `Get-IntervalPercentile($returnHoldPctile)` or `$maxHoldTime`

**Remove** these subsections entirely:
- "EMA (Exponential Moving Average)"
- "Adaptive Safety Margin"
- The old "Prediction Timing" formulas (`predictionBaseTime + emaInterval`, swap/return time calculations)
- "False Positive Handling" (the CDF self-corrects as new longer intervals enter; no explicit nudge)

**Bounce Coalescing** — update to reference `Get-MinStableInterval` and the adaptive floor.

### 3. Add "Cluster Detection" section

New section after the prediction engine. Cover:
- **Detection logic:** `Update-ClusterState` counts disconnects within `$clusterGapThreshold` of each other. Two or more triggers cluster mode.
- **Behavior during clusters:** Extended return hold time (`$clusterHoldMultiplier`), higher non-predictive recovery threshold, lower predictive swap threshold.
- **Post-cluster cooldown:** After cluster ends, intermediate thresholds remain active for `$clusterCooldownInterval` seconds.
- **Rationale:** Prevents ping-ponging during burst disconnect patterns.

### 4. Update "Link Degradation Detection" section

Update to describe:
- Baseline latency window (`$baselineLatencyWindow`, `$baselineWindowSize` = 100 samples)
- Relative jitter threshold: `max($minJitterThreshold, baselineJitter × $jitterMultiplier)`
- Baseline persists across brief outages (not cleared when primary goes down)
- Minimum 30 baseline samples before relative thresholds activate; below that, `$minJitterThreshold` is used as absolute fallback

### 5. Update "Failover Logic" section

**When Primary is Active:**
- **Predictive swap:** Update description. "If `Get-DisconnectProbability(elapsed) >= $swapProbThreshold` and secondary is healthy, swap. When degradation is detected, uses the lower `$degradationProbThreshold` instead." Remove references to margin-based timing. Note that post-cluster cooldown also lowers the threshold.

**When Secondary is Active:**
- **Predictive return:** Update description. "After elapsed time exceeds the `$returnHoldPctile` percentile of historical intervals (or `$maxHoldTime`), return to primary. During clusters, hold times are multiplied by `$clusterHoldMultiplier`."
- **Primary recovered (non-predictive):** Note the cluster-aware recovery threshold.
- Remove the false-positive EMA nudge description.

### 6. Update "State Tracking Summary" table

Remove:
- `$emaInterval`
- `$savedPredictDisconnectAt`

Add:
- `$inCluster` — Whether currently in a disconnect burst
- `$clusterDisconnects` — Count of disconnects in current cluster
- `$lastClusterEnd` — When the last cluster ended (for cooldown)
- `$baselineLatencyWindow` — Long-term latency baseline for relative degradation thresholds

Update description of `$predictionBaseTime` — remove the "used by predictive return to detect whether a real disconnect occurred" note (that mechanism is simplified in the CDF model).

### 7. Update "Logging" section

Update CSV format:
```
Timestamp,Adapter,IntervalSeconds,Prob,Jitter,Trend,Degraded,Cluster
```

Note the column changes:
- `EMA_Seconds` replaced by `Prob` (CDF probability at disconnect time)
- `Cluster` column added (boolean)

### 8. Update "Disconnect Detection" section

Add a note about the adaptive bounce filter:
- `Get-MinStableInterval` returns `max($minStableIntervalFloor, median_interval × 0.20)`
- As the prediction model learns longer intervals, the bounce filter scales up automatically

## Verification

1. Read through the updated `README.md` end-to-end.
2. Confirm every configuration parameter in the doc matches the actual script.
3. Confirm no references to `$emaInterval`, `$emaAlpha`, `$safetyMarginPct`, `$degradationLookaheadPct`, `$jitterThreshold` (the old fixed one), `Get-PredictedDisconnectTime`, `Get-AdaptiveSafetyMargin`, or `Get-PredictiveSwapTime` remain.
4. Confirm the state tracking table matches the actual state variables in the script.

## Dependencies

- Requires PRPs 01–04 all completed
- This is the final PRP
