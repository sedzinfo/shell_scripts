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

$attention = 0

foreach ($dir in Get-ChildItem -LiteralPath $Folder -Directory) {
  $path = $dir.FullName
  if (-not (Test-Path -LiteralPath (Join-Path $path '.git'))) { continue }
  $branch = git -C $path rev-parse --abbrev-ref HEAD 2> $null
  if (-not $NoFetch) { git -C $path fetch -q 2> $null }

  # each note is its text and its color
  $notes = @()
  $changed = @(git -C $path status --porcelain).Count
  if ($changed -gt 0) { $notes += , @("$changed uncommitted", 'Red') }
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

  Write-Host ('{0,-32} {1,-12} ' -f $dir.Name, $branch) -NoNewline
  if ($notes.Count -eq 0) {
    Write-Host 'clean' -ForegroundColor Green
  } else {
    $attention++
    for ($i = 0; $i -lt $notes.Count; $i++) {
      if ($i -gt 0) { Write-Host ', ' -NoNewline }
      Write-Host $notes[$i][0] -ForegroundColor $notes[$i][1] -NoNewline
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
