# Finds the knitr caches of pkgdown articles (vignettes\**\<article>_cache) that are older
# than the package functions the article uses, in every R package in Documents\GitHub (or the
# folder given). knitr re-runs a cached chunk only when the chunk's own code changes, not when
# a function it calls does, so an article can go on showing what an old version of the package
# printed; and a lazy build (pkgdown::build_site(lazy = TRUE)) does not even look. An article
# counts as using a function when its chunks call it, or call a function of the package that
# calls it, at any depth.
#   r_article_caches.ps1 [folder] [package ...]   every package, or only the ones named
#   r_article_caches.ps1 -Clean                   deletes the stale caches, and touches their
#                                                 article so that a lazy build rebuilds it
#   r_article_caches.ps1 -Accept                  records every cache as up to date (after a
#                                                 full build)
# With -Clean and -Accept it records, in each cache folder, a fingerprint of the functions the
# article uses (r_article_caches.txt); from then on a function whose code changed is found
# exactly, and named. For a cache without that record git gives the code each function had in
# the last commit before the cache was written, and that is compared with its code now,
# committed or not. Either way only changes to what the code does count: not comments or
# layout, nor = for <- or braces around a single expression. The exit code is 1 if a stale
# cache is left.

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Names,
  [switch]$Clean,
  [switch]$Accept
)

# anything but y/yes is no
function Test-Yes([string]$question) {
  $answer = Read-Host "$question [y/N]"
  return $answer -match '^\s*y(es)?\s*$'
}

# Rscript: on the PATH, or where the R installer put it (the registry, or Program Files)
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

if ($Clean -and $Accept) { Write-Host 'Either -Clean or -Accept, not both'; exit 1 }
if ($Clean) { $mode = 'clean' } elseif ($Accept) { $mode = 'accept' } else { $mode = 'report' }

# the first argument that is an existing folder is the folder, the others are packages
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

# the part of a path inside the folder, as rwf\rwf
function Get-Relative([string]$path) {
  if ($path.StartsWith($Root + [IO.Path]::DirectorySeparatorChar)) { return $path.Substring($Root.Length + 1) }
  return $path
}

# the value of a field of a DESCRIPTION file, as Package
function Get-Field([string]$description, [string[]]$fields) {
  foreach ($line in Get-Content -LiteralPath $description) {
    foreach ($field in $fields) {
      if ($line -cmatch "^${field}:\s*(.*?)\s*$") { return $Matches[1] }
    }
  }
}

# the R part, the same as in r_article_caches.sh: for one package and mode, one line per
# cached article, tab separated: status, article, when the cache was written, how many
# functions it uses, details
$analysis = @'
args <- commandArgs(trailingOnly = TRUE)
package <- args[1]; mode <- args[2]
record_name <- "r_article_caches.txt"
# an argument for git, quoted as the system starts programs (Windows has no ' quotes)
q <- function(x) shQuote(x, type = if (.Platform$OS.type == "windows") "cmd" else "sh")
git_ok <- nzchar(Sys.which("git")) &&
  system2("git", c("-C", q(package), "rev-parse", "--is-inside-work-tree"), stdout = FALSE, stderr = FALSE) == 0

# code with the same meaning written the same way: = as <-, and no braces around a single
# expression (if (x) { y } is if (x) y)
normalize <- function(e) {
  if (!is.call(e)) return(e)
  if (identical(e[[1]], as.name("="))) e[[1]] <- as.name("<-")
  if (identical(e[[1]], as.name("{")) && length(e) == 2) return(normalize(e[[2]]))
  for (i in seq_along(e)[-1]) {
    if (is.null(e[[i]]) || identical(e[[i]], quote(expr = ))) next   # NULL, or an empty argument as in x[i, ]
    part <- normalize(e[[i]])
    if (!is.null(part)) e[[i]] <- part
  }
  e
}

# the functions in the text of an R file (name <- function at the top): their lines, a
# hash of the code without comments and layout, and the names the code uses
read_functions <- function(text) {
  found <- list()
  exprs <- tryCatch(parse(text = text, keep.source = TRUE), error = function(e) NULL)
  if (is.null(exprs)) return(found)
  refs <- attr(exprs, "srcref")
  for (k in seq_along(exprs)) {
    e <- exprs[[k]]
    if (is.call(e) && length(e) == 3 && as.character(e[[1]]) %in% c("<-", "=") && is.name(e[[2]]) &&
        is.call(e[[3]]) && identical(e[[3]][[1]], as.name("function"))) {
      definition <- e[[3]]
      if (length(definition) >= 4) definition[[4]] <- NULL   # the source reference, with the comments
      code <- paste(deparse(normalize(definition)), collapse = "\n")
      found[[as.character(e[[2]])]] <- list(start = refs[[k]][1], end = refs[[k]][3],
        hash = unname(tools::md5sum(bytes = charToRaw(code))), uses = unique(all.names(definition)))
    }
  }
  found
}

# the functions of the package, as its R/*.R files are now
functions <- list()
for (file in list.files(file.path(package, "R"), pattern = "\\.[Rr]$", full.names = TRUE)) {
  for (name in names(found <- read_functions(readLines(file, warn = FALSE)))) {
    functions[[name]] <- c(found[[name]], file = file)
  }
}
known <- names(functions)

# a function and every function of the package it calls, at any depth
closure <- function(roots) {
  seen <- character(); queue <- roots
  while (length(queue)) {
    name <- queue[1]; queue <- queue[-1]
    if (name %in% seen) next
    seen <- c(seen, name)
    queue <- c(queue, setdiff(intersect(functions[[name]]$uses, known), seen))
  }
  seen
}

# the functions of an R file as they were in a commit (from git); NULL when git does not
# know the file or the commit
git <- function(folder, ...) suppressWarnings(system2("git", c("-C", q(folder), ...), stdout = TRUE, stderr = FALSE))
versions <- new.env()
functions_in <- function(file, commit) {
  key <- paste(commit, file)
  if (exists(key, envir = versions, inherits = FALSE)) return(get(key, envir = versions))
  path <- git(dirname(file), "ls-files", "--full-name", "--", q(basename(file)))
  found <- NULL
  if (length(path) && length(commit) && nzchar(commit)) {
    text <- git(dirname(file), "show", q(paste0(commit, ":", path[1])))
    found <- if (is.null(attr(text, "status"))) read_functions(text) else list()
  }
  assign(key, found, envir = versions)
  found
}
# the last commit before a time
commits <- new.env()
commit_before <- function(time) {
  key <- format(floor(as.numeric(time)))
  if (!exists(key, envir = commits, inherits = FALSE)) {
    assign(key, git(package, "rev-list", "-1", paste0("--before=@", key), "HEAD")[1], envir = commits)
  }
  get(key, envir = commits)
}

# whether a function changed since a time: its code then is taken from the last commit
# before that time and compared with its code now, so that only changes to the code count,
# committed since or not committed yet. Without git, or before the first commit, a file
# saved since then counts as a change. Returns how it changed, or NULL
changed_since <- function(name, time) {
  f <- functions[[name]]
  then <- if (git_ok) functions_in(f$file, commit_before(time)) else NULL
  if (is.null(then)) {
    return(if (file.mtime(f$file) > time) "saved since" else NULL)
  }
  if (is.null(then[[name]]) || then[[name]]$hash == f$hash) return(NULL)   # new since, or the same
  head <- functions_in(f$file, "HEAD")
  if (!is.null(head[[name]]) && head[[name]]$hash == then[[name]]$hash) "not committed yet" else "committed since"
}

# the record of a cache: the hash of every function the article uses
write_record <- function(cache, uses) {
  dir.create(cache, showWarnings = FALSE, recursive = TRUE)
  writeLines(paste(uses, vapply(uses, function(n) functions[[n]]$hash, ""), sep = "\t"), file.path(cache, record_name))
}

articles <- list.files(file.path(package, "vignettes"), pattern = "\\.(Rmd|rmd|qmd)$", recursive = TRUE, full.names = TRUE)
for (article in articles) {
  cache <- file.path(dirname(article), paste0(tools::file_path_sans_ext(basename(article)), "_cache"))
  results <- list.files(cache, pattern = "\\.rdb$", recursive = TRUE, full.names = TRUE)
  relative <- substring(article, nchar(package) + 2)
  record <- file.path(cache, record_name)
  if (!length(results) && !file.exists(record)) next   # not cached
  # the R code of its chunks, and the functions of the package that code names
  lines <- readLines(article, warn = FALSE); code <- character(); inside <- FALSE
  for (line in lines) {
    if (!inside && grepl("^\\s*```+\\s*\\{[rR]([ ,}]|$)", line)) { inside <- TRUE; next }
    if (inside && grepl("^\\s*```+\\s*$", line)) { inside <- FALSE; next }
    if (inside) code <- c(code, line)
  }
  words <- unique(unlist(regmatches(code, gregexpr("[A-Za-z.][A-Za-z0-9._]*", code))))
  uses <- closure(intersect(words, known))
  if (!length(results)) {
    # deleted by --clean and not built since: the next build uses the code as it is now,
    # so that is what --clean and --accept record
    if (mode %in% c("clean", "accept")) write_record(cache, uses)
    cat("empty", relative, "", 0, "", sep = "\t", fill = TRUE)
    next
  }
  written <- file.mtime(results)
  cached_at <- min(written)
  if (file.exists(record)) {
    old <- tryCatch(read.delim(record, header = FALSE, col.names = c("name", "hash"), colClasses = "character", quote = ""),
                    error = function(e) data.frame(name = character(), hash = character()))
    old <- setNames(old$hash, old$name)
    now <- vapply(uses, function(n) functions[[n]]$hash, "")
    changed <- uses[uses %in% names(old) & old[uses] != now]
    status <- if (length(changed)) "stale" else "ok"
    details <- paste(changed, collapse = ", ")
  } else {
    how <- lapply(uses, changed_since, time = cached_at); names(how) <- uses
    after <- uses[!vapply(how, is.null, NA)]
    status <- if (length(after)) "probably" else "unrecorded"
    details <- paste(vapply(after, function(n) sprintf("%s (%s)", n, how[[n]]), ""), collapse = ", ")
  }
  if (mode == "clean" && status %in% c("stale", "probably")) {
    unlink(cache, recursive = TRUE)
    write_record(cache, uses)
    Sys.setFileTime(article, Sys.time())
    status <- paste0(status, "+cleaned")
  } else if (mode %in% c("clean", "accept") && status %in% c("ok", "unrecorded")) {
    write_record(cache, uses)
    if (status == "unrecorded") status <- "recorded"
  } else if (mode == "accept") {
    write_record(cache, uses)
    status <- "accepted"
  }
  cat(status, relative, format(cached_at, "%Y-%m-%d %H:%M"), length(uses), details, sep = "\t")
  cat("\n")
}
'@

# the packages: every folder with a DESCRIPTION that has cached articles
$dirs = @()
$skip = '^(\.git|renv|venv|\.venv|node_modules|.*\.Rcheck)$'
$descriptions = Get-ChildItem -LiteralPath $Root -Recurse -Depth 2 -Filter DESCRIPTION -File -ErrorAction SilentlyContinue |
  Where-Object { -not ((Get-Relative $_.DirectoryName) -split '[\\/]' | Where-Object { $_ -match $skip }) } |
  Sort-Object FullName
foreach ($description in $descriptions) {
  $dir = $description.DirectoryName
  $name = Get-Field $description.FullName 'Package'
  if (-not $name) { continue }
  if ($only.Count -gt 0) {
    $folder = Split-Path -Leaf $dir
    if (-not ($only | Where-Object { $_ -ceq $name -or $_ -ceq $folder })) { continue }
  }
  $vignettes = Join-Path $dir 'vignettes'
  if ((Test-Path -LiteralPath $vignettes) -and
      (Get-ChildItem -LiteralPath $vignettes -Recurse -Directory -Filter '*_cache' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
    $dirs += $dir
  }
}
if ($dirs.Count -eq 0) {
  if ($only.Count -gt 0) { Write-Host "No R packages named $($only -join ' ') with cached articles in $Root" }
  else { Write-Host "No R packages with cached articles in $Root" }
  exit 1
}

switch ($mode) {
  'clean'  { Write-Host "Deleting the stale caches of the articles in $Root" }
  'accept' { Write-Host "Recording the caches of the articles in $Root as up to date" }
  default  { Write-Host "Caches of the articles in $Root (nothing is changed; -Clean deletes the stale ones)" }
}

# the R part as a file, removed at the end; R writes UTF-8, which is read as such, and the
# console's setting is put back at the end
$program = Join-Path ([IO.Path]::GetTempPath()) "r_article_caches_$PID.R"
[IO.File]::WriteAllText($program, $analysis, (New-Object Text.UTF8Encoding $false))
$encoding = [Console]::OutputEncoding
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

$staleLeft = 0; $cleaned = 0; $failed = @()
try {
  foreach ($dir in $dirs) {
    Write-Host ''
    Write-Host ('#' * 80)
    Write-Host (Get-Relative $dir) -ForegroundColor Cyan
    $output = @(& $rscript $program $dir $mode 2>&1 | ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
      Write-Host '  could not be read:' -ForegroundColor Red
      $output | Select-Object -Last 5 | ForEach-Object { Write-Host "    $_" }
      $failed += Get-Relative $dir; continue
    }
    foreach ($line in $output) {
      $status, $article, $cachedAt, $uses, $details = $line -split "`t"
      if (-not $article) { continue }
      Write-Host ('  {0,-44} ' -f $article) -NoNewline
      if ($uses -eq '1') { $functions = '1 function' } else { $functions = "$uses functions" }
      switch -Wildcard ($status) {
        'ok'         { Write-Host 'up to date' -ForegroundColor Green -NoNewline; Write-Host "  (cache of $cachedAt, $functions)" }
        'unrecorded' { Write-Host 'no function changed since the cache' -ForegroundColor Green -NoNewline; Write-Host "  ($cachedAt, $functions)" }
        'recorded'   { Write-Host 'up to date, now recorded' -ForegroundColor Green -NoNewline; Write-Host "  ($cachedAt)" }
        'accepted'   { Write-Host 'recorded as up to date' -ForegroundColor Green -NoNewline; Write-Host "  ($cachedAt)" }
        'stale'      { Write-Host 'stale' -ForegroundColor Red -NoNewline; Write-Host ": changed since the cache of ${cachedAt}: $details"; $staleLeft++ }
        'probably'   { Write-Host 'stale' -ForegroundColor Yellow -NoNewline; Write-Host " (cache of $cachedAt; by git): $details"; $staleLeft++ }
        '*+cleaned'  { Write-Host 'cache deleted' -ForegroundColor Green -NoNewline; Write-Host ": $details"; $cleaned++ }
        'empty'      { Write-Host 'cache deleted, not built again yet' }
        default      { Write-Host "$status $details" }
      }
    }
  }
} finally {
  try { [Console]::OutputEncoding = $encoding } catch { }
  Remove-Item -LiteralPath $program -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ('#' * 80)
if ($cleaned -eq 1) { $caches = '1 cache' } else { $caches = "$cleaned caches" }
if ($staleLeft -eq 1) { $stale = '1 stale cache' } else { $stale = "$staleLeft stale caches" }
if ($cleaned -gt 0) { Write-Host "Deleted $caches; their articles are touched, so pkgdown::build_site(lazy = TRUE) rebuilds them" -ForegroundColor Green }
if ($staleLeft -gt 0) { Write-Host "${stale}: r_article_caches.ps1 -Clean deletes them" -ForegroundColor Yellow }
if ($failed.Count -gt 0) { Write-Host "Could not be read: $($failed -join ' ')" -ForegroundColor Red }
if ($staleLeft -eq 0 -and $cleaned -eq 0 -and $failed.Count -eq 0) { Write-Host 'No stale caches' -ForegroundColor Green }
if ($staleLeft -gt 0 -or $failed.Count -gt 0) { exit 1 }
exit 0
