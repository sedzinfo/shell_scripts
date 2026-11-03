#!/usr/bin/env bash
# Finds the knitr caches of pkgdown articles (vignettes/**/<article>_cache) that
# are older than the package functions the article uses, in every R package in
# ~/GitHub (or the folder given). knitr re-runs a cached chunk only when the
# chunk's own code changes, not when a function it calls does, so an article can
# go on showing what an old version of the package printed; and a lazy build
# (pkgdown::build_site(lazy = TRUE)) does not even look. An article counts as
# using a function when its chunks call it, or call a function of the package
# that calls it, at any depth.
#   r_article_caches.sh [folder] [package ...]   every package, or only the ones named
#   r_article_caches.sh --clean                  deletes the stale caches, and touches
#                                                their article so that a lazy build
#                                                rebuilds it
#   r_article_caches.sh --accept                 records every cache as up to date
#                                                (after a full build)
# With --clean and --accept it records, in each cache folder, a fingerprint of
# the functions the article uses (r_article_caches.txt); from then on a function
# whose code changed is found exactly, and named. For a cache without that record
# git gives the code each function had in the last commit before the cache was
# written, and that is compared with its code now, committed or not. Either way
# only changes to what the code does count: not comments or layout, nor = for <-
# or braces around a single expression. The exit code is 1
# if a stale cache is left.

root="$HOME/GitHub"; mode=report; only=(); root_given=0
for arg in "$@"; do
  case "$arg" in
    --clean)   mode=clean ;;
    --accept)  mode=accept ;;
    -h|--help) sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    -*)        echo "Unknown option: $arg (see --help)"; exit 1 ;;
    *)
      if [ $root_given -eq 0 ] && [ -d "${arg/#\~/$HOME}" ]; then
        root="${arg/#\~/$HOME}"; root_given=1
      else
        only+=("$arg")
      fi ;;
  esac
done

# ask for the folder until one that exists is given (Tab completes paths, ~ works)
while [ ! -d "$root" ]; do
  echo "Folder not found: $root"
  read -e -r -p "Folder with the repositories (empty to quit): " root || exit 1
  [ -z "$root" ] && exit 1
  root="${root/#\~/$HOME}"
done
root=$(cd "$root" && pwd)

red=$'\e[31m'; yellow=$'\e[33m'; green=$'\e[32m'; bold=$'\e[1m'; reset=$'\e[0m'

# a line of 80 # characters, between the packages
separator() { printf '#%.0s' {1..80}; printf '\n'; }

command -v Rscript > /dev/null || { echo "R is needed (sudo apt install r-base)"; exit 1; }

# the R part: for one package and mode, one line per cached article, tab separated:
# status, article, when the cache was written, how many functions it uses, details
read -r -d '' analysis <<'EOF'
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
EOF

# the packages: every folder with a DESCRIPTION that has cached articles
dirs=()
while IFS= read -r description; do
  dir=$(dirname "$description")
  name=$(awk -F': *' '$1 == "Package" { print $2; exit }' "$description")
  [ -n "$name" ] || continue
  if [ ${#only[@]} -gt 0 ]; then
    wanted=0
    for want in "${only[@]}"; do
      [ "$want" = "$name" ] || [ "$want" = "$(basename "$dir")" ] && wanted=1
    done
    [ $wanted -eq 1 ] || continue
  fi
  [ -n "$(find "$dir/vignettes" -type d -name '*_cache' -print -quit 2> /dev/null)" ] && dirs+=("$dir")
done < <(find "$root" -maxdepth 3 \
           \( -name .git -o -name '*.Rcheck' -o -name renv -o -name venv -o -name .venv -o -name node_modules \) -prune \
           -o -name DESCRIPTION -type f -print | sort)
if [ ${#dirs[@]} -eq 0 ]; then
  echo "No R packages${only[*]:+ named ${only[*]}} with cached articles in $root"; exit 1
fi

# the R part as a file (Rscript -e takes 10000 bytes at most), removed at the end
program=$(mktemp --suffix=.R)
trap 'rm -f -- "$program"' EXIT
printf '%s\n' "$analysis" > "$program"

case "$mode" in
  clean)  echo "Deleting the stale caches of the articles in $root" ;;
  accept) echo "Recording the caches of the articles in $root as up to date" ;;
  *)      echo "Caches of the articles in $root (nothing is changed; --clean deletes the stale ones)" ;;
esac

stale_left=0; cleaned=0; failed=()
for dir in "${dirs[@]}"; do
  echo
  separator
  echo "${bold}${dir#"$root"/}${reset}"
  if ! output=$(Rscript "$program" "$dir" "$mode" 2>&1); then
    echo "  ${red}could not be read:${reset}"; echo "$output" | tail -n 5 | sed 's/^/    /'
    failed+=("${dir#"$root"/}"); continue
  fi
  while IFS=$'\t' read -r status article cached_at uses details; do
    [ -n "$article" ] || continue
    printf '  %-44s ' "$article"
    [ "$uses" = 1 ] && functions="1 function" || functions="$uses functions"
    case "$status" in
      ok)          echo "${green}up to date${reset}  (cache of $cached_at, $functions)" ;;
      unrecorded)  echo "${green}no function changed since the cache${reset}  ($cached_at, $functions)" ;;
      recorded)    echo "${green}up to date, now recorded${reset}  ($cached_at)" ;;
      accepted)    echo "${green}recorded as up to date${reset}  ($cached_at)" ;;
      stale)       echo "${red}stale${reset}: changed since the cache of $cached_at: $details"; stale_left=$((stale_left + 1)) ;;
      probably)    echo "${yellow}stale${reset} (cache of $cached_at; by git): $details"; stale_left=$((stale_left + 1)) ;;
      *+cleaned)   echo "${green}cache deleted${reset}: $details"; cleaned=$((cleaned + 1)) ;;
      empty)       echo "cache deleted, not built again yet" ;;
      *)           echo "$status $details" ;;
    esac
  done <<< "$output"
done

echo
separator
[ $cleaned -eq 1 ] && caches="1 cache" || caches="$cleaned caches"
[ $cleaned -gt 0 ] && echo "${green}Deleted $caches; their articles are touched, so pkgdown::build_site(lazy = TRUE) rebuilds them${reset}"
[ $stale_left -eq 1 ] && stale="1 stale cache" || stale="$stale_left stale caches"
[ $stale_left -gt 0 ] && echo "${yellow}$stale: r_article_caches.sh --clean deletes them${reset}"
[ ${#failed[@]} -gt 0 ] && echo "${red}Could not be read: ${failed[*]}${reset}"
[ $stale_left -eq 0 ] && [ $cleaned -eq 0 ] && [ ${#failed[@]} -eq 0 ] && echo "${green}No stale caches${reset}"
[ $stale_left -eq 0 ] && [ ${#failed[@]} -eq 0 ]
