# Regenerates manifest.json, the file Posit Connect (Cloud) deploys a Shiny app from, in
# every app of Documents\GitHub that already has one, so that it lists the package versions
# installed now. It lists the apps and asks first. Files that git ignores (such as .Renviron)
# are left out of the manifest, and an app that uses a package not installed here fails, as
# the manifest would leave the package out. Each manifest that changed is committed on its own
# and pushed, only when that pushes nothing else: the branch must track a branch on GitHub and
# have no commits that are not pushed yet (they would go with it). A branch behind (such as
# after the commits of GitHub Actions) first catches up, fast-forward only. Other changes,
# staged or not, are left as they are.
#   r_shiny_update_manifests.ps1              all apps with a manifest.json
#   r_shiny_update_manifests.ps1 golemirt     only these apps (also a first manifest)
#   r_shiny_update_manifests.ps1 -Yes         without asking first
#   r_shiny_update_manifests.ps1 -NoPush      write them only, no commit or push
# Another folder than Documents\GitHub: r_shiny_update_manifests.ps1 -Root ~\Projects
# Needs R and its rsconnect package, and git.

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Apps,
  [string]$Root = $env:ROOT,
  [switch]$Yes,
  [switch]$NoPush
)

# anything but y/yes is no
function Test-Yes([string]$question) {
  $answer = Read-Host "$question [y/N]"
  return $answer -match '^\s*y(es)?\s*$'
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
  Install-Program 'RProject.R'
  $rscript = Find-Rscript
  if (-not $rscript) {
    Write-Host 'Install it from https://cran.r-project.org/ or with: winget install RProject.R'; exit 1
  }
}
& $rscript -e "quit(status = !requireNamespace('rsconnect', quietly = TRUE))" 2> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host 'The R package rsconnect is not installed; installing it into your R library ...'
  & $rscript -e "lib <- Sys.getenv('R_LIBS_USER'); dir.create(lib, recursive = TRUE, showWarnings = FALSE); install.packages('rsconnect', lib = lib, repos = 'https://cloud.r-project.org')"
  if ($LASTEXITCODE -ne 0) { exit 1 }
}

# git tells which files it ignores, and whether a manifest changed
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Install-Program 'Git.Git' }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Write-Host 'git is needed: winget install Git.Git'; exit 1
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

# what is rewritten, and the question before anything is
if ($Apps.Count -gt 0 -and -not $Yes) {
  Write-Host "manifest.json is written anew in: $($Apps -join ' ')"
  if (-not $NoPush) { Write-Host 'and each one that changes is committed and pushed (manifest.json only)' }
  if ([Console]::IsInputRedirected) { Write-Host 'Not a terminal, so nothing can be asked: add -Yes to write them'; exit 1 }
  if (-not (Test-Yes 'Write them?')) { Write-Host 'Nothing was changed'; exit 0 }
}

# the files of the app as rsconnect lists them, without the ones git ignores (such as
# .Renviron, which would be deployed with its secrets); and a stop when a package they use is
# not installed, which writeManifest would quietly leave out. Only single quotes in the R
# code, as Windows PowerShell 5.1 drops the double quotes of an argument
$manifestCode = @(
  "files <- rsconnect::listDeploymentFiles('.')"
  "git <- suppressWarnings(system2('git', c('ls-files', '-co', '--exclude-standard'), stdout = TRUE, stderr = FALSE))"
  "if (is.null(attr(git, 'status'))) files <- intersect(files, git)"
  "used <- unique(renv::dependencies(files, quiet = TRUE, progress = FALSE)`$Package)"
  "missing <- setdiff(used, rownames(installed.packages()))"
  "if (length(missing)) stop('not installed here, so the manifest would leave them out: ', toString(missing), call. = FALSE)"
  "rsconnect::writeManifest(appDir = '.', appFiles = files, appPrimaryDoc = 'app.R')"
) -join '; '

# commits manifest.json alone and pushes it, when that pushes nothing else; says why not
# otherwise. The manifest stays written either way
function Push-Manifest([string]$dir) {
  $branch = git -C $dir symbolic-ref --short -q HEAD 2> $null
  if ($LASTEXITCODE -ne 0 -or -not $branch) { Write-Host '    not pushed: not on a branch'; return $false }
  $remote = git -C $dir config "branch.$branch.remote"
  $merge = git -C $dir config "branch.$branch.merge"
  if (-not $remote -or -not $merge) { Write-Host "    not pushed: $branch does not track a branch on GitHub"; return $false }
  $null = git -C $dir fetch -q $remote
  if ($LASTEXITCODE -ne 0) { Write-Host "    not pushed: could not reach $remote"; return $false }
  $ahead, $behind = [int[]]((git -C $dir rev-list --left-right --count 'HEAD...@{u}') -split '\s+')
  if ($ahead -gt 0) { Write-Host "    not pushed: $branch has $ahead commit(s) not pushed yet, which would go with it"; return $false }
  # the commits of GitHub Actions (or of another computer) first
  if ($behind -gt 0) {
    git -C $dir merge -q --ff-only '@{u}' *> $null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "    not pushed: $branch is $behind commit(s) behind GitHub and could not catch up (changes here in the way)"; return $false
    }
  }
  git -C $dir ls-files --error-unmatch manifest.json *> $null
  $tracked = $LASTEXITCODE -eq 0
  git -C $dir diff --quiet HEAD -- manifest.json *> $null
  if ($tracked -and $LASTEXITCODE -eq 0) { Write-Host '    already on GitHub'; return $true }
  # with the path, the commit takes manifest.json only, whatever else is staged
  git -C $dir add -- manifest.json *> $null
  if ($LASTEXITCODE -eq 0) { git -C $dir commit -q -m 'Update manifest.json' -- manifest.json *> $null }
  if ($LASTEXITCODE -ne 0) { Write-Host '    not pushed: the commit failed'; return $false }
  $null = git -C $dir push -q $remote "HEAD:$merge"
  if ($LASTEXITCODE -ne 0) { Write-Host "    committed, but the push failed: git -C $dir push"; return $false }
  Write-Host '    committed and pushed'
  return $true
}

$updated = @(); $unchanged = @(); $failed = @(); $not_pushed = @()

foreach ($name in $Apps) {
  $dir = Join-Path $Root $name
  Write-Host "=== $name"
  if (-not (Test-Path -LiteralPath (Join-Path $dir 'app.R'))) {
    Write-Host '    no app.R, skipped'
    $failed += "${name}: no app.R"
    continue
  }
  Push-Location -LiteralPath $dir
  $output = & $rscript -e $manifestCode 2>&1
  $status = $LASTEXITCODE
  Pop-Location
  if ($status -eq 0) {
    git -C $dir ls-files --error-unmatch manifest.json *> $null
    $tracked = $LASTEXITCODE -eq 0
    # against the last commit, so that a manifest written before and not committed counts too
    git -C $dir diff --quiet HEAD -- manifest.json *> $null
    if ($tracked -and $LASTEXITCODE -eq 0) {
      Write-Host '    unchanged'
      $unchanged += $name
    } else {
      Write-Host '    updated'
      $updated += $name
      if (-not $NoPush -and -not (Push-Manifest $dir)) { $not_pushed += $name }
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
  Write-Host 'Apps without a manifest.json, not touched (to make one: r_shiny_update_manifests.ps1 NAME):'
  $not_deployed | ForEach-Object { Write-Host "  $_" }
}
if ($NoPush -and $updated.Count -gt 0) {
  Write-Host 'Commit and push each updated manifest.json for Posit Connect to use it.'
} elseif ($not_pushed.Count -gt 0) {
  Write-Host 'Updated but not pushed (the reason is above), to commit and push yourself:'
  $not_pushed | ForEach-Object { Write-Host "  $_" }
}
if ($failed.Count -gt 0) {
  Write-Host "Failed ($($failed.Count)):"
  $failed | ForEach-Object { Write-Host "  $_" }
  exit 1
}
if ($not_pushed.Count -gt 0) { exit 1 }
