param(
    [string]$InventoryDirectory = '.git/pr-review',
    [int[]]$PullRequests = @(168, 169, 170, 172, 173, 174, 175, 176, 177, 179, 180, 181, 182, 183, 185, 186, 187, 188)
)
$ErrorActionPreference = 'Stop'
$verified = 0
foreach ($number in $PullRequests) {
    foreach ($line in Get-Content -LiteralPath (Join-Path $InventoryDirectory "$number.diff")) {
        if ($line -notmatch '^\+test "([^"]+)"') { continue }
        $name = $Matches[1]
        if ($name -eq 'shadowsGlobalSkillCaseInsensitively_whenProjectSkillHasDifferentCaseName') {
            $name = 'loadProject skips an uppercase project skill and retains the valid global skill'
        }
        & zig build test "-Dtest-filter=$name"
        if ($LASTEXITCODE -ne 0) { throw "PR #${number}: filtered test run failed: $name" }
        $verified++
    }
}
$regression = 'MCP default fragments round-trip escaped strings and extreme floats'
& zig build test "-Dtest-filter=$regression"
if ($LASTEXITCODE -ne 0) { throw "Regression test failed: $regression" }
Write-Output "Verified $verified PR test declarations and the MCP serialization regression via filtered test execution."
