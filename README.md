# WiFi Failover Watchdog with Predictive Swapping

A PowerShell script that monitors two WiFi adapters and automatically switches between them based on connectivity health, with a predictive engine that learns disconnect patterns and preemptively swaps before failures occur.

**Requires:** Administrator privileges (modifies network interface metrics).

## Configuration

| Parameter | Default | Description |
|---|---|---|
| `$primary` | `Wi-Fi 2` | Primary adapter (MediaTek) |
| `$secondary` | `Wi-Fi 3` | Secondary adapter (Realtek) |
| `$pingTarget` | `192.168.50.1` | IP to ping for health checks |
| `$checkInterval` | `0.5s` | Main loop tick rate |
| `$pingInterval` | `0.5s` | Background ping frequency per adapter |
| `$latencyThreshold` | `200ms` | Latency above this = degraded |
| `$failoverThreshold` | `1` | Consecutive failures before switching away |
| `$recoveryThreshold` | `10` | Consecutive good pings before switching back |
| `$goodMetric` / `$badMetric` | `10` / `500` | Interface metrics (lower = preferred route) |
| `$swapCooldown` | `10s` | Minimum time between non-forced swaps |
| `$safetyMarginPct` | `15%` | Base safety margin (adaptive: scales with interval variance, caps at 40%) |
| `$emaAlpha` | `0.3` | EMA smoothing factor (higher = more reactive) |
| `$minDataPoints` | `3` | Disconnects needed before prediction activates |
| `$staleProbeThreshold` | `10s` | Treat probe as down if no update within this window |
| `$minStableInterval` | `8s` | Intervals shorter than this are bounces (excluded from EMA) |
| `$latencyWindowSize` | `20` | Sliding window size for degradation detection |
| `$jitterThreshold` | `50ms` | Latency stddev above this = jittery link |
| `$trendThreshold` | `5ms/tick` | Latency slope above this = worsening link |
| `$degradationLookaheadPct` | `30%` | Early swap window when degradation detected |
| `$maxLogLines` | `500` | Max CSV log entries on disk |
| `$maxIntervals` | `500` | Max in-memory interval history |

## Architecture

### Background Ping Probes

Two runspaces ping the target continuously via `ping.exe -S <source_ip>`, binding each ping to its adapter's IP. Each probe writes an immutable snapshot (`Up`, `Latency`, `Updated`) to a synchronized hashtable. The main loop reads these atomically -- no locks needed since .NET reference assignment is atomic.

A staleness guard treats any probe whose `Updated` timestamp exceeds `$staleProbeThreshold` as down, preventing decisions based on frozen data from a stalled thread.

### Main Loop

Runs every `$checkInterval` seconds. Each tick:

1. **Reads** atomic snapshots from both probes (with staleness check).
2. **Tracks** up/down transitions for display and prediction timing.
3. **Displays** a status line: adapter latency, uptime/downtime, active adapter, prediction countdown.
4. **Executes** failover logic based on which adapter is active.

### Swap Mechanism

Swaps work by setting Windows interface metrics via `Set-NetIPInterface`:
- **Active adapter** gets metric `10` (preferred).
- **Inactive adapter** gets metric `500` (deprioritized).

A cooldown (`$swapCooldown`) prevents rapid oscillation. Critical failovers (reactive, secondary-degraded) bypass the cooldown with `-Force`.

On shutdown (`finally` block), both adapters are restored to automatic metrics.

## Disconnect Detection

Disconnect logging is **centralized** — a single block in the main loop detects when primary transitions from healthy to unhealthy and logs it immediately, regardless of which adapter is active or which swap path is running. This keeps swap logic and disconnect tracking fully independent.

**Bounce filtering:** A disconnect is only logged if primary was stably healthy for at least `$minStableInterval` seconds before dropping. This uses `$primaryHealthySince` (the existing healthy-streak timer). Brief flickers (e.g. 2-3 second recovery between drops) don't produce log entries.

## Failover Logic

### When Primary is Active

- **Reactive failover:** If primary fails `$failoverThreshold` consecutive checks and secondary is healthy, immediately switch to secondary (bypasses cooldown).
- **Degradation swap:** If the link degradation detector flags the primary as degraded (high jitter or rising latency trend) and we're within `$degradationLookaheadPct` of the predicted disconnect, swap early. Uses a wider lookahead window than the normal predictive swap.
- **Predictive swap:** If the prediction engine says a disconnect is imminent and secondary is healthy, preemptively switch.

### When Secondary is Active

- **Secondary degraded:** If secondary fails `$failoverThreshold` checks and primary is healthy, force-switch back to primary (bypasses cooldown). Re-anchors prediction base if in a predictive window.
- **Primary recovered (non-predictive):** After `$recoveryThreshold` consecutive good primary pings, switch back.
- **Predictive return:** After the predicted disconnect window passes (plus a `2x safety margin` buffer), return to primary. If `$predictionBaseTime` was nulled during the window (by the centralized disconnect logger), a real drop occurred — reset uptime anchor. If not (false positive), nudge the EMA upward to reduce future false positives.

## Prediction Engine

### Data Model

Tracks the interval (in seconds) between primary becoming healthy and its next failure. This measures **primary uptime cadence**, excluding time spent on secondary.

- `$predictionBaseTime`: set when primary transitions from unhealthy to healthy while active.
- `$lastDisconnectTime`: set when a disconnect is logged.

### Bounce Coalescing

When primary drops, briefly recovers for 1-3 seconds, then drops again, each micro-recovery would produce a tiny interval that drags the EMA down. Two guards prevent this:

1. **Prediction base debounce:** `$predictionBaseTime` is only set after primary has been continuously healthy for `$minStableInterval` seconds. Brief flickers don't reset the prediction anchor.
2. **EMA input filter:** Intervals shorter than `$minStableInterval` are still logged to CSV for diagnostics but are excluded from the in-memory `$intervals` list and EMA calculation.

### EMA (Exponential Moving Average)

```
emaInterval = alpha * latest_interval + (1 - alpha) * previous_ema
```

Weights recent disconnects more heavily than old ones. With `alpha = 0.3`, the last observation contributes 30% of the estimate. Only intervals >= `$minStableInterval` are fed into the EMA.

### Adaptive Safety Margin

The base `$safetyMarginPct` (15%) is scaled by the coefficient of variation (CV = stddev / mean) of the interval history:

```
adaptiveMargin = min(safetyMarginPct * (1 + CV), 0.40)
```

Predictable patterns (low CV) keep the margin tight. Erratic patterns (high CV) widen the margin up to 40%. Applied to both swap and return timing.

### Prediction Timing

- **Predicted disconnect** = `predictionBaseTime + emaInterval`
- **Swap time** = `predicted disconnect - (emaInterval * adaptiveMargin)`
- **Return time** = `predicted disconnect + (emaInterval * adaptiveMargin * 2)`

Prediction only activates after `$minDataPoints` disconnects are recorded and only for windows that start after `$scriptStartTime` (prevents acting on stale predictions from log history).

### Link Degradation Detection

A sliding window of the last `$latencyWindowSize` primary latency readings is analysed each tick for:

- **Jitter** (standard deviation) -- high jitter signals an unstable link before it actually drops.
- **Trend** (linear regression slope) -- a positive slope means latency is rising.

If either crosses its threshold, the link is flagged as "degraded". When degraded AND the current time is within `$degradationLookaheadPct` of the predicted disconnect, a **degradation swap** triggers earlier than the normal predictive swap window. This catches the "slow decay before hard drop" pattern.

The degradation swap sets `$predictivelySwapped = $true`, so the existing predictive return logic handles timing the return identically.

### False Positive Handling

If the predictive window passes without a primary drop, the EMA is nudged upward (interval was longer than predicted), and no disconnect is logged. This self-corrects the model over time.

## Logging

Disconnects are appended to `disconnect_log.csv` in the script directory:

```
Timestamp,Adapter,IntervalSeconds,EMA_Seconds,Jitter,Trend,Degraded
2026-04-09 14:30:15,Wi-Fi 2,342,298,32.5,3.12,False
```

Each row captures the link degradation state at the moment of disconnect: `Jitter` (latency stddev in ms), `Trend` (latency slope in ms/sample), and `Degraded` (whether thresholds were exceeded). This enables post-hoc analysis of whether degradation detection is catching pre-disconnect patterns.

- On startup, existing log entries are loaded to bootstrap the EMA and interval history.
- The log is trimmed to `$maxLogLines` every 50 disconnects.

## State Tracking Summary

| Variable | Purpose |
|---|---|
| `$primaryFails` / `$secondaryFails` | Consecutive failure counters for reactive failover |
| `$primaryRecoveredCount` | Consecutive good pings on primary (for recovery threshold) |
| `$predictivelySwapped` | Whether currently in a predictive swap window |
| `$primaryWasHealthy` | Tracks unhealthy-to-healthy transitions for EMA base timing |
| `$previousTickHealthy` | Last tick's health state — detects healthy→unhealthy transitions for centralized disconnect logging |
| `$primaryHealthySince` | When current healthy streak began (bounce filtering for disconnect logging and prediction base anchoring) |
| `$predictionBaseTime` | Anchor for "time since primary became healthy" (debounced). Nulled by `Write-DisconnectLog`; used by predictive return to detect whether a real disconnect occurred during the window |
| `$latencyWindow` | Sliding window of recent primary latencies for degradation analysis |
| `$lastSwapTime` | Cooldown enforcement |
