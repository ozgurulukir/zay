param(
    [Parameter(Mandatory)][string]$TestExecutable,
    [string]$InventoryDirectory = '.git/pr-review'
)
$ErrorActionPreference = 'Stop'
$binary = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes((Resolve-Path $TestExecutable)))
$integrated = @(168, 169, 170, 172, 173, 174, 175, 176, 177, 179, 180, 181, 182, 183, 185, 186, 187, 188)
$verified = 0
foreach ($number in $integrated) {
    foreach ($line in Get-Content -LiteralPath (Join-Path $InventoryDirectory "$number.diff")) {
        if ($line -notmatch '^\+test "([^"]+)"') { continue }
        $name = $Matches[1]
        if ($name -eq 'shadowsGlobalSkillCaseInsensitively_whenProjectSkillHasDifferentCaseName') {
            $name = 'loadProject skips an uppercase project skill and retains the valid global skill'
        }
        if (-not $binary.Contains($name)) { throw "PR #${number}: test was not compiled: $name" }
        $verified++
    }
}
$regression = 'MCP default fragments round-trip escaped strings and extreme floats'
if (-not $binary.Contains($regression)) { throw "Regression test was not compiled: $regression" }
Write-Output "Verified $verified PR test declarations and the MCP serialization regression in $TestExecutable."
Write-Output 'This proves test reachability; the full suite exit code must separately prove execution succeeded.'
