# shell_scripts

Small bash scripts: looking after many git repositories at once, and keeping an eye on the machine.
The git scripts work on `~/GitHub` by default; if that folder does not exist, they ask for one
(Tab completes paths, `~` works, an empty answer quits). Each one except `hwrt_pi.sh` also
comes as a PowerShell script for Windows (`.ps1`); see [Windows](#windows).

When a program a script needs is missing (`lm-sensors`, `alsa-utils`, `pciutils`,
`curl`, `jq`), the script says what it is for and asks before installing it with
`sudo apt install`. Answer no and it goes on with what it can (`git_clone_all.sh`
stops, since it cannot work without `curl` and `jq`). Graphics drivers such as
NVIDIA's are never offered.

| Script | What it does | Changes anything? |
|---|---|---|
| [`git_status_all.sh`](git_status_all.sh) | One line per repository: clean, or what is not yet on GitHub | No |
| [`git_pull_all.sh`](git_pull_all.sh) | Pulls every repository | Yes, asks before anything destructive |
| [`git_clone_all.sh`](git_clone_all.sh) | Clones every repository of a GitHub user that is not downloaded yet | Only adds new folders |
| [`hwrt.sh`](hwrt.sh) | Live view of RAM, CPU speed, GPU, temperatures and fans; beeps when RAM is low | No |
| [`hwrt_pi.sh`](hwrt_pi.sh) | The same for a Raspberry Pi, plus the power supply (under-voltage, throttling) | No |
| [`shiny_update_manifests.sh`](shiny_update_manifests.sh) | Regenerates `manifest.json` of the Shiny apps for Posit Connect | Rewrites `manifest.json` only |
| [`r_install_packages.sh`](r_install_packages.sh) | Installs the system and R packages a repository needs | Installs, after asking |
| [`leave_machine.sh`](leave_machine.sh) | Before handing back a computer: checks that everything is on GitHub, then removes your repositories, GitHub key and logins | Yes, asks before each step |

## git_status_all.sh

```bash
git_status_all.sh [folder] [--no-fetch]
```

Shows, for each repository, its branch and one of:

- **clean** (green): everything is committed and on GitHub
- **N uncommitted** (red): changed or new files not yet committed
- **N to push** (red): commits that are not on GitHub yet
- **N to pull** (yellow): commits on GitHub that are not here yet
- **no upstream branch** / **detached HEAD** (yellow)

It fetches from GitHub first so the counts are current; `--no-fetch` skips that
(faster, or when offline). It never changes any files. Handy before leaving
work, to see what was forgotten.

## git_pull_all.sh

```bash
git_pull_all.sh [folder]
```

Runs `git pull --ff-only` in every repository, so a repository is only moved
forward to match GitHub and never merged or rebased.

When a pull fails (local commits that are not on GitHub, or uncommitted changes
that clash with the incoming ones), it lists what would be lost and asks:

```
git reset --hard origin/main? This DELETES the above [y/N]:
```

- **y / yes**: the repository becomes exactly the GitHub version; the listed
  local commits and changes are lost (untracked files are kept)
- anything else, or Enter: the repository is left as it is

Repositories on a detached HEAD or without an upstream branch are skipped.
At the end it lists what was pulled and what was not; the exit code is 1 if
anything was not pulled.

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
and pass it for that run only; do not write it in the script:

```bash
GITHUB_TOKEN=ghp_... git_clone_all.sh
```

Needs `curl` and `jq`.

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

## shiny_update_manifests.sh

```bash
shiny_update_manifests.sh              # every app in ~/GitHub that has a manifest.json
shiny_update_manifests.sh golemirt     # only the apps named (also makes a first manifest)
ROOT=~/Projects shiny_update_manifests.sh
```

Posit Connect (Cloud) installs an app from its `manifest.json`: the list of R
packages, with their versions, that the app uses. After updating packages in R,
the manifest is out of date. For each app (a folder with `app.R`) this runs

```r
rsconnect::writeManifest(appDir = ".", appPrimaryDoc = "app.R")
```

and says whether the manifest was **updated** or **unchanged**. It fails for an
app that uses a package not installed here; the end of R's message shows which
one (install it in R and run again). Apps with an `app.R` but no `manifest.json`
are listed but not touched. Nothing is committed: commit and push the updated
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

## leave_machine.sh

```bash
leave_machine.sh --check            # only the report, nothing is removed
leave_machine.sh [folder] [user]    # default ~/GitHub and sedzinfo
```

For the day you hand back a computer. First it shows, for each of your
repositories (the ones whose origin is github.com/`user`), whether it is
**completely on GitHub**: nothing uncommitted, nothing to push on any branch,
nothing stashed. It fetches all of them at once first. Files that git ignores
are listed, since they go with the folder (caches and the like, which R and
Python make again, are not).

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
while any repository is not completely on GitHub.

## Windows

The `.ps1` scripts do the same as the bash ones, with the same arguments and questions, in
Windows PowerShell 5.1 (part of Windows) or PowerShell 7. Run them from PowerShell:

```powershell
.\git_status_all.ps1 -NoFetch
.\leave_machine.ps1 -Check
```

If Windows refuses to run scripts, allow the ones on this computer once:
`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

What is different on Windows:

- The default folder is `Documents\GitHub`, where GitHub Desktop puts repositories, or
  `~\GitHub` if that does not exist. The folder question does not complete paths with Tab,
  but takes a path pasted with *Copy as path* (quotes and all).
- Switches are written the PowerShell way: `-NoFetch`, `-Check`, and `-Root` for
  `shiny_update_manifests.ps1` (or `$env:ROOT`).
- Missing programs are offered with `winget install` instead of `sudo apt install`. R is
  found where its installer put it, even though it is not on the PATH.
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
- `leave_machine.ps1` also deletes, after asking, the GitHub logins in the Windows Credential
  Manager (git's and GitHub Desktop's, which signs GitHub Desktop out), and looks for tokens
  in the PowerShell profiles and history, in R's files in `Documents` (R's `~` on Windows),
  and in user environment variables named like a token (`setx GITHUB_PAT ...`). It deletes a
  repository with `rd`, which does not follow the links (junctions) that `renv` makes to its
  package cache.
- `hwrt_pi.sh` has no Windows version: it reads what only a Raspberry Pi has.

## New computer

```bash
git clone git@github.com:sedzinfo/shell_scripts.git ~/GitHub/shell_scripts
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
