# Clones every repository of a GitHub user into Documents\GitHub (or the folder given).
# Repositories that are already there are skipped, so it is safe to run again.
#   git_clone_all.ps1 [folder] [user] [-Ssh]
# It clones over HTTPS, which git logs in to through the Git Credential Manager, as GitHub
# Desktop does; with -Ssh it clones over SSH, with the SSH key of this computer.
# Private repositories are included only if a token of that user is set, for that run only:
#   $env:GITHUB_TOKEN = 'ghp_...'; .\git_clone_all.ps1; Remove-Item Env:GITHUB_TOKEN

param(
  [string]$Folder,
  [string]$User = 'sedzinfo',
  [switch]$Ssh
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
# the full path: git is given paths in the folder, and it takes a ~ in them literally
$Folder = (Resolve-Path -LiteralPath $Folder).ProviderPath

# git is needed, so without it it stops
Install-Missing 'git:Git.Git:clones the repositories'
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { exit 1 }

# Windows PowerShell 5.1 does not use TLS 1.2, which GitHub needs, unless told
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# the list of repositories, 100 per page: with a token of that user, public and private;
# otherwise public only (a token of someone else still raises the limit of requests)
$url = "https://api.github.com/users/$User/repos?type=owner"; $headers = @{}
# the token: GITHUB_TOKEN, else the GitHub CLI's when it is logged in
$token = $env:GITHUB_TOKEN
if (-not $token -and (Get-Command gh -ErrorAction SilentlyContinue)) {
  $token = (gh auth token 2> $null)
}
$scope = 'public only: no token ($env:GITHUB_TOKEN or gh auth login for private ones)'
if ($token) {
  $headers = @{ Authorization = "Bearer $token" }
  try {
    $owner = (Invoke-RestMethod -Uri 'https://api.github.com/user' -Headers $headers -UseBasicParsing).login
  } catch {
    Write-Host 'GitHub did not accept the token'
    exit 1
  }
  if ($owner -eq $User) {
    $url = 'https://api.github.com/user/repos?affiliation=owner'
    $scope = 'public and private'
  } else {
    $scope = "public only: the token is $owner's, not $User's"
  }
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
Write-Host "Found $($repos.Count) repositories of $User ($scope)"
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
