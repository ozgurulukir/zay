[CmdletBinding()]
param(
    [Parameter()]
    [string]$VaxisDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
# Windows PowerShell 5.1 defaults $OutputEncoding to ASCII, so a
# `Get-Content ... | patch` pipe would replace the em-dashes in the guard
# comments with '?'. Emit UTF-8 so the patch reaches patch(1) byte-faithfully.
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$repoRoot = Split-Path -Parent $PSScriptRoot
$patchRoot = Join-Path $repoRoot "tools/vendor-patches"
$manifestPath = Join-Path $patchRoot "manifest.txt"

function Get-ManifestRows {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Vendor patch manifest not found: $manifestPath"
    }

    $rows = @()
    $lineNo = 0
    foreach ($rawLine in Get-Content -LiteralPath $manifestPath -Encoding UTF8) {
        $lineNo++
        $line = $rawLine.Trim()
        if ($line.Length -eq 0 -or $line.StartsWith("#")) {
            continue
        }

        # -split takes a REGEX: the pipe must be escaped ('\|'), otherwise it is
        # an alternation that splits on the empty string (one field per char).
        $fields = @($line -split '\|' | ForEach-Object { $_.Trim() })
        if ($fields.Count -ne 3) {
            throw "Malformed manifest row at ${manifestPath}:$lineNo (expected 3 '|'-separated fields)"
        }
        $patchFile = $fields[0]
        $targetsField = $fields[1]
        $label = $fields[2]
        if ($patchFile.Length -eq 0 -or $targetsField.Length -eq 0 -or $label.Length -eq 0) {
            throw "Malformed manifest row at ${manifestPath}:$lineNo (empty field)"
        }

        $targets = @()
        foreach ($rawPair in ($targetsField -split ',')) {
            $pair = $rawPair.Trim()
            $parts = @($pair -split '=')
            if ($parts.Count -ne 2) {
                throw "Malformed manifest row at ${manifestPath}:$lineNo (expected 'path=count')"
            }
            $targetPath = $parts[0].Trim()
            $countText = $parts[1].Trim()
            $required = 0
            if ($targetPath.Length -eq 0 -or -not [int]::TryParse($countText, [ref]$required)) {
                throw "Malformed manifest row at ${manifestPath}:$lineNo ('$countText' is not a marker count)"
            }
            $targets += [pscustomobject]@{ Path = $targetPath; Required = $required }
        }
        $rows += [pscustomobject]@{ PatchFile = $patchFile; Targets = $targets; Label = $label }
    }
    return $rows
}

function Get-TargetPath {
    param(
        [string]$Directory,
        [string]$RelativePath
    )
    $osRelative = $RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar
    return (Join-Path $Directory $osRelative)
}

function Get-MarkerCount {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 0
    }
    $contents = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return ([regex]::Matches($contents, "ZAY-LOCAL-PATCH")).Count
}

function Resolve-VaxisDirectory {
    param(
        [string]$RequestedPath,
        [object[]]$Rows
    )

    if ($RequestedPath) {
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    # 1. Hash match: the zig-pkg dir name equals build.zig.zon's vaxis .hash.
    $zonPath = Join-Path $repoRoot "build.zig.zon"
    if (Test-Path -LiteralPath $zonPath -PathType Leaf) {
        $zon = Get-Content -LiteralPath $zonPath -Raw -Encoding UTF8
        $match = [regex]::Match($zon, '\.hash = "(vaxis-[^"]+)"')
        if ($match.Success) {
            $hashDir = Join-Path $repoRoot "zig-pkg/$($match.Groups[1].Value)"
            if (Test-Path -LiteralPath $hashDir -PathType Container) {
                return (Resolve-Path -LiteralPath $hashDir).Path
            }
        }
    }

    # 2. Content-signature scan across the local and global package caches.
    $searchRoots = @((Join-Path $repoRoot "zig-pkg"))
    if ($env:ZIG_GLOBAL_CACHE_DIR) {
        $searchRoots += (Join-Path $env:ZIG_GLOBAL_CACHE_DIR "p")
    }
    if ($env:LOCALAPPDATA) {
        $searchRoots += (Join-Path $env:LOCALAPPDATA "zig/p")
    }

    $candidates = @()
    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }
        foreach ($directory in (Get-ChildItem -LiteralPath $root -Directory -Filter "vaxis-*" -ErrorAction SilentlyContinue)) {
            $hasAll = Test-Path -LiteralPath (Join-Path $directory.FullName "src/vaxis.zig") -PathType Leaf
            if ($hasAll) {
                foreach ($row in $Rows) {
                    foreach ($target in $row.Targets) {
                        if (-not (Test-Path -LiteralPath (Get-TargetPath -Directory $directory.FullName -RelativePath $target.Path) -PathType Leaf)) {
                            $hasAll = $false
                            break
                        }
                    }
                    if (-not $hasAll) {
                        break
                    }
                }
            }
            if ($hasAll) {
                $candidates += $directory.FullName
            }
        }
    }

    if ($candidates.Count -eq 0) {
        throw "No fetched vaxis directory was found (scanned repo zig-pkg, ZIG_GLOBAL_CACHE_DIR, LOCALAPPDATA\zig). Run 'zig build --fetch' first, then pass -VaxisDir with the path printed by the build."
    }
    if ($candidates.Count -gt 1) {
        $paths = $candidates -join [Environment]::NewLine
        throw "More than one vaxis directory was found. Re-run with -VaxisDir and choose the dependency path used by the build:`n$paths"
    }
    return $candidates[0]
}

function Remove-StaleRejects {
    param([string]$Directory)
    Get-ChildItem -LiteralPath $Directory -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq ".rej" -or $_.Extension -eq ".orig" } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

function Get-Rejects {
    param([string]$Directory)
    return @(Get-ChildItem -LiteralPath $Directory -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -eq ".rej" })
}

function Assert-NoRejects {
    param(
        [object]$Row,
        [string]$Directory
    )
    # A .rej file means the tree is half-patched: it must never reach final
    # verification and pass it. Hard-fail immediately, before any fallback runs.
    $rejects = @(Get-Rejects -Directory $Directory)
    if ($rejects.Count -eq 0) {
        return
    }
    $paths = ($rejects | ForEach-Object { $_.FullName }) -join [Environment]::NewLine
    throw "Patch '$($Row.PatchFile)' left .rej files - hunks could not be applied:`n$paths`nregeneration recipe: docs/BUILDING.md `"Bumping vaxis`""
}

function Invoke-PatchTool {
    param(
        [string]$PatchPath,
        [string]$TargetDirectory,
        [string]$PatchExecutable
    )
    # Native stderr must not become a terminating error mid-pipeline; capture and
    # display it, then return ONLY the exit code (pipe output would otherwise be
    # folded into the function's return value).
    $oldErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        Get-Content -LiteralPath $PatchPath -Raw -Encoding UTF8 |
            & $PatchExecutable -N -t -F 3 -p1 -d $TargetDirectory 2>&1 |
            ForEach-Object { Write-Host $_ }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorAction
    }
}

function Invoke-GitApply {
    param(
        [string]$PatchPath,
        [string]$TargetDirectory,
        [string[]]$ExtraArgs
    )
    $gitArgs = @("-C", $TargetDirectory, "apply") + $ExtraArgs + @("-p1", "--whitespace=nowarn", $PatchPath)
    $oldErrorAction = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & git @gitArgs 2>&1 | ForEach-Object { Write-Host $_ }
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldErrorAction
    }
}

function Apply-PatchRow {
    param(
        [object]$Row,
        [string]$TargetDirectory,
        [string]$PatchExecutable
    )
    $patchPath = Join-Path $patchRoot $Row.PatchFile
    if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf)) {
        throw "Patch file not found: $patchPath"
    }

    # 1. patch(1): -N (forward, tolerate already-applied), -t (batch, never
    #    prompt), -F 3 (fuzz for a few moved context lines), -p1.
    if ($PatchExecutable) {
        Write-Host "Applying $($Row.PatchFile) with patch ..."
        $exitCode = Invoke-PatchTool -PatchPath $patchPath -TargetDirectory $TargetDirectory -PatchExecutable $PatchExecutable
        Assert-NoRejects -Row $Row -Directory $TargetDirectory
        if ($exitCode -eq 0) {
            return
        }
    }

    # 2. git apply: atomic per file, strictly context-checked. Works outside a repo.
    if (Get-Command git -ErrorAction SilentlyContinue) {
        Write-Host "Applying $($Row.PatchFile) with git apply ..."
        $exitCode = Invoke-GitApply -PatchPath $patchPath -TargetDirectory $TargetDirectory -ExtraArgs @()
        Assert-NoRejects -Row $Row -Directory $TargetDirectory
        if ($exitCode -eq 0) {
            return
        }

        # 3. git apply --3way: needs the patch's `index` blobs, so only for a
        #    vaxis git checkout (the package cache has no .git).
        if (Test-Path -LiteralPath (Join-Path $TargetDirectory ".git")) {
            Write-Host "Applying $($Row.PatchFile) with git apply --3way ..."
            $exitCode = Invoke-GitApply -PatchPath $patchPath -TargetDirectory $TargetDirectory -ExtraArgs @("--3way")
            Assert-NoRejects -Row $Row -Directory $TargetDirectory
            if ($exitCode -eq 0) {
                return
            }
        }
    }

    throw "Could not apply $($Row.PatchFile) to $TargetDirectory. Regeneration recipe: docs/BUILDING.md `"Bumping vaxis`""
}

function Confirm-RowMarkers {
    param(
        [object]$Row,
        [string]$Directory
    )
    foreach ($target in $Row.Targets) {
        $path = Get-TargetPath -Directory $Directory -RelativePath $target.Path
        $found = Get-MarkerCount -Path $path
        if ($found -lt $target.Required) {
            throw "$($Row.Label) verification failed: $path shows $found of $($target.Required) markers."
        }
    }
}

$rows = @(Get-ManifestRows)
if ($rows.Count -eq 0) {
    throw "No patch rows found in $manifestPath"
}

$patchCommand = Get-Command patch.exe -ErrorAction SilentlyContinue
$patchExecutable = $null
if ($patchCommand) {
    $patchExecutable = $patchCommand.Source
}
if (-not $patchExecutable -and -not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "patch.exe was not found. Install Git for Windows or add its usr/bin directory to PATH, then re-run this script."
}

$targetDirectory = Resolve-VaxisDirectory -RequestedPath $VaxisDir -Rows $rows

foreach ($row in $rows) {
    # Stale rejects/backups poison failure detection; the vendor copy is
    # gitignored and regenerable, so drop them before checking or applying.
    Remove-StaleRejects -Directory $targetDirectory

    $alreadyPresent = $true
    $summary = @()
    foreach ($target in $row.Targets) {
        $path = Get-TargetPath -Directory $targetDirectory -RelativePath $target.Path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "The selected vaxis directory is missing '$path'."
        }
        $found = Get-MarkerCount -Path $path
        $summary += "$($target.Path)=$found"
        if ($found -lt $target.Required) {
            $alreadyPresent = $false
        }
    }

    if ($alreadyPresent) {
        Write-Host "$($row.Label) already present ($($summary -join ', '))"
        continue
    }

    Apply-PatchRow -Row $row -TargetDirectory $targetDirectory -PatchExecutable $patchExecutable
    Confirm-RowMarkers -Row $row -Directory $targetDirectory
}

Write-Host "vaxis patches are ready in $targetDirectory"
