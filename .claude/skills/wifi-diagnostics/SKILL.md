---
name: wifi-diagnostics
description: WiFi failover decision logic, CDF prediction engine, cluster detection state machine, link degradation algorithm, and diagnostic troubleshooting for dual-adapter watchdog.
---

# WiFi Diagnostics & Failover Patterns

## When to Activate

Use this skill when:
- Working on the failover decision engine
- Debugging connectivity issues
- Modifying prediction or detection algorithms
- Analyzing disconnect patterns
- Tuning threshold parameters

## Failover Decision Matrix

### When Primary is Active

| Condition | Action | Force? | Reason |
|-----------|--------|--------|--------|
| Primary fails health check | Switch to secondary | Yes (bypass cooldown) | Reactive failover |
| CDF prob >= 65% | Switch to secondary | No | Predictive swap |
| CDF prob >= 40% AND degraded | Switch to secondary | No | Degraded predictive |
| Primary healthy | Stay on primary | - | Normal operation |

### When Secondary is Active

| Condition | Action | Force? | Reason |
|-----------|--------|--------|--------|
| Secondary fails | Failback to primary | Yes | Secondary degraded |
| Primary recovered (N good pings) | Failback to primary | No | Recovery detected |
| Elapsed > P90 or maxHold | Failback to primary | No | Predictive return |

### Recovery Thresholds

| State | Good Pings Required |
|-------|-------------------|
| Normal | 10 (`$recoveryThreshold`) |
| During cluster | 20 (10 x 2.0) |
| Post-cluster cooldown | 15 (10 x 1.5) |

## CDF Prediction Engine

### How It Works

The CDF (Cumulative Distribution Function) computes: "Given elapsed uptime T, what fraction of historical intervals were <= T?"

```
P(disconnect by T) = count(intervals <= T) / count(intervals)
```

### Key Properties
- **Outlier-resistant**: Single extreme value shifts tail by only 1/N
- **No tuning constants**: Unlike EMA, no alpha parameter to tune
- **Recency-biased**: Uses last 20 intervals (not all history)
- **Minimum data**: Returns 0.0 with fewer than 3 intervals

### Threshold Interactions
- Normal: swap at 65% CDF probability
- Degraded link: swap at 40% CDF probability
- Post-cluster: swap at min(configured, 40%)

## Cluster Detection

### State Machine

```
CALM → (gap <= 120s, count >= 2) → CLUSTER
CLUSTER → (gap > 120s) → POST_CLUSTER_COOLDOWN (300s)
POST_CLUSTER_COOLDOWN → (elapsed > 300s) → CALM
```

### Behavior Modifications During Cluster

- Hold time: P90 x 2.0
- Max hold: 180s x 2.0 = 360s
- Recovery: 10 x 2.0 = 20 pings
- Post-cluster recovery: 10 x 1.5 = 15 pings

### Rationale

Without clusters: `swap → wait → return → immediate drop → swap` (ping-pong)
With clusters: Stay on secondary through burst, return only when calm confirmed.

## Link Degradation Detection

### Relative Threshold Algorithm

```
baselineJitter = stddev(last 100 latency samples)
effectiveThreshold = max(15ms, baselineJitter x 2.5)

Degraded if:
  jitter > effectiveThreshold  OR  trend > 5ms/tick
```

### Why Relative (Not Fixed)

| Adapter Type | Baseline | Threshold | Spike at 20ms | Result |
|-------------|----------|-----------|---------------|--------|
| Low-jitter (2ms) | 2ms | 15ms | Degraded | Correct - early warning |
| High-jitter (20ms) | 20ms | 50ms | Normal | Correct - no false alarm |

### Baseline Behavior
- Samples: last 100 latencies (long-term window)
- Activation: only after 30+ samples collected
- Persistence: does NOT clear when primary goes down
- Purpose: represents adapter's natural jitter profile

## Data Pipeline

### Interval Tracking

```
$predictionBaseTime set when:
  Primary healthy for >= Get-MinStableInterval()
  AND currently active on primary

Interval = disconnect_time - $predictionBaseTime
  (excludes time spent on secondary)

Only main loop sets $predictionBaseTime (never CSV loading)
```

### Bounce Filter

```
$floor = max($minStableIntervalFloor, median(intervals) x 0.20)

If interval >= floor: add to model (quality data)
If interval < floor: log to CSV but exclude from CDF
```

## Diagnostic Checklist

When debugging unexpected behavior:
1. Is `$predictionBaseTime` being set? (Only by main loop on healthy primary)
2. Are there enough intervals? (Need >= 3 for CDF)
3. Is probe data stale? (> 10s = treated as DOWN)
4. Is bounce filter excluding too many intervals? (Check median)
5. Is cluster mode active? (Doubles hold time and recovery threshold)
6. Is baseline established? (Need >= 30 samples)
7. Is degradation threshold too tight/loose? (Check baseline jitter value)
