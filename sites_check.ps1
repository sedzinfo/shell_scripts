# Checks that the websites and the Shiny apps are live and working: the site at
# https://sedzinfo.github.io/, each site whose sitemap its robots.txt lists, every page of
# each sitemap, and the app each site links to with the live app button of its navigation
# bar. The apps are opened in headless Chrome (or Edge, when Chrome is not installed), which
# waits until Shiny has connected and drawn the first tab (an app asleep on Posit Connect
# Cloud is woken up, which can take a minute or two), and reports the errors on the page.
# Exits 1 when anything is wrong, so it can run from the Task Scheduler.
#   sites_check.ps1                                  websites and apps
#   sites_check.ps1 -NoApps                          only the websites (no browser needed)
#   sites_check.ps1 https://user.shinyapps.io/app/   also this app
# Someone else's sites: sites_check.ps1 -Site https://user.github.io/ (or $env:SITE)
# It never changes anything. Needs R with its curl and chromote packages.

param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Apps,
  [switch]$NoApps,
  [string]$Site = $env:SITE
)
if (-not $Site) { $Site = 'https://sedzinfo.github.io/' }
foreach ($url in $Apps) {
  if ($url -notmatch '^https?://') { Write-Host "Not an address: $url"; exit 2 }
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

# the R packages it needs, installed into your R library when they are missing. Only single
# quotes in the R code, as Windows PowerShell 5.1 drops the double quotes of an argument
$needed = @('curl')
if (-not $NoApps) { $needed += 'chromote' }
$missing = & $rscript -e "cat(Filter(function(p) !requireNamespace(p, quietly = TRUE), commandArgs(TRUE)))" @needed
$missing = @("$missing" -split '\s+' | Where-Object { $_ })
if ($missing.Count -gt 0) {
  Write-Host "The R packages $($missing -join ', ') are not installed; installing them into your R library ..."
  & $rscript -e "lib <- Sys.getenv('R_LIBS_USER'); dir.create(lib, recursive = TRUE, showWarnings = FALSE); install.packages(commandArgs(TRUE), lib = lib, repos = 'https://cloud.r-project.org')" @missing
  if ($LASTEXITCODE -ne 0) { exit 1 }
}

# the check, the same R code as in sites_check.sh
$rCode = @'
# The check, the same in sites_check.sh and sites_check.ps1. Arguments: the address of the
# websites, "apps" or "no-apps", and the addresses of more apps
args <- commandArgs(trailingOnly = TRUE)
site <- sub("/?$", "/", args[1])
with_apps <- identical(args[2], "apps")
more_apps <- args[-(1:2)]
app_timeout <- 240  # seconds an app has to start: one asleep on Connect Cloud takes a minute or two
problems <- character()
line <- function(verdict, name, detail = "") cat(sprintf("  %-12s %-24s %s\n", verdict, name, detail))

# the HTTP status of each address, after redirects; 0 when the server did not answer
http_status <- function(urls) {
  urls <- unique(urls)
  status <- setNames(integer(length(urls)), urls)
  pool <- curl::new_pool(host_con = 6)
  for (url in urls) local({
    u <- url
    curl::curl_fetch_multi(u, pool = pool,
      handle = curl::new_handle(nobody = TRUE, followlocation = TRUE, timeout = 60),
      done = function(res) status[[u]] <<- res$status_code,
      fail = function(msg) status[[u]] <<- 0L)
  })
  curl::multi_run(pool = pool)
  status
}
# the same, with a second try 5 seconds later for the addresses that failed, as GitHub Pages
# now and then answers 503 to one of many requests
http_status_retried <- function(urls) {
  status <- http_status(urls)
  failed <- names(status)[status != 200]
  if (length(failed)) {
    Sys.sleep(5)
    status[failed] <- http_status(failed)
  }
  status
}
fetch <- function(url) {
  res <- tryCatch(curl::curl_fetch_memory(url, handle = curl::new_handle(timeout = 60)), error = function(e) NULL)
  if (is.null(res) || res$status_code != 200) return(NULL)
  rawToChar(res$content)
}

# --- the websites: every sitemap in robots.txt, and every page of each sitemap ---
robots <- fetch(paste0(site, "robots.txt"))
sitemaps <- character()
if (!is.null(robots)) {
  sitemaps <- grep("^Sitemap:", strsplit(robots, "\r?\n")[[1]], value = TRUE, ignore.case = TRUE)
  sitemaps <- trimws(sub("^Sitemap:", "", sitemaps, ignore.case = TRUE))
}
cat("Websites: ", site, " and the ", length(sitemaps), " sites of its robots.txt\n", sep = "")
status <- http_status_retried(site)
if (status == 200) line("ok", site) else {
  line("DOWN", site, if (status == 0) "no answer" else paste("HTTP", status))
  problems <- c(problems, paste0(site, ": down"))
}
if (is.null(robots)) problems <- c(problems, paste0(site, "robots.txt: cannot be read, so no site was checked"))
app_links <- character()
for (sitemap in sitemaps) {
  home <- sub("sitemap\\.xml$", "", sitemap)
  name <- sub("/$", "", sub(site, "", home, fixed = TRUE))
  xml <- fetch(sitemap)
  if (is.null(xml)) {
    line("NO SITEMAP", name, sitemap)
    problems <- c(problems, paste0(name, ": no sitemap at ", sitemap))
    next
  }
  pages <- gsub("</?loc>", "", regmatches(xml, gregexpr("<loc>[^<]+</loc>", xml))[[1]])
  status <- http_status_retried(c(home, pages))
  broken <- status[status != 200]
  if (length(broken)) {
    line("BROKEN", name, sprintf("%d of %d pages", length(broken), length(status)))
    for (page in names(broken)) {
      cat(sprintf("%16s  %s\n", if (broken[[page]] == 0) "no answer" else paste("HTTP", broken[[page]]), page))
    }
    problems <- c(problems, sprintf("%s: %d broken pages", name, length(broken)))
  } else {
    line("ok", name, sprintf("%d pages", length(status)))
  }
  # the app of the site, from the live app button of its navigation bar
  if (with_apps && status[[home]] == 200) {
    html <- fetch(home)
    link <- regmatches(html, regexpr('<a[^>]*aria-label="Open the live app"[^>]*>', html))
    if (length(link)) app_links[name] <- sub('.*href="([^"]+)".*', "\\1", link)
  }
}

# --- the apps: each opened in headless Chrome, all at once ---
# an app given is named by the last part of its path, or by the first part of its host name
# (all of it for an IP address)
names(more_apps) <- vapply(strsplit(sub("^https?://", "", sub("/+$", "", more_apps)), "/"), function(parts) {
  if (length(parts) > 1) parts[length(parts)] else if (grepl("^[0-9]", parts[1])) parts[1] else sub("[.].*", "", parts[1])
}, "")
apps <- c(app_links, more_apps)
apps <- apps[!duplicated(apps)]
if (with_apps && length(apps)) {
  given <- sum(!more_apps %in% app_links)
  cat("\nApps: ", length(app_links), " linked from the websites",
      if (given) paste0(" and ", given, " more given"), "\n", sep = "")
  chrome <- suppressMessages(tryCatch(chromote::find_chrome(), error = function(e) NULL))
  edge <- file.path(Sys.getenv("ProgramFiles(x86)"), "Microsoft", "Edge", "Application", "msedge.exe")
  if (is.null(chrome) && .Platform$OS.type == "windows" && file.exists(edge)) {
    Sys.setenv(CHROMOTE_CHROME = edge)  # Edge, which every Windows has, does as well
    chrome <- edge
  }
  if (is.null(chrome)) {
    line("NOT CHECKED", "apps", "Chrome or Chromium is needed to open them")
    problems <- c(problems, "apps: not checked, Chrome or Chromium is missing")
    apps <- character()
  }
} else if (with_apps) {
  cat("\nApps: none linked from the websites\n")
}
if (with_apps && length(apps)) {
  # the state of the app, found in the page or in a frame of the same site (shinyapps.io puts
  # the app in a frame): starting, busy, ready, or disconnected (the grey screen of a crash);
  # the errors of its outputs, the error notifications, and the messages of validate()
  state_js <- "(function() {
    function find(w) {
      try { if (w.Shiny && w.Shiny.shinyapp) return w; } catch (e) {}
      var frames = [];
      try { frames = w.document.querySelectorAll('iframe'); } catch (e) {}
      for (var i = 0; i < frames.length; i++) {
        try { var found = find(frames[i].contentWindow); if (found) return found; } catch (e) {}
      }
      return null;
    }
    var w = find(window);
    if (!w) return JSON.stringify({state: 'starting', text: document.body ? document.body.innerText.slice(0, 200) : ''});
    var d = w.document;
    // the outputs of the tabs not shown stay marked as recalculating until their tab is opened
    var visible = function(selector) {
      return Array.prototype.filter.call(d.querySelectorAll(selector), function(e) { return e.getClientRects().length > 0; });
    };
    var texts = function(selector) {
      return Array.prototype.map.call(d.querySelectorAll(selector), function(e) {
        return (e.id ? e.id + ': ' : '') + e.textContent.trim().replace(/\\s+/g, ' ').slice(0, 150);
      });
    };
    var crashed = !!d.getElementById('shiny-disconnected-overlay');
    var state = crashed ? 'disconnected' : !w.Shiny.shinyapp.isConnected() ? 'starting' :
      (d.documentElement.classList.contains('shiny-busy') || visible('.recalculating').length) ? 'busy' : 'ready';
    return JSON.stringify({
      state: state,
      errors: texts('.shiny-output-error:not(.shiny-output-error-validation)').concat(texts('.shiny-notification-error')),
      messages: texts('.shiny-output-error-validation')
    });
  })()"

  tabs <- lapply(apps, function(url) {
    tab <- chromote::ChromoteSession$new(width = 1440, height = 1000)
    # an app asleep on Connect Cloud can take minutes to answer
    promises::catch(tab$Page$navigate(url, wait_ = FALSE, timeout_ = app_timeout), function(e) NULL)
    tab
  })
  info <- lapply(apps, function(url) list(state = "starting"))
  ready_since <- rep(NA_real_, length(apps))
  done <- rep(FALSE, length(apps))
  started <- Sys.time()
  # an app is ready once Shiny has been connected and idle for 3 seconds
  while (!all(done)) {
    Sys.sleep(1)
    elapsed <- as.numeric(difftime(Sys.time(), started, units = "secs"))
    for (i in which(!done)) {
      value <- tryCatch(tabs[[i]]$Runtime$evaluate(state_js, timeout_ = 10)$result$value, error = function(e) NULL)
      if (is.character(value)) info[[i]] <- jsonlite::fromJSON(value)
      if (identical(info[[i]]$state, "ready")) {
        if (is.na(ready_since[i])) ready_since[i] <- elapsed
        done[i] <- elapsed - ready_since[i] >= 3
      } else {
        ready_since[i] <- NA
        done[i] <- identical(info[[i]]$state, "disconnected") || elapsed > app_timeout
      }
    }
  }
  for (i in seq_along(apps)) {
    x <- info[[i]]
    verdict <- switch(x$state,
      ready = if (length(x$errors)) "ERRORS" else "ok",
      busy = "STILL BUSY",
      disconnected = "CRASHED",
      "NOT STARTED"
    )
    line(verdict, names(apps)[i], if (x$state == "ready") sprintf("%s  ready in %.0f s", apps[[i]], ready_since[i])
         else if (x$state == "disconnected") apps[[i]] else sprintf("%s  after %d s", apps[[i]], app_timeout))
    for (e in x$errors) cat("                 error:  ", e, "\n")
    for (m in x$messages) cat("                 message:", m, "\n")
    if (x$state == "starting" && !is.null(x$text) && nzchar(x$text)) {
      cat("                 the page says:", gsub("\\s+", " ", x$text), "\n")
    }
    if (verdict != "ok") problems <- c(problems, paste0(names(apps)[i], ": ", tolower(verdict)))
    tabs[[i]]$close()
  }
}

cat("===============================\n")
if (length(problems)) {
  cat("With a problem (", length(problems), "):\n", sep = "")
  cat(paste0("  ", problems, "\n"), sep = "")
  quit(status = 1)
}
cat("No problems\n")
'@

$code = Join-Path ([IO.Path]::GetTempPath()) "sites_check_$PID.R"
[IO.File]::WriteAllText($code, $rCode)
$mode = if ($NoApps) { 'no-apps' } else { 'apps' }
& $rscript $code $Site $mode @Apps
$status = $LASTEXITCODE
Remove-Item -LiteralPath $code -ErrorAction SilentlyContinue
exit $status
