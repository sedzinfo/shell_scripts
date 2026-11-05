# shell_scripts

Small bash scripts: looking after many git repositories at once, and keeping an eye on the machine.
The git scripts work on `~/GitHub` by default; if that folder does not exist, they ask for one
(Tab completes paths, `~` works, an empty answer quits). Each one except `hwrt_pi.sh`,
`machine_new.sh` and `tmux_update_plugins.sh` also comes as a PowerShell script for Windows
(`.ps1`); see [Windows](#windows).

Every script asks before it deletes, overwrites, pushes or installs anything, after
showing what that is. Where a script has `--yes` (`-Yes` on Windows), that answers
the question in advance; without a terminal to ask in (cron), such a script does
nothing unless given `--yes`. A script that takes a folder and names (of
repositories or packages) takes the folder as a path, such as `~/GitHub`, `.` or
`../work`: a plain word is a name, even when a folder of that name is where it runs.

When a program a script needs is missing (`lm-sensors`, `alsa-utils`, `pciutils`,
`curl`, `jq`, `fio`), the script says what it is for and asks before installing it with
`sudo apt install`. Answer no and it goes on with what it can (`git_clone_all.sh`
stops, since it cannot work without `curl` and `jq`). Graphics drivers such as
NVIDIA's are never offered.

| Script | What it does | Changes anything? |
|---|---|---|
| [`git_status_all.sh`](git_status_all.sh) | One line per repository: clean, or what is not yet on GitHub | No |
| [`git_pull_all.sh`](git_pull_all.sh) | Pulls every repository | Yes, asks before anything destructive |
| [`git_clone_all.sh`](git_clone_all.sh) | Clones every repository of a GitHub user that is not downloaded yet | Only adds new folders |
| [`git_push_checked.sh`](git_push_checked.sh) | Pushes what is not on GitHub yet, once R CMD check passes for each R package it changes | Pushes what passes, after asking; commits nothing |
| [`git_actions_all.sh`](git_actions_all.sh) | The latest GitHub Actions run of every workflow of every repository, problems first, and which repositories have a problem | No |
| [`git_large_files_all.sh`](git_large_files_all.sh) | Finds files that GitHub would refuse (over 100 MB) or warn about (over 50 MB), files that should be in Git LFS, and LFS files never downloaded | No |
| [`git_lfs_prune_all.sh`](git_lfs_prune_all.sh) | Frees the space of the local copies of old Git LFS versions (`git lfs prune`), which GitHub keeps | Deletes them, after asking |
| [`hwrt.sh`](hwrt.sh) | Live view of RAM, CPU speed, GPU, temperatures and fans; beeps when RAM is low | No |
| [`hwrt_pi.sh`](hwrt_pi.sh) | The same for a Raspberry Pi, plus the power supply (under-voltage, throttling) | No |
| [`disk_speed.sh`](disk_speed.sh) | Read and write speed of every drive, on a PC or a Raspberry Pi | Only a temporary test file, deleted at the end |
| [`r_shiny_update_manifests.sh`](r_shiny_update_manifests.sh) | Regenerates `manifest.json` of the Shiny apps for Posit Connect | Rewrites `manifest.json` only, after asking |
| [`r_install_packages.sh`](r_install_packages.sh) | Installs the system and R packages a repository needs | Installs, after asking |
| [`r_document_all.sh`](r_document_all.sh) | Updates the help pages and `NAMESPACE` of every R package from its roxygen comments; `--check` lists the ones out of date | Rewrites `man/` and `NAMESPACE` after asking (not with `--check`); commits nothing |
| [`r_cmd_check.sh`](r_cmd_check.sh) | Runs R CMD check on every R package and reports which have errors, warnings or notes | No (works in `~/.cache`) |
| [`r_pkgdown_all.sh`](r_pkgdown_all.sh) | Builds the pkgdown website of every R package and reports failed builds and failing examples | Rewrites each site (`docs/`), after asking; commits nothing |
| [`r_pdf_all.sh`](r_pdf_all.sh) | Makes the PDF reference manual of every R package | Rewrites `<package>.pdf` in each repository, or writes to `--to`, after asking; commits nothing |
| [`r_article_caches.sh`](r_article_caches.sh) | Finds the knitr caches of pkgdown articles that are older than the package functions they use | No (`--clean` deletes the stale caches, after asking) |
| [`machine_new.sh`](machine_new.sh) | Sets up a new computer with Linux Mint with the programs of the old one | Installs, asks before each step |
| [`machine_leave.sh`](machine_leave.sh) | Before handing back a computer: checks that everything is on GitHub, then removes your repositories, GitHub key and logins | Yes, asks before each step |
| [`tmux_update_plugins.sh`](tmux_update_plugins.sh) | Updates the tmux plugins (TPM) and repairs what copying their folder broke | Only the plugins, after asking; never your tmux configuration |
| [`ssh_setup_keys.sh`](ssh_setup_keys.sh) | Sets up passwordless SSH logins to every machine of a list | Adds your public key on the machines that need it; asks before creating a key |
| [`ssh_run_all.sh`](ssh_run_all.sh) | Runs a command on every machine of the same list, one after the other or all at once | Whatever the command does; asks before running it |

## git_status_all.sh

```bash
git_status_all.sh [folder] [--no-fetch]
```

Shows, for each repository, its branch and one of:

- **clean** (green): everything is committed and on GitHub
- **N uncommitted** (red): changed or new files not yet committed
- **N to push** (red): commits that are not on GitHub yet
- **N to pull** (yellow): commits on GitHub that are not here yet
- **N other branches not on GitHub** (red): local branches with commits that are on no
  branch of GitHub
- **N stashed** (red): changes put aside with `git stash`
- **no upstream branch** / **detached HEAD** / **not fetched** (yellow); not fetched:
  GitHub could not be reached, so the counts may be out of date

It fetches from GitHub first so the counts are current; `--no-fetch` skips that
(faster, or when offline). It never changes any files. Handy before leaving
work, to see what was forgotten.

## git_pull_all.sh

```bash
git_pull_all.sh [folder]
```

Fetches every repository and moves it forward to match GitHub (`git merge --ff-only`,
as `git pull --ff-only` does), so a repository is never merged or rebased.

When that fails (local commits that are not on GitHub, or uncommitted changes
that clash with the incoming ones), it lists what would be lost and asks:

```
git reset --hard origin/main? This DELETES the above [y/N]:
```

- **y / yes**: the repository becomes exactly the GitHub version; the listed
  local commits and changes are lost. Files git does not track are kept, except
  those that the GitHub version also has, which it lists separately and replaces
- anything else, or Enter: the repository is left as it is

Repositories on a detached HEAD or without an upstream branch are skipped, and a
reset is never offered when GitHub could not be reached. At the end it lists what
was pulled and what was not; the exit code is 1 if anything was not pulled.

## git_clone_all.sh

```bash
git_clone_all.sh [folder] [user]
```

Asks GitHub for the repositories owned by `user` (default `sedzinfo`) and runs
`git clone` (over SSH) for each one that is not in the folder yet. Folders that
already exist are skipped and never touched, so it is safe to run again; to
update them, use `git_pull_all.sh`. It only checks the folder name.

Without a token only public repositories are listed. To include private ones,
create a token (classic, `repo` scope) at <https://github.com/settings/tokens>
and pass it for that run only; do not write it in the script (private ones are
listed only when `user` is the token's owner):

```bash
GITHUB_TOKEN=ghp_... git_clone_all.sh
```

Needs `curl` and `jq`.

## git_actions_all.sh

```bash
git_actions_all.sh [owner ...] [--problems]
```

Asks GitHub for the repositories of each `owner`, a user or an organisation
(default `sedzinfo`; archived ones are left out), and shows the latest run of
each of their workflows, one line each, with its result, branch, date and link:

- **failure**, **cancelled**, **timed_out**, ...: first, these are the problems
- **in_progress**, **queued**: still running
- **success** (or skipped): last

At the end it lists the repositories with a problem, and how many have no
Actions at all; the exit code is 1 if any repository has a problem, so it can
run from cron. `--problems` leaves out the lines that passed. Only the latest
run of a workflow counts: a failure that a later run fixed is not shown.

```bash
git_actions_all.sh sedzinfo evalioncode   # your repositories and an organisation's
git_actions_all.sh --problems             # only what failed or is still running
```

Without a token only public repositories are listed, and GitHub allows 60
requests an hour, one per repository. With the GitHub CLI logged in
(`gh auth login`) its token is used by itself; otherwise pass one for that run
(classic, `repo` scope, from <https://github.com/settings/tokens>; for the
private repositories of an organisation, the token of a member):

```bash
GITHUB_TOKEN=ghp_... git_actions_all.sh sedzinfo evalioncode
```

It never changes anything. Needs `curl` and `jq`.

## git_push_checked.sh

```bash
git_push_checked.sh                    # every repository in ~/GitHub
git_push_checked.sh worldbank snp      # only these repositories
git_push_checked.sh --dry-run          # checks, but pushes nothing
git_push_checked.sh --strict           # notes also stop a push
git_push_checked.sh --yes              # pushes without asking first
```

Pushes the commits that are not on GitHub yet, as `git push` in each
repository would, but first runs `R CMD check` (with `r_cmd_check.sh`) on each
R package those commits change, and pushes a repository only when its packages
pass: no errors or warnings, and with `--strict` no notes either. Half-finished
work then stays on this computer instead of reaching GitHub and starting the
build-tarball workflow. It first lists the repositories with commits to push and
asks before it checks and pushes them (`--yes` does not ask, and without a
terminal to ask in, it pushes nothing unless given `--yes`):

```text
worldbank  (main, 1 commit to push)
  bf3ff77 fix
  checking worldbank on a clean copy of the last commit
  worldbank 0.0.0.9000  (worldbank)
    1 WARNING
      WARNING: data for ASCII and uncompressed saves
  not pushed: worldbank 1 WARNING
```

The check runs on a clean copy of the last commit (a git worktree in
`~/.cache/git_push_checked`), exactly what is pushed, so uncommitted or
untracked files neither help nor spoil it; they stay as they are and are not
pushed. Only the commit that was listed is checked and pushed, to the branch's
upstream: commits made while the checks run, or a switch to another branch,
wait for the next run. Commits that change nothing that goes into a package (its site in
`docs/`, or other files left out by `.Rbuildignore`) are pushed without a
check, as are repositories without R packages.

A repository that is behind GitHub is not pushed (pull first, with
`git_pull_all.sh`), and one without an upstream branch is skipped. A name that
matches no repository stops it before anything is checked. At the end, a table
of the repositories with commits to push and what happened to each. Nothing is
committed; the exit code is 1 if any repository with commits to push was not
pushed. Needs R and `r_cmd_check.sh` next to it.

## git_large_files_all.sh

```bash
git_large_files_all.sh                  # every repository in ~/GitHub
git_large_files_all.sh rwf worldbank    # only these
git_large_files_all.sh --size 20M       # also smaller files (default 50M)
git_large_files_all.sh --history        # also the largest files ever committed
```

GitHub warns about a file over 50 MB and refuses a push with a file over
100 MB, even one that a later commit deletes again. For each repository this
lists, largest first:

- files over 100 MB in commits not pushed yet: the push would fail
- files over the size without Git LFS, committed or not yet (`git add` would add them)
- files that `.gitattributes` puts in LFS but that were committed without it
  (usually before `git lfs install`)
- LFS files whose content was never downloaded (`git lfs pull` fetches them)

```text
rscripts_repo  (main)
     54.0 MB  scoring/tirt_scoring/models/model_scores_parallel_response_patterns.csv in git, not in LFS: GitHub warns
    git lfs migrate import --no-rewrite FILE moves a committed file to LFS in a new commit (older commits keep it)
```

Under each repository it says which command fixes what it found. `--history`
also shows what makes `.git` big: the files ever committed, each with its
versions added up, which stay in `.git` after they are deleted (taking them out
means rewriting the history with `git filter-repo`), and the local copies of
old LFS versions, which `git lfs prune` deletes (GitHub keeps them):

```text
golemworldbank  (main)
  .git is 6,0G: 252M of commits, 5,8G of LFS copies
  largest files ever committed:
    282.9 MB  worldbankmodular_0.0.1.tar.gz  (4 versions)
    taking them out of .git means rewriting the history (git filter-repo), which changes every commit since
    git lfs prune would free 5.5 GB: the local copies of 142 old LFS versions (GitHub keeps them)
```

Nothing is changed; the exit code is 1 if GitHub would refuse a push.
[`git_lfs_prune_all.sh`](#git_lfs_prune_allsh) frees the space of the LFS copies.

## git_lfs_prune_all.sh

```bash
git_lfs_prune_all.sh                  # every repository in ~/GitHub
git_lfs_prune_all.sh rwf worldbank    # only these
git_lfs_prune_all.sh --dry-run        # only shows what would be freed
git_lfs_prune_all.sh --yes            # prunes without asking
```

Git LFS keeps in `.git/lfs` a copy of every version of an LFS file it ever
downloaded, so a file that changed often can take more space there than all the
commits. Only old commits need the old versions: GitHub keeps every one, and
`git lfs` downloads one again when a checkout needs it. This shows how much
`git lfs prune` would free in each repository, and deletes nothing until you
answer yes:

```text
  rscripts_repo               652 MB of    940 MB  (267 old versions)
  rwf                         126 MB of    138 MB  (1434 old versions)
  nothing to free in 21 other repositories

Total: 778 MB
Delete them? Git asks origin first that it has them [y/N]:
```

It keeps what `git lfs prune` keeps: the files of the current checkout, the
stashes, the other worktrees, the branches with a commit in the last 10 days,
and the commits not pushed yet. Before deleting, git asks origin whether it has
the versions that commits still use (`--verify-remote`); if one is missing there,
nothing of that repository is deleted. Versions that only the reflog still knows
(from before a `git commit --amend` or a rebase) are deleted too. A repository
without an `origin` keeps everything, and one with its own LFS storage
(`lfs.storage`), which others may share, is skipped. The exit code is 1 if a
repository could not be pruned.

## hwrt.sh

```bash
hwrt.sh     # Ctrl+C to quit
```

Every 5 seconds (updating in place, without flashing) shows the available RAM (MB), the CPU speed, the Intel graphics
(speed and how busy they are), the NVIDIA GPU temperature (only
on machines with an NVIDIA card), all temperatures and the fan speeds. When less
than 3000 MB of RAM is available it plays a tone with `speaker-test`.
Temperatures and fans come from `lm-sensors` (`sudo apt install lm-sensors`).

## hwrt_pi.sh

```bash
hwrt_pi.sh  # Ctrl+C to quit
```

`hwrt.sh` for a Raspberry Pi, in the same layout:

- available RAM (it beeps below 10% of the RAM, as a Pi has 1 to 16 GB; the
  terminal bell too, since a Pi often has no speakers)
- CPU speed, cores and model; GPU (VideoCore) speed and memory
- the chip temperature (it slows down at 80°C, stops at 85°C), on a Pi 5 the
  power chip too, the core voltage
- **Power**: OK, or what is wrong now (under-voltage, speed capped, throttled,
  temperature limit) and what has happened since the Pi started. Under-voltage
  means a weak power supply or cable, the most common cause of a slow Pi.
- the fan speed (the official Pi 5 fan, or any fan the kernel knows)

The Pi lines need `vcgencmd` (on Raspberry Pi OS; the user must be in the
`video` group). Without it the script still shows RAM, CPU, temperatures and fans.

## disk_speed.sh

```bash
disk_speed.sh                 # every drive
disk_speed.sh sda nvme0n1     # only these (the names lsblk shows)
disk_speed.sh --list          # only show the drives and how each would be tested
```

How fast each drive reads and writes, in MB/s, with the tests of CrystalDiskMark:
**SEQ1M Q8** (large files), **RND4K Q32** (many small reads and writes at once)
and **RND4K Q1** (one small read or write at a time: the slowest, and closest to
how fast a system disk feels). Works on a PC and on a Raspberry Pi (SD card, USB
drives, NVMe on a Pi 5).

- A drive with a mounted filesystem that has room is tested with a temporary file
  (`.disk_speed.<number>.tmp`) on its filesystem with the most free space, also
  inside LUKS or LVM: written, read, and deleted at the end, also on Ctrl+C. On a
  slow drive the file is written for at most 30 seconds, so it can be smaller than
  asked for.
- A drive with nothing mounted (another system's disk, BitLocker, a closed LUKS
  drive) is only read, straight from the drive, and its write column shows `-`.
  Nothing is ever written to a drive itself: fio runs there with `--readonly`.
- `--read-only` tests every drive that way, writing nothing at all.
- `--size 256M` makes the test file smaller (default `1G`), quicker on SD cards and
  USB sticks; `--time 10` runs each test longer (default 5 seconds).
- On a filesystem that cannot bypass the cache (some NTFS and exFAT drives, ZFS)
  the file is tested through the cache, emptied before each read; it says so, and
  the numbers are rougher.

It runs itself with sudo (it asks for the password), since reading a drive
directly and writing on `/` need root. Needs `fio`. A drive takes about half a
minute (6 tests of 5 seconds), one that is only read about 15 seconds.

## r_shiny_update_manifests.sh

```bash
r_shiny_update_manifests.sh              # every app in ~/GitHub that has a manifest.json
r_shiny_update_manifests.sh golemirt     # only the apps named (also makes a first manifest)
r_shiny_update_manifests.sh --yes        # without asking first
ROOT=~/Projects r_shiny_update_manifests.sh
```

Posit Connect (Cloud) installs an app from its `manifest.json`: the list of R
packages, with their versions, that the app uses. After updating packages in R,
the manifest is out of date. It lists the apps and asks first; then for each app
(a folder with `app.R`) it runs `rsconnect::writeManifest()` on the app's files,
without the ones git ignores (such as `.Renviron`, which would otherwise be
deployed with its secrets), and says whether the manifest was **updated** or
**unchanged**. It fails for an app that uses a package not installed here, as
`writeManifest()` would quietly leave the package out; the message says which
(install it in R and run again). Apps with an `app.R` but no `manifest.json` are
listed but not touched. Nothing is committed: commit and push the updated
`manifest.json` files for Posit Connect to use them.

The versions written are the ones installed on the computer it runs on, so run
it where the apps work.

## r_install_packages.sh

```bash
r_install_packages.sh ~/GitHub/rwf     # or with no folder: the current one
```

Installs what the R code of a repository needs, in three steps, each one
listed first and asked (`y`) before anything is installed:

1. **System packages** (apt) that the R packages need to compile, such as
   `libcurl4-openssl-dev`, `libxml2-dev` or `default-jdk` (for rJava).
   Worked out by the R package `pak`; on Linux Mint it uses the Ubuntu version
   Mint is built on. A Java or pandoc that is already there counts as installed.
2. **R packages** not installed yet, into your own R library (no sudo):
   - for an R package (a `DESCRIPTION`, also one folder down as in `rwf/rwf`):
     its Depends, Imports, LinkingTo and Suggests
   - otherwise (analyses, Quarto sites such as `vignettes`): the packages the
     `.R`, `.Rmd` and `.qmd` files load
3. **The repository's own package** (for example rwf itself).

Packages already installed are not touched or upgraded. If R, the compilers or
`pak` are missing, it offers to install them first.

## r_document_all.sh

```bash
r_document_all.sh                      # every R package in ~/GitHub
r_document_all.sh rwf mleirt           # only these (package or folder names)
r_document_all.sh --check              # only list the ones out of date
r_document_all.sh --yes                # without asking first
```

Updates the help pages (`man/*.Rd`) and `NAMESPACE` of each R package from its
roxygen comments with `roxygen2::roxygenise()`, which is what
`devtools::document()` does for one package. `r_cmd_check.sh`,
`r_pkgdown_all.sh` and `r_pdf_all.sh` use `man/` as it is, so run this first;
otherwise a help page whose comments changed since it was last written is
checked and published as it was.

It lists the packages and asks before it writes anything (`--yes` does not
ask). For each package it lists the files that changed and roxygen's warnings
(such as a topic skipped for having no title); at the end, the repositories with
changes, to commit and push. With `--check` roxygen runs on a copy of each
package, so nothing changes, and it lists the packages whose help pages or
`NAMESPACE` no longer match their comments:

```text
Out of date in 2: covid mleirt
  r_document_all.sh covid mleirt updates them; git diff then shows what changed
```

Roxygen also writes its own version into `DESCRIPTION`; `--check` ignores that
line, and when a package was last documented with another major or minor
roxygen2 version (covid with 7.3.2), it says that some differences may only be
layout. Mirror repositories are each documented, and packages without roxygen
comments are skipped. Roxygen loads each package, so what it uses must be
installed (`r_install_packages.sh`). Nothing is committed or pushed; the logs
are in `~/.cache/r_document_all`. The exit code is 1 if any failed, or with
`--check` if any is out of date. Needs R and roxygen2 (it offers to install it).

## r_cmd_check.sh

```bash
r_cmd_check.sh                     # every R package in ~/GitHub
r_cmd_check.sh rwf mleirt          # only these (package or folder names)
r_cmd_check.sh ~/Projects          # another folder
r_cmd_check.sh --as-cran           # as CRAN checks a submission
r_cmd_check.sh --manual            # also the PDF manual (needs LaTeX)
```

Runs `R CMD check` on each R package (a folder with a `DESCRIPTION`, also one
folder down as in `rwf/rwf`), one after the other: first `R CMD build`, as for
CRAN (`.Rbuildignore` applied, vignettes built), then the check of the tarball.
For each package it shows the result and the checks that were not OK; an error
with its last lines, where R's error message is:

```text
generaterpm 0.1.0  (raven_like_progressive_matrix)
  1 ERROR, 1 WARNING, 1 NOTE
    NOTE: dependencies in R code
    WARNING: Rd \usage sections
        Undocumented arguments in Rd file 'fill_rectangle_nn.Rd'
    ERROR: examples
        Error in fill_rectangle_nn(items, labels = seq_along(items), ncol = 3,  :
          unused argument (labels = seq_along(items))
```

At the end, a table of all packages (version, time, result) and the lists of
the ones with errors and with warnings. The exit code is 1 if any package has
errors.

The repositories are not changed: everything is built and checked in
`~/.cache/r_cmd_check_all/<package>`, where the full logs stay until the next run.
The same package in two folders (`crypto` and `golemcrypto`) is checked once.
Unlike CRAN, a suggested package that is not installed does not stop a check,
and the tests marked `skip_on_cran()` run (as with `devtools::check()`);
`--as-cran` keeps CRAN's rules. `r_install_packages.sh` installs what a package
needs.

## r_pkgdown_all.sh

```bash
r_pkgdown_all.sh                   # the site of every R package in ~/GitHub
r_pkgdown_all.sh rwf mleirt        # only these (package or folder names)
r_pkgdown_all.sh --no-examples     # without running the examples (quicker)
r_pkgdown_all.sh --yes             # without asking first
```

Builds the pkgdown website of each R package that has a `_pkgdown.yml`, with
`pkgdown::build_site()`, into the folder GitHub Pages publishes it from:
`docs/`, or the `destination` in `_pkgdown.yml` (`../docs` for rwf). It lists the
sites and asks first (`--yes` does not ask). For each
package it says whether the build worked, how many files of the site changed,
pkgdown's warnings (such as missing alt-text), and the help pages whose
examples fail: pkgdown still builds those pages, with the error in them, so
they are easy to miss (also on the pages of the development version, in
`docs/dev/reference`). At the end it lists the failed builds, the examples
with errors, and the repositories whose site changed; after `--no-examples` it
says to build again before committing, as the help pages then show no examples:

```text
Examples with errors (the help page shows the error):
  raven_like_progressive_matrix: compute_operation_sequence fill_rectangle_nn ...
Changed sites, to commit and push for GitHub Pages: raven_like_progressive_matrix snp
```

Nothing is committed or pushed. Mirror repositories (`crypto` and
`golemcrypto`) each get their own site, as each publishes its own. Packages
without a `_pkgdown.yml` are listed and skipped (`pkgdown::use_pkgdown()` sets
one up). The logs are in `~/.cache/r_pkgdown_all`; the exit code is 1 if any
build failed. Needs R, pkgdown (it offers to install it) and pandoc.

## r_pdf_all.sh

```bash
r_pdf_all.sh                       # the manual of every R package in ~/GitHub
r_pdf_all.sh rwf mleirt            # only these (package or folder names)
r_pdf_all.sh --to ~/manuals        # all of them in one folder instead
r_pdf_all.sh --yes                 # without asking first
```

Makes the PDF reference manual of each R package, the one CRAN shows, with
`R CMD Rd2pdf`: every help page, with an index. By default it writes
`<package>.pdf` at the top of the repository (`rwf/rwf.pdf`,
`raven_like_progressive_matrix/generaterpm.pdf`), where the build-tarball
workflows put it; they rebuild it on every push anyway, so this is for seeing
LaTeX errors before pushing. With `--to` all the manuals go in one folder,
one per package (of mirror repositories with the same package, the first by
name is made, `crypto`, and `golemcrypto` is skipped there), and the
repositories are not touched. It lists the manuals and asks first (`--yes` does
not ask). A PDF that could not be replaced (one open in a viewer that locks it)
counts as failed, not as written.

For each package it shows the pages and size of the PDF, or, when LaTeX
fails, LaTeX's first error with the line it is on (usually a `\eqn{}` or
special character in a help file). At the end, the list of failed manuals;
the exit code is 1 if any failed. The logs are in `~/.cache/r_pdf_all`.
Needs R and LaTeX with the inconsolata font: TinyTeX
(`tinytex::install_tinytex()`), or TeX Live with `texlive-fonts-extra`
(the LaTeX step of `machine_new.sh`); it offers what is missing.

## r_article_caches.sh

```bash
r_article_caches.sh                  # every package in ~/GitHub with cached articles
r_article_caches.sh rwf              # only this one
r_article_caches.sh --clean          # deletes the stale caches, after asking
r_article_caches.sh --clean --yes    # without asking
r_article_caches.sh --accept         # records every cache as up to date (after building
                                     # the articles anew, with their caches deleted)
```

knitr runs a cached chunk again only when the chunk's own code changes, not when a
function it calls does. So after a fix in the package, an article can go on showing
what the old version printed, without any error, and a lazy build
(`pkgdown::build_site(lazy = TRUE)`, which rebuilds only the articles whose `.Rmd`
changed) does not even look. This finds those caches: for every article with a
cache (`vignettes/**/<article>_cache`) it reads which functions of the package its
chunks call, and also the functions those call, at any depth (also in their default
arguments, the operators such as `%+%`, and the methods of a generic such as
`print.myclass`), and checks whether any of them changed after the cache was written:

```text
vignettes/articles/EXPLORE_ASSUMPTIONS.rmd   stale (cache of 2026-10-29 16:54; by git): report_normality_tests (committed since)
vignettes/articles/FUNCTIONS_RECODE.rmd      stale: changed since the cache of 2026-10-29 16:54: change_data_type
vignettes/articles/GLM_FRIEDMAN.rmd          up to date  (cache of 2026-10-29 16:56, 1 function)
```

Only changes to what a function does count, not comments or layout, `=` for `<-`, or
braces around a single expression. `--clean` lists the stale caches and asks, then
deletes them and touches their articles (their date only, not their content), so that
the next lazy build rebuilds exactly those (`--yes` does not ask, and without a
terminal to ask in, nothing is deleted unless given `--yes`). `--accept` records the
caches as they are, so use it only after building the articles anew with their caches
deleted, as a full build reuses the stale ones. With `--clean` and `--accept` it also keeps, in each cache
folder, a fingerprint of the functions the article uses (`r_article_caches.txt`, so
it goes wherever the cache goes, and git ignores it as it ignores the cache), which says from then on exactly which function
changed; a record older than the cache, or a function it names that the package no
longer has, sends it back to git. A cache without that record is compared through git:
each function as it was in the last commit before the cache was written (in any file of
`R/`, as a function may have moved since), against the function now, committed or not.
The exit code is 1 if a stale cache is left, and 0 for packages without cached articles,
so it can run before every build:

```bash
r_article_caches.sh rwf --clean && Rscript -e 'pkgdown::build_site("~/GitHub/rwf/rwf", lazy = TRUE)'
```

## machine_new.sh

```bash
machine_new.sh          # asks before each step
machine_new.sh --yes    # every step, without asking
machine_new.sh --list   # only shows the steps and what they install
```

Sets up a new computer with the latest Linux Mint (22 and later; Ubuntu 24.04
and later too) with the programs used on the old one, from apt repositories
and from the .deb files of their makers, never from Flatpak (on Ubuntu itself,
not Mint, apt installs Firefox and Thunderbird as snaps). One step at a
time, it shows what the step installs and asks before installing it; a step
that fails does not stop the others, and at the end it lists what was
installed, skipped and failed. Apps from their makers are always their newest
version.

- **System updates** (`apt full-upgrade`)
- **NVIDIA driver**, only on a computer with an NVIDIA card: the driver Mint's
  Driver Manager recommends, `nvidia-settings`, and fan control in it
  (Coolbits 4, written to `/etc/X11/xorg.conf`). On a computer that also has
  another GPU it asks about fan control again, as that `xorg.conf` leaves the
  screen of a laptop with PRIME blank; `--yes` leaves it out there
- **Tools**: htop, tmux, git, Git LFS, gh, git-cola, meld, rclone, ffmpeg,
  ImageMagick, the SSH server, ...
- **System and hardware tools**: lm-sensors, fio, smartmontools, nvme-cli,
  cpu-x, ... (what `hwrt.sh` and `disk_speed.sh` need)
- **Programming**: compilers, Java, Lisp, Node.js, Rust, PostgreSQL, the MySQL
  client, Python (pip, venv, pipx) and the libraries programs compile against
- **Python 3.12 with pyenv**, in `~/.pyenv` (for virtual environments such as
  pwf's); `~/.bashrc` is not changed, so the system Python stays the default
- **R** from CRAN (the newest R, not the older one of Ubuntu), the libraries
  that the R packages of your repositories need, and shiny, rmarkdown, rJava,
  SparseM and rgl for all users
- **RStudio**; **Shiny Server** and **RStudio Server**
  (<http://localhost:3838>, <http://localhost:8787>)
- **LaTeX** (TeX Live with Greek, TeXmaker); **Docker**
- **Apps**: calibre, VLC, GIMP, Inkscape, Audacity, LyX, pdfarranger,
  VirtualBox with its Extension Pack (free only for personal and educational
  use), the Microsoft fonts, ...; **Games**: Steam, Hedgewars, Neverball,
  Solitaire
- From their makers: **VS Code** with your extensions, **Sublime Text**,
  **Chrome**, **Edge**, **Slack**, **Discord**, **Zoom**, **Viber**,
  **Dropbox**, **Insync**, **Surfshark**, **TeamViewer**, **PowerShell**,
  **AWS CLI**, **Agent DVR**, **AfterShot Pro 3**
- **Network tools**: nmap, arp-scan, Wireshark (captures as your user),
  aircrack-ng, wifite, macchanger
- **Security checks**: ClamAV, rkhunter, chkrootkit, debsums (rkhunter and
  chkrootkit bring the postfix mail server for their reports, set to deliver
  on this computer only)

RealVNC Viewer (no download link a script can use) and Mplus (licence) are left
to do by hand. Afterwards restart (for the NVIDIA driver), or log out and in
(for the `docker`, `vboxusers` and `wireshark` groups). Then `git_clone_all.sh`
downloads your repositories and `r_install_packages.sh` the R packages each one
needs.

## machine_leave.sh

```bash
machine_leave.sh --check            # only the report, nothing is removed
machine_leave.sh [folder] [user]    # default ~/GitHub and sedzinfo
```

For the day you hand back a computer. First it shows, for each of your
repositories (the ones whose origin is github.com/`user`), whether it is
**completely on GitHub**: nothing uncommitted, nothing to push on any branch,
tag or detached HEAD, nothing stashed. It fetches all of them at once first.
Files that git ignores are listed (up to 10, then how many more), since they go
with the folder. Only what R, Python and the builds make again is left out of
the list and does not keep a repository: `.Rproj.user`, `.Rhistory`, `renv/library`,
`node_modules`, `__pycache__`, `_site`, `_freeze`, `*.Rcheck` and the like, and a
`report_files/` or `report_cache/` folder only next to its `report.Rmd` or `.qmd`.
A saved workspace (`.RData`) counts as your data. A repository folder that is a
link to one elsewhere is left alone.

Then, one step at a time and only after a `y`:

1. Deletes the repositories that are completely on GitHub. The others are kept,
   and so are other people's repositories (your employer's) and ones without a remote.
2. Deletes the SSH keys of this computer that are on your GitHub account
   (GitHub lists them at `github.com/USER.keys`). Other keys, such as the ones
   for work servers, are left alone.
3. Makes git forget the GitHub passwords and tokens it saved, and logs the
   GitHub CLI out.
4. Deletes lines with tokens or keys (`GITHUB_PAT`, `COINMARKETCAP_APIKEY`, ...)
   from `~/.Renviron`, `~/.bashrc` and similar files and from the shell and R
   history, after showing them with the values hidden.
5. Removes the shinyapps.io / Posit Connect logins that `rsconnect` saved.

At the end it lists what only you can do on the websites: delete the key from
your GitHub account (it shows the fingerprint), sign out the other sessions,
revoke tokens, and the token of shinyapps.io. Run it before deleting the key on
GitHub, as it needs GitHub to check the repositories. Running `--check` a few
days before shows what still needs a commit or a push; the exit code is 1
while any repository is not completely on GitHub, including one without a remote.

## tmux_update_plugins.sh

```bash
tmux_update_plugins.sh             # repairs and updates every plugin, after asking
tmux_update_plugins.sh --yes       # without asking
tmux_update_plugins.sh --dry-run   # only shows what it would do
```

Updates the plugins that [TPM](https://github.com/tmux-plugins/tpm) installed in
`~/.tmux/plugins` (or, as TPM has it, in `~/.config/tmux/plugins` when there is a
`~/.config/tmux/tmux.conf`), without touching your configuration (`~/.tmux.conf`) or the
sessions tmux-resurrect saved; at the end it checks that the configuration files
are unchanged, byte for byte. First it repairs what copying the plugin folder
(from a backup, a USB stick or another computer) breaks: files that lost their
executable bit, so that tmux cannot run the plugin (`run '~/.tmux/plugins/tpm/tpm'`
then fails with "Permission denied" and no plugin loads), symlinks turned into
copies of what they pointed to, missing submodules, and files and folders anyone
could write to (also the plugins folder and `~/.tmux`: whoever can write there can
swap a plugin for their own). It tells these apart from edits of your own: a plugin
you changed, or with commits of yours in a submodule, is not updated, and a plugin
folder that is a link to one elsewhere is left alone. It first shows what it would
repair and update, and asks (`--yes` does not ask; `--dry-run` stops there, though
git still fetches what is new). Then it updates each plugin from GitHub, only forward, so commits of your own
are never lost, and checks that every script of the plugin can run: the files git
marks executable, also in its submodules, and the `*.tmux` files TPM runs:

```text
tmux-resurrect  (git@github.com:tmux-plugins/tmux-resurrect.git)
  repaired: 26 file permissions, 168 files and folders anyone could write to
  updated a2ddfb9 -> cff343c, 6 new commits
  can run: all 25 scripts
```

It also says when apt has a newer tmux and asks before installing it, and lists
the plugins of your configuration that are not installed. In a running tmux,
`tmux source-file ~/.tmux.conf` loads the updated plugins. The exit code is 1 if a
plugin could not be updated or a script of it cannot run.

## ssh_setup_keys.sh

```bash
ssh_setup_keys.sh                        # the machines in ~/.ssh/machines.txt
ssh_setup_keys.sh ~/servers.txt          # or in another file
ssh_setup_keys.sh --key ~/.ssh/id_rsa    # copies this key instead of the first one found
ssh_setup_keys.sh --check                # only checks which machines need no password
```

Sets up passwordless SSH logins, with your key instead of a password, to every
machine of a list.

**The list** is `~/.ssh/machines.txt`, or the file you give. It is not a standard
file and nothing creates it: make it yourself with any text editor
(`nano ~/.ssh/machines.txt`, `xed`, `code`), and write one machine per line, as you
would type it. A complete example:

```text
# ~/.ssh/machines.txt: the machines ssh_setup_keys.sh sets up, one per line.
# Lines starting with # and empty lines are skipped.

# at home, by address or by name
ssh dimitrios@192.168.1.10
ssh pi@raspberrypi.local
dimitrios@192.168.1.11

# from outside, through the router: the port with -p (lowercase, not -P)
ssh dimitrios@myhost.example.com -p 5000
ssh dimitrios@myhost.example.com -p 1515

# a line copied from your notes, with a forward: the -L part is left out
ssh -L 8080:192.168.1.1:80 dimitrios@myhost.example.com -p 1500

# a machine with a Host entry in ~/.ssh/config (see below)
ssh pip0
```

Write `ssh` at the start or not, as you like, and use your own user names,
addresses and ports.

Empty lines and lines starting with `#` are skipped. ssh reads each line itself
(`ssh -G`), so your `~/.ssh/config` applies; a forward such as `-L` is not needed
for the key and is left out, and a second line for the same machine is skipped.
The port is `-p` (lowercase): with `-P 5000` (the port option of `scp`) ssh uses
port 22, and the script says so. To add a machine later, add its line and run the
script again: the machines that already work are left as they are.

With the machine in `~/.ssh/config`, the standard file of ssh, a line can be as
short as `ssh pip0`, and the same name works in `scp`, `rsync`, git and VS Code:

```text
Host pip0
    HostName myhost.example.com
    User dimitrios
    Port 5000
```

The list has no secrets: copy it (and `~/.ssh/config`) to your other computers,
but keep it out of public repositories such as this one, as it has your servers'
addresses. Run the script on each computer: each one has its own key, so a lost
laptop's key can be removed from the machines without affecting the others.
Never copy a private key between computers.

It uses the key you already have (`~/.ssh/id_ed25519`, `id_ecdsa` or `id_rsa`, in
that order), and creates one only when there is none, after asking; a key is never
replaced. For each machine it first tries to log in without a password, and leaves
the machine alone if that works. Otherwise `ssh-copy-id` copies your public key: it
asks for the machine's password once, adds the key only if it is not there yet (so
running the script again adds nothing twice), and creates `~/.ssh` there with the
permissions sshd requires if it is missing (`ssh_setup_keys.ps1` also sets them on
one that exists). Then it checks that the login works without a password:

```text
dimitrios@myhost.example.com:5000  (ssh dimitrios@myhost.example.com -p 5000)
  copying your key: ssh-copy-id asks for the password of dimitrios@myhost.example.com:5000 once
  logs in without a password now
```

A key with a passphrase is added to ssh-agent first (`ssh-add` asks for the
passphrase once), as otherwise every login would ask for it. A key given with
`--key` whose name ssh does not try by itself (such as `~/.ssh/pi_key`) works only
with `-i ~/.ssh/pi_key` on the machines' lines or an `IdentityFile` line in
`~/.ssh/config`. The exit code is 1 if a machine still asks for a password or cannot
be reached.

## ssh_run_all.sh

```bash
ssh_run_all.sh 'sudo apt update && sudo apt full-upgrade -y'   # update every machine
ssh_run_all.sh 'df -h /'                                       # free space everywhere
ssh_run_all.sh --parallel uptime                               # all at the same time
ssh_run_all.sh --list ~/servers.txt --yes 'sudo reboot'        # another list, without asking
```

Runs a command on every machine of `~/.ssh/machines.txt`, the list of
[`ssh_setup_keys.sh`](#ssh_setup_keyssh) (the same format; a machine listed twice
runs once; the same address behind two jump hosts is two machines). The options
come before the command. Put the command in single quotes whenever it has more than
plain words: without them, this computer's shell would handle `&&`, `;`, `|`, `$`,
`~`, `*`, `<`, `>` and quotes itself, before the machines get it (`ls ~/backups`
would send this computer's home folder, and `ls /var/log/*` its file names). It shows the command and the machines and asks
before running it, as a mistyped command would reach every machine at once
(`--yes` runs without asking, also where there is no terminal, such as cron).

By default the machines run one after the other, each in a terminal of its own, so
the command can ask you things: the password of `sudo`, or apt asking about a
changed configuration file. With `--parallel` all machines run at the same time,
which is quicker for long updates, but nothing can be asked: a `sudo` that needs a
password fails with "a terminal is required", instead of waiting forever. What each
machine printed is shown under its name, followed by the result:

```text
demo@192.168.1.10:22
hello from pi4
  done in 0s
pwonly@192.168.1.11:22
pwonly@192.168.1.11: Permission denied (publickey,password).
  asks for a password: skipped (ssh_setup_keys.sh sets up the key)
```

The logins must not ask for a password (that is what `ssh_setup_keys.sh` sets up); a
machine that asks is skipped. When ssh ends with its code for a failed login (255),
a second login without the command tells whether the machine could not be reached,
asks for a password, or the command itself ended with 255. What each machine printed
stays in `~/.cache/ssh_run_all/<user@host:port>.log` until the next run. The exit code
is 1 if the command failed on a machine, or a machine could not be reached or asked
for a password.

## Windows

The `.ps1` scripts do the same as the bash ones, with the same arguments and questions, in
Windows PowerShell 5.1 (part of Windows) or PowerShell 7. Run them from PowerShell:

```powershell
.\git_status_all.ps1 -NoFetch
.\machine_leave.ps1 -Check
```

If Windows refuses to run scripts, allow the ones on this computer once:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

What is different on Windows:

- The default folder is `Documents\GitHub`, where GitHub Desktop puts repositories, or
  `~\GitHub` if that does not exist. The folder question does not complete paths with Tab,
  but takes a path pasted with *Copy as path* (quotes and all).
- Switches are written the PowerShell way: `-NoFetch`, `-Check`, `-DryRun`, `-Strict`,
  `-AsCran`, `-Manual`, `-NoExamples`, `-To`, `-List`, `-Size`, `-History`, `-Yes`, `-Time`, `-ReadOnly`,
  `-Key`, `-Parallel`, `-Clean`, `-Accept`, and
  `-Root` for `r_shiny_update_manifests.ps1` (or `$env:ROOT`).
- The logs and working copies that the bash scripts keep in `~/.cache` go to
  `%LOCALAPPDATA%` (e.g. `%LOCALAPPDATA%\r_cmd_check_all`).
- Missing programs are offered with `winget install` instead of `sudo apt install`. R is
  found where its installer put it, even though it is not on the PATH.
  `git_large_files_all.ps1` and `git_lfs_prune_all.ps1` use the git-lfs that comes with Git
  for Windows, and say so when it is missing, without offering to install it.
- `git_clone_all.ps1` needs only git, and clones over HTTPS, which git logs in to through the
  Git Credential Manager as GitHub Desktop does; `-Ssh` clones over SSH. For private
  repositories: `$env:GITHUB_TOKEN = 'ghp_...'; .\git_clone_all.ps1; Remove-Item Env:GITHUB_TOKEN`.
- `hwrt.ps1` shows the RAM, the CPU speed (above the base speed when it boosts) and load, and
  how busy each GPU is, by name, with the temperature, speed and memory of NVIDIA cards
  (`nvidia-smi`). Windows itself reports only the temperatures of its ACPI thermal zones and no
  fan speeds; while [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor)
  runs (as administrator), it shows all of its temperatures and fans instead, as `lm-sensors`
  does on Linux. Below 3000 MB of available RAM it beeps.
- `r_install_packages.ps1` has no system packages to install, as R packages for Windows come
  ready built; only a package with C/C++ code needs
  [Rtools](https://cran.r-project.org/bin/windows/Rtools/) to be installed from source.
- `machine_leave.ps1` also deletes, after asking, the GitHub logins in the Windows Credential
  Manager (git's and GitHub Desktop's, which signs GitHub Desktop out), and looks for tokens
  in the PowerShell profiles and history, in R's files in `Documents` (R's `~` on Windows),
  and in user environment variables named like a token (`setx GITHUB_PAT ...`). It deletes a
  repository with `rd`, which does not follow the links (junctions) that `renv` makes to its
  package cache.
- `r_cmd_check.ps1` (and so `git_push_checked.ps1`) builds packages with C/C++ code only with
  Rtools installed; `-Manual` and `r_pdf_all.ps1` need LaTeX, which they offer as MiKTeX.
- `r_document_all.ps1 -Check` links the big folders of its copy of a package with junctions,
  which need no administrator rights, copies the other files, and deletes the copy with `rd`.
- `disk_speed.ps1` names the drives by the numbers `Get-Disk` shows (`disk_speed.ps1 0 1`).
  fio comes from its [Windows installer](https://github.com/axboe/fio/releases). The test file
  goes in your temporary folder on the Windows drive and in a folder of its own on the others;
  reading a drive itself (a drive without a drive letter, or `-ReadOnly`) needs PowerShell run
  as administrator, and without it that drive is skipped.
- `hwrt_pi.sh` has no Windows version: it reads what only a Raspberry Pi has.
- `machine_new.sh` has no Windows version: it sets up Linux Mint.
- `tmux_update_plugins.sh` has no Windows version: tmux runs on Linux and macOS (and in WSL).
- `ssh_setup_keys.ps1` and `ssh_run_all.ps1` use the OpenSSH client of Windows 10 and 11
  (Settings > System > Optional features > OpenSSH Client), and the list in
  `%USERPROFILE%\.ssh\machines.txt` (`notepad $HOME\.ssh\machines.txt`). Windows has no
  `ssh-copy-id`, so `ssh_setup_keys.ps1` adds the key itself, the same way (only if it is
  missing, with the permissions sshd requires). The ssh-agent service is off on Windows until
  turned on, as administrator, which a key with a passphrase needs for logins without asking:
  `Get-Service ssh-agent | Set-Service -StartupType Automatic; Start-Service ssh-agent`.
- `ssh_run_all.ps1` takes the command in quotes, as one argument (`ssh_run_all.ps1 'df -h /'`):
  PowerShell takes any beginning of an option's name for the option, so a `-y` of the command
  would be taken for `-Yes`; a command of several words without quotes, or `-Yes` written
  shorter, is refused. One machine after the other, what the command
  prints goes straight to the window, so that it can ask you things; only `-Parallel` keeps
  what each machine printed, in `%LOCALAPPDATA%\ssh_run_all` (with `_` for the `:` in the
  names, which Windows does not allow).

## New computer

```bash
sudo apt install git                      # if git is not there yet
git clone git@github.com:sedzinfo/shell_scripts.git ~/GitHub/shell_scripts
~/GitHub/shell_scripts/machine_new.sh     # programs, R, drivers, apps
~/GitHub/shell_scripts/git_clone_all.sh   # download everything
~/GitHub/shell_scripts/git_pull_all.sh    # later: keep it up to date
```

To run the scripts by name from any folder, add to `~/.bashrc`:

```bash
export PATH="$HOME/GitHub/shell_scripts:$PATH"
```

On Windows, in PowerShell:

```powershell
git clone https://github.com/sedzinfo/shell_scripts.git "$HOME\Documents\GitHub\shell_scripts"
& "$HOME\Documents\GitHub\shell_scripts\git_clone_all.ps1"   # download everything
& "$HOME\Documents\GitHub\shell_scripts\git_pull_all.ps1"    # later: keep it up to date
```

To run them by name from any folder (in new windows):

```powershell
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ";$HOME\Documents\GitHub\shell_scripts", 'User')
```
