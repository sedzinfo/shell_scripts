# shell_scripts

Small bash scripts: looking after many git repositories at once, and keeping an eye on the machine.
The git scripts work on `~/GitHub` by default; if that folder does not exist, they ask for one
(Tab completes paths, `~` works, an empty answer quits).

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
