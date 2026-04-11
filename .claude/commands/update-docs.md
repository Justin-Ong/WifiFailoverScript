# Update Documentation

Sync documentation from source-of-truth (the actual code):

1. Read WifiFix.ps1 config section
   - Extract all configuration variables
   - Document type, default value, and purpose
   - Generate config reference table for README

2. Read WifiFix-Functions.ps1
   - Extract all function signatures
   - Document parameters and return values
   - Verify README function descriptions match

3. Read CSV format from Write-DisconnectLog
   - Document column names and types
   - Verify README CSV documentation matches

4. Read test files
   - Verify documented behavior matches test assertions
   - Identify new features without documentation

5. Update README.md sections:
   - Configuration table
   - Architecture overview
   - Function reference
   - Console output guide

6. Update/create PRPs:
   - Mark completed items
   - Note any behavior changes since PRP was written

7. Show diff summary

Single source of truth: WifiFix.ps1 and WifiFix-Functions.ps1
