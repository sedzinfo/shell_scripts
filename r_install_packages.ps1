# Installs everything the R code of a repository needs. For an R package (a DESCRIPTION
# file) these are its Depends, Imports, LinkingTo and Suggests; for other repositories
# (analyses, Quarto sites) the packages that the .R/.Rmd/.qmd files load. It shows what is
# missing and asks before installing anything; what is already installed is left as it is.
# R packages for Windows come ready built from CRAN, so unlike on Linux there are no system
# packages to install first.
#   r_install_packages.ps1 ~\Documents\GitHub\rwf
#   r_install_packages.ps1                         the repository of the current folder

param(
  [string]$Repo = '.'
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

# ask for the repository until one that exists is given (~ works, and the quotes of "Copy as path")
$Repo = $Repo.Trim().Trim('"') -replace '^~', $HOME
while (-not (Test-Path -LiteralPath $Repo -PathType Container)) {
  Write-Host "Folder not found: $Repo"
  $Repo = Read-Host 'Repository (empty to quit)'
  if (-not $Repo) { exit 1 }
  $Repo = $Repo.Trim().Trim('"') -replace '^~', $HOME
}
$Repo = (Resolve-Path -LiteralPath $Repo).ProviderPath

# R itself; without R it stops
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

# R's own library in the user folder, so no administrator rights are needed for R packages
& $rscript -e "dir.create(Sys.getenv('R_LIBS_USER'), recursive = TRUE, showWarnings = FALSE)"
$env:R_LIBS_USER = & $rscript -e "cat(Sys.getenv('R_LIBS_USER'))"

# pak works out what to install and installs it
& $rscript -e "quit(status = !requireNamespace('pak', quietly = TRUE))" 2> $null
if ($LASTEXITCODE -ne 0) {
  Write-Host 'The R package pak is needed to work out what to install.'
  if (-not (Test-Yes 'Install pak now?')) { exit 1 }
  & $rscript -e "install.packages('pak', lib = Sys.getenv('R_LIBS_USER'), repos = sprintf('https://r-lib.github.io/p/pak/stable/%s/%s/%s', .Platform`$pkgType, R.Version()`$os, R.Version()`$arch))"
  if ($LASTEXITCODE -ne 0) { exit 1 }
}

# the R package of the repository: a DESCRIPTION at its top or one folder down (rwf\rwf)
$description = Join-Path $Repo 'DESCRIPTION'
if (-not (Test-Path -LiteralPath $description -PathType Leaf)) {
  $description = Get-ChildItem -LiteralPath $Repo -Directory |
    Where-Object { $_.Name -notin '.git', 'renv' -and $_.Name -notlike '*.Rcheck' } |
    ForEach-Object { Join-Path $_.FullName 'DESCRIPTION' } |
    Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
    Select-Object -First 1
}

Write-Host "=== Working out what $(Split-Path $Repo -Leaf) needs (this takes a minute)"
# the R code in a file, and the list it writes: one R package that is not installed per line
$code = Join-Path ([IO.Path]::GetTempPath()) "r_install_packages_$PID.R"
$list = Join-Path ([IO.Path]::GetTempPath()) "r_install_packages_$PID.txt"
try {
  [IO.File]::WriteAllText($code, @'
repo <- normalizePath(Sys.getenv("REPO"), winslash = "/")
description <- Sys.getenv("DESCRIPTION_FILE")
if (nzchar(description)) {
  description <- normalizePath(description, winslash = "/")
  fields <- c("Depends", "Imports", "LinkingTo", "Suggests")
  d <- read.dcf(description, fields = fields)
  wanted <- unlist(lapply(d[!is.na(d)], function(x) trimws(sub("[(].*", "", strsplit(x, ",")[[1]]))))
  cat("From", sub(paste0(dirname(repo), "/"), "", description, fixed = TRUE), "\n")
} else {
  if (!requireNamespace("renv", quietly = TRUE)) pak::pkg_install("renv", ask = FALSE)
  wanted <- unique(renv::dependencies(repo, progress = FALSE, quiet = TRUE)$Package)
  cat("From the library() and :: calls of the .R/.Rmd/.qmd files\n")
}
base <- rownames(installed.packages(priority = "base"))
own <- if (nzchar(description)) read.dcf(description, fields = "Package")[1] else character()
wanted <- setdiff(unique(wanted[nzchar(wanted)]), c("R", base, own))
missing <- wanted[!vapply(wanted, function(p) nzchar(system.file(package = p)), logical(1))]
cat(length(wanted), "R packages needed,", length(missing), "not installed\n")
writeLines(missing, Sys.getenv("OUT"))
'@)
  $env:REPO = $Repo
  $env:DESCRIPTION_FILE = if ($description) { $description } else { '' }
  $env:OUT = $list
  & $rscript $code
  if ($LASTEXITCODE -ne 0) { exit 1 }
  $missing_r = @(Get-Content -LiteralPath $list | Where-Object { $_ })
} finally {
  Remove-Item -LiteralPath $code, $list -ErrorAction SilentlyContinue
}

# 1. R packages
if ($missing_r.Count -eq 0) {
  Write-Host 'R packages: all installed'
} else {
  Write-Host "R packages not installed ($($missing_r.Count)):"
  # in columns, as many as fit in 80 characters
  $width = ($missing_r | Measure-Object Length -Maximum).Maximum + 2
  $columns = [math]::Max(1, [math]::Floor(78 / $width))
  for ($i = 0; $i -lt $missing_r.Count; $i += $columns) {
    $row = $missing_r[$i..([math]::Min($i + $columns, $missing_r.Count) - 1)]
    Write-Host ('  ' + (($row | ForEach-Object { $_.PadRight($width) }) -join '')).TrimEnd()
  }
  if (Test-Yes "Install them (into $env:R_LIBS_USER)?") {
    & $rscript -e "pak::pkg_install(commandArgs(TRUE), ask = FALSE, lib = Sys.getenv('R_LIBS_USER'))" @missing_r
  }
}

# 2. the repository's own package
if ($description) {
  $own = (Select-String -LiteralPath $description -Pattern '^Package:\s*(\S+)' | Select-Object -First 1).Matches[0].Groups[1].Value
  $package_dir = Split-Path $description
  if (Test-Path -LiteralPath (Join-Path $package_dir 'src')) {
    Write-Host "$own has C/C++ code: building it needs Rtools, from https://cran.r-project.org/bin/windows/Rtools/"
  }
  if (Test-Yes "Install $own itself from ${package_dir}?") {
    & $rscript -e "pak::local_install(commandArgs(TRUE)[1], dependencies = FALSE, ask = FALSE, lib = Sys.getenv('R_LIBS_USER'))" $package_dir
  }
}
