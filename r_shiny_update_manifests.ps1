# Regenerates manifest.json, the file Posit Connect (Cloud) deploys a Shiny app from, in
# every app of Documents\GitHub that already has one, so that it lists the package versions
# installed now. Nothing is committed or pushed.
#   shiny_update_manifests.ps1              all apps with a manifest.json
#   shiny_update_manifests.ps1 golemirt     only these apps (also a first manifest)
# Another folder than Documents\GitHub: shiny_update_manifests.ps1 -Root ~\Projects
# Needs R and its rsconnect package.

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Apps,
  [string]$Root = $env:ROOT
)

# anything but y/yes is no
function Test-Yes([string]$question) {
  $answer = Read-Host "$question [y/N]"
  return $answer -match '^\s*y(es)?\s*$'
}

# Rscript: on the PATH, or where the R installer put it, as it does not add R to the PATH
function Find-Rscript {
  $command = Get-Command Rscript -ErrorAction SilentlyContinue
  if ($command) { return $command.Source }
  foreach ($key in 'HKCU:\SOFTWARE\R-core\R', 'HKLM:\SOFTWARE\R-core\R') {
    $path = (Get-ItemProperty -Path $key -ErrorAction SilentlyContinue).InstallPath
    if ($path -and (Test-Path -LiteralPath "$path\bin\Rscript.exe")) { return "$path\bin\Rscript.exe" }
  }
  # the newest R in Program Files
  Get-ChildItem "$env:ProgramFiles\R\R-*\bin\Rscript.exe" -ErrorAction SilentlyContinue |
    Sort-Object { [version]($_.Directory.Parent.Name -replace '^R-', '' -replace '[^0-9.]', '') } |
    Select-Object -Last 1 -ExpandProperty FullName
}

# R is needed, so without it it stops
$rscript = Find-Rscript
if (-not $rscript) {
  Write-Host 'Missing:'
  Write-Host ('  {0,-14} {1,-26} package {2}' -f 'Rscript', '(runs R)', 'RProject.R')
  if ((Get-Command winget -ErrorAction SilentlyContinue) -and (Test-Yes 'Install it now with winget install RProject.R?')) {
    winget install --id RProject.R --exact --source winget
    $rscript = Find-Rscript
  } else {
    Write-Host 'Install it from https://cran.r-project.org/ or with: winget install RProject.R'
  }
  if (-not $rscript) { exit 1 }
}
& $rscript -e "quit(status = !requireNamespace('rsconnect', quietly = TRUE))" 2> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host 'The R package rsconnect is missing; in R: install.packages("rsconnect")'
  exit 1
}

# the folder given, or Documents\GitHub (where GitHub Desktop puts the repositories), or ~\GitHub
if (-not $Root) {
  $Root = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'GitHub'
  if (-not (Test-Path -LiteralPath $Root -PathType Container)) { $Root = Join-Path $HOME 'GitHub' }
}
$Root = $Root.Trim().Trim('"') -replace '^~', $HOME
# ask for the folder until one that exists is given (~ works, and the quotes of "Copy as path")
while (-not (Test-Path -LiteralPath $Root -PathType Container)) {
  Write-Host "Folder not found: $Root"
  $Root = Read-Host 'Folder with the repositories (empty to quit)'
  if (-not $Root) { exit 1 }
  $Root = $Root.Trim().Trim('"') -replace '^~', $HOME
}

# the apps: the ones named, or every folder with both app.R and manifest.json
$not_deployed = @()
if (-not $Apps) {
  $Apps = @()
  foreach ($dir in Get-ChildItem -LiteralPath $Root -Directory) {
    if (-not (Test-Path -LiteralPath (Join-Path $dir.FullName 'app.R'))) { continue }
    if (Test-Path -LiteralPath (Join-Path $dir.FullName 'manifest.json')) {
      $Apps += $dir.Name
    } else {
      $not_deployed += $dir.Name
    }
  }
}

$updated = @(); $unchanged = @(); $failed = @()

foreach ($name in $Apps) {
  $dir = Join-Path $Root $name
  Write-Host "=== $name"
  if (-not (Test-Path -LiteralPath (Join-Path $dir 'app.R'))) {
    Write-Host '    no app.R, skipped'
    $failed += "${name}: no app.R"
    continue
  }
  # the same call as by hand; it fails when a package the app uses is not installed
  Push-Location -LiteralPath $dir
  $output = & $rscript -e "rsconnect::writeManifest(appDir = '.', appPrimaryDoc = 'app.R')" 2>&1
  $status = $LASTEXITCODE
  Pop-Location
  if ($status -eq 0) {
    git -C $dir ls-files --error-unmatch manifest.json *> $null
    $tracked = $LASTEXITCODE -eq 0
    git -C $dir diff --quiet -- manifest.json *> $null
    if ($tracked -and $LASTEXITCODE -eq 0) {
      Write-Host '    unchanged'
      $unchanged += $name
    } else {
      Write-Host '    updated'
      $updated += $name
    }
  } else {
    # the end of R's message says what went wrong (usually a missing package)
    $output | Select-Object -Last 8 | ForEach-Object { Write-Host "    $_" }
    $failed += $name
  }
}

Write-Host '==============================='
Write-Host "Updated: $($updated.Count)"
$updated | ForEach-Object { Write-Host "  $_" }
Write-Host "Unchanged: $($unchanged.Count)"
if ($not_deployed.Count -gt 0) {
  Write-Host 'Apps without a manifest.json, not touched (to make one: shiny_update_manifests.ps1 NAME):'
  $not_deployed | ForEach-Object { Write-Host "  $_" }
}
if ($updated.Count -gt 0) {
  Write-Host 'Commit and push each updated manifest.json for Posit Connect to use it.'
}
if ($failed.Count -gt 0) {
  Write-Host "Failed ($($failed.Count)):"
  $failed | ForEach-Object { Write-Host "  $_" }
  exit 1
}
