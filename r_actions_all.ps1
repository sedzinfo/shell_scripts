# Did the latest build and check of every R package on GitHub Actions go fine? For each R
# package in Documents\GitHub (or the folder given), the latest run of the workflows of its
# repository that build or check it, told apart by what they run:
#   build   R CMD build: the source tarball (build-tarball.yml)
#   check   R CMD check, with the tests (R-CMD-check.yaml, r.yml)
# Only the runs of the default branch (main) count, not those of other branches or of pull
# requests. One line per package, with the result of each and when it started:
#   success                          it went fine
#   failure, cancelled, timed_out    shown with the job and step that failed, and the link
#   in_progress, queued              still running: run this again in a few minutes
#   no runs on main                  never ran there (its on: may name another branch)
#   no workflow                      the repository has none that builds, or checks
#   r_actions_all.ps1 [folder] [package ...]   every package, or only the ones named
# A package is a folder with a DESCRIPTION: a repository, or a folder in one (rwf\rwf). The
# folder is given as a path (~\GitHub, ., ..\work, C:\work): a plain word is a package.
# The token is $env:GITHUB_TOKEN, else the GitHub CLI's when it is logged in (gh auth login).
# Without one only public repositories are seen, and GitHub allows 60 requests an hour,
# about 3 per package. Nothing is changed. The exit code is 1 when a latest run failed or
# was cancelled, a workflow has no runs on main, or GitHub could not be asked.

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Names
)

# installs the programs this script needs, when they are missing, with winget and without
# asking (an installer may ask for administrator approval). Each argument is
# program:package:what it is for. Where winget is missing it only says what to install
function Install-Missing {
  $packages = @(); $lines = @()
  foreach ($entry in $args) {
    $program, $package, $purpose = $entry -split ':', 3
    if (-not (Get-Command $program -ErrorAction SilentlyContinue)) {
      $packages += $package
      $lines += '{0,-14} {1,-26} package {2}' -f $program, "($purpose)", $package
    }
  }
  if ($packages.Count -eq 0) { return }
  Write-Host 'Missing:'
  $lines | ForEach-Object { Write-Host "  $_" }
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    foreach ($package in $packages) {
      Write-Host "Installing $package with winget ..."
      winget install --id $package --exact --source winget --silent --accept-package-agreements --accept-source-agreements
    }
    # a new program is on the PATH of new windows only: this one gets it too
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
  } else {
    Write-Host "Install them with: winget install $($packages -join ' ')"
  }
}

# the folder is given as a path (~\GitHub, ., ..\work, C:\work): a plain word is a package,
# as a package's name may also be a folder here
$Root = $null; $only = @()
foreach ($arg in $Names) {
  if ($arg -like '-*') { Write-Host "Unknown option: $arg"; exit 1 }
  $path = $arg.Trim().Trim('"') -replace '^~', $HOME
  if (-not $Root -and ($arg -match '[\\/]|^[A-Za-z]:' -or $arg -in '~', '.', '..')) { $Root = $path } else { $only += $arg }
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

# git is needed, so without it it stops
Install-Missing 'git:Git.Git:finds the repositories'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { exit 1 }

# Windows PowerShell 5.1 does not use TLS 1.2, which GitHub needs, unless told
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
# no progress bar for each answer, which slows Windows PowerShell down
$ProgressPreference = 'SilentlyContinue'

# the part of a path inside the folder, as rwf\rwf
function Get-Relative([string]$path) {
  if ($path.StartsWith($Root + [IO.Path]::DirectorySeparatorChar)) { return $path.Substring($Root.Length + 1) }
  return $path
}

# the value of a field of a DESCRIPTION file, as Package or Version
function Get-Field([string]$description, [string]$field) {
  foreach ($line in Get-Content -LiteralPath $description) {
    if ($line -match "^${field}:\s*(.*?)\s*$") { return $Matches[1] }
  }
}

# the packages: their folders, names and the labels of the table (the folder, and the
# package's name when it is not the folder's)
$skip = '^(\.git|renv|venv|\.venv|node_modules|.*\.Rcheck)$'
$descriptions = Get-ChildItem -LiteralPath $Root -Recurse -Depth 2 -Filter DESCRIPTION -File -ErrorAction SilentlyContinue |
  Where-Object { -not ((Get-Relative $_.DirectoryName) -split '[\\/]' | Where-Object { $_ -match $skip }) } |
  Sort-Object FullName
$packages = @()
foreach ($description in $descriptions) {
  $dir = $description.DirectoryName
  $name = Get-Field $description.FullName 'Package'
  if (-not $name) { continue }
  $folder = Split-Path -Leaf $dir
  if ($only.Count -gt 0 -and -not ($only | Where-Object { $_ -ceq $name -or $_ -ceq $folder })) { continue }
  $short = if ($dir -eq $Root) { $folder } else { Get-Relative $dir }
  $label = if ($folder -ceq $name) { $short } else { "$short ($name)" }
  $packages += [pscustomobject]@{ Dir = $dir; Short = $short; Label = $label }
}
if ($packages.Count -eq 0) {
  if ($only.Count -gt 0) { Write-Host "No R packages named $($only -join ' ') in $Root" } else { Write-Host "No R packages in $Root" }
  exit 1
}

# the token: GITHUB_TOKEN, else the GitHub CLI's when it is logged in
$token = $env:GITHUB_TOKEN
if (-not $token -and (Get-Command gh -ErrorAction SilentlyContinue)) {
  $token = (gh auth token 2> $null)
}
$headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
if ($token) { $headers.Authorization = "Bearer $token" }

# asks GitHub for https://api.github.com/<path>. Returns the answer, with $script:status 200;
# or $null, with $script:status 404 when GitHub has no such thing, otherwise -1 and the
# reason in $script:apiError. After a token GitHub refuses, or its limit of requests, the
# questions that follow are not asked. A fault of GitHub's (500 and up) is tried again twice
$script:apiError = $null; $script:apiStop = $false; $script:status = 0
function Get-GitHub([string]$path) {
  $script:status = -1
  if ($script:apiStop) { return $null }
  for ($try = 1; $try -le 3; $try++) {
    try {
      $answer = Invoke-RestMethod -Uri "https://api.github.com/$path" -Headers $headers -UseBasicParsing -TimeoutSec 30
      $script:status = 200
      return $answer
    } catch {
      $code = 0
      if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
      $message = "$($_.ErrorDetails.Message)"
      if ($code -eq 404) { $script:status = 404; return $null }
      if ($code -eq 401) {
        $script:apiError = 'GitHub did not accept the token ($env:GITHUB_TOKEN, or the GitHub CLI''s: gh auth login)'
        $script:apiStop = $true; return $null
      }
      if ($code -in 403, 429 -and $message -match 'rate limit') {
        $script:apiError = "GitHub's limit of requests an hour was reached"
        if (-not $token) { $script:apiError += ' (60 without a token: gh auth login, or $env:GITHUB_TOKEN)' }
        $script:apiStop = $true; return $null
      }
      if ($code -ne 0 -and $code -lt 500) { $script:apiError = "GitHub answered $code"; return $null }
      if ($try -eq 3) {
        $script:apiError = if ($code) { "GitHub answered $code" } else { 'GitHub could not be reached' }
        return $null
      }
      Start-Sleep -Seconds 3
    }
  }
}

# what a workflow does, from what it runs (not its comments): check, build, or nothing
function Get-Kind([string]$path) {
  $code = (Get-Content -LiteralPath $path | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
  if ($code -match 'check-r-package|rcmdcheck|R CMD check|devtools::check') { return 'check' }
  if ($code -match 'R CMD build|devtools::build|pkgbuild::build') { return 'build' }
  return $null
}

# the branches a workflow names (under on:), such as [master]
function Get-Branches([string]$path) {
  $found = @(); $list = $false
  foreach ($line in Get-Content -LiteralPath $path) {
    if ($line -match '^\s*#') { continue }
    $line = $line -replace '\s#.*$', ''
    if ($line -match '^\s*branches:\s*(.*)$') {
      if ($Matches[1]) { $found += $Matches[1].Trim() } else { $list = $true }
    } elseif ($list -and $line -match '^\s*-\s*(.+)$') {
      $found += $Matches[1].Trim()
    } else {
      $list = $false
    }
  }
  @($found | Sort-Object -Unique) -join ' '
}

# when a run started, in local time: Windows PowerShell 5.1 gives the time as text, and
# PowerShell 7 as a date
function Format-When($value) {
  if ($value -is [datetime]) {
    $t = $value
  } else {
    $t = [datetime]::Parse([string]$value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
  }
  if ($t.Kind -ne [DateTimeKind]::Local) { $t = [datetime]::SpecifyKind($t, [DateTimeKind]::Utc).ToLocalTime() }
  $t.ToString('dd/MM HH:mm', [Globalization.CultureInfo]::InvariantCulture)
}

# the latest run on the default branch of one workflow: Rank (1 a problem, 2 still running,
# 3 fine), Text (the result and when it started) and Details, to show under the line
function Get-LatestRun([string]$kind, [IO.FileInfo]$file, [string]$slug, [string]$branch) {
  $name = $file.Name
  $answer = Get-GitHub "repos/$slug/actions/workflows/$([uri]::EscapeDataString($name))/runs?branch=$([uri]::EscapeDataString($branch))&per_page=1"
  if ($script:status -eq 404) {
    return @{ Rank = 1; Text = 'not on GitHub'; Details = @("${kind}: GitHub does not have $name yet: push it") }
  }
  if ($script:status -ne 200) { return @{ Rank = 1; Text = 'unknown'; Details = @() } }
  $run = @($answer.workflow_runs) | Select-Object -First 1
  if (-not $run) {
    $on = Get-Branches $file.FullName
    if ($on -and $on -notmatch "\b$([regex]::Escape($branch))\b") {
      $detail = "${kind}: $name runs only on the branches $on, not on $branch"
    } else {
      $detail = "${kind}: $name has never run on ${branch}: start it with Run workflow on https://github.com/$slug/actions/workflows/$name"
    }
    return @{ Rank = 1; Text = "no runs on $branch"; Details = @($detail) }
  }
  $result = if ($run.conclusion) { [string]$run.conclusion } else { [string]$run.status }
  $text = '{0,-11} {1}' -f $result, (Format-When $run.created_at)
  if ($result -in 'success', 'skipped', 'neutral') { return @{ Rank = 3; Text = $text; Details = @() } }
  if ($result -in 'in_progress', 'queued', 'waiting', 'requested', 'pending') { return @{ Rank = 2; Text = $text; Details = @() } }
  $details = @("${kind} ${result}: $($run.html_url)")
  # the jobs that failed, each with the step it failed at
  if ($result -in 'failure', 'timed_out') {
    $jobs = Get-GitHub "repos/$slug/actions/runs/$($run.id)/jobs?per_page=100"
    foreach ($job in @($jobs.jobs)) {
      if ($job.conclusion -notin 'failure', 'timed_out') { continue }
      $step = @($job.steps) | Where-Object { $_.conclusion -in 'failure', 'timed_out' } | Select-Object -First 1
      $where = if ($step) { $step.name } else { $job.conclusion }
      $details += "  $($job.name): $where"
    }
  }
  return @{ Rank = 1; Text = $text; Details = $details }
}

Write-Host "$($packages.Count) R package(s) in ${Root}: the latest run on GitHub of their build and check"
if (-not $token) { Write-Host 'No token ($env:GITHUB_TOKEN, or gh auth login): public repositories only, 60 requests an hour' }
Write-Host ''
$width = [Math]::Max(7, ($packages | ForEach-Object { $_.Label.Length } | Measure-Object -Maximum).Maximum)
Write-Host ('{0}  {1}  {2}' -f 'package'.PadRight($width), 'build'.PadRight(24), 'check')

$branchOf = @{}
$problems = @(); $running = @(); $withoutBuild = @(); $withoutCheck = @(); $checkFailed = $false; $seen = 0
foreach ($package in $packages) {
  Write-Host ($package.Label.PadRight($width) + '  ') -NoNewline

  # the repository on GitHub, from its remote origin
  $top = git -C $package.Dir rev-parse --show-toplevel 2> $null
  $url = git -C $package.Dir remote get-url origin 2> $null
  $slug = $null
  if ($url -and ("$url".TrimEnd('/') -match 'github\.com[:/]+([^/]+)/([^/]+?)(\.git)?$')) { $slug = "$($Matches[1])/$($Matches[2])" }
  if (-not $top) { Write-Host 'not on GitHub (not a git repository)' -ForegroundColor DarkGray; continue }
  if (-not $url) { Write-Host 'not on GitHub (no remote origin)' -ForegroundColor DarkGray; continue }
  # without the user name and password an address may hold (https://user:token@host/...)
  if (-not $slug) { Write-Host "not on GitHub (origin: $($url -replace '//[^/@]*@', '//'))" -ForegroundColor DarkGray; continue }

  # its default branch, asked once per repository
  if (-not $branchOf.ContainsKey($slug)) {
    $answer = Get-GitHub "repos/$slug"
    if ($script:status -eq 200) {
      $branchOf[$slug] = if ($answer.archived) { ':archived' } else { [string]$answer.default_branch }
    } elseif ($script:status -eq 404) {
      $branchOf[$slug] = ':not found'
    } else {
      $branchOf[$slug] = ':unknown'
    }
  }
  $branch = $branchOf[$slug]
  if ($branch -eq ':archived') { Write-Host "archived on GitHub ($slug)" -ForegroundColor DarkGray; continue }
  if ($branch -eq ':not found') {
    $reason = "not found on GitHub ($slug)"
    if (-not $token) { $reason += ': a private repository needs a token' }
    Write-Host $reason -ForegroundColor Red; $problems += $package.Short; continue
  }
  if ($branch -eq ':unknown') { Write-Host 'could not ask GitHub' -ForegroundColor Red; $problems += $package.Short; continue }

  # its workflows that build and that check, and the latest run of each: with two of a kind,
  # the cell shows the worse
  $files = @{ build = @(); check = @() }
  $workflows = Join-Path $top '.github\workflows'
  foreach ($file in @(Get-ChildItem -LiteralPath $workflows -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.yml', '.yaml' } | Sort-Object Name)) {
    $kind = Get-Kind $file.FullName
    if ($kind) { $files[$kind] += $file }
  }
  $details = @(); $bad = @(); $busy = @()
  foreach ($kind in 'build', 'check') {
    $cellRank = 4; $cellText = 'no workflow'
    if ($files[$kind].Count -gt 0) {
      $cellRank = 5
      foreach ($file in $files[$kind]) {
        $run = Get-LatestRun $kind $file $slug $branch
        $details += $run.Details
        if ($run.Rank -lt $cellRank) { $cellRank = $run.Rank; $cellText = $run.Text }
        if ($kind -eq 'check' -and $run.Text -like 'failure*') { $checkFailed = $true }
      }
    }
    switch ($cellRank) {
      1 { $color = 'Red'; $bad += $kind }
      2 { $color = 'Yellow'; $busy += $kind }
      3 { $color = 'Green' }
      default {
        $color = 'DarkGray'
        if ($kind -eq 'build') { $withoutBuild += $package.Short } else { $withoutCheck += $package.Short }
      }
    }
    if ($cellRank -le 3) { $seen++ }
    if ($kind -eq 'build') {
      Write-Host $cellText.PadRight(24) -ForegroundColor $color -NoNewline; Write-Host '  ' -NoNewline
    } else {
      Write-Host $cellText -ForegroundColor $color
    }
  }
  foreach ($line in $details) { Write-Host "    $line" }
  if ($bad.Count -gt 0) { $problems += "$($package.Short) ($($bad -join ', '))" }
  if ($busy.Count -gt 0) { $running += "$($package.Short) ($($busy -join ', '))" }
}

Write-Host ''
if ($script:apiError) { Write-Host $script:apiError -ForegroundColor Red }
if ($withoutBuild.Count -gt 0) { Write-Host "No build workflow: $($withoutBuild -join ', ')" -ForegroundColor DarkGray }
if ($withoutCheck.Count -gt 0) { Write-Host "No check workflow: $($withoutCheck -join ', ')" -ForegroundColor DarkGray }
if ($running.Count -gt 0) {
  Write-Host 'Still running, run this again in a few minutes:' -ForegroundColor Yellow -NoNewline
  Write-Host " $($running -join ', ')"
}
if ($problems.Count -gt 0) {
  Write-Host "With a problem ($($problems.Count)):" -ForegroundColor Red -NoNewline
  Write-Host " $($problems -join ', ')"
  if ($checkFailed) { Write-Host "r_cmd_check.ps1 <package> runs the same check here, with R's messages" }
  exit 1
}
if ($seen -eq 0) {
  Write-Host 'Nothing to look at: none of these packages has a build or check workflow on GitHub'
  exit 1
} elseif ($running.Count -gt 0) {
  Write-Host 'No problems so far' -ForegroundColor Green
} else {
  Write-Host 'The latest build and check of every package went fine' -ForegroundColor Green
}
exit 0
