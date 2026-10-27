# Parse every PowerShell script in the repo and fail on syntax errors.
# Run with: pwsh -NoProfile -File tests/lint-ps1.ps1
$root = Split-Path -Parent $PSScriptRoot
$failed = 0
Get-ChildItem -Path $root -Recurse -Filter '*.ps1' | ForEach-Object {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors) {
        $failed++
        $errors | ForEach-Object { Write-Host "$($_.Extent.File):$($_.Extent.StartLineNumber): $($_.Message)" }
    } else {
        Write-Host "ok  $($_.FullName.Substring($root.Length + 1))"
    }
}
exit $failed
