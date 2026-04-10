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
| `$swapProbThreshold` | `0.65` | CDF probability triggering predictive swap |
| `$degradationProbThreshold` | `0.40` | Lower swap probability threshold when degradation detected |
| `$returnHoldPctile` | `0.90` | Stay on secondary until elapsed time exceeds this percentile of intervals |
| `$maxHoldTime` | `180s` | Hard ceiling on secondary hold time |
| `$predictionWindowSize` | `20` | Number of recent intervals for CDF calculation (0 = all) |
| `$minDataPoints` | `3` | Disconnects needed before prediction activates |
| `$staleProbeThreshold` | `10s` | Treat probe as down if no update within this window |
| `$minStableIntervalFloor` | `8s` | Absolute floor for adaptive bounce filter |
| `$latencyWindowSize` | `20` | Sliding window size for degradation detection |
| `$baselineWindowSize` | `100` | Sliding window for long-term latency baseline |
| `$jitterMultiplier` | `2.5` | Degradation when current jitter exceeds baseline × this |
| `$minJitterThreshold` | `15ms` | Absolute floor for jitter degradation threshold |
| `$trendThreshold` | `5ms/tick` | Latency slope above this = worsening link |
| `$clusterGapThreshold` | `120s` | Disconnects closer than this are part of the same cluster |
| `$clusterHoldMultiplier` | `2.0` | Return hold time multiplier during clusters |
| `$clusterCooldownInterval` | `300s` | Post-cluster heightened alertness period |
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
3. **Displays** a status line: adapter latency, uptime/downtime, active adapter, prediction probability, cluster state.
4. **Executes** failover logic based on which adapter is active.

### Swap Mechanism

Swaps work by setting Windows interface metrics via `Set-NetIPInterface`:
- **Active adapter** gets metric `10` (preferred).
- **Inactive adapter** gets metric `500` (deprioritized).

A cooldown (`$swapCooldown`) prevents rapid oscillation. Critical failovers (reactive, secondary-degraded) bypass the cooldown with `-Force`.

On shutdown (`finally` block), both adapters are restored to automatic metrics.

## Disconnect Detection

Disconnect logging is **centralized** — a single block in the main loop detects when primary transitions from healthy to unhealthy and logs it immediately, regardless of which adapter is active or which swap path is running. This keeps swap logic and disconnect tracking fully independent.

**Bounce filtering:** A disconnect is only logged if primary was stably healthy for at least `Get-MinStableInterval` seconds before dropping. `Get-MinStableInterval` returns `max($minStableIntervalFloor, median_interval × 0.20)` — as the prediction model learns longer intervals, the bounce filter scales up automatically. Brief flickers (e.g. 2-3 second recovery between drops) don't produce log entries.

## Failover Logic

### When Primary is Active

- **Reactive failover:** If primary fails `$failoverThreshold` consecutive checks and secondary is healthy, immediately switch to secondary (bypasses cooldown).
- **Predictive swap (CDF-based):** If `Get-DisconnectProbability(elapsed) >= $swapProbThreshold` and secondary is healthy, swap. When link degradation is detected, uses the lower `$degradationProbThreshold` instead. Post-cluster cooldown also lowers the threshold for earlier swapping.

### When Secondary is Active

- **Secondary degraded:** If secondary fails `$failoverThreshold` checks and primary is healthy, force-switch back to primary (bypasses cooldown). Re-anchors prediction base unconditionally.
- **Primary recovered (non-predictive):** After `$recoveryThreshold` consecutive good primary pings, switch back. During a cluster, the threshold is multiplied by `$clusterHoldMultiplier`. During post-cluster cooldown, an intermediate 1.5× threshold is used.
- **Predictive return:** After elapsed time exceeds the `$returnHoldPctile` percentile of historical intervals (or `$maxHoldTime`), return to primary. During clusters, hold times are multiplied by `$clusterHoldMultiplier`. If `$predictionBaseTime` was nulled during the window (by the centralized disconnect logger), a real drop occurred — reset uptime anchor.

## Prediction Engine

### Data Model

Tracks the interval (in seconds) between primary becoming healthy and its next failure. This measures **primary uptime cadence**, excluding time spent on secondary.

- `$predictionBaseTime`: set when primary transitions from unhealthy to healthy while active, after the adaptive bounce debounce (`Get-MinStableInterval`) is satisfied. Not pre-set from the log during bootstrap — the main loop establishes it fresh on each startup.
- `$lastDisconnectTime`: set when a disconnect is logged.

### Bounce Coalescing

When primary drops, briefly recovers for 1-3 seconds, then drops again, each micro-recovery would produce a tiny interval that pollutes the model. Two guards prevent this:

1. **Prediction base debounce:** `$predictionBaseTime` is only set after primary has been continuously healthy for `Get-MinStableInterval` seconds. Brief flickers don't reset the prediction anchor.
2. **Interval input filter:** Intervals shorter than `Get-MinStableInterval` are still logged to CSV for diagnostics but are excluded from the in-memory `$intervals` list and CDF calculation.

`Get-MinStableInterval` returns `max($minStableIntervalFloor, median_interval × 0.20)`, adapting as the model learns.

### Empirical CDF (Cumulative Distribution Function)

```
P(disconnect | elapsed) = count(intervals <= elapsed) / count(intervals)
```

`Get-DisconnectProbability($elapsed)` returns the fraction of historical intervals ≤ elapsed time. Uses the most recent `$predictionWindowSize` intervals for recency bias without smoothing fragility.

**Why CDF over EMA:**
- Robust to outliers (a single extreme value shifts the CDF by 1/N at the tail)
- Naturally conservative (swaps early enough to beat most disconnects)
- No smoothing constant to tune
- Graceful degradation: with few data points, the probability stays low and you don't swap prematurely

### Prediction Timing

- **Swap** when `P(disconnect) >= $swapProbThreshold` (65%), or `$degradationProbThreshold` (40%) if degraded or in post-cluster cooldown.
- **Return** when elapsed time exceeds `Get-IntervalPercentile($returnHoldPctile)` (P90), or after `$maxHoldTime` seconds (hard ceiling). During clusters, both are multiplied by `$clusterHoldMultiplier`.

Prediction only activates after `$minDataPoints` disconnects are recorded. Since `$predictionBaseTime` is only set by the main loop after startup (never from log bootstrap), predictions are always based on current-session observations.

## Cluster Detection

Detects when disconnects occur in rapid bursts and adjusts behavior to stay on secondary for the duration.

### Detection Logic

`Update-ClusterState` counts disconnects within `$clusterGapThreshold` (120s) of each other. Two or more triggers cluster mode. When the gap between disconnects exceeds the threshold, the cluster ends and `$lastClusterEnd` is recorded.

### Behavior During Clusters

- **Extended return hold time:** Both percentile-based and hard timeout hold times are multiplied by `$clusterHoldMultiplier` (2.0×).
- **Higher non-predictive recovery threshold:** `$recoveryThreshold × $clusterHoldMultiplier` consecutive good pings required.
- **Lower predictive swap threshold:** Post-cluster cooldown uses `$degradationProbThreshold` for more aggressive predictive swapping.

### Post-Cluster Cooldown

After a cluster ends, intermediate thresholds remain active for `$clusterCooldownInterval` (300s):
- Recovery threshold is 1.5× normal.
- Predictive swap threshold is lowered to `$degradationProbThreshold`.

This prevents returning to primary too eagerly after a burst of disconnects.

### Rationale

Without cluster awareness, the behavior during a burst is: predictive swap → wait → return → immediately drop → reactive swap → repeat. With cluster detection, the script stays on secondary through the entire burst.

## Link Degradation Detection

A sliding window of the last `$latencyWindowSize` primary latency readings is analysed each tick for:

- **Jitter** (standard deviation) -- high jitter signals an unstable link before it actually drops.
- **Trend** (linear regression slope) -- a positive slope means latency is rising.

### Relative Jitter Threshold

Instead of a fixed absolute threshold, jitter is compared against a **rolling baseline** from the longer-term `$baselineLatencyWindow` (last `$baselineWindowSize` samples):

```
effectiveThreshold = max($minJitterThreshold, baselineJitter × $jitterMultiplier)
```

- Below 30 baseline samples: uses `$minJitterThreshold` (15ms) as absolute fallback.
- The baseline persists across brief outages (not cleared when primary goes down), maintaining its longer-term character.
- This prevents false degradation flags on adapters with naturally higher jitter, and catches degradation on low-jitter adapters that a fixed threshold would miss.

If either jitter or trend crosses its threshold, the link is flagged as "degraded". When degraded, the predictive swap uses `$degradationProbThreshold` instead of `$swapProbThreshold`, allowing earlier swapping based on the CDF.

## Reading the Console Output

### Startup Banner

When the script launches, it prints a banner showing your configuration:

```
==========================================
  WiFi Failover Watchdog + Prediction
==========================================
Primary:     Wi-Fi 2
Secondary:   Wi-Fi 3
Ping mode:   ping.exe -S (async background threads)
Threshold:   200ms | Failover: 1 | Recovery: 10
Prediction:  CDF swap=65% return=P90 maxhold=180s
Bounce:      8s min stable (adaptive) | Jitter: 2.5x baseline (floor 15ms) | Trend: 5ms/tick
Cluster:     120s gap | 2x hold | 300s cooldown
Min data:    3 disconnects before prediction
Max log:     500 entries | Max intervals: 500
Log file:    C:\...\disconnect_log.csv
Press Ctrl+C to stop
===========================================
```

Check that the adapter names and parameters match what you expect before the main loop begins.

### Status Line

Each tick (~0.5s) prints a single status line:

```
[14:30:15] P=4ms(312s) S=8ms(312s) Act=Wi-Fi 2 Total=312s [P=72% elapsed=312s]
```

| Segment | Meaning |
|---|---|
| `[14:30:15]` | Current timestamp (HH:mm:ss) |
| `P=4ms(312s)` | **Primary** adapter: latency in ms, uptime in parentheses. Green = healthy, Red = degraded or down |
| `S=8ms(312s)` | **Secondary** adapter: same format. Green = healthy, Red = degraded or down |
| `Act=Wi-Fi 2` | Which adapter is currently **active** (routing traffic) |
| `Total=312s` | Total script uptime since launch |
| `[P=72% elapsed=312s]` | **Prediction**: CDF probability of disconnect at current elapsed time, and seconds since primary became healthy |

When the adapter is down, the latency is replaced with a down timer:

```
P=DOWN(5s) S=8ms(120s) ...
```

When the prediction engine is still learning (fewer than `$minDataPoints` disconnects recorded), the prediction field shows:

```
[Learning (2 more)]
```

Once enough data is collected but `$predictionBaseTime` hasn't been set yet (e.g. primary is on secondary), it shows:

```
[Waiting]
```

### Cluster Indicators

Cluster state is appended to the status line:

- **`[CLUSTER x5]`** — Active cluster detected; 5 disconnects in the current burst. The script is holding on secondary with extended thresholds.
- **`[POST-CLUSTER 180s]`** — Cluster ended, 180 seconds remaining in the cooldown period. Intermediate recovery thresholds are still in effect.

### Degradation Warning

When primary is the active adapter and link degradation is detected, a yellow warning line appears below the status line:

```
  [DEGRADED jitter=32.5ms(thr=22.0ms) trend=3.12ms/tick]
```

- **jitter** — Current standard deviation of latencies in the sliding window.
- **thr** — The adaptive jitter threshold (`max($minJitterThreshold, baselineJitter × $jitterMultiplier)`).
- **trend** — Linear regression slope of recent latencies (ms per tick). Positive = latency rising.

When this line appears, the script is using the lower `$degradationProbThreshold` for predictive swaps.

### Swap and Failover Events

Event messages appear below the status line when the script changes adapters:

| Message | Color | Meaning |
|---|---|---|
| `REACTIVE FAILOVER -> Wi-Fi 3` | Magenta | Primary failed health checks; emergency switch to secondary (bypasses cooldown) |
| `PREDICTIVE SWAP -> Wi-Fi 3 (predictive P=72%)` | Blue | CDF probability crossed the swap threshold; pre-emptive switch |
| `PREDICTIVE SWAP -> Wi-Fi 3 (predictive+degraded P=45%)` | Blue | Same, but triggered at the lower degradation threshold |
| `FAILBACK -> Wi-Fi 2 (primary recovered)` | Magenta | Primary passed enough consecutive recovery checks; returning |
| `FAILBACK -> Wi-Fi 2 (secondary degraded)` | Magenta | Secondary failed; forced return to primary |
| `PREDICTIVE RETURN -> Wi-Fi 2 (disconnect window passed)` | Blue | Elapsed time exceeded the return-hold percentile; returning to primary |
| `PREDICTIVE RETURN -> Wi-Fi 2 (max hold time)` | Blue | Hard timeout reached while on secondary |
| `PREDICTIVE RETURN -> Wi-Fi 2 (max hold time (cluster))` | Blue | Hard timeout reached during a cluster (extended hold) |
| `>>> ACTIVE: Wi-Fi 2 (reason) <<<` | Green | Confirms the adapter switch succeeded |

### Disconnect Logging Messages

When a disconnect is recorded:

```
  LOGGED | Count: 47 | Avg: 312s | Min: 45s | Max: 920s
```

This shows updated interval statistics after the new entry. If the interval was too short (bounce filtered):

```
  (bounce: 3s < 8s threshold, skipping)
```

### Other Messages

| Message | Color | Meaning |
|---|---|---|
| `[CLUSTER DETECTED: 3 disconnects in rapid succession]` | Yellow | Two or more disconnects within `$clusterGapThreshold` — cluster mode activated |
| `[CLUSTER ENDED after 5 disconnects]` | DarkYellow | Gap between disconnects exceeded threshold — cluster over, cooldown begins |
| `Swap to Wi-Fi 3 suppressed (cooldown)` | Gray | A non-forced swap was blocked by the cooldown timer |
| `Swap to Wi-Fi 3 FAILED (metric change error)` | Red | `Set-NetIPInterface` failed — check adapter availability |
| `Failed to set metric for Wi-Fi 2 : ...` | Red | Initial metric setup error at startup |
| `Skipping malformed log row: ...` | Yellow | A corrupted CSV line was skipped during log bootstrap |
| `Loaded 47 previous disconnect intervals.` | Gray | Startup: historical intervals loaded from CSV |
| `Warning: no valid rows found in log, starting fresh` | Yellow | Startup: CSV existed but had no parseable data |
| `Shutting down...` | Yellow | Ctrl+C pressed; cleanup in progress |
| `Restored automatic metrics on Wi-Fi 2 and Wi-Fi 3` | Gray | Metrics restored to automatic on exit |
| `Cleanup complete.` | Green | All resources released; safe to close the window |

## Logging

Disconnects are appended to `disconnect_log.csv` in the script directory:

```
Timestamp,Adapter,IntervalSeconds,Prob,Jitter,Trend,Degraded,Cluster
2026-04-09 14:30:15,Wi-Fi 2,342,0.72,32.5,3.12,False,False
```

Each row captures the CDF probability at the moment of disconnect, the link degradation state (`Jitter`, `Trend`, `Degraded`), and whether the disconnect occurred during a cluster.

- On startup, existing log entries are loaded to bootstrap the interval history. CSV parsing is corruption-tolerant: lines with fewer than 7 fields are silently skipped, and individual malformed lines don't invalidate the entire log.
- `$predictionBaseTime` is **not** pre-set from log history — the main loop establishes it when primary is first observed healthy.
- The `$lastDisconnectTime` fallback in `Write-DisconnectLog` has an age guard: intervals based on pre-startup timestamps are ignored.
- The log is trimmed to `$maxLogLines` every 50 disconnects.

## State Tracking Summary

| Variable | Purpose |
|---|---|
| `$primaryFails` / `$secondaryFails` | Consecutive failure counters for reactive failover |
| `$primaryRecoveredCount` | Consecutive good pings on primary (for recovery threshold) |
| `$predictivelySwapped` | Whether currently in a predictive swap window |
| `$primaryWasHealthy` | Tracks unhealthy-to-healthy transitions for prediction base timing |
| `$previousTickHealthy` | Last tick's health state — detects healthy→unhealthy transitions for centralized disconnect logging |
| `$primaryHealthySince` | When current healthy streak began (bounce filtering for disconnect logging and prediction base anchoring) |
| `$predictionBaseTime` | Anchor for "time since primary became healthy" (debounced). Nulled by `Write-DisconnectLog` |
| `$lastDisconnectTime` | Timestamp of last logged disconnect (fallback for first interval calculation) |
| `$latencyWindow` | Sliding window of recent primary latencies for degradation analysis |
| `$baselineLatencyWindow` | Long-term latency baseline for relative degradation thresholds |
| `$inCluster` | Whether currently in a disconnect burst |
| `$clusterDisconnects` | Count of disconnects in current cluster |
| `$lastClusterEnd` | When the last cluster ended (for cooldown) |
| `$lastSwapTime` | Cooldown enforcement |
