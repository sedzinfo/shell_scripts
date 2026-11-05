# Pulls every git repository in Documents\GitHub (or the folder given).
# --ff-only: a repository is only moved forward; if it has diverged from GitHub,
# it shows what a reset to GitHub's version would delete and asks; otherwise it
# is skipped (and listed at the end), never merged or rebased.
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

# installs a missing program with winget, without asking (its installer may ask for
# administrator approval). A new program is on the PATH of new windows only: this one gets
# it too. Nothing happens where winget is missing
function Install-Program([string]$package) {
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return }
  Write-Host "Installing $package with winget ..."
  winget install --id $package --exact --source winget --silent --accept-package-agreements --accept-source-agreements
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
}

# git is needed, so without it it stops
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Install-Program 'Git.Git' }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Host 'git is needed: winget install Git.Git'; exit 1
}
$pulled = @(); $current = 0; $failed = @()

foreach ($dir in Get-ChildItem -LiteralPath $Folder -Directory) {
  $path = $dir.FullName
  if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { continue }
  $name = $dir.Name
  # the branch, also in a repository without commits yet
  $branch = git -C $path symbolic-ref -q --short HEAD 2> $null
  if (-not $branch) { $branch = 'HEAD' }
  Write-Host "=== $name ($branch)"

  if ($branch -eq 'HEAD') {
    Write-Host '    detached HEAD, skipped'
    $failed += "${name}: detached HEAD"
    continue
  }
  if (-not (git -C $path config "branch.$branch.merge")) {
    Write-Host '    no upstream branch, skipped'
    $failed += "${name}: no upstream branch"
    continue
  }
  # fetch first, so that a reset is offered only when GitHub could be reached
  git -C $path fetch -q
  if ($LASTEXITCODE -ne 0) {
    $failed += "${name}: fetch failed (no connection?)"
    Write-Host ''
    continue
  }
  git -C $path rev-parse -q --verify '@{u}' *> $null
  if ($LASTEXITCODE -ne 0) {
    Write-Host '    its branch is not on GitHub (deleted there?), skipped'
    $failed += "${name}: its branch is not on GitHub"
    continue
  }

  $before = git -C $path rev-parse -q --verify HEAD 2> $null
  git -C $path -c advice.diverging=false merge --ff-only '@{u}'
  if ($LASTEXITCODE -eq 0) {
    $after = git -C $path rev-parse -q --verify HEAD 2> $null
    if ($after -eq $before) { $current++ } else { $pulled += $name }
  } else {
    # show what a reset would throw away, then ask (anything but y/yes means no)
    Write-Host '    --- local commits that are not on GitHub:'
    git -C $path log --oneline '@{u}..HEAD' | ForEach-Object { "    $_" }
    Write-Host '    --- uncommitted changes:'
    git -C $path status -s --untracked-files=no | ForEach-Object { "    $_" }
    # files git does not track here that GitHub's version has: the reset replaces them with
    # GitHub's. The other untracked files are kept
    $here = New-Object 'System.Collections.Generic.HashSet[string]'
    git -C $path -c core.quotePath=false ls-tree -r --name-only HEAD 2> $null | ForEach-Object { [void]$here.Add($_) }
    $replaced = @(git -C $path -c core.quotePath=false ls-tree -r --name-only '@{u}' |
      Where-Object { -not $here.Contains($_) -and (Test-Path -LiteralPath (Join-Path $path $_)) })
    if ($replaced.Count -gt 0) {
      Write-Host '    --- files git does not track here, which the GitHub version replaces:'
      $replaced | ForEach-Object { Write-Host "    $_" }
    }
    $upstream = git -C $path rev-parse --abbrev-ref '@{u}'
    if (Test-Yes "    git reset --hard ${upstream}? This DELETES the above") {
      git -C $path reset --hard '@{u}'
      if ($LASTEXITCODE -eq 0) { $pulled += "$name (reset --hard)" } else { $failed += $name }
    } else {
      $failed += $name
    }
  }
  Write-Host ''
}

Write-Host '==============================='
Write-Host "Pulled: $($pulled.Count)"
$pulled | ForEach-Object { Write-Host "  $_" }
Write-Host "Already up to date: $current"
if ($failed.Count -gt 0) {
  Write-Host "Not pulled ($($failed.Count)):"
  $failed | ForEach-Object { Write-Host "  $_" }
  exit 1
}
