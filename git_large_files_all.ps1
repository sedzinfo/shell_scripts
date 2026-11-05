# Finds the large files in every git repository in Documents\GitHub (or the folder given),
# before GitHub refuses them: it warns about a file over 50 MB, and refuses a push with a file
# over 100 MB, even one deleted again in a later commit. Nothing is changed. For each
# repository it lists:
#   - files over 100 MB in commits not yet on GitHub, which make the push fail
#   - files over the size (50 MB) without Git LFS, committed or not yet
#   - files that .gitattributes puts in LFS but that were committed without it
#   - LFS files whose content was never downloaded (git lfs pull fetches them)
#   git_large_files_all.ps1 [folder] [repository ...]   every repository, or only the ones named
#   git_large_files_all.ps1 -Size 20M                   also smaller files (default 50M)
#   git_large_files_all.ps1 -History                    also the largest files ever committed,
#                                                       which .git keeps after they are deleted
# The exit code is 1 if GitHub would refuse a push (or a commit of a file as it is now).

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Names,
  [string]$Size = '50M',
  [switch]$History
)

# the folder is given as a path (~\GitHub, ., ..\work, C:\work): a plain word is a
# repository, as a repository's name may also be a folder here
$Root = $null; $only = @()
foreach ($arg in $Names) {
  if ($arg -like '-*') { Write-Host "Unknown option: $arg"; exit 1 }
  $path = $arg.Trim().Trim('"') -replace '^~', $HOME
  if (-not $Root -and ($arg -match '[\\/]|^[A-Za-z]:' -or $arg -in '~', '.', '..')) {
    $Root = $path
  } else {
    $only += $arg
  }
}
$units = @{ '' = 1; 'K' = 1KB; 'M' = 1MB; 'G' = 1GB; 'T' = 1TB }
if ($Size -notmatch '^\s*(\d+(?:\.\d+)?)\s*([KMGTkmgt]?)(i?B)?\s*$' -or
    ($min = [long]([double]$Matches[1] * $units[$Matches[2].ToUpper()])) -lt 1) {
  Write-Host "-Size takes a size such as 20M or 50M, not: $Size"; exit 1
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

# GitHub refuses a push with a file over 100 MB (100 MiB)
$limit = 100MB

# a size in MB, as GitHub gives its limits (130.2 MB), or in KB below 1 MB, or in GB
function Format-Size([double]$bytes) {
  if ($bytes -lt 1MB) { return '{0} KB' -f [math]::Ceiling($bytes / 1KB) }
  if ($bytes -ge 1GB) { return '{0:0.0} GB' -f ($bytes / 1GB) }
  return '{0:0.0} MB' -f ($bytes / 1MB)
}

# the size of a folder and everything in it; nothing when there is no such folder
function Get-FolderSize([string]$path) {
  if (-not (Test-Path -LiteralPath $path -PathType Container)) { return $null }
  return (Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
}

# the output of git with -z: its entries, which end in a NUL character
function Split-Nul($output) {
  return @((@($output) -join "`n") -split "`0" | Where-Object { $_ })
}

# whether a repository puts files in LFS: a .gitattributes of it has filter=lfs
function Test-UsesLfs([string]$dir) {
  foreach ($file in Split-Nul (git -C $dir ls-files -z -- '*.gitattributes' 2> $null)) {
    $path = [IO.Path]::Combine($dir, $file)
    if ((Test-Path -LiteralPath $path) -and (Select-String -LiteralPath $path -Pattern 'filter=lfs' -SimpleMatch -Quiet)) { return $true }
  }
  return $false
}

# the files of a list that .gitattributes puts in LFS, asked of git 100 at a time (a
# command line has a length limit)
function Select-LfsPaths([string]$dir, [string[]]$paths) {
  for ($i = 0; $i -lt $paths.Count; $i += 100) {
    $batch = $paths[$i..([math]::Min($i + 99, $paths.Count - 1))]
    $answer = Split-Nul (git -C $dir check-attr -z filter -- @batch 2> $null)
    for ($j = 0; $j + 2 -lt $answer.Count; $j += 3) {
      if ($answer[$j + 2] -eq 'lfs') { $answer[$j] }
    }
  }
}

# the blobs of a repository of at least the size, by their id, with their size: git lists
# every object it has with its size, which needs nothing piped into git
function Get-LargeBlobs([string]$dir) {
  $sizes = @{}
  foreach ($line in git -C $dir cat-file --batch-all-objects '--batch-check=%(objecttype) %(objectname) %(objectsize)' 2> $null) {
    $type, $sha, $bytes = $line -split ' '
    if ($type -eq 'blob' -and [long]$bytes -ge $min) { $sizes[$sha] = [long]$bytes }
  }
  return $sizes
}

# git writes paths in UTF-8; they are read as such, so that names with Greek letters come
# through. The console's setting is put back at the end
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

  # git lfs is needed only where a repository uses LFS; without it the LFS files that were
  # never downloaded are not looked for. It comes with Git for Windows
  git lfs version *> $null
  $lfs = $LASTEXITCODE -eq 0
  if (-not $lfs -and ($repositories | Where-Object { Test-UsesLfs $_.FullName } | Select-Object -First 1)) {
    Write-Host 'Missing:'
    Write-Host ('  {0,-14} {1,-26} {2}' -f 'git-lfs', '(Git LFS files)', 'comes with Git for Windows: https://git-scm.com')
  }

  Write-Host "Files over $(Format-Size $min) in the repositories of $Root"
  Write-Host '(GitHub warns about a file over 50 MB and refuses a push with one over 100 MB)'

  $refused_repos = @(); $warned_repos = @(); $pointer_repos = @(); $clean = 0
  foreach ($repository in $repositories) {
    $dir = $repository.FullName
    $repo = $repository.Name
    $branch = git -C $dir rev-parse --abbrev-ref HEAD 2> $null
    $findings = @(); $hints = @{}; $refused = $false; $warned = $false; $lfs_note = $null; $biggest = @()
    $seen = @{}
    $large = Get-LargeBlobs $dir

    # files in the commits that are on no remote yet, which a push would send
    if ($large.Count -gt 0) {
      foreach ($line in git -C $dir rev-list --objects HEAD --not --remotes 2> $null) {
        $sha, $path = $line -split ' ', 2
        if (-not $path -or -not $large.ContainsKey($sha)) { continue }
        $bytes = $large[$sha]
        $seen[$path] = $true
        $commit = git -C $dir log --reverse --format=%h "--find-object=$sha" HEAD --not --remotes 2> $null | Select-Object -First 1
        $hints[1] = 'git lfs migrate import --include=FILE puts a file in LFS, rewriting only the commits not pushed yet'
        if ($bytes -gt $limit) {
          $findings += [pscustomobject]@{ Bytes = $bytes; Path = $path; Color = 'Red'; Note = "in commit $commit, not pushed yet: GitHub refuses the push" }
          $refused = $true
        } else {
          $findings += [pscustomobject]@{ Bytes = $bytes; Path = $path; Color = 'Yellow'; Note = "in commit $commit, not pushed yet, not in LFS: GitHub warns" }
          $warned = $true
        }
      }
    }

    # files in the folder, committed or that git add would add (not the ignored ones), that
    # are not in LFS
    foreach ($path in Split-Nul (git -C $dir ls-files -z --cached --others --exclude-standard 2> $null)) {
      if ($seen.ContainsKey($path)) { continue }
      $file = [IO.FileInfo]::new([IO.Path]::Combine($dir, $path))
      if (-not $file.Exists -or $file.Length -lt $min) { continue }
      if (Select-LfsPaths $dir @($path)) { continue }
      $seen[$path] = $true
      git -C $dir ls-files --error-unmatch -- $path *> $null
      if ($LASTEXITCODE -eq 0) {
        $state = 'in git, not in LFS'
        $hints[2] = 'git lfs migrate import --no-rewrite FILE moves a committed file to LFS in a new commit (older commits keep it)'
      } else {
        $state = 'not committed yet, not in LFS'
        $hints[3] = 'git lfs track FILE, before git add, puts a new file in LFS; or .gitignore leaves it out'
      }
      if ($file.Length -gt $limit) {
        $findings += [pscustomobject]@{ Bytes = $file.Length; Path = $path; Color = 'Red'; Note = "${state}: GitHub would refuse it" }
        $refused = $true
      } else {
        $findings += [pscustomobject]@{ Bytes = $file.Length; Path = $path; Color = 'Yellow'; Note = "${state}: GitHub warns" }
        $warned = $true
      }
    }

    if (Test-UsesLfs $dir) {
      # files .gitattributes puts in LFS but committed as they are: in a commit an LFS file is
      # a pointer of about 130 bytes, so a larger one is the file itself
      $blob_size = @{}
      foreach ($record in Split-Nul (git -C $dir ls-tree -r -l -z HEAD 2> $null)) {
        $meta, $path = $record -split "`t", 2
        $bytes = ($meta -split ' +')[-1]
        if ($bytes -match '^\d+$' -and [long]$bytes -gt 1024 -and -not $seen.ContainsKey($path)) { $blob_size[$path] = [long]$bytes }
      }
      foreach ($path in Select-LfsPaths $dir @($blob_size.Keys)) {
        $findings += [pscustomobject]@{ Bytes = $blob_size[$path]; Path = $path; Color = 'Yellow'; Note = 'in LFS by .gitattributes, but committed without it' }
        $hints[4] = 'git lfs migrate import --no-rewrite FILE moves it to LFS in a new commit (committed before git lfs install?)'
        $warned = $true
      }

      # LFS files whose content was never downloaded: only their pointer is here
      if ($lfs) {
        $pointers = @(git -C $dir lfs ls-files 2> $null | Where-Object { $_ -match '^\S+ - ' } | ForEach-Object { $_ -replace '^\S+ - ', '' })
        if ($pointers.Count -gt 0) {
          $files = if ($pointers.Count -eq 1) { 'LFS file' } else { 'LFS files' }
          $lfs_note = "$($pointers.Count) $files not downloaded, e.g. $($pointers[0]) (git lfs pull fetches them)"
          $pointer_repos += $repo
        }
      }
    }

    # the largest files of the whole history, which make .git big even when deleted: per
    # file its versions over the size, added up
    if ($History -and $large.Count -gt 0) {
      $totals = @{}; $versions = @{}
      foreach ($line in git -C $dir rev-list --objects --all 2> $null) {
        $sha, $path = $line -split ' ', 2
        if (-not $path -or -not $large.ContainsKey($sha)) { continue }
        $totals[$path] += $large[$sha]; $versions[$path] += 1
      }
      $biggest = @($totals.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5)
    }
    # and the local copies of old LFS versions, which git lfs prune deletes (GitHub keeps
    # them); git lfs says how much it would free
    $prune_note = $null
    if ($History -and $lfs -and (Test-Path -LiteralPath (Join-Path (Join-Path $dir '.git') 'lfs') -PathType Container)) {
      # git-lfs before 3.5 starts the line with "prune: "
      $pruned = '^(?:prune: )?(\d+) files? would be pruned \((.*)\), done\.$'
      $line = git -C $dir lfs prune --dry-run 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } } | Where-Object { $_ -match $pruned } | Select-Object -Last 1
      if ($line -match $pruned -and [int]$Matches[1] -gt 0) {
        $prune_note = "git lfs prune would free $($Matches[2]): the local copies of $($Matches[1]) old LFS versions (GitHub keeps them)"
      }
    }

    if ($refused) { $refused_repos += $repo } elseif ($warned) { $warned_repos += $repo }
    if ($findings.Count -eq 0 -and -not $lfs_note) {
      $clean++
      if ($biggest.Count -eq 0 -and -not $prune_note) { continue }
    }

    Write-Host ''
    Write-Host ('#' * 80)
    Write-Host "$repo  ($branch)"
    foreach ($finding in $findings | Sort-Object Bytes -Descending) {
      Write-Host ('  {0,10}  {1,-44} ' -f (Format-Size $finding.Bytes), $finding.Path) -NoNewline
      Write-Host $finding.Note -ForegroundColor $finding.Color
    }
    if ($lfs_note) { Write-Host "  $lfs_note" }
    foreach ($key in $hints.Keys | Sort-Object) { Write-Host "    $($hints[$key])" }
    if ($biggest.Count -gt 0 -or $prune_note) {
      $git_dir = Join-Path $dir '.git'
      $lfs_cache = Get-FolderSize (Join-Path $git_dir 'lfs')
      $sizes = "  .git is $(Format-Size (Get-FolderSize $git_dir)): $(Format-Size (Get-FolderSize (Join-Path $git_dir 'objects'))) of commits"
      if ($lfs_cache) { $sizes += ", $(Format-Size $lfs_cache) of LFS copies" }
      Write-Host $sizes
    }
    if ($biggest.Count -gt 0) {
      Write-Host '  largest files ever committed:'
      foreach ($entry in $biggest) {
        $name = if ($versions[$entry.Key] -gt 1) { "$($entry.Key)  ($($versions[$entry.Key]) versions)" } else { $entry.Key }
        Write-Host ('  {0,10}  {1}' -f (Format-Size $entry.Value), $name)
      }
      Write-Host '    taking them out of .git means rewriting the history (git filter-repo), which changes every commit since'
    }
    if ($prune_note) { Write-Host "    $prune_note" }
  }

  Write-Host ''
  Write-Host ('#' * 80)
  if ($refused_repos.Count -gt 0) { Write-Host "GitHub would refuse: $($refused_repos -join ' ')" -ForegroundColor Red }
  if ($warned_repos.Count -gt 0) { Write-Host "Files over $(Format-Size $min) without LFS: $($warned_repos -join ' ')" -ForegroundColor Yellow }
  if ($pointer_repos.Count -gt 0) { Write-Host "LFS files not downloaded: $($pointer_repos -join ' ')" }
  if ($clean -gt 0) { Write-Host "No large files in $clean of $($repositories.Count) repositories" -ForegroundColor Green }
} finally {
  try { [Console]::OutputEncoding = $encoding } catch { }
}
if ($refused_repos.Count -gt 0) { exit 1 }
exit 0
