#!/usr/bin/env python3
"""
ricesync / CachyOS-OG — collect.py

Run this ON THE SOURCE MACHINE, from inside your local clone of ricesync:

    python3 -I CachyOS-OG/collect.py            # collect, review, commit
    python3 -I CachyOS-OG/collect.py --no-commit

It:
  1. copies everything listed in manifest/files.list into CachyOS-OG/
     (package-owned system files only if you modified them),
  2. follows niri/kitty/GTK includes so kept configs never point at missing files,
  3. scrubs private data (home path, username, hostnames, Wi-Fi/network names, IPs, MACs,
     e-mails, real name, tokens/passwords, anything listed in ~/.config/ricesync-private.txt),
  4. builds package lists from `pacman -Qqe` using manifest/packages.conf, re-adding anything
     a kept config or script actually calls,
  5. refuses to continue if anything that looks like a secret survived,
  6. writes a review report OUTSIDE the repo, shows `git status`, and commits only after you say yes.

Nothing is pushed. Push yourself after reviewing: `git push`.
"""
from __future__ import annotations

import argparse
import configparser
import fnmatch
import glob
import ipaddress
import os
import pwd
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent            # .../ricesync/CachyOS-OG
REPO = HERE.parent
HOME = Path.home()
USER = pwd.getpwuid(os.getuid()).pw_name
HOME_S = str(HOME)
PRIVATE_LIST = HOME / ".config" / "ricesync-private.txt"
REPORT = Path(os.environ.get("XDG_CACHE_HOME", HOME / ".cache")) / "ricesync-collect-report.txt"

# Placeholders; install.sh fills @HOME@ / @USER@ automatically and lists the rest.
P_HOME, P_USER, P_HOST, P_NET = "@HOME@", "@USER@", "@HOSTNAME@", "@NETNAME@"
P_IP, P_MAC, P_MAIL, P_RED, P_NAME = "@IP@", "@MAC@", "@EMAIL@", "@REDACTED@", "@NAME@"

GENERATED_DIRS = ["files", "packages"]   # wiped and rebuilt every run
SECTIONS_SPECIFIC = ["network", "hardware", "services"]

# Paths that must never be committed, whatever the manifest says.
FORBIDDEN_PATH = re.compile(
    r"(^|/)(shadow|gshadow|passwd|group)-?$|/\.ssh/|ssh_host_.*key|\.nmconnection$|"
    r"/system-connections/|/keyrings?/|/\.gnupg/|/gnupg/|/samba/private|cookies|"
    r"\.sqlite$|logins\.json|key[34]\.db|cert9\.db|_history$|\.bash_history|"
    r"fish_history|/\.netrc$|\.kdbx$|credentials|\.pem$|/known_hosts|tailscaled\.state",
    re.I)

# Content that must never be committed. If any of this survives scrubbing, we abort.
FORBIDDEN_CONTENT = [
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}"), "GitHub token"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{30,}"), "GitHub token"),
    (re.compile(r"\bsk-(ant-)?[A-Za-z0-9_-]{20,}"), "API key"),
    (re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"), "Slack token"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "AWS key"),
    (re.compile(r"\btskey-[A-Za-z0-9-]{10,}"), "Tailscale key"),
    (re.compile(r"\bAIza[0-9A-Za-z_-]{30,}"), "Google API key"),
]

# key = value style secrets / location → value redacted. Keys are split into words
# (snake_case, kebab-case, dotted, camelCase); a key matches only if one word / word pair is listed.
SECRET_WORDS = {
    "password", "passwd", "passphrase", "psk", "secret", "token", "apikey", "authkey", "privatekey",
    "clientsecret", "cookie", "sessionid", "ssid", "bssid", "wpapsk", "latitude", "longitude", "lat",
    "lon", "lng", "city", "location", "weatherlocation", "netbiosname", "serverstring", "hostsallow",
    "hostsdeny", "listenaddress", "allowusers", "allowgroups", "webhook", "email", "hostname",
    "peers", "peer", "remotehost",
}
HARMLESS_WORDS = {"command", "cmd", "file", "path", "prompt", "store", "manager", "length", "min", "max",
                  "timeout", "enabled", "enable", "show", "icon", "font", "color", "colour", "program", "app",
                  "format", "style", "mode", "type", "dir"}
RE_KV = re.compile(r"""^(?P<pre>\s*(?P<kq>["']?)(?P<key>[A-Za-z][\w.-]*(?:[ ][A-Za-z][\w.-]*)?)(?P=kq)\s*(?P<sep>=|:|\s)\s*)(?P<val>\S.*?)\s*$""")
# shell/fish exports of secret-looking UPPERCASE env vars
RE_ENV = re.compile(r"^(?P<pre>\s*(?:set\s+(?:-\w+\s+)*|export\s+|env\s+)?"
                    r"[A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|AUTH_?KEY|PRIVATE_?KEY)[A-Z0-9_]*\s*[= ]\s*)(?P<val>\S.*)$")

def key_words(key: str) -> list[str]:
    key = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", key)
    return [w for w in re.split(r"[\s_.\-]+", key.lower()) if w]

def secret_key(key: str) -> bool:
    w = key_words(key)
    if not w or set(w) & HARMLESS_WORDS:
        return False
    if set(w) & SECRET_WORDS:
        return True
    return any(a + b in SECRET_WORDS for a, b in zip(w, w[1:]))

RE_MAC = re.compile(r"\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b")
RE_V4 = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?(?![\w.])")
RE_V6 = re.compile(r"(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?:/\d{1,3})?(?![\w:])")
RE_MAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
RE_TSNET = re.compile(r"\b[\w-]+(?:\.[\w-]+)*\.ts\.net\b")
RE_LONGTOKEN = re.compile(r"(?<![\w/.-])[A-Za-z0-9+/_-]{40,}={0,2}(?![\w/.-])")
RE_NIRI_OUTPUT = re.compile(r'^\s*output\s+"[^"]*"')

report: list[str] = []
def note(msg: str) -> None:
    report.append(msg)

def die(msg: str) -> None:
    print(f"\n\033[1;31mABORT:\033[0m {msg}\n", file=sys.stderr)
    write_report()
    sys.exit(1)

def write_report() -> None:
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    REPORT.write_text("\n".join(report) + "\n")

def run(cmd: list[str], check=False, input_=None) -> str:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, input=input_)
    except FileNotFoundError:
        return ""
    if check and r.returncode != 0:
        die(f"{' '.join(cmd)} failed:\n{r.stderr}")
    return r.stdout


# ----------------------------------------------------------------------------- manifest
class Entry:
    def __init__(self, section: str, kind: str, pattern: str):
        self.section, self.kind, self.pattern = section, kind, pattern

def load_manifest():
    entries: list[Entry] = []
    excludes: list[str] = []
    section = "core"
    for raw in (HERE / "manifest" / "files.list").read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            continue
        if line.startswith("!"):
            excludes.append(line[1:].strip())
            continue
        kind, _, pat = line.partition(" ")
        entries.append(Entry(section, kind, pat.strip()))
    return entries, excludes

def dotsync_excludes() -> list[str]:
    """X-rules from the repo's dotsync.list (generated / per-machine files)."""
    f = REPO / "dotsync.list"
    out = []
    if not f.exists():
        note("dotsync.list not found at repo root; only built-in generated-file rules used")
        return out
    for raw in f.read_text().splitlines():
        s = raw.strip()
        if not s or s.startswith("#"):
            continue
        m = re.match(r"^X\s+(.+?)\s*$", s)
        if m:
            p = m.group(1).strip().strip('"').strip("'")
            p = p.replace("~/", "").replace("$HOME/", "")
            out.append(p.rstrip("/"))
            out.append(p.rstrip("/") + "/**")
    note(f"dotsync.list: {len(out)//2} X (exclude) rules applied")
    return out

# Files noctalia / matugen regenerate per machine — never committed (they come back on first theming run).
GENERATED = [
    "**/themes/noctalia*", "**/colorschemes/noctalia*", "**/flavors/noctalia.yazi", "**/flavors/noctalia.yazi/**",
    "**/colors/matugen*", "**/colors.css", "**/noctalia*.css", "**/noctalia*.colors",
    "**/matugen.conf", ".config/btop/themes/noctalia*",
    ".config/umbriel/noctalia.toml", ".config/nvtop/nvtop.colors",
    "**/chrome/wallpaper.png",
]

def match_any(rel: str, pats: list[str]) -> bool:
    for p in pats:
        if fnmatch.fnmatch(rel, p) or fnmatch.fnmatch(rel, p.lstrip("/")):
            return True
        if p.startswith("**/") and fnmatch.fnmatch(rel, p[3:]):
            return True
    return False


# ----------------------------------------------------------------------------- pacman helpers
_owner_cache: dict[str, str | None] = {}
_modified_cache: dict[str, set[str]] = {}

def owner(path: str) -> str | None:
    if path in _owner_cache:
        return _owner_cache[path]
    o = run(["pacman", "-Qqo", path]).strip().splitlines()
    _owner_cache[path] = o[0] if o else None
    return _owner_cache[path]

def modified_files(pkg: str) -> set[str]:
    if pkg not in _modified_cache:
        out = run(["sudo", "-n", "pacman", "-Qkk", pkg]) or run(["pacman", "-Qkk", pkg])
        mods = set()
        for l in out.splitlines():
            m = re.match(r"^(?:warning|backup file):\s*[^:]+:\s*(/\S.*?)\s+\((?:.*mismatch|.*checksum).*\)$", l)
            if m:
                mods.add(m.group(1))
        _modified_cache[pkg] = mods
    return _modified_cache[pkg]


# ----------------------------------------------------------------------------- reading
def read_bytes(p: Path) -> bytes | None:
    try:
        return p.read_bytes()
    except PermissionError:
        r = subprocess.run(["sudo", "cat", str(p)], capture_output=True)
        if r.returncode == 0:
            return r.stdout
        note(f"UNREADABLE (skipped): {p}")
        return None
    except (IsADirectoryError, FileNotFoundError):
        return None

def list_dir_files(p: Path) -> list[Path]:
    try:
        if p.is_file():
            return [p]
        if p.is_dir() and os.access(p, os.R_OK | os.X_OK):
            out = []
            for root, dirs, files in os.walk(p, followlinks=False):
                dirs[:] = [d for d in dirs if d not in (".git", "__pycache__", "node_modules")]
                for d in dirs:
                    if os.path.islink(os.path.join(root, d)):
                        note(f"  note: symlinked dir not followed: {os.path.join(root, d)}")
                out += [Path(root) / f for f in files]
            return out
    except PermissionError:
        pass
    r = run(["sudo", "-n", "find", str(p), "-type", "f"])
    return [Path(x) for x in r.splitlines() if x]


# ----------------------------------------------------------------------------- include following
def includes_of(path: Path, text: str) -> list[Path]:
    base = path.parent
    found: list[Path] = []
    name = path.name
    def add(s: str):
        s = s.strip().strip('"').strip("'")
        if not s or "://" in s:
            return
        s = os.path.expanduser(s.replace("$HOME", HOME_S).replace("${HOME}", HOME_S))
        p = Path(s) if os.path.isabs(s) else base / s
        for g in (glob.glob(str(p)) or [str(p)]):
            found.append(Path(g))
    if name.endswith(".kdl"):
        for m in re.finditer(r'^\s*include\s+(?:optional=\S+\s+)?"([^"]+)"', text, re.M):
            add(m.group(1))
    if "kitty" in str(path) and name.endswith(".conf"):
        for m in re.finditer(r"^\s*(?:include|globinclude)\s+(.+?)\s*$", text, re.M):
            add(m.group(1))
    if name.endswith(".css"):
        for m in re.finditer(r"""@import\s+(?:url\()?\s*["']?([^"')\s;]+)["']?\s*\)?""", text):
            add(m.group(1))
    if name == "config.fish" or (name.endswith(".fish") and "fish" in str(path)):
        for m in re.finditer(r"^\s*source\s+(\S+)", text, re.M):
            add(m.group(1))
    return found


# ----------------------------------------------------------------------------- scrubbing
class Scrubber:
    def __init__(self):
        lits: dict[str, str] = {}
        hosts = {socket.gethostname(), run(["hostnamectl", "hostname"]).strip()}
        try:
            hosts.add(Path("/etc/hostname").read_text().strip())
        except OSError:
            pass
        # hosts named in dotsync config, e.g. the other machine
        dcfg = HOME / ".config/dotsync/config"
        if dcfg.exists():
            for m in re.finditer(r"\b(cachyos-[\w-]+)\b", dcfg.read_text(errors="ignore")):
                hosts.add(m.group(1))
        for h in hosts:
            if h and len(h) >= 3 and h not in ("localhost", "cachyos"):
                lits[h] = P_HOST
        # network names (Wi-Fi SSIDs, connection names)
        for n in run(["nmcli", "-t", "-f", "NAME", "connection", "show"]).splitlines():
            n = n.replace("\\:", ":")
            if len(n.strip()) >= 4 and n.strip().lower() not in ("lo", "wired connection 1"):
                lits[n] = P_NET
        for f in glob.glob("/etc/NetworkManager/system-connections/*.nmconnection"):
            stem = Path(f).stem
            if len(stem.strip()) >= 4:
                lits[stem] = P_NET
        # real name / git identity
        gecos = pwd.getpwuid(os.getuid()).pw_gecos.split(",")[0].strip()
        if len(gecos) >= 3 and gecos != USER:
            lits[gecos] = P_NAME
        gname = run(["git", "config", "--global", "user.name"]).strip()
        if len(gname) >= 3 and gname != USER:
            lits[gname] = P_NAME
        gmail = run(["git", "config", "--global", "user.email"]).strip()
        if gmail:
            lits[gmail] = P_MAIL
        # your own list of private strings (one per line)
        if PRIVATE_LIST.exists():
            for l in PRIVATE_LIST.read_text().splitlines():
                l = l.rstrip("\n")
                if l.strip() and not l.startswith("#"):
                    lits[l] = P_RED
        # your public GitHub handle (repo owner in the remote URL) is not private
        remote = run(["git", "-C", str(REPO), "remote", "get-url", "origin"]).strip()
        public = {m.group(1).lower() for m in re.finditer(r"github\.com[:/]+([^/]+)/", remote)}
        for lit in list(lits):
            if lit.lower() in public or any(lit.lower() in p_ for p_ in public):
                note(f"scrubber: '{lit}' is your public GitHub handle (repo remote) — not treated as private")
                del lits[lit]
        self.literals = sorted(lits.items(), key=lambda kv: len(kv[0]), reverse=True)
        u = re.escape(USER)
        self.user_ctx = [
            (re.compile(rf"(?m)^{u}(?=\s)"), P_USER),                               # sudoers
            (re.compile(rf"(?i)((?:^|\s)(?:user|owner|username|login)\s*[=:]\s*[\"']?){u}\b"), rf"\1{P_USER}"),
            (re.compile(rf"(?m)(^\s*User=){u}\b"), rf"\1{P_USER}"),
            (re.compile(rf"(-u\s+|--user[= ]|chown\s+(?:-\w+\s+)*|su\s+(?:-\s+)?){u}\b"), rf"\1{P_USER}"),
            (re.compile(rf"\b{u}:{u}\b"), f"{P_USER}:{P_USER}"),
            (re.compile(rf"(/run/media/|/var/lib/AccountsService/icons/|/var/spool/mail/){u}\b"), rf"\1{P_USER}"),
            (re.compile(rf"([\"'])%?{u}\1"), rf"\1{P_USER}\1"),
        ]
        # home configs: only unambiguous contexts (never bare "red" — it's a colour name)
        self.user_ctx_home = [
            (re.compile(rf"(?i)((?:^|\s)(?:user|owner|username|login)\s*[=:]\s*[\"']?){u}\b"), rf"\1{P_USER}"),
            (re.compile(rf"(-u\s+|--user[= ]|chown\s+(?:-\w+\s+)*|su\s+(?:-\s+)?){u}\b"), rf"\1{P_USER}"),
            (re.compile(rf"\b{u}:{u}\b"), f"{P_USER}:{P_USER}"),
            (re.compile(rf"(/run/media/|/var/lib/AccountsService/icons/){u}\b"), rf"\1{P_USER}"),
        ]
        note(f"scrubber: {len(self.literals)} literal private strings "
             f"(hostnames, network names, identity{', private list' if PRIVATE_LIST.exists() else ''})")

    @staticmethod
    def _ip_ok(s: str) -> bool:
        """True = keep as is (loopback, unspecified, masks, link-local-free generic)."""
        try:
            ip = ipaddress.ip_interface(s).ip
        except ValueError:
            return True  # not an IP at all (version string etc.)
        if ip.is_loopback or ip.is_unspecified:
            return True
        if isinstance(ip, ipaddress.IPv4Address) and str(ip).startswith("255."):
            return True
        return False

    def scrub(self, text: str, rel: str, system: bool) -> str:
        hits: dict[str, int] = defaultdict(int)
        text = text.replace(HOME_S + "/", P_HOME + "/").replace(HOME_S, P_HOME)
        if f"/home/{USER}" in text:
            text = text.replace(f"/home/{USER}", P_HOME)
        for lit, ph in self.literals:
            if lit in text:
                hits[ph] += text.count(lit)
                text = text.replace(lit, ph)
        for rx, rep in (self.user_ctx if system else self.user_ctx_home):
            text, n = rx.subn(rep, text)
            if n:
                hits[P_USER] += n

        def mac(m):
            hits[P_MAC] += 1
            return P_MAC
        text = RE_MAC.sub(mac, text)

        def v4(m):
            s = m.group(0)
            if self._ip_ok(s):
                return s
            hits[P_IP] += 1
            return P_IP
        text = RE_V4.sub(v4, text)

        def v6(m):
            s = m.group(0)
            if s.count(":") < 2 or not re.search(r"[0-9A-Fa-f]", s):
                return s
            try:
                ipaddress.ip_interface(s)
            except ValueError:
                return s
            if self._ip_ok(s):
                return s
            hits[P_IP] += 1
            return P_IP
        text = RE_V6.sub(v6, text)

        def mail(m):
            s_ = m.group(0)
            if s_.startswith(("git@", "noreply@", "users.noreply")) or re.search(
                    r"\.(service|socket|timer|target|mount|path|slice|scope|device|swap)$", s_):
                return s_
            hits[P_MAIL] += 1
            return P_MAIL
        text = RE_MAIL.sub(mail, text)
        text, n = RE_TSNET.subn(P_HOST, text)
        hits[P_HOST] += n

        out_lines = []
        for i, line in enumerate(text.split("\n"), 1):
            m = RE_ENV.match(line)
            if m and P_RED not in line:
                line = m.group("pre") + P_RED
                hits[P_RED] += 1
            else:
                m = RE_KV.match(line)
                if m and secret_key(m.group("key")) and not (m.group("sep") == ":" and rel.endswith(".css")):
                    val = m.group("val")
                    if not val.startswith("@") and not self._harmless_val(val):
                        q = val[0] if val[0] in "\"'" else ""
                        trail = "," if val.rstrip().endswith(",") else ""
                        line = m.group("pre") + q + P_RED + q + trail
                        hits[P_RED] += 1
            # report-only checks
            if RE_NIRI_OUTPUT.match(line):
                note(f"  REVIEW {rel}:{i}: monitor identity → {line.strip()}")
            for tok in RE_LONGTOKEN.findall(line):
                if self._entropy(tok) > 4.0 and not re.fullmatch(r"[0-9a-f]{40,64}", tok):
                    note(f"  REVIEW {rel}:{i}: long random-looking string → {tok[:12]}…")
            if system and re.search(rf"\b{re.escape(USER)}\b", line):
                note(f"  REVIEW {rel}:{i}: username may remain → {line.strip()[:120]}")
            out_lines.append(line)
        text = "\n".join(out_lines)
        hits = {k: v for k, v in hits.items() if v}
        if hits:
            note(f"  scrubbed {rel}: " + ", ".join(f"{k}×{v}" for k, v in sorted(hits.items())))
        return text

    @staticmethod
    def _harmless_val(val: str) -> bool:
        v = val.strip().strip(",;").strip("\"'").lower()
        return v in ("", "true", "false", "yes", "no", "0", "1", "none", "null", "auto", "default",
                     "prompt", "ask", "{", "[", "(", "{}", "[]") or v.startswith(("@home@", "$"))

    @staticmethod
    def _entropy(s: str) -> float:
        import math
        from collections import Counter
        c = Counter(s)
        return -sum(n / len(s) * math.log2(n / len(s)) for n in c.values())


def is_text(b: bytes) -> bool:
    if b"\0" in b[:8192]:
        return False
    try:
        b.decode("utf-8")
        return True
    except UnicodeDecodeError:
        return False


# ----------------------------------------------------------------------------- collection
class Collector:
    def __init__(self, scrubber: Scrubber, excludes: list[str]):
        self.s = scrubber
        self.excludes = excludes
        self.staged: dict[Path, tuple[str, bytes | None, str | None]] = {}  # dest -> (section, data, linktarget)
        self.src_by_dest: dict[Path, Path] = {}
        self.text_files: list[tuple[Path, str]] = []
        self.collected_src: set[str] = set()
        self.ff_chrome: Path | None = None

    def dest_root(self, section: str) -> Path:
        return HERE / "files" if section == "core" else HERE / "SPECIFIC" / section

    @staticmethod
    def rename_parts(rel: str) -> str:
        parts = []
        for p in rel.split("/"):
            if p == USER:
                p = P_USER
            elif p.startswith(USER + "-"):
                p = P_USER + p[len(USER):]
            parts.append(p)
        return "/".join(parts)

    def excluded(self, src: Path) -> str | None:
        s = str(src)
        rel = os.path.relpath(s, HOME_S) if s.startswith(HOME_S + "/") else s
        if FORBIDDEN_PATH.search(s):
            return "forbidden (private)"
        if match_any(rel, self.excludes) or match_any(s, self.excludes):
            return "excluded"
        if match_any(rel, GENERATED):
            return "generated per machine (noctalia/matugen regenerate it)"
        return None

    def add_file(self, section: str, src: Path, why: str = ""):
        if str(src) in self.collected_src:
            return
        reason = self.excluded(src)
        if reason:
            note(f"  skip {src} — {reason}")
            return
        s = str(src)
        if s.startswith(HOME_S + "/"):
            rel_dest = "home/" + os.path.relpath(s, HOME_S)
            system = False
        else:
            o = owner(s)
            if o and s not in modified_files(o):
                note(f"  skip {s} — shipped unmodified by package '{o}' (installer gets it from the package)")
                return
            rel_dest = "system" + s
            system = True
        if self.ff_chrome and s.startswith(str(self.ff_chrome) + "/"):
            rel_dest = "firefox-chrome/" + os.path.relpath(s, self.ff_chrome)
        data = read_bytes(src)
        if data is None:
            return
        rel_dest = self.rename_parts(rel_dest)
        for lit, ph in self.s.literals:
            rel_dest = rel_dest.replace(lit, ph)
        dest = self.dest_root(section) / rel_dest
        self.collected_src.add(s)
        if is_text(data):
            txt = self.s.scrub(data.decode("utf-8"), str(dest.relative_to(HERE)), system)
            self.staged[dest] = (section, txt.encode("utf-8"), None)
            self.text_files.append((dest, txt))
            for inc in includes_of(src, data.decode("utf-8")):
                if inc.exists() and str(inc) not in self.collected_src:
                    old = re.search(r"(dank|dms|caelestia|cosmic|hypr|plasma|kde)", str(inc), re.I)
                    note(f"  dependency: {src.name} includes {inc} → collected"
                         + (" (old-desktop file, kept because a live config still uses it)" if old else ""))
                    self.add_file(section, inc, why=f"included by {src}")
                elif not inc.exists():
                    note(f"  WARNING: {src} includes missing file {inc}")
        else:
            self.staged[dest] = (section, data, None)
        self.src_by_dest[dest] = src

    def add_entry(self, e: Entry):
        if e.kind == "home":
            pats = glob.glob(str(HOME / e.pattern))
            if not pats:
                note(f"  not found (skipped): ~/{e.pattern}")
            for p in sorted(pats):
                for f in list_dir_files(Path(p)):
                    self.add_file(e.section, f)
        elif e.kind == "system":
            pats = glob.glob(e.pattern)
            if not pats:
                r = run(["sudo", "sh", "-c", f"ls -d {e.pattern} 2>/dev/null"])
                pats = [x for x in r.splitlines() if x]
            if not pats:
                note(f"  not found (skipped): {e.pattern}")
            for p in sorted(pats):
                for f in list_dir_files(Path(p)):
                    self.add_file(e.section, f)
        elif e.kind == "firefox":
            chrome = find_ff_chrome()
            if not chrome:
                note("  WARNING: no Firefox profile with a chrome/ dir found")
                return
            self.ff_chrome = chrome
            for f in list_dir_files(chrome):
                self.add_file(e.section, f)
        elif e.kind == "settings":
            self.add_settings(e.section, HOME / e.pattern)
        else:
            note(f"  unknown manifest kind '{e.kind}' — ignored")

    def add_settings(self, section: str, d: Path):
        if not d.is_dir():
            note(f"  not found (skipped): {d}")
            return
        self._pending_settings = (section, d)

    def finish_settings(self):
        """Run after everything else, so we know which link targets are in the repo."""
        if not getattr(self, "_pending_settings", None):
            return
        section, d = self._pending_settings
        for entry in sorted(d.iterdir()):
            rel_name = self.rename_parts(entry.name)
            dest = self.dest_root(section) / "home" / d.name / rel_name
            if not entry.is_symlink():
                note(f"  ~/Settings/{entry.name} is not a symlink — copied as file/dir")
                for f in list_dir_files(entry):
                    self.add_file(section, f)
                continue
            target = os.path.realpath(entry)
            raw = os.readlink(entry)
            ok = target in self.collected_src or any(s.startswith(target + "/") for s in self.collected_src)
            if not ok:
                note(f"  skip ~/Settings/{entry.name} → {raw} (target not part of the repo)")
                continue
            if target.startswith(HOME_S + "/"):
                link = os.path.relpath(target, d)        # portable relative link
            else:
                link = target                            # system path, e.g. /etc/greetd/config.toml
            self.staged[dest] = (section, None, link)
            note(f"  settings link: {d.name}/{entry.name} → {link}")


def find_ff_chrome() -> Path | None:
    for base in (HOME / ".config/mozilla/firefox", HOME / ".mozilla/firefox"):
        ini = base / "profiles.ini"
        if not ini.exists():
            continue
        cp = configparser.RawConfigParser()
        cp.read(ini)
        cands = []
        for sec in cp.sections():
            if sec.startswith("Install") and cp.has_option(sec, "Default"):
                cands.insert(0, cp.get(sec, "Default"))
            elif cp.has_option(sec, "Path"):
                (cands.insert(0, cp.get(sec, "Path")) if cp.get(sec, "Default", fallback="0") == "1"
                 else cands.append(cp.get(sec, "Path")))
        for c in cands:
            p = (base / c) if not os.path.isabs(c) else Path(c)
            if (p / "chrome").is_dir():
                return p / "chrome"
    return None


# ----------------------------------------------------------------------------- packages
def load_pkg_rules():
    rules, adds = [], []
    for raw in (HERE / "manifest" / "packages.conf").read_text().splitlines():
        l = raw.strip()
        if not l or l.startswith("#"):
            continue
        kind, _, rx = l.partition(" ")
        if kind == "add":
            adds.append(rx.strip())
        else:
            rules.append((kind, re.compile(rf"(?:{rx.strip()})")))
    return rules, adds

def build_packages(text_files: list[tuple[Path, str]]):
    explicit = run(["pacman", "-Qqe"], check=True).split()
    foreign = set(run(["pacman", "-Qqm"]).split())
    deps_only = set(run(["pacman", "-Qqd"]).split())
    rules, adds = load_pkg_rules()

    # binary name → package, for everything installed
    bin2pkg: dict[str, str] = {}
    ql = run(["pacman", "-Ql"]).splitlines()
    for l in ql:
        pkg, _, path = l.partition(" ")
        if path.startswith("/usr/bin/") and not path.endswith("/"):
            b = path[len("/usr/bin/"):]
            if "/" not in b and len(b) >= 3:
                bin2pkg.setdefault(b, pkg)
    # desktop-file ids → package (for mimeapps.list etc.)
    for l in ql:
        pkg, _, path = l.partition(" ")
        if path.startswith("/usr/share/applications/") and path.endswith(".desktop"):
            bin2pkg.setdefault(Path(path).name, pkg)

    # which binaries do kept configs / scripts reference?
    referenced: dict[str, set[str]] = defaultdict(set)
    code_like = re.compile(r"(\.kdl|\.fish|\.lua|\.toml|\.ini|\.conf|\.list|\.portal|\.desktop|\.sh|\.py|\.luau|\.json|"
                           r"/usr/local/bin/[^/]+|/functions/[^/]+|config)$")
    tok = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+-]{2,}")
    for dest, txt in text_files:
        r = str(dest)
        if r.endswith(".css") or not code_like.search(r):
            continue
        for t in set(tok.findall(txt)):
            for cand in {t, t.rstrip("."), *t.split(".")}:
                if cand in bin2pkg:
                    referenced[bin2pkg[cand]].add(str(dest.relative_to(HERE)))

    def classify(p: str) -> str:
        for kind, rx in rules:
            if rx.fullmatch(p):
                return kind
        return "keep"

    core: set[str] = set()
    specific: dict[str, set[str]] = defaultdict(set)
    for p in explicit:
        k = classify(p)
        if k == "keep":
            core.add(p)
        elif k.startswith("specific:"):
            specific[k.split(":", 1)[1]].add(p)
        elif k == "olde":
            if p in referenced:
                core.add(p)
                note(f"  pkg KEPT (old-desktop rule, but used by {', '.join(sorted(referenced[p]))[:200]}): {p}")
            else:
                note(f"  pkg dropped (old desktop leftover): {p}")
        elif k == "hard":
            if p in referenced:
                note(f"  pkg dropped (niche app) BUT referenced by {', '.join(sorted(referenced[p]))[:200]}: {p}"
                     " — edit packages.conf if you want it")
            else:
                note(f"  pkg dropped (niche app): {p}")
    # things only installed as a dependency of something we dropped, but used by kept configs
    for p, where in referenced.items():
        if p in deps_only and p not in core and classify(p) == "keep":
            needed_by = run(["pacman", "-Qi", p])
            m = re.search(r"^Required By\s*:\s*(.*)$", needed_by, re.M)
            req = set(m.group(1).split()) if m else set()
            if req and req & core:
                continue   # will be pulled in anyway
            core.add(p)
            note(f"  pkg ADDED (dependency of a dropped package, used by {', '.join(sorted(where))[:160]}): {p}")
    for a in adds:
        core.add(a)
        note(f"  pkg added by rule: {a}")

    def split(ps: set[str]):
        repo_ = sorted(p for p in ps if p not in foreign)
        aur_ = sorted(p for p in ps if p in foreign)
        # an `add` package that isn't installed: decide via sync db
        for p in list(repo_):
            if p not in explicit and p not in deps_only and not run(["pacman", "-Si", p]).strip():
                repo_.remove(p)
                aur_.append(p)
        return repo_, sorted(aur_)

    out = {}
    out["core"] = split(core)
    for sec, ps in specific.items():
        out[sec] = split(ps)
    return out


def extra_repos() -> str:
    std = re.compile(r"^(options|core|extra|multilib|core-testing|extra-testing|multilib-testing|cachyos.*)$")
    out, keep = [], False
    try:
        conf = Path("/etc/pacman.conf").read_text()
    except OSError:
        note("WARNING: /etc/pacman.conf unreadable — no extra repos exported")
        return ""
    for l in conf.splitlines():
        m = re.match(r"^\s*\[([^\]]+)\]", l)
        if m:
            keep = not std.match(m.group(1))
        if keep and l.strip() and not l.lstrip().startswith("#"):
            out.append(l)
    return "\n".join(out) + ("\n" if out else "")


# ----------------------------------------------------------------------------- write / verify / commit
def clean_outputs():
    for d in GENERATED_DIRS:
        shutil.rmtree(HERE / d, ignore_errors=True)
    for sec in SECTIONS_SPECIFIC:
        for sub in ("home", "system", "packages-repo.txt", "packages-aur.txt"):
            p = HERE / "SPECIFIC" / sec / sub
            if p.is_dir():
                shutil.rmtree(p)
            elif p.exists():
                p.unlink()

def write_all(c: Collector, pk: dict, repos: str):
    for dest, (section, data, link) in c.staged.items():
        dest.parent.mkdir(parents=True, exist_ok=True)
        if link is not None:
            if dest.is_symlink() or dest.exists():
                dest.unlink()
            os.symlink(link, dest)
            continue
        dest.write_bytes(data)
        src = c.src_by_dest.get(dest)
        try:
            mode = os.stat(src).st_mode if src else 0o644
        except PermissionError:
            mode = 0o755 if str(dest).find("/usr/local/bin/") >= 0 else 0o644
        os.chmod(dest, 0o755 if mode & 0o111 else 0o644)
    pkgdir = HERE / "packages"
    pkgdir.mkdir(exist_ok=True)
    for sec, (repo_, aur_) in pk.items():
        d = pkgdir if sec == "core" else HERE / "SPECIFIC" / sec
        d.mkdir(parents=True, exist_ok=True)
        pre = "" if sec == "core" else "packages-"
        (d / f"{pre}repo.txt").write_text("\n".join(repo_) + "\n")
        (d / f"{pre}aur.txt").write_text("\n".join(aur_) + "\n")
        note(f"packages[{sec}]: {len(repo_)} repo, {len(aur_)} AUR")
    if repos:
        (pkgdir / "pacman-repos.conf").write_text(repos)
        note("packages: extra pacman repos exported → packages/pacman-repos.conf")

def final_guard():
    """Scan everything that will be committed. Abort on anything secret-looking."""
    bad = []
    lits = [l for l, _ in SCRUB.literals]
    for root, dirs, files in os.walk(HERE):
        dirs[:] = [d for d in dirs if d != ".git"]
        for f in files:
            p = Path(root) / f
            rel = str(p.relative_to(HERE))
            if p.is_symlink():
                tgt = os.readlink(p)
                if HOME_S in tgt or f"/home/{USER}" in tgt:
                    bad.append(f"{rel}: symlink points into your home by absolute path")
                continue
            if FORBIDDEN_PATH.search("/" + rel) and not rel.startswith("manifest/"):
                bad.append(f"{rel}: forbidden file type")
            if rel in ("collect.py",) or rel.startswith("manifest/"):
                continue
            b = p.read_bytes()
            if not is_text(b):
                for lit in lits:
                    if len(lit) >= 5 and lit.encode() in b:
                        bad.append(f"{rel}: binary file contains a private string")
                continue
            t = b.decode()
            for rx, what in FORBIDDEN_CONTENT:
                if rx.search(t):
                    bad.append(f"{rel}: looks like a {what}")
            if HOME_S in t or f"/home/{USER}/" in t:
                bad.append(f"{rel}: still contains your home path")
            for lit in lits:
                if lit in t:
                    bad.append(f"{rel}: still contains a private string ({SCRUB.literals and dict(SCRUB.literals)[lit]})")
    if bad:
        for b in bad:
            note("GUARD: " + b)
        # don't leave rejected files lying around in the working tree
        clean_outputs()
        subprocess.run(["git", "-C", str(REPO), "checkout", "HEAD", "--",
                        *[str(HERE / d) for d in ("files", "packages", "SPECIFIC")]],
                       capture_output=True)
        die("privacy guard found problems (see above / report). Nothing was committed.\n  " + "\n  ".join(bad[:30]))
    note("GUARD: passed — no home paths, private strings, keys or tokens found")

def git(*a: str) -> str:
    return run(["git", "-C", str(REPO), *a])

def strip_exif():
    if not shutil.which("exiftool"):
        note("exiftool not installed — wallpapers kept as-is (they came from wallhaven, so normally no personal EXIF)")
        return
    for root, _, files in os.walk(HERE):
        for f in files:
            if f.lower().endswith((".jpg", ".jpeg", ".png", ".webp")):
                subprocess.run(["exiftool", "-q", "-all=", "-overwrite_original", os.path.join(root, f)])
    note("EXIF/metadata stripped from images")


SCRUB: Scrubber

def main():
    global SCRUB
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-commit", action="store_true", help="collect and verify, but do not commit")
    ap.add_argument("-y", "--yes", action="store_true", help="commit without asking")
    args = ap.parse_args()

    if not (REPO / ".git").exists():
        die(f"{REPO} is not a git repository — run this from your ricesync clone")
    if os.geteuid() == 0:
        die("run as your normal user (sudo is used only to read root-only files)")
    print(":: sudo is used to read root-only files (sudoers.d, greetd, …)")
    subprocess.run(["sudo", "-v"])

    report.append(f"ricesync collect report — {HERE}\n(never committed; lives outside the repo)\n")
    entries, excludes = load_manifest()
    excludes += dotsync_excludes()
    SCRUB = Scrubber()
    c = Collector(SCRUB, excludes)
    for e in entries:
        note(f"[{e.section}] {e.kind} {e.pattern}")
        c.add_entry(e)
    c.finish_settings()

    print(":: building package lists")
    pk = build_packages(c.text_files)
    repos = extra_repos()

    clean_outputs()
    write_all(c, pk, repos)
    strip_exif()
    final_guard()
    write_report()

    git("add", "-A", "--", str(HERE))
    print(git("status", "--short", "--", str(HERE)))
    print(f"\n:: Review report (what was scrubbed / skipped / flagged): {REPORT}")
    flagged = [l for l in report if "REVIEW" in l or "WARNING" in l]
    if flagged:
        print(f":: {len(flagged)} line(s) flagged for manual review:")
        for l in flagged[:40]:
            print("   " + l.strip())
    if args.no_commit:
        print(":: --no-commit: changes are staged, not committed.")
        return
    if not args.yes:
        a = input("\nCommit these changes? (nothing is pushed) [y/N] ").strip().lower()
        if a not in ("y", "yes"):
            print(":: not committed. Changes remain staged; `git restore --staged CachyOS-OG` to unstage.")
            return
    msg = ("CachyOS-OG: config snapshot + installer\n\n"
           "Configs, package lists and install.sh to rebuild this setup on a\n"
           "no-desktop CachyOS install. Machine-specific parts live in SPECIFIC/.\n\n"
           "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\n"
           "Claude-Session: https://claude.ai/code/session_01T75ij69KbrmmVwpjbPiGa6\n")
    r = subprocess.run(["git", "-C", str(REPO), "commit", "-F", "-"], input=msg, text=True)
    if r.returncode == 0:
        print("\n:: committed. Check it with `git show --stat`, then `git push` when happy.")

if __name__ == "__main__":
    main()
