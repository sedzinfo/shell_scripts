# Everything that makes an R package ready to push, for every R package in Documents\GitHub
# (or the folder given), step by step: the help pages, the installation, R CMD check, the
# pkgdown website, the manifest.json of the Shiny apps, the PDF manual and the source
# tarball. Each step is the script of this folder that does it, so it does the same and
# reports the same; install and tarball are done here. It lists the packages and the steps
# and asks once, first. Nothing is committed or pushed.
#   r_build_all.ps1 [folder] [package ...]   every step, for every package or only the ones named
#   r_build_all.ps1 -Skip check,pdf          without these steps
#   r_build_all.ps1 -Only pkgdown,tarball    only these steps
#   r_build_all.ps1 -Yes                     without asking first
# The steps, in this order:
#   document   help pages (man\) and NAMESPACE from roxygen     r_document_all.ps1
#   install    the package installed in the R library            R CMD INSTALL
#   check      R CMD check: the tests and the examples           r_cmd_check.ps1
#   pkgdown    the website, for packages with a _pkgdown.yml     r_pkgdown_all.ps1
#   manifests  manifest.json, for apps that already have one     r_shiny_update_manifests.ps1
#   pdf        the PDF manual, <package>.pdf                     r_pdf_all.ps1
#   tarball    <package>_<version>.tar.gz at the top of the repository, replacing an
#              older one                                         R CMD build --resave-data
# The folder is given as a path (~\GitHub, ., ..\work, C:\work): a plain word is a package.
# A step that fails does not stop the others. The exit code is 1 if any step failed.

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Names,
  [string[]]$Skip = @(),
  [string[]]$Only = @(),
  [switch]$Yes
)

$stepsAll = 'document', 'install', 'check', 'pkgdown', 'manifests', 'pdf', 'tarball'
# -Skip check,pdf and -Skip check -Skip pdf both work
$Skip = @($Skip | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
foreach ($name in $Skip + $Only) {
  if ($name -notin $stepsAll) { Write-Host "Unknown step: $name (steps: $($stepsAll -join ' '))"; exit 1 }
}
$steps = @($stepsAll | Where-Object { ($Only.Count -eq 0 -or $_ -in $Only) -and $_ -notin $Skip })
if ($steps.Count -eq 0) { Write-Host 'No steps left to run'; exit 1 }

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

# the folder is given as a path: a plain word is a package, as a package's name may also be a
# folder here
$Root = $null; $onlyNames = @()
foreach ($arg in $Names) {
  if ($arg -like '-*') { Write-Host "Unknown option: $arg"; exit 1 }
  $path = $arg.Trim().Trim('"') -replace '^~', $HOME
  if (-not $Root -and ($arg -match '[\\/]|^[A-Za-z]:' -or $arg -in '~', '.', '..')) {
    $Root = $path
  } else {
    $onlyNames += $arg
  }
}
$rootGiven = [bool]$Root

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

$rscript = Find-Rscript
if (-not $rscript) { Write-Host 'R is needed: winget install RProject.R'; exit 1 }
# R CMD runs through R.exe, which sits next to Rscript.exe
$r = Join-Path (Split-Path -Parent $rscript) 'R.exe'
if (-not (Test-Path -LiteralPath $r)) { $r = Join-Path (Split-Path -Parent $rscript) 'R' }

# the part of a path inside the folder, as rwf\rwf
function Get-Relative([string]$path) {
  if ($path.StartsWith($Root + [IO.Path]::DirectorySeparatorChar)) { return $path.Substring($Root.Length + 1) }
  return $path
}
# the value of a field of a DESCRIPTION file, as Package
function Get-Field([string]$dir, [string]$field) {
  foreach ($line in Get-Content -LiteralPath (Join-Path $dir 'DESCRIPTION')) {
    if ($line -cmatch "^${field}:\s*(.*?)\s*$") { return $Matches[1] }
  }
}
# the top of the repository a package is in
function Get-Top([string]$dir) {
  $top = git -C $dir rev-parse --show-toplevel 2> $null
  if ($top) { return [IO.Path]::GetFullPath($top) } else { return $dir }
}

# the packages: every folder with a DESCRIPTION, as the step scripts find them
$dirs = @()
$skipDirs = '^(\.git|renv|venv|\.venv|node_modules|.*\.Rcheck)$'
$descriptions = Get-ChildItem -LiteralPath $Root -Recurse -Depth 2 -Filter DESCRIPTION -File -ErrorAction SilentlyContinue |
  Where-Object { -not ((Get-Relative $_.DirectoryName) -split '[\\/]' | Where-Object { $_ -match $skipDirs }) } |
  Sort-Object FullName
foreach ($description in $descriptions) {
  $dir = $description.DirectoryName
  $name = Get-Field $dir 'Package'
  if (-not $name) { continue }
  if ($onlyNames.Count -gt 0) {
    $folder = Split-Path -Leaf $dir
    if (-not ($onlyNames | Where-Object { $_ -ceq $name -or $_ -ceq $folder })) { continue }
  }
  $dirs += $dir
}
if ($dirs.Count -eq 0) {
  if ($onlyNames.Count -gt 0) { Write-Host "No R packages named $($onlyNames -join ' ') in $Root" } else { Write-Host "No R packages in $Root" }
  exit 1
}

# the Shiny apps whose manifest is updated: those named that already have a manifest.json
# (without names, r_shiny_update_manifests.ps1 finds them all)
$apps = @()
if ($onlyNames.Count -gt 0) {
  foreach ($dir in $dirs) {
    if ((Test-Path -LiteralPath (Join-Path $dir 'manifest.json')) -and (Split-Path -Parent $dir) -eq $Root) {
      $apps += Split-Path -Leaf $dir
    }
  }
}

$cache = if ($env:XDG_CACHE_HOME) { $env:XDG_CACHE_HOME } elseif ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME '.cache' }
$out = Join-Path $cache 'r_build_all'
New-Item -ItemType Directory -Path $out -Force | Out-Null

Write-Host "$($dirs.Count) package(s) in ${Root}: $(($dirs | ForEach-Object { Get-Relative $_ }) -join ' ')"
Write-Host "Steps: $($steps -join ' ')"
# the one question, before anything is written; the steps are then run with -Yes
if (-not $Yes) {
  Write-Host 'This rewrites man\, NAMESPACE, the websites, the manifests, the PDFs and the tarballs of these'
  Write-Host 'packages (as far as the steps go), and installs them. Nothing is committed or pushed.'
  if ([Console]::IsInputRedirected) { Write-Host 'Not a terminal, so nothing can be asked: add -Yes to run'; exit 1 }
  if (-not (Test-Yes 'Run the steps?')) { Write-Host 'Nothing was changed'; exit 0 }
}

# the folder and the names, as the step scripts take them
$pass = @()
if ($rootGiven) { $pass += $Root }
$pass += $onlyNames

function Write-Banner([string]$text) {
  Write-Host ''
  Write-Host ('=' * 80)
  Write-Host $text
}
# runs R CMD with its output in a log; the output R writes to its errors comes as error
# records, which Windows PowerShell 5.1 would show as their type
function Invoke-RCmd([string]$log, [string[]]$arguments) {
  $output = & $r CMD @arguments 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } }
  $status = $LASTEXITCODE
  [IO.File]::WriteAllText($log, (@($output) -join [Environment]::NewLine) + [Environment]::NewLine)
  return $status
}
function Show-LogEnd([string]$log) {
  Write-Host ' failed' -ForegroundColor Red -NoNewline
  Write-Host ", the end of ${log}:"
  Get-Content -LiteralPath $log -Tail 8 | ForEach-Object { Write-Host "    $_" }
}

$result = [ordered]@{}
foreach ($step in $steps) {
  Write-Banner "Step: $step"
  $status = 0
  switch ($step) {
    'document' { & (Join-Path $PSScriptRoot 'r_document_all.ps1') @pass -Yes; $status = $LASTEXITCODE }
    'check' { & (Join-Path $PSScriptRoot 'r_cmd_check.ps1') @pass; $status = $LASTEXITCODE }
    'pkgdown' { & (Join-Path $PSScriptRoot 'r_pkgdown_all.ps1') @pass -Yes; $status = $LASTEXITCODE }
    'pdf' { & (Join-Path $PSScriptRoot 'r_pdf_all.ps1') @pass -Yes; $status = $LASTEXITCODE }
    'manifests' {
      if ($onlyNames.Count -gt 0 -and $apps.Count -eq 0) {
        Write-Host 'None of these packages is a Shiny app with a manifest.json'
        $status = -1
      } else {
        & (Join-Path $PSScriptRoot 'r_shiny_update_manifests.ps1') @apps -Root $Root -Yes; $status = $LASTEXITCODE
      }
    }
    'install' {
      foreach ($dir in $dirs) {
        $label = Get-Relative $dir
        $log = Join-Path $out ('install_' + ($label -replace '[\\/]', '_') + '.log')
        Write-Host ('  {0,-32}' -f $label) -NoNewline
        if ((Invoke-RCmd $log @('INSTALL', $dir)) -eq 0) {
          Write-Host " installed $(Get-Field $dir 'Version')" -ForegroundColor Green
        } else {
          Show-LogEnd $log; $status = 1
        }
      }
    }
    'tarball' {
      foreach ($dir in $dirs) {
        $label = Get-Relative $dir
        $name = Get-Field $dir 'Package'
        $log = Join-Path $out ('tarball_' + ($label -replace '[\\/]', '_') + '.log')
        # at the top of the repository, as generate_package.R and the build-tarball workflows
        # put it, replacing the tarballs of older versions
        $top = Get-Top $dir
        Write-Host ('  {0,-32}' -f $label) -NoNewline
        Get-ChildItem -LiteralPath $top -Filter "${name}_*.tar.gz" -File -ErrorAction SilentlyContinue | Remove-Item -Force
        Push-Location -LiteralPath $top
        try { $code = Invoke-RCmd $log @('build', '--resave-data', $dir) } finally { Pop-Location }
        $tarball = Get-ChildItem -LiteralPath $top -Filter "${name}_*.tar.gz" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($code -eq 0 -and $tarball) {
          Write-Host (' {0} ({1:0}K)' -f (Get-Relative $tarball.FullName), ($tarball.Length / 1KB)) -ForegroundColor Green
        } else {
          Show-LogEnd $log; $status = 1
        }
      }
    }
  }
  $result[$step] = if ($status -eq -1) { 'none' } elseif ($status -eq 0) { 'ok' } else { 'failed' }
}

Write-Banner 'Summary'
$failed = $false
foreach ($step in $steps) {
  Write-Host ('  {0,-10} ' -f $step) -NoNewline
  switch ($result[$step]) {
    'ok' { Write-Host 'ok' -ForegroundColor Green }
    'none' { Write-Host 'nothing to do' }
    default { Write-Host 'failed' -ForegroundColor Red -NoNewline; Write-Host ' (see its report above)'; $failed = $true }
  }
}
# the repositories with changes to commit (the tarball and the PDF may be ignored by git)
Write-Host ''
$seen = @{}
foreach ($dir in $dirs) {
  $top = Get-Top $dir
  if ($seen.ContainsKey($top)) { continue }
  $seen[$top] = $true
  $changed = @(git -C $top status --porcelain 2> $null).Count
  if ($changed -gt 0) { Write-Host "  $(Get-Relative $top): $changed changed file(s) to commit" -ForegroundColor Yellow }
}
Write-Host "Logs of install and tarball in $out"
if ($failed) { exit 1 }
exit 0
