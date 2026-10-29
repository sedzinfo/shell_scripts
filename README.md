# shell_scripts

Small bash scripts: looking after many git repositories at once, and keeping an eye on the machine.
The git scripts work on `~/GitHub` by default; if that folder does not exist, they ask for one
(Tab completes paths, `~` works, an empty answer quits).

| Script | What it does | Changes anything? |
|---|---|---|
| [`git_status_all.sh`](git_status_all.sh) | One line per repository: clean, or what is not yet on GitHub | No |
| [`git_pull_all.sh`](git_pull_all.sh) | Pulls every repository | Yes, asks before anything destructive |
| [`git_clone_all.sh`](git_clone_all.sh) | Clones every repository of a GitHub user that is not downloaded yet | Only adds new folders |
| [`hwrt.sh`](hwrt.sh) | Live view of RAM, CPU speed, GPU, temperatures and fans; beeps when RAM is low | No |

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
