# CachyOS-OG

Snapshot of the original CachyOS setup: **niri** + **noctalia** (shell and greetd greeter), kitty,
fish + starship, fuzzel, yazi, Zed, a Firefox userChrome, and the helper scripts in
`/usr/local/bin`. It also has an installer that rebuilds the setup on a fresh machine.

## Install on a new machine

1. Install CachyOS and pick **no desktop**.
2. Then:

```sh
sudo pacman -S --needed git
git clone https://github.com/UnRedKnown/ricesync
cd ricesync/CachyOS-OG
./install.sh --dry-run      # see what it would do
./install.sh                # do it
```

Optional machine-specific parts (VM bridge, peripherals, backup job) are in [`SPECIFIC/`](SPECIFIC/README.md):
`./install.sh --specific network,hardware,services`.

What `install.sh` does:
1. Adds any extra pacman repos the original machine used (it asks first).
2. Runs `pacman -Syu`, installs `packages/repo.txt`, then installs `packages/aur.txt` via paru (paru is installed if missing).
3. Copies `files/home` to `~` and `files/system` to `/`.
   - Everything it overwrites is backed up to `~/.local/state/ricesync-backup/<time>/`.
   - `@HOME@` and `@USER@` are filled in for the new machine.
   - Files in `sudoers.d` are checked with `visudo` before they're installed.
4. Puts `files/firefox-chrome` into your Firefox profile and enables userChrome loading.
5. Enables greetd (and seatd), and offers to make fish your login shell.
6. Lists any file that still has a scrubbed placeholder (`@IP@`, `@REDACTED@` …) for you to fill in.

The colour files (kitty/btop/yazi/GTK/Firefox themes) are **not** in the repo. noctalia generates
them per machine, so pick a wallpaper in noctalia once after the first login.

## Update the snapshot (on the source machine)

```sh
cd ~/path/to/ricesync
python3 -I CachyOS-OG/collect.py         # collect → scrub → verify → asks before committing
git push
```

- What gets collected: `manifest/files.list`. Package rules: `manifest/packages.conf`.
- Every run writes a report outside the repo, at `~/.cache/ricesync-collect-report.txt`. It lists
  what was scrubbed, skipped and flagged.
- Before committing, a privacy guard checks for home paths, hostnames, network names, IPs/MACs,
  e-mails, keys and tokens. If it finds any, it aborts.
- Add any other strings that must never be published to `~/.config/ricesync-private.txt`, one per
  line (real name, city, a server name …). That file is not part of the repo.

## Layout

```
CachyOS-OG/
├── install.sh            installer
├── collect.py            snapshot + scrub + commit (source machine only)
├── manifest/             what to collect, package rules
├── files/
│   ├── home/             → ~   (includes the ~/Settings symlink menu)
│   ├── system/           → /   (only files you created or changed; package defaults aren't copied)
│   └── firefox-chrome/   → <firefox profile>/chrome
├── packages/             repo.txt, aur.txt, pacman-repos.conf
└── SPECIFIC/             opt-in machine-specific sections (see its README)
```
