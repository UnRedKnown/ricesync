# ricesync

<!--
  Markdown quick reference (this comment is invisible on GitHub — delete it whenever):
    # Title / ## Section / ### Subsection   → headings
    **bold**   *italic*   `code`            → text styles
    - item                                  → bullet list (1. item for numbered)
    [text](https://link)                    → link
    > text                                  → quote / callout box
    ```sh ... ```                           → code block (sh = shell highlighting)
  A blank line starts a new paragraph; a single line break is ignored.
-->

> [!WARNING]
> **This entire repository is vibecoded.**
> The scripts, configs and docs here were written mostly by an AI (Claude) and
> reviewed only lightly. They work on my machines, but they may not work on yours.

## What this is

A list of rices I made, plus the tools I use to keep them in sync between
my machines and to rebuild on any new ones.

- `dotsync` / `dotsync.list`: syncs configs between my machines
- [`CachyOS-OG/`](CachyOS-OG/README.md): a snapshot of the latest config of my first CachyOS install, plus an installer

## Before you use anything here

- **Read the scripts before running them.** Some of them use `sudo` and change system files.
- Try `./install.sh --dry-run` first to check what will be changed.
- Expect bugs, rough edges and assumptions that only hold for my hardware.
- No support or warranty. Use at your own risk.

## All programs and files belong to their respective owners

I do not claim ownership of any copyrighted files within this repo.
Things like fonts, programs, ELF binaries are simply repackaged here for ease of use.
