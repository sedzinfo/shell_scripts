# Clones every repository of a GitHub user into Documents\GitHub (or the folder given).
# Repositories that are already there are skipped, so it is safe to run again.
#   git_clone_all.ps1 [folder] [user] [-Ssh]
# It clones over HTTPS, which git logs in to through the Git Credential Manager, as GitHub
# Desktop does; with -Ssh it clones over SSH, with the SSH key of this computer.
# Private repositories are included only if a token is set, for that run only:
#   $env:GITHUB_TOKEN = 'ghp_...'; .\git_clone_all.ps1; Remove-Item Env:GITHUB_TOKEN

param(
  [string]$Folder,
  [string]$User = 'sedzinfo',
  [switch]$Ssh
)

# anything but y/yes is no
function Test-Yes([string]$question) {
  $answer = Read-Host "$question [y/N]"
  return $answer -match '^\s*y(es)?\s*$'
}

# offers to install the programs this script needs, when they are missing.
# Each argument is program:package:what it is for. It only asks (never installs
# by itself), only once, and only where winget exists; with no, the script goes on
# and shows what it can.
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
  if ((Get-Command winget -ErrorAction SilentlyContinue) -and -not [Console]::IsInputRedirected) {
    if (Test-Yes "Install them now with winget install $($packages -join ' ')?") {
      foreach ($package in $packages) { winget install --id $package --exact --source winget }
      # a new program is on the PATH of new windows only: this one gets it too
      $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    }
  } else {
    Write-Host "Install them with: winget install $($packages -join ' ')"
  }
}

# the folder given, or Documents\GitHub (where GitHub Desktop puts the repositories), or ~\GitHub
if (-not $Folder) {
  $Folder = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'GitHub'
  if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { $Folder = Join-Path $HOME 'GitHub' }
}
# ask for the folder until one that exists is given (~ works, and the quotes of "Copy as path")
while (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
  Write-Host "Folder not found: $Folder"
  $Folder = Read-Host 'Folder to clone into (empty to quit)'
  if (-not $Folder) { exit 1 }
  $Folder = $Folder.Trim().Trim('"') -replace '^~', $HOME
}

# git is needed, so without it it stops
Install-Missing 'git:Git.Git:clones the repositories'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { exit 1 }

# Windows PowerShell 5.1 does not use TLS 1.2, which GitHub needs, unless told
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# the list of repositories, 100 per page
if ($env:GITHUB_TOKEN) {
  $url = 'https://api.github.com/user/repos?affiliation=owner'    # public and private
  $headers = @{ Authorization = "Bearer $env:GITHUB_TOKEN" }
} else {
  $url = "https://api.github.com/users/$User/repos?type=owner"     # public only
  $headers = @{}
}

$repos = @()
$page = 1
while ($true) {
  try {
    $response = Invoke-RestMethod -Uri "$url&per_page=100&page=$page" -Headers $headers -UseBasicParsing
  } catch {
    Write-Host 'Could not reach GitHub'
    exit 1
  }
  # piped, so that the list is taken apart the same way in every PowerShell version
  $batch = @($response | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
  if ($batch.Count -eq 0) { break }
  $repos += $batch
  $page++
}
Write-Host "Found $($repos.Count) repositories of $User"
Write-Host ''

$cloned = @(); $skipped = @(); $failed = @()

foreach ($repo in $repos) {
  $name = $repo.name
  if (Test-Path -LiteralPath (Join-Path $Folder $name)) {
    $skipped += $name
    continue
  }
  Write-Host "=== $name"
  $address = if ($Ssh) { $repo.ssh_url } else { $repo.clone_url }
  git clone $address (Join-Path $Folder $name)
  if ($LASTEXITCODE -eq 0) { $cloned += $name } else { $failed += $name }
  Write-Host ''
}

Write-Host '==============================='
Write-Host "Cloned: $($cloned.Count)"
$cloned | ForEach-Object { Write-Host "  $_" }
Write-Host "Already there, skipped: $($skipped.Count)"
if ($failed.Count -gt 0) {
  Write-Host "Failed ($($failed.Count)):"
  $failed | ForEach-Object { Write-Host "  $_" }
  exit 1
}
