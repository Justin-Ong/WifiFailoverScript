# Security Guidelines

## Mandatory Security Checks

Before ANY commit:
- [ ] No hardcoded credentials (WiFi passwords, API keys)
- [ ] No hardcoded IP addresses beyond default gateway patterns
- [ ] Adapter names configurable, not hardcoded in logic
- [ ] No command injection risks in string-built commands
- [ ] CSV log doesn't contain sensitive network information
- [ ] Error messages don't leak internal network topology

## Command Execution Safety

```powershell
# NEVER: Build commands from unvalidated input
Invoke-Expression "ping $userInput"

# ALWAYS: Use direct cmdlet calls with typed parameters
Test-Connection -ComputerName $pingTarget -Count 1

# ALWAYS: Validate adapter names against known adapters
$validAdapters = Get-NetAdapter | Select-Object -ExpandProperty Name
if ($adapterName -notin $validAdapters) {
    Write-Host "Invalid adapter: $adapterName" -ForegroundColor Red
    return
}
```

## Network Interface Safety

- ALWAYS verify adapter exists before setting metrics
- NEVER disable network adapters (only change metrics/priority)
- ALWAYS use `-ErrorAction Stop` with `Set-NetIPInterface` to catch failures
- NEVER assume adapter state; always check before acting

## Sensitive Data

- WiFi passwords must never appear in logs or console output
- Adapter MAC addresses should not be logged
- Network SSIDs are acceptable in diagnostic output only
- CSV disconnect log should contain only: timestamps, adapter names, metrics

## Security Response Protocol

If security issue found:
1. STOP immediately
2. Use **security-reviewer** agent
3. Fix CRITICAL issues before continuing
4. Review entire codebase for similar issues
