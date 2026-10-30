# Pulls every git repository in Documents\GitHub (or the folder given).
# --ff-only: a repository is only moved forward; if it has diverged from GitHub
# it is skipped (and listed at the end) instead of being merged or rebased.
#   git_pull_all.ps1 [folder]

param(
  [string]$Folder
)

# anything but y/yes is no
function Test-Yes([string]$question) {
  $answer = Read-Host "$question [y/N]"
  return $answer -match '^\s*y(es)?\s*$'
}

# the folder given, or Documents\GitHub (where GitHub Desktop puts the repositories), or ~\GitHub
if (-not $Folder) {
  $Folder = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'GitHub'
  if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { $Folder = Join-Path $HOME 'GitHub' }
}
# ask for the folder until one that exists is given (~ works, and the quotes of "Copy as path")
while (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
  Write-Host "Folder not found: $Folder"
  $Folder = Read-Host 'Folder with the repositories (empty to quit)'
  if (-not $Folder) { exit 1 }
  $Folder = $Folder.Trim().Trim('"') -replace '^~', $HOME
}
$ok = @(); $failed = @()

foreach ($dir in Get-ChildItem -LiteralPath $Folder -Directory) {
  $path = $dir.FullName
  if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { continue }
  $name = $dir.Name
  $branch = git -C $path rev-parse --abbrev-ref HEAD
  Write-Host "=== $name ($branch)"

  if ($branch -eq 'HEAD') {
    Write-Host '    detached HEAD, skipped'
    $failed += "${name}: detached HEAD"
    continue
  }

  git -C $path pull --ff-only
  if ($LASTEXITCODE -eq 0) {
    $ok += $name
  } else {
    git -C $path rev-parse --verify -q '@{u}' *> $null
    if ($LASTEXITCODE -eq 0) {
      # show what a reset would throw away, then ask (anything but y/yes means no)
      Write-Host '    --- local commits that are not on GitHub:'
      git -C $path log --oneline '@{u}..HEAD' | ForEach-Object { "    $_" }
      Write-Host '    --- uncommitted changes:'
      git -C $path status -s | ForEach-Object { "    $_" }
      $upstream = git -C $path rev-parse --abbrev-ref '@{u}'
      if (Test-Yes "    git reset --hard ${upstream}? This DELETES the above") {
        git -C $path reset --hard '@{u}'
        if ($LASTEXITCODE -eq 0) { $ok += "$name (reset --hard)" } else { $failed += $name }
      } else {
        $failed += $name
      }
    } else {
      $failed += "${name}: no upstream branch"
    }
  }
  Write-Host ''
}

Write-Host '==============================='
Write-Host "Pulled: $($ok.Count)"
if ($failed.Count -gt 0) {
  Write-Host "Not pulled ($($failed.Count)):"
  $failed | ForEach-Object { Write-Host "  $_" }
  exit 1
}
