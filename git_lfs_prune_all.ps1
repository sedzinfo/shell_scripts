# Frees disk space in every git repository in Documents\GitHub (or the folder given) that
# uses Git LFS. Git LFS keeps in .git\lfs a copy of every version of an LFS file it ever
# downloaded, and git lfs prune deletes the old ones, which only old commits need: GitHub
# keeps every version, and git lfs downloads one again when a checkout needs it. First it
# shows how much each repository would free, and deletes nothing until you answer yes. As
# git lfs prune does, it keeps the files of:
#   - the current checkout, the stashes and the other worktrees
#   - the branches with a commit in the last 10 days
#   - the commits not pushed to origin yet
# Before deleting, git asks origin whether it has the versions that commits still use
# (--verify-remote); if one is missing there, nothing of that repository is deleted.
#   git_lfs_prune_all.ps1 [folder] [repository ...]   every repository, or only the ones named
#   git_lfs_prune_all.ps1 -DryRun                     only shows what would be freed
#   git_lfs_prune_all.ps1 -Yes                        prunes without asking
# Versions that only the reflog still knows (from before a git commit --amend or a rebase)
# are deleted too. A repository with its own LFS storage (lfs.storage), which others may
# share, is skipped. The exit code is 1 if a repository could not be pruned.

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Names,
  [switch]$DryRun,
  [switch]$Yes
)

# the first argument that is an existing folder is the folder, the others are repositories
$Root = $null; $only = @()
foreach ($arg in $Names) {
  if ($arg -like '-*') { Write-Host "Unknown option: $arg"; exit 1 }
  $path = $arg.Trim().Trim('"') -replace '^~', $HOME
  if (-not $Root -and (Test-Path -LiteralPath $path -PathType Container)) {
    $Root = $path
  } else {
    $only += $arg
  }
}

# the folder given, or Documents\GitHub (where GitHub Desktop puts the repositories), or ~\GitHub
if (-not $Root) {
  $Root = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'GitHub'
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { $Root = Join-Path $HOME 'GitHub' }
}
# ask for the folder until one that exists is given (~ works, and the quotes of "Copy as path")
while (-not (Test-Path -LiteralPath $Root -PathType Container)) {
  Write-Host "Folder not found: $Root"
  $Root = Read-Host 'Folder with the repositories (empty to quit)'
  if (-not $Root) { exit 1 }
  $Root = $Root.Trim().Trim('"') -replace '^~', $HOME
}
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')

# anything but y/yes is no
function Test-Yes([string]$question) {
  $answer = Read-Host "$question [y/N]"
  return $answer -match '^\s*y(es)?\s*$'
}

# a size as git lfs gives it, in units of 1000 (126 MB, 5.5 GB)
function Format-Size([double]$bytes) {
  $units = 'B', 'KB', 'MB', 'GB', 'TB'; $i = 0
  while ($bytes -ge 1000 -and $i -lt 4) { $bytes /= 1000; $i++ }
  if ($i -eq 0) { return '{0} B' -f $bytes }
  if ($bytes -lt 10) { return '{0:0.0} {1}' -f $bytes, $units[$i] }
  return '{0:0} {1}' -f $bytes, $units[$i]
}

# the bytes of a size as git lfs gives it (126 MB is 126000000)
function ConvertFrom-LfsSize([string]$text) {
  if ($text -notmatch '^([\d.]+) ([KMGT]?)B$') { return 0 }
  $power = @{ '' = 0; 'K' = 1; 'M' = 2; 'G' = 3; 'T' = 4 }[$Matches[2]]
  return [long]([double]$Matches[1] * [math]::Pow(1000, $power))
}

# the size of a folder and everything in it
function Get-FolderSize([string]$path) {
  return [long](Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
}

# git lfs writes paths in UTF-8; they are read as such, so that a folder with Greek letters
# comes through. The console's setting is put back at the end
$encoding = [Console]::OutputEncoding
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

try {
  $repositories = @(Get-ChildItem -LiteralPath $Root -Directory | Sort-Object Name |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') } |
    Where-Object { $only.Count -eq 0 -or $only -contains $_.Name })
  if ($repositories.Count -eq 0) {
    if ($only.Count -gt 0) { Write-Host "No git repositories named $($only -join ' ') in $Root" } else { Write-Host "No git repositories in $Root" }
    exit 1
  }

  # it comes with Git for Windows
  git lfs version *> $null
  if ($LASTEXITCODE -ne 0) {
    Write-Host 'Missing:'
    Write-Host ('  {0,-14} {1,-26} {2}' -f 'git-lfs', '(Git LFS files)', 'comes with Git for Windows: https://git-scm.com')
    exit 1
  }

  Write-Host "Old Git LFS versions in the repositories of $Root"
  Write-Host '(the local copies in .git\lfs, which git lfs prune deletes; GitHub keeps every version)'
  Write-Host ''

  $to_prune = @(); $total = 0; $nothing = 0; $seen = @{}
  $would = '^prune: (\d+) files? would be pruned \((.*)\), done\.$'
  foreach ($repository in $repositories) {
    $dir = $repository.FullName
    $repo = $repository.Name

    # where git lfs keeps the copies: .git\lfs\objects, or the folder of lfs.storage; a
    # worktree shares that of its repository
    $environment = @(git -C $dir lfs env 2> $null)
    $media = @($environment | Where-Object { $_ -like 'LocalMediaDir=*' })[0]
    $storage = @($environment | Where-Object { $_ -like 'LocalGitStorageDir=*' })[0]
    if (-not $media -or -not $storage) { $nothing++; continue }
    $media = [IO.Path]::GetFullPath($media.Substring('LocalMediaDir='.Length))
    $storage = [IO.Path]::GetFullPath($storage.Substring('LocalGitStorageDir='.Length))
    if (-not (Test-Path -LiteralPath $media -PathType Container) -or
        -not (Get-ChildItem -LiteralPath $media -Recurse -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) {
      $nothing++; continue
    }
    if ($seen.ContainsKey($media)) { continue }
    $seen[$media] = $true
    if ($media -ne [IO.Path]::Combine($storage, 'lfs', 'objects')) {
      Write-Host ('  {0,-24} ' -f $repo) -NoNewline
      Write-Host "skipped: its LFS copies are in $media (lfs.storage), which other repositories may share" -ForegroundColor Yellow
      continue
    }

    # without the remote prune checks (origin), every copy counts as not pushed
    $remote = git -C $dir config --get lfs.pruneremotetocheck
    if (-not $remote) { $remote = 'origin' }
    git -C $dir remote get-url $remote *> $null
    if ($LASTEXITCODE -ne 0) {
      Write-Host ('  {0,-24} kept: no remote named {1}, so git lfs prune keeps every copy' -f $repo, $remote)
      continue
    }

    $line = git -C $dir lfs prune --dry-run 2>&1 | ForEach-Object { "$_" -split "`r" } | Where-Object { $_ -match $would } | Select-Object -Last 1
    if (-not ($line -match $would) -or [int]$Matches[1] -eq 0) { $nothing++; continue }
    $count = [int]$Matches[1]
    $freed = ConvertFrom-LfsSize $Matches[2]
    $versions = if ($count -eq 1) { 'old version' } else { 'old versions' }
    Write-Host ('  {0,-24} {1,9} of {2,9}  ({3} {4})' -f $repo, (Format-Size $freed), (Format-Size (Get-FolderSize $media)), $count, $versions)
    $to_prune += [pscustomobject]@{ Dir = $dir; Repo = $repo; Media = $media }
    $total += $freed
  }

  if ($nothing -gt 0 -and $to_prune.Count -gt 0) { Write-Host "  nothing to free in $nothing other repositories" }
  if ($to_prune.Count -eq 0) {
    Write-Host 'Nothing to free' -ForegroundColor Green
    exit 0
  }
  Write-Host ''
  Write-Host "Total: $(Format-Size $total)"
  if ($DryRun) { Write-Host 'Dry run: nothing is deleted'; exit 0 }
  if (-not $Yes -and -not (Test-Yes 'Delete them? Git asks origin first that it has them')) {
    Write-Host 'Nothing deleted'; exit 0
  }

  $freed_total = 0; $pruned = @(); $failed = @()
  foreach ($item in $to_prune) {
    Write-Host ''
    Write-Host ('#' * 80)
    Write-Host "$($item.Repo)  asking origin, then deleting..."
    $before = Get-FolderSize $item.Media
    $output = @(git -C $item.Dir lfs prune --verify-remote 2>&1 | ForEach-Object { "$_" -split "`r" })
    $status = $LASTEXITCODE
    # the last state of each line of progress
    $output | Where-Object { $_ -match '^prune: .*done\.$' } | ForEach-Object { Write-Host "  $_" }
    if ($status -ne 0) {
      if ($output -match 'missing on remote') {
        Write-Host "  $(@($output -match '^ \* ').Count) versions are not on origin: nothing deleted" -ForegroundColor Red
        Write-Host '    git lfs push --all origin uploads them'
      } else {
        $output | Where-Object { $_ -and $_ -notmatch '^( \* |prune: )' } | Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" }
        Write-Host '  git lfs prune failed: nothing deleted' -ForegroundColor Red
      }
      $failed += $item.Repo
      continue
    }
    $after = Get-FolderSize $item.Media
    Write-Host "  Freed $(Format-Size ($before - $after)): the LFS copies are now $(Format-Size $after)" -ForegroundColor Green
    $freed_total += $before - $after
    $pruned += $item.Repo
  }

  Write-Host ''
  Write-Host ('#' * 80)
  if ($pruned.Count -gt 0) { Write-Host "Freed $(Format-Size $freed_total) in $($pruned -join ' ')" -ForegroundColor Green }
  if ($failed.Count -gt 0) { Write-Host "Not pruned: $($failed -join ' ')" -ForegroundColor Red }
} finally {
  try { [Console]::OutputEncoding = $encoding } catch { }
}
if ($failed.Count -gt 0) { exit 1 }
