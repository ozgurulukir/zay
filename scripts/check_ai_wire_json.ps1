$ErrorActionPreference = "Stop"

$repo_root = Split-Path -Parent $PSScriptRoot
Push-Location $repo_root
try {
    & zig test src/ai/json.zig
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    & zig build test -Dtest-filter="invalid"
    exit $LASTEXITCODE
}
finally {
    Pop-Location
}
