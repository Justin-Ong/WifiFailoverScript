# Performance Optimization

## Model Selection Strategy

**Haiku 4.5** (90% of Sonnet capability, 3x cost savings):
- Lightweight agents with frequent invocation
- Simple code reviews and single-function changes
- Quick test generation

**Sonnet 4.6** (Best coding model):
- Main development work
- Multi-file changes
- Complex debugging

**Opus 4.6** (Deepest reasoning):
- Complex algorithmic decisions (CDF engine, cluster detection)
- Architecture planning for new prediction features
- Multi-agent orchestration

## Context Window Management

Avoid last 20% of context window for:
- Multi-function refactoring across WifiFix.ps1 and WifiFix-Functions.ps1
- Feature implementation spanning main script and tests
- Debugging background runspace interactions

Lower context sensitivity tasks:
- Single function edits in WifiFix-Functions.ps1
- Adding test assertions to existing test files
- Documentation updates
- PRP writing

## Script Performance Considerations

When modifying the main loop or background probes:
- Main loop runs every 0.5s - keep operations fast
- Background pings run in separate runspaces - avoid blocking
- `$intervals` list operations should use `.GetRange()` not LINQ
- Latency windows (20 samples) and baseline windows (100 samples) are deliberately sized
- Log trimming happens every 50 disconnects to amortize I/O cost

## Debugging Tips

If script behavior is unexpected:
1. Check `$staleProbeThreshold` - probes older than 10s are treated as DOWN
2. Check `$minDataPoints` - CDF returns 0.0 with fewer than 3 intervals
3. Check `Get-MinStableInterval` - bounces below floor are excluded from model
4. Verify `$predictionBaseTime` is being set correctly by main loop
5. Run individual test suites to isolate which feature area is affected
