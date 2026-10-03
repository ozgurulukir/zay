[CmdletBinding()]
param(
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

if (-not $SkipBuild) {
    & zig build test-plugin
    if ($LASTEXITCODE -ne 0) { throw "zig build test-plugin failed" }

    & zig build test
    if ($LASTEXITCODE -ne 0) { throw "zig build test failed" }
}

$documentationScopes = @("docs/plugins", "plugins")
foreach ($forbidden in @("cp -r", "in_progress")) {
    $matches = & rg --fixed-strings --line-number --glob "*.md" --glob "*.lua" $forbidden @documentationScopes 2>$null
    if ($LASTEXITCODE -eq 0) {
        throw "Forbidden plugin documentation text '$forbidden' remains:`n$($matches -join "`n")"
    }
}

& git diff --check
if ($LASTEXITCODE -ne 0) { throw "git diff --check failed" }

Write-Host "Plugin quality verification passed."
