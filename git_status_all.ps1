# One line per git repository in Documents\GitHub (or the folder given): what is not yet
# on GitHub. Nothing is changed; the remote branches are fetched first so the counts are
# up to date (add -NoFetch to skip that, e.g. without internet).
#   git_status_all.ps1 [folder] [-NoFetch]

param(
  [string]$Folder,
  [switch]$NoFetch
)

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

$attention = 0

foreach ($dir in Get-ChildItem -LiteralPath $Folder -Directory) {
  $path = $dir.FullName
  if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { continue }
  # the branch, also in a repository without commits yet
  $branch = git -C $path symbolic-ref -q --short HEAD 2> $null
  if (-not $branch) { $branch = 'HEAD' }

  # each note is its text and its color
  $notes = @()
  if (-not $NoFetch) {
    git -C $path fetch -q 2> $null
    if ($LASTEXITCODE -ne 0) { $notes += , @('not fetched', 'Yellow') }
  }
  $changed = @(git -C $path status --porcelain).Count
  if ($changed -gt 0) {
    # the date of the uncommitted file changed last: the files inside new folders too, not
    # deleted files (they have no date), and the new name of a renamed file. Read as UTF-8,
    # so that names with Greek or other letters are found
    $encoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [Text.Encoding]::UTF8
    $raw = (git -C $path status --porcelain -z --untracked-files=all) -join ''
    [Console]::OutputEncoding = $encoding
    $entries = $raw -split "`0"
    $latest = $null
    for ($i = 0; $i -lt $entries.Count; $i++) {
      $entry = $entries[$i]
      if ($entry.Length -lt 4) { continue }
      $state = $entry.Substring(0, 2)
      $file = Join-Path $path $entry.Substring(3)
      if ($state -match '^[RC]') { $i++ } # the next entry is the old name of a rename
      $item = Get-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
      if ($item -and (-not $latest -or $item.LastWriteTime -gt $latest)) { $latest = $item.LastWriteTime }
    }
    $when = if ($latest) { ' (latest {0})' -f $latest.ToString('dd/MM/yyyy HH:mm') } else { '' }
    # the third element is printed after the note, in the normal color
    $notes += , @("$changed uncommitted", 'Red', $when)
  }
  git -C $path rev-parse --verify -q '@{u}' *> $null
  if ($LASTEXITCODE -eq 0) {
    $ahead = [int](git -C $path rev-list --count '@{u}..HEAD')
    $behind = [int](git -C $path rev-list --count 'HEAD..@{u}')
    if ($ahead -gt 0) { $notes += , @("$ahead to push", 'Red') }
    if ($behind -gt 0) { $notes += , @("$behind to pull", 'Yellow') }
  } elseif ($branch -eq 'HEAD') {
    $notes += , @('detached HEAD', 'Yellow')
  } else {
    $notes += , @('no upstream branch', 'Yellow')
  }
  # the other branches with commits that are on no branch of GitHub, and the stashes
  $others = 0
  foreach ($ref in @(git -C $path for-each-ref --format='%(refname)' refs/heads)) {
    if ($ref -ceq "refs/heads/$branch") { continue }
    if ([int](git -C $path rev-list --count $ref --not --remotes) -gt 0) { $others++ }
  }
  if ($others -eq 1) { $notes += , @('1 other branch not on GitHub', 'Red') }
  if ($others -gt 1) { $notes += , @("$others other branches not on GitHub", 'Red') }
  $stashes = @(git -C $path stash list).Count
  if ($stashes -gt 0) { $notes += , @("$stashes stashed", 'Red') }

  Write-Host ('{0,-32} {1,-12} ' -f $dir.Name, $branch) -NoNewline
  if ($notes.Count -eq 0) {
    Write-Host 'clean' -ForegroundColor Green
  } else {
    $attention++
    for ($i = 0; $i -lt $notes.Count; $i++) {
      if ($i -gt 0) { Write-Host ', ' -NoNewline }
      Write-Host $notes[$i][0] -ForegroundColor $notes[$i][1] -NoNewline
      if ($notes[$i].Count -gt 2) { Write-Host $notes[$i][2] -NoNewline }
    }
    Write-Host ''
  }
}

Write-Host ''
if ($attention -eq 0) {
  Write-Host 'Everything is on GitHub' -ForegroundColor Green
} else {
  Write-Host "$attention repositories need attention"
}
