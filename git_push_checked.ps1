# Pushes the commits of every git repository in Documents\GitHub (or the folder given) that
# are not on GitHub yet, but first runs R CMD check (r_cmd_check.ps1) on each R package those
# commits change, and pushes a repository only when its packages pass: no errors or warnings
# (with -Strict, no notes either). The check runs on a clean copy of the last commit (a git
# worktree), exactly what would be pushed, so uncommitted or untracked files neither help nor
# spoil it. Nothing is committed.
#   git_push_checked.ps1 [folder] [repository ...]   every repository, or only the ones named
#   git_push_checked.ps1 -DryRun                     checks, but pushes nothing
#   git_push_checked.ps1 -Strict                     notes also stop a push
# Commits that change nothing that goes into a package (only its site in docs\, or other
# files in .Rbuildignore) are pushed without a check. A repository behind GitHub, or without
# an upstream branch, is skipped. The exit code is 1 if any repository with commits to push
# was not pushed.

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Names,
  [switch]$DryRun,
  [switch]$Strict
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

# minutes and seconds since a time
function Get-Duration([datetime]$since) {
  $seconds = [int]((Get-Date) - $since).TotalSeconds
  return '{0}m{1:00}s' -f [math]::Floor($seconds / 60), ($seconds % 60)
}

# a line of the summary: repository, time, result
function Format-Line([string]$repo, [string]$time, [string]$result) {
  return '{0,-32} {1,-10} {2}' -f $repo, $time, $result
}

# the checks are those of r_cmd_check.ps1, which sits next to this script
$checker = Join-Path $PSScriptRoot 'r_cmd_check.ps1'
if (-not (Test-Path -LiteralPath $checker)) {
  Write-Host "r_cmd_check.ps1 is needed next to this script: $checker"; exit 1
}

# the clean copies and the checks' logs; the checks get their own folder, so that they
# never clash with an r_cmd_check.ps1 running at the same time
$cache = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } elseif ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.cache' }
$out = Join-Path $cache 'git_push_checked'
New-Item -ItemType Directory -Path $out -Force | Out-Null

# the clean copy of a repository, removed after each repository and at the end, also after
# Ctrl+C. git removes it, and only as a worktree of that repository
$worktree = $null; $worktree_of = $null
function Remove-Worktree {
  if ($script:worktree) {
    git -C $script:worktree_of worktree remove --force $script:worktree 2> $null
    git -C $script:worktree_of worktree prune 2> $null
  }
  $script:worktree = $null; $script:worktree_of = $null
}

# a regular expression for the lines of a .Rbuildignore (given as lines): R CMD build leaves
# out every path that matches one of them, ignoring case
function Get-IgnoreRegex([string[]]$lines) {
  $patterns = @($lines | Where-Object { $_ -and $_.Trim() } | ForEach-Object { "(?:$_)" })
  return $patterns -join '|'
}

# whether a file (relative to its package folder) goes into the built package: neither it
# nor a folder it is in matches .Rbuildignore. .Rbuildignore itself counts, as it changes
# what is built. A line .NET cannot read as a regular expression leaves the file in
function Test-GoesIntoBuild([string]$regex, [string]$file) {
  if ($file -ceq '.Rbuildignore' -or -not $regex) { return $true }
  $path = ''
  foreach ($part in $file -split '/') {
    $path = if ($path) { "$path/$part" } else { $part }
    try {
      if ([regex]::IsMatch($path, $regex, 'IgnoreCase')) { return $false }
    } catch {
      return $true
    }
  }
  return $true
}

# the result of the check of a package just run: the Status line of its log. r_cmd_check.ps1
# makes the package's folder anew for each check, so an older folder means that this run
# did not check it
function Get-Status([string]$name, [datetime]$since) {
  $work = Join-Path (Join-Path (Join-Path $out 'cache') 'r_cmd_check_all') $name
  if (-not (Test-Path -LiteralPath $work) -or (Get-Item -LiteralPath $work).LastWriteTime -lt $since) {
    return 'not checked'
  }
  $log = Join-Path (Join-Path $work "$name.Rcheck") '00check.log'
  if (-not (Test-Path -LiteralPath $log)) { return 'build failed' }
  $status = Get-Content -LiteralPath $log | Where-Object { $_ -cmatch '^Status: ' } | Select-Object -Last 1
  if ($status) { return $status -creplace '^Status: ', '' }
  return 'check did not finish'
}

# whether a check result lets the push through
function Test-Passes([string]$status) {
  if ($status -ceq 'OK') { return $true }
  if ($status -clike '*ERROR*' -or $status -clike '*WARNING*') { return $false }
  if ($status -clike '*NOTE*') { return -not $Strict }
  return $false
}

# runs r_cmd_check.ps1 on the packages of the clean copy and shows its lines for each
# package, without its summary, with their colors and with the copy's path shown as the
# repository's name; all its lines go to a log
function Invoke-Checker([string]$repo, [string[]]$packages, [string]$log) {
  $saved = $env:XDG_CACHE_HOME
  $env:XDG_CACHE_HOME = Join-Path $out 'cache'
  $skip = $false; $pieces = @(); $logged = New-Object System.Collections.Generic.List[string]
  # Write-Host records the console's color also for a line without one; only the others
  # are shown in color (and not a color some consoles report as -1, "none")
  $default = try { $Host.UI.RawUI.ForegroundColor } catch { $null }
  try {
    # Write-Host writes to stream 6, so 6>&1 passes its lines on; a line written in parts
    # (-NoNewline) is put together before it is shown
    & $checker $script:worktree @packages 6>&1 2>&1 | ForEach-Object {
      $text = "$_"; $color = $null; $continues = $false
      if ($_ -is [System.Management.Automation.InformationRecord] -and
          $_.MessageData -is [System.Management.Automation.HostInformationMessage]) {
        $text = $_.MessageData.Message
        $color = $_.MessageData.ForegroundColor
        $continues = $_.MessageData.NoNewLine
      }
      $pieces += , @($text, $color)
      if ($continues) { return }
      $line = ($pieces | ForEach-Object { $_[0] }) -join ''
      $logged.Add($line)
      if ($line -like '*Summary*') { $skip = $true }
      if (-not $skip -and $line -and $line -notlike 'Checking*' -and $line -notlike '#*') {
        Write-Host '  ' -NoNewline
        foreach ($piece in $pieces) {
          $shown = $piece[0].Replace($script:worktree, $repo)
          $color = $piece[1]
          if ($null -ne $color -and [Enum]::IsDefined([ConsoleColor], $color) -and $color -ne $default) {
            Write-Host $shown -ForegroundColor $color -NoNewline
          } else {
            Write-Host $shown -NoNewline
          }
        }
        Write-Host ''
      }
      $pieces = @()
    }
  } finally {
    if ($null -eq $saved) { Remove-Item Env:XDG_CACHE_HOME -ErrorAction SilentlyContinue } else { $env:XDG_CACHE_HOME = $saved }
  }
  [IO.File]::WriteAllText($log, ($logged -join [Environment]::NewLine) + [Environment]::NewLine)
}

Write-Host "Pushing what is not on GitHub yet in $Root, after checking the R packages it changes"
if ($Strict) { Write-Host 'Strict: notes also stop a push' }
if ($DryRun) { Write-Host 'Dry run: nothing is pushed' }

$not_pushed = @(); $summary = @(); $nothing = 0
try {
  foreach ($folder in Get-ChildItem -LiteralPath $Root -Directory | Sort-Object Name) {
    $dir = $folder.FullName
    if (-not (Test-Path -LiteralPath (Join-Path $dir '.git'))) { continue }
    $repo = $folder.Name
    if ($only.Count -gt 0 -and -not ($only -contains $repo)) { continue }

    $branch = git -C $dir rev-parse --abbrev-ref HEAD 2> $null
    git -C $dir rev-parse --verify -q '@{u}' *> $null
    if ($LASTEXITCODE -ne 0) {
      # without an upstream branch there is nowhere to push to
      $reason = if ($branch -eq 'HEAD') { 'detached HEAD' } else { "no upstream branch (git push -u origin $branch the first time)" }
      $summary += Format-Line $repo '' "skipped: $reason"
      continue
    }
    git -C $dir fetch -q 2> $null
    if ($LASTEXITCODE -ne 0) {
      $not_pushed += $repo; $summary += Format-Line $repo '' 'skipped: fetch failed (no connection?)'
      continue
    }
    $ahead = [int](git -C $dir rev-list --count '@{u}..HEAD')
    $behind = [int](git -C $dir rev-list --count 'HEAD..@{u}')
    if ($ahead -eq 0) { $nothing++; continue }

    Write-Host ''
    Write-Host ('#' * 80)
    $commits = if ($ahead -eq 1) { '1 commit' } else { "$ahead commits" }
    Write-Host "$repo  ($branch, $commits to push)"
    git -C $dir log -n 5 --format='  %h %s' '@{u}..HEAD'
    if ($ahead -gt 5) { Write-Host '  ...' }
    $start = Get-Date
    if ($behind -gt 0) {
      $result = "not pushed: $behind commits on GitHub to pull first (git_pull_all.ps1)"
      Write-Host "  $result" -ForegroundColor Yellow
      $not_pushed += $repo; $summary += Format-Line $repo '' $result
      continue
    }
    $uncommitted = @(git -C $dir status --porcelain).Count
    if ($uncommitted -gt 0) { Write-Host "  $uncommitted uncommitted files stay here: they are neither checked nor pushed" }

    # the R packages in the last commit whose built package the new commits change
    $changed = @(git -C $dir diff --name-only --no-renames '@{u}' HEAD)
    $packages = @()
    foreach ($description in @(git -C $dir ls-tree -r --name-only HEAD | Where-Object { $_ -cmatch '^([^/]+/)?DESCRIPTION$' })) {
      $prefix = $description.Substring(0, $description.Length - 'DESCRIPTION'.Length)
      $name = git -C $dir show "HEAD:$description" | Where-Object { $_ -match '^Package:\s*(.*?)\s*$' } |
        Select-Object -First 1 | ForEach-Object { $_ -replace '^Package:\s*(.*?)\s*$', '$1' }
      if (-not $name) { continue }
      $regex = Get-IgnoreRegex @(git -C $dir show "HEAD:${prefix}.Rbuildignore" 2> $null)
      foreach ($file in $changed) {
        if (-not ($file.StartsWith($prefix) -and $file.Length -gt $prefix.Length)) { continue }
        if (Test-GoesIntoBuild $regex $file.Substring($prefix.Length)) { $packages += $name; break }
      }
    }

    $checked = ''
    if ($packages.Count -gt 0) {
      Write-Host "  checking $($packages -join ' ') on a clean copy of the last commit"
      $suffix = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
      $worktree = Join-Path $out "$repo.$suffix"; $worktree_of = $dir
      $worktree_log = Join-Path $out "$repo.worktree.log"
      $output = git -C $dir worktree add --detach -q $worktree HEAD 2>&1 | ForEach-Object { "$_" }
      if ($LASTEXITCODE -ne 0) {
        [IO.File]::WriteAllText($worktree_log, (@($output) -join [Environment]::NewLine) + [Environment]::NewLine)
        $result = "not pushed: could not make a clean copy ($worktree_log)"
        Write-Host "  $result" -ForegroundColor Red
        Remove-Worktree
        $not_pushed += $repo; $summary += Format-Line $repo (Get-Duration $start) $result
        continue
      }
      # the copy has a .git file where a repository has a .git folder. R CMD build always
      # leaves the folder out, but not the file, which R CMD check then notes as a hidden
      # file; the copy's .Rbuildignore leaves it out
      $ignore = Join-Path $worktree '.Rbuildignore'
      if ((Test-Path -LiteralPath $ignore) -and -not ([IO.File]::ReadAllText($ignore)).EndsWith("`n") -and (Get-Item -LiteralPath $ignore).Length -gt 0) {
        [IO.File]::AppendAllText($ignore, "`n")
      }
      [IO.File]::AppendAllText($ignore, "^\.git`$`n")
      # r_cmd_check.ps1's lines for each package, without its summary
      $check_start = Get-Date
      Invoke-Checker $repo $packages (Join-Path $out "$repo.check.log")
      Remove-Worktree
      $failing = @(); $results = @()
      foreach ($name in $packages) {
        $status = Get-Status $name $check_start
        $results += "$name $status"
        if (-not (Test-Passes $status)) { $failing += "$name $status" }
      }
      $checked = " (checked: $($results -join ', '))"
      if ($failing.Count -gt 0) {
        $result = "not pushed: $($failing -join ', ')"
        Write-Host "  $result" -ForegroundColor Red
        $not_pushed += $repo; $summary += Format-Line $repo (Get-Duration $start) $result
        continue
      }
    } else {
      $checked = ' (no R package changed)'
    }

    $push_log = Join-Path $out "$repo.push.log"
    if ($DryRun) {
      $result = "would push$checked"
      Write-Host "  $result" -ForegroundColor Green
    } else {
      $output = git -C $dir push -q 2>&1 | ForEach-Object { "$_" }
      $status = $LASTEXITCODE
      [IO.File]::WriteAllText($push_log, (@($output) -join [Environment]::NewLine) + [Environment]::NewLine)
      if ($status -eq 0) {
        $result = "pushed$checked"
        Write-Host "  $result" -ForegroundColor Green
      } else {
        $result = "push failed (see $push_log)"
        Write-Host "  $result" -ForegroundColor Red
        @($output) | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" }
        $not_pushed += $repo
      }
    }
    $summary += Format-Line $repo (Get-Duration $start) $result
  }
} finally {
  Remove-Worktree
}

Write-Host ''
Write-Host ('#' * 80)
Write-Host 'Summary'
$summary | ForEach-Object { Write-Host "  $_" }
Write-Host "  Nothing to push in $nothing repositories"
if ($not_pushed.Count -gt 0) {
  Write-Host "Not pushed: $($not_pushed -join ' ')" -ForegroundColor Red
  exit 1
}
exit 0
