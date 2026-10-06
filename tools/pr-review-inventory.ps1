param([string]$OutputDirectory = '.git/pr-review')
$ErrorActionPreference = 'Stop'
$repository = 'ozgurulukir/zay'
$origin = git remote get-url origin
if ($LASTEXITCODE -ne 0 -or $origin -notmatch 'github\.com[:/]ozgurulukir/zay(?:\.git)?$') {
    throw 'origin must resolve to ozgurulukir/zay before reviewing PRs.'
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$inventory = gh pr list --repo $repository --state open --limit 100 --json number,title,headRefName,headRefOid,baseRefName,mergeable,mergeStateStatus,statusCheckRollup,url
if ($LASTEXITCODE -ne 0) { throw 'Failed to read PR inventory.' }
$inventory | Set-Content -LiteralPath (Join-Path $OutputDirectory 'inventory.json')
foreach ($pull in ($inventory | ConvertFrom-Json)) {
    $diff = gh pr diff $pull.number --repo $repository
    if ($LASTEXITCODE -ne 0) { throw "Failed to read PR #$($pull.number)." }
    $diff | Set-Content -LiteralPath (Join-Path $OutputDirectory "$($pull.number).diff")
    Write-Output "#$($pull.number): $($pull.title) [$($pull.mergeStateStatus)]"
}
