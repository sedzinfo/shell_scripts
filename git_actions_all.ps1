# GitHub Actions of every repository of one or more GitHub users or organisations:
# the latest run of each workflow, problems first (failed, cancelled, timed out),
# then the ones still running, then the ones that passed, and at the end the list
# of repositories with a problem. Archived repositories are left out.
#   git_actions_all.ps1                       the repositories of sedzinfo
#   git_actions_all.ps1 sedzinfo evalioncode  these users and organisations
#   git_actions_all.ps1 -Problems             only the problems and the runs still running
# Private repositories (and an organisation's) are included only with a token:
#   $env:GITHUB_TOKEN = 'ghp_...'; .\git_actions_all.ps1; Remove-Item Env:GITHUB_TOKEN
# Without GITHUB_TOKEN, the token of the GitHub CLI (gh auth token) is used when
# it is logged in. Without any token GitHub allows 60 requests an hour, one per
# repository. Exits 1 when a latest run has a problem, so it can run from the Task
# Scheduler.

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Owners,
  [switch]$Problems
)

$names = @()
foreach ($arg in $Owners) {
  if ($arg -eq '--problems') { $Problems = $true; continue }
  if ($arg -like '-*') { Write-Host "Unknown option: $arg"; exit 2 }
  $names += $arg
}
if ($names.Count -eq 0) { $names = @('sedzinfo') }

# Windows PowerShell 5.1 does not use TLS 1.2, which GitHub needs, unless told
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
# no progress bar for each answer, which slows Windows PowerShell down
$ProgressPreference = 'SilentlyContinue'

# the token: GITHUB_TOKEN, else the GitHub CLI's when it is logged in
$token = $env:GITHUB_TOKEN
if (-not $token -and (Get-Command gh -ErrorAction SilentlyContinue)) {
  $token = (gh auth token 2> $null)
}
$headers = @{ Accept = 'application/vnd.github+json' }
$me = ''
if ($token) {
  $headers.Authorization = "Bearer $token"
  try {
    $me = (Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -UseBasicParsing).login
  } catch {
    Write-Host 'GitHub did not accept the token'
    exit 1
  }
} else {
  Write-Host 'No token ($env:GITHUB_TOKEN or gh auth login): public repositories only, 60 requests an hour'
}

# every page of a list from the API, as one list; $null when GitHub could not be asked
function Get-All([string]$url) {
  $sep = if ($url -match '\?') { '&' } else { '?' }
  $all = @(); $page = 1
  while ($true) {
    try {
      $response = Invoke-RestMethod -Uri "$url${sep}per_page=100&page=$page" -Headers $headers -UseBasicParsing
    } catch {
      return $null
    }
    # piped, so that the list is taken apart the same way in every PowerShell version
    $batch = @($response | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
    if ($batch.Count -eq 0) { break }
    $all += $batch
    if ($batch.Count -lt 100) { break }
    $page++
  }
  return , $all
}

# the start of a text, at most $length characters
function Limit-Text([string]$text, [int]$length) {
  if ($text.Length -gt $length) { return $text.Substring(0, $length) }
  return $text
}

# the day of a run, as GitHub gives it (UTC): Windows PowerShell 5.1 gives the time as
# text, PowerShell 7 as a date
function Get-Day($value) {
  if ($value -is [datetime]) {
    $t = if ($value.Kind -eq [DateTimeKind]::Local) { $value.ToUniversalTime() } else { $value }
    return $t.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
  }
  return Limit-Text "$value" 10
}

# the repositories of each owner: with a token, the private ones too (the owner's own
# token, or a member's for an organisation)
$repos = @()
foreach ($owner in $names) {
  try {
    $kind = (Invoke-RestMethod -Uri "https://api.github.com/users/$owner" -Headers $headers -UseBasicParsing).type
  } catch {
    Write-Host "GitHub user or organisation not found: $owner"
    exit 1
  }
  if ($kind -eq 'Organization') {
    $url = "https://api.github.com/orgs/$owner/repos?type=all"
  } elseif ($me -and $me -eq $owner) {
    $url = 'https://api.github.com/user/repos?affiliation=owner'
  } else {
    $url = "https://api.github.com/users/$owner/repos?type=owner"
  }
  $list = Get-All $url
  if ($null -eq $list) { Write-Host "Could not list the repositories of $owner"; exit 1 }
  $repos += @($list | Where-Object { -not $_.archived } | ForEach-Object { $_.full_name } | Sort-Object)
}
Write-Host "Checking $($repos.Count) repositories of $($names -join ' ')"
Write-Host ''

# the latest run of each workflow of each repository (the last 100 runs are enough
# to find every active workflow), told apart by the workflow file, since Dependabot
# and Copilot give every run a name of its own. Rank: 1 problem, 2 running, 3 passed
$lines = @(); $noActions = @(); $unreadable = @()
foreach ($repo in $repos) {
  try {
    $response = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/actions/runs?per_page=100" -Headers $headers -UseBasicParsing
  } catch {
    $unreadable += $repo
    continue
  }
  $runs = @($response.workflow_runs | Where-Object { $null -ne $_ })
  if ($runs.Count -eq 0) { $noActions += $repo; continue }
  foreach ($group in ($runs | Group-Object path)) {
    $run = $group.Group | Sort-Object created_at -Descending | Select-Object -First 1
    $result = if ($run.conclusion) { [string]$run.conclusion } else { [string]$run.status }
    $rank = if ($result -in 'success', 'skipped', 'neutral') { 3 } elseif (-not $run.conclusion) { 2 } else { 1 }
    $lines += [pscustomobject]@{
      Rank = $rank; Result = $result; Repo = $repo; Workflow = (Limit-Text $run.name 30)
      Branch = (Limit-Text "$($run.head_branch)" 16); Date = (Get-Day $run.created_at); Link = $run.html_url
    }
  }
}

# problems first, then running, then passed; inside each, by repository
$lines = @($lines | Sort-Object Rank, Repo, Workflow)
$failedRepos = @()
foreach ($line in $lines) {
  if ($line.Rank -eq 1) { $failedRepos += $line.Repo }
  if ($Problems -and $line.Rank -eq 3) { continue }
  Write-Host ('{0,-12} {1,-40} {2,-30} {3,-16} {4}  {5}' -f $line.Result, $line.Repo, $line.Workflow, $line.Branch, $line.Date, $line.Link)
}
if ($lines.Count -eq 0) { Write-Host 'No workflow runs found' }

$failedRepos = @($failedRepos | Sort-Object -Unique)
Write-Host ''
Write-Host '==============================='
Write-Host "Repositories with Actions: $($repos.Count - $noActions.Count - $unreadable.Count), without: $($noActions.Count)"
if ($unreadable.Count -gt 0) {
  Write-Host "Could not read the runs of ($($unreadable.Count)):"
  $unreadable | ForEach-Object { Write-Host "  $_" }
}
if ($failedRepos.Count -gt 0) {
  Write-Host "With a problem ($($failedRepos.Count)):"
  $failedRepos | ForEach-Object { Write-Host "  $_" }
  exit 1
}
Write-Host 'No problems'
exit 0
