#!/usr/bin/env bash
# ricesync / CachyOS-OG — install.sh
#
# Recreates this setup (niri + noctalia + friends) on a fresh CachyOS install
# with NO desktop selected. Run as your normal user (sudo is used where needed):
#
#   git clone https://github.com/UnRedKnown/ricesync && cd ricesync/CachyOS-OG
#   ./install.sh                       # core rice
#   ./install.sh --specific network    # + opt-in machine-specific parts (see SPECIFIC/README.md)
#   ./install.sh --specific all
#
# Options:
#   --specific a,b,c   also install SPECIFIC/<a> … (network, hardware, services, or all)
#   --only parts       only run some steps: repos,packages,home,system,firefox,services,shell
#   --no-packages      skip package installation
#   --dry-run          print what would happen, change nothing
#   -y, --yes          don't ask for confirmations
#
# Existing files that get overwritten are backed up to ~/.local/state/ricesync-backup/<time>/.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/.local/state/ricesync-backup/$TS"
DRY=0 YES=0 NOPKG=0 SPECIFIC="" ONLY=""
INSTALLED=()
ALL_SPECIFIC="network hardware services"

c_b=$'\e[1m' c_g=$'\e[32m' c_y=$'\e[33m' c_r=$'\e[31m' c_0=$'\e[0m'
msg()  { printf '%s::%s %s\n' "$c_b$c_g" "$c_0" "$*"; }
warn() { printf '%s!!%s %s\n' "$c_b$c_y" "$c_0" "$*" >&2; }
die()  { printf '%sxx%s %s\n' "$c_b$c_r" "$c_0" "$*" >&2; exit 1; }
run()  { if ((DRY)); then printf '   [dry] %q' "$1"; shift; printf ' %q' "$@"; echo; else "$@"; fi; }
ask()  { ((YES)) && return 0; local a; read -rp "$1 [Y/n] " a; [[ -z $a || $a =~ ^[Yy] ]]; }

while (($#)); do
  case "$1" in
    --specific) SPECIFIC="${2//,/ }"; shift ;;
    --specific=*) SPECIFIC="${1#*=}"; SPECIFIC="${SPECIFIC//,/ }" ;;
    --only) ONLY="${2//,/ }"; shift ;;
    --only=*) ONLY="${1#*=}"; ONLY="${ONLY//,/ }" ;;
    --no-packages) NOPKG=1 ;;
    --dry-run) DRY=1 ;;
    -y|--yes) YES=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
[[ $SPECIFIC == all ]] && SPECIFIC="$ALL_SPECIFIC"
for s in $SPECIFIC; do [[ -d "$HERE/SPECIFIC/$s" ]] || die "no such SPECIFIC section: $s"; done
step() { [[ -z $ONLY || " $ONLY " == *" $1 "* ]]; }

# ---------------------------------------------------------------------------- sanity
((EUID)) || die "run as your normal user, not root"
command -v pacman >/dev/null || die "pacman not found — this is for CachyOS / Arch"
grep -qi cachyos /etc/os-release 2>/dev/null || warn "this doesn't look like CachyOS — continuing anyway"
[[ -d "$HERE/files" ]] || die "files/ missing — was collect.py run and committed?"
for d in /usr/share/wayland-sessions /usr/share/xsessions; do
  if ls "$d"/*.desktop >/dev/null 2>&1 && ! ls "$d"/niri*.desktop >/dev/null 2>&1; then
    warn "another desktop session is installed ($(ls "$d" | tr '\n' ' ')). This script expects a no-desktop install;"
    warn "it won't remove anything, but greetd will replace the current display manager."
    break
  fi
done
((DRY)) || sudo -v

# substitute placeholders written by collect.py
subst() {  # subst <file>   (in place, text files only)
  grep -Iq . "$1" 2>/dev/null || return 0
  sed -i -e "s|@HOME@|$HOME|g" -e "s|@USER@|$USER|g" "$1"
}
destname() { local p="$1"; p="${p//@USER@/$USER}"; printf '%s' "$p"; }

# ---------------------------------------------------------------------------- repos + packages
read_list() { [[ -f $1 ]] && grep -vE '^\s*(#|$)' "$1" || true; }

install_pkgs() {  # install_pkgs <repo.txt> <aur.txt>
  local repo_list aur_list avail missing=()
  mapfile -t repo_list < <(read_list "$1")
  mapfile -t aur_list  < <(read_list "$2")
  if ((${#repo_list[@]})); then
    avail="$(pacman -Slq | sort -u)"
    local ok=()
    for p in "${repo_list[@]}"; do
      if grep -qxF "$p" <<<"$avail" || pacman -Sgq "$p" &>/dev/null; then ok+=("$p"); else missing+=("$p"); fi
    done
    ((${#missing[@]})) && warn "not in your repos, trying AUR instead: ${missing[*]}"
    aur_list+=("${missing[@]}")
    ((${#ok[@]})) && run sudo pacman -S --needed --noconfirm "${ok[@]}"
  fi
  if ((${#aur_list[@]})); then
    ensure_paru
    run paru -S --needed --noconfirm --skipreview "${aur_list[@]}" || \
      warn "some AUR packages failed — rerun: paru -S --needed ${aur_list[*]}"
  fi
}

ensure_paru() {
  command -v paru >/dev/null && return
  if pacman -Si paru &>/dev/null; then run sudo pacman -S --needed --noconfirm paru; return; fi
  msg "building paru from AUR"
  run sudo pacman -S --needed --noconfirm base-devel git
  local t; t="$(mktemp -d)"
  run git clone https://aur.archlinux.org/paru-bin.git "$t/paru-bin"
  ( cd "$t/paru-bin" && run makepkg -si --noconfirm )
}

if step repos && [[ -s "$HERE/packages/pacman-repos.conf" ]]; then
  msg "extra pacman repos used on the original machine:"
  sed 's/^/   /' "$HERE/packages/pacman-repos.conf"
  new=""
  while read -r sec; do
    grep -q "^\[$sec\]" /etc/pacman.conf || new+="$sec "
  done < <(sed -n 's/^\s*\[\([^]]*\)\].*/\1/p' "$HERE/packages/pacman-repos.conf")
  if [[ -n $new ]] && ask "Append missing repo(s) [$new] to /etc/pacman.conf? (their keyring/mirrorlist must be set up for them to work)"; then
    run sudo cp /etc/pacman.conf "/etc/pacman.conf.ricesync-$TS"
    ((DRY)) || sudo tee -a /etc/pacman.conf <"$HERE/packages/pacman-repos.conf" >/dev/null
  fi
fi

if step packages && ! ((NOPKG)); then
  msg "updating system"
  run sudo pacman -Syu --noconfirm
  msg "installing core packages"
  install_pkgs "$HERE/packages/repo.txt" "$HERE/packages/aur.txt"
  for s in $SPECIFIC; do
    msg "installing SPECIFIC/$s packages"
    install_pkgs "$HERE/SPECIFIC/$s/packages-repo.txt" "$HERE/SPECIFIC/$s/packages-aur.txt"
  done
fi

# ---------------------------------------------------------------------------- files
backup() {  # backup <absolute path> [sudo]
  [[ -e $1 || -L $1 ]] || return 0
  local dst="$BACKUP/${1#/}"
  run mkdir -p "$(dirname "$dst")"
  if [[ ${2:-} == sudo ]]; then run sudo cp -a "$1" "$dst"; else run cp -a "$1" "$dst"; fi
}

install_home() {  # install_home <tree>
  [[ -d $1 ]] || return 0
  local n=0
  while IFS= read -r -d '' src; do
    local rel="${src#"$1"/}" dst
    dst="$HOME/$(destname "$rel")"
    if [[ -L $src ]]; then
      local tgt; tgt="$(readlink "$src")"; tgt="${tgt//@HOME@/$HOME}"
      backup "$dst"; run mkdir -p "$(dirname "$dst")"; run ln -sfn "$tgt" "$dst"
    else
      [[ -e $dst ]] && cmp -s "$src" "$dst" && continue
      backup "$dst"; run mkdir -p "$(dirname "$dst")"; run cp -f "$src" "$dst"
      ((DRY)) || subst "$dst"
      grep -qE '@(IP|MAC|HOSTNAME|NETNAME|EMAIL|REDACTED|NAME)@' "$src" 2>/dev/null && INSTALLED+=("$dst")
    fi
    ((++n))
  done < <(find "$1" \( -type f -o -type l \) -print0)
  msg "  $n file(s) → ~"
}

sys_mode() {
  case "$1" in
    /etc/sudoers.d/*) echo 0440 ;;
    /usr/local/bin/*) echo 0755 ;;
    *) [[ -x $2 ]] && echo 0755 || echo 0644 ;;
  esac
}

install_system() {  # install_system <tree>
  [[ -d $1 ]] || return 0
  local n=0
  while IFS= read -r -d '' src; do
    local dst; dst="/$(destname "${src#"$1"/}")"
    local tmp; tmp="$(mktemp)"; cp "$src" "$tmp"; subst "$tmp"
    if [[ $dst == /etc/sudoers.d/* ]] && ! ((DRY)) && ! sudo visudo -cqf "$tmp"; then
      warn "  $dst failed visudo check — skipped"; rm -f "$tmp"; continue
    fi
    if ((DRY)); then cmp -s "$tmp" "$dst" 2>/dev/null && { rm -f "$tmp"; continue; }
    elif [[ -e $dst ]] && sudo cmp -s "$tmp" "$dst"; then rm -f "$tmp"; continue; fi
    backup "$dst" sudo
    run sudo install -D -m "$(sys_mode "$dst" "$src")" -o root -g root "$tmp" "$dst"
    grep -qE '@(IP|MAC|HOSTNAME|NETNAME|EMAIL|REDACTED|NAME)@' "$tmp" && INSTALLED+=("$dst")
    rm -f "$tmp"; ((++n))
  done < <(find "$1" -type f -print0)
  msg "  $n file(s) → /"
}

if step home; then
  msg "installing home configs"
  install_home "$HERE/files/home"
  for s in $SPECIFIC; do install_home "$HERE/SPECIFIC/$s/home"; done
  command -v fc-cache >/dev/null && run fc-cache -f >/dev/null
fi

if step system; then
  msg "installing system files"
  install_system "$HERE/files/system"
  for s in $SPECIFIC; do install_system "$HERE/SPECIFIC/$s/system"; done
  if [[ -d "$HERE/SPECIFIC" ]]; then
    for s in $SPECIFIC; do
      [[ -d "$HERE/SPECIFIC/$s/system/etc/udev" ]] && { run sudo udevadm control --reload; run sudo systemd-hwdb update; run sudo udevadm trigger; }
      [[ -d "$HERE/SPECIFIC/$s/system/etc/sysctl.d" ]] && run sudo sysctl --system >/dev/null
    done
  fi
  run sudo systemctl daemon-reload
fi

# ---------------------------------------------------------------------------- firefox
ff_profile() {
  local base ini path
  for base in "$HOME/.config/mozilla/firefox" "$HOME/.mozilla/firefox"; do
    ini="$base/profiles.ini"; [[ -f $ini ]] || continue
    path="$(awk -F= '/^\[Install/{i=1} i&&/^Default=/{print $2; exit}' "$ini")"
    [[ -z $path ]] && path="$(awk -F= '/^Path=/{p=$2} /^Default=1/{print p; exit}' "$ini")"
    [[ -z $path ]] && path="$(awk -F= '/^Path=/{print $2; exit}' "$ini")"
    [[ -n $path ]] || continue
    [[ $path == /* ]] && echo "$path" || echo "$base/$path"
    return
  done
}

if step firefox && [[ -d "$HERE/files/firefox-chrome" ]]; then
  prof="$(ff_profile || true)"
  if [[ -z $prof ]] && command -v firefox >/dev/null; then
    msg "creating a Firefox profile (headless)"
    run timeout 20 firefox --headless -CreateProfile default-release >/dev/null 2>&1 || true
    prof="$(ff_profile || true)"
  fi
  if [[ -n $prof ]]; then
    msg "Firefox: installing userChrome into $(basename "$prof")"
    run mkdir -p "$prof/chrome"
    [[ -d $prof/chrome && -n "$(ls -A "$prof/chrome" 2>/dev/null)" ]] && { run mkdir -p "$BACKUP"; run cp -a "$prof/chrome" "$BACKUP/firefox-chrome"; }
    run cp -rf "$HERE/files/firefox-chrome/." "$prof/chrome/"
    ((DRY)) || find "$prof/chrome" -type f -exec bash -c 'grep -Iq . "$1" && sed -i -e "s|@HOME@|$HOME|g" -e "s|@USER@|$USER|g" "$1"' _ {} \;
    pref='user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);'
    grep -qF "$pref" "$prof/user.js" 2>/dev/null || { ((DRY)) || echo "$pref" >>"$prof/user.js"; }
  else
    warn "no Firefox profile yet — open Firefox once, then: ./install.sh --only firefox"
  fi
fi

# ---------------------------------------------------------------------------- services
enable() { run sudo systemctl enable "$@" || warn "could not enable: $*"; }
if step services; then
  msg "enabling services"
  cur_dm="$(readlink /etc/systemd/system/display-manager.service 2>/dev/null || true)"
  if [[ -n $cur_dm && $cur_dm != *greetd* ]]; then
    warn "display manager is $(basename "$cur_dm") — switching to greetd"
    run sudo systemctl disable "$(basename "$cur_dm")"
  fi
  enable greetd.service
  systemctl list-unit-files seatd.service &>/dev/null && enable seatd.service
  for s in $SPECIFIC; do
    f="$HERE/SPECIFIC/$s/services.txt"; [[ -f $f ]] || continue
    while read -r unit scope; do
      [[ -z $unit || $unit == \#* ]] && continue
      if ! systemctl list-unit-files "$unit" &>/dev/null || [[ -z "$(systemctl list-unit-files "$unit" --no-legend 2>/dev/null)" ]]; then
        warn "  $unit not installed — skipped"; continue
      fi
      if [[ ${scope:-system} == user ]]; then run systemctl --user enable "$unit" || true
      else enable "$unit"; fi
    done <"$f"
  done
fi

# ---------------------------------------------------------------------------- shell
if step shell && command -v fish >/dev/null && [[ "$(getent passwd "$USER" | cut -d: -f7)" != */fish ]]; then
  ask "Make fish your login shell?" && run chsh -s "$(command -v fish)"
fi

# ---------------------------------------------------------------------------- leftovers
msg "checking for placeholders that need your input"
ph=("${INSTALLED[@]}")
if ((${#ph[@]})); then
  warn "these files contain scrubbed values (@IP@, @MAC@, @HOSTNAME@, @REDACTED@ …) — fill them in if you use them:"
  printf '   %s\n' "${ph[@]}"
fi

cat <<EOF

${c_b}${c_g}Done.${c_0}
 • Backups of anything overwritten: $BACKUP
 • Reboot (or: sudo systemctl start greetd) to land in the greeter → niri.
 • Colour files (kitty/btop/yazi/GTK/Firefox themes …) are generated by noctalia:
   pick a wallpaper in noctalia once and they'll be created.
EOF
