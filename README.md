# powerline-install-config

Install [powerline](https://github.com/powerline/powerline), apply my prompt
configuration, and print the line to add to your shell — on macOS, Ubuntu,
Debian, Fedora or NixOS, from one script.

```bash
git clone https://github.com/xdaco/powerline-install-config.git
cd powerline-install-config && ./install.sh
```

Three things happen, in this order:

1. **powerline** is installed, together with
   [powerline-gitstatus](https://github.com/jaspernbrouwer/powerline-gitstatus)
   — the theme here needs it, so it is not optional.
2. **the configuration** in [`config/`](config) is copied to
   `~/.config/powerline/`, backing up anything already there.
3. **the shell entry** is printed for you to paste.

Step 3 is printed, never written. No rc file is edited — those are frequently
symlinks into a dotfiles repo, and appending to one of those silently edits
tracked source.

![What you get](powerline-prompt.png "What you get")

`install.sh` is **POSIX sh** — no bashisms, verified with `checkbashisms` and
`shellcheck -s sh`, and exercised under `dash` and busybox `ash` as well as
bash. It needs no bash at all: the full suite passes on Alpine, which ships
none.

## How powerline gets installed

The script detects the OS and asks. Either answer ends with the same prompt;
they differ in *whose* python ends up carrying powerline.

| | **pipx** (recommended) | **native** |
| --- | --- | --- |
| What | Our fork in its own venv | The distribution's package |
| Version | `xdaco/powerline` @ `2.8.4-py314` | Whatever the distro ships, upstream |
| System python | Untouched | Used |
| gitstatus | `pipx inject`, into the same venv | Must reach the system python |
| Shell bindings | in the venv | `/usr/share/powerline/bindings` (Debian) or `/usr/share/powerline` (Fedora) |

```bash
./install.sh --mode=pipx      # skip the question
./install.sh --mode=native
```

A run with no terminal attached (piped, CI, called from another script) **must**
pass `--mode`. Guessing how to install python software on someone's machine is
not a decision this script makes silently.

### Why the fork rather than PyPI

Released powerline 2.8.4 dies on python 3.14 with `argument groups cannot be
nested` — its daemon nests an argparse group, which 3.14 forbids. Upstream fixed
it in PR 2271 but has cut no release carrying it, so
[`xdaco/powerline`](https://github.com/xdaco/powerline) tags that commit as
`2.8.4-py314`, and that is what pipx mode installs. Point it elsewhere if you
want to — note that plain PyPI on python 3.14 brings the crash back:

```bash
POWERLINE_SPEC=powerline-status ./install.sh --mode=pipx
```

### Per-OS reality

| OS | pipx mode | native mode |
| --- | --- | --- |
| **macOS** | `brew install pipx`, then pipx | same as pipx — see below |
| **Ubuntu / Debian** | `apt-get install pipx` (or `python3-pipx` on bullseye and older) | `apt-get install powerline` + `python3-powerline-gitstatus` |
| **Fedora** | `dnf install pipx` | `dnf install powerline`; gitstatus falls back to pip |
| **NixOS** | reported, not installed | reported, not installed |
| anything else | pipx if you have it | tells you to install it yourself |

**macOS has no native option.** Homebrew carries no `powerline` formula — the
only thing in homebrew-core matching the name is `powerline-go`, an unrelated Go
reimplementation that does not read `config.json` or themes, so the
configuration here would not apply to it. On macOS both `--mode` values
therefore do the same thing: brew supplies pipx, pipx supplies powerline.

**NixOS installs nothing.** It is declarative, so the script prints what to
declare — `environment.systemPackages`, Home Manager's `home.packages`, or a
one-off `nix-shell -p` — and stops. Editing `configuration.nix` is yours.

On NixOS, use `--mode=pipx`. Checked against nixpkgs: `powerline`, `pipx`,
`powerline-fonts` and `powerline-symbols` all exist, but **`powerline-gitstatus`
does not**, under any attribute — so native mode cannot produce a working prompt
there, because this theme imports it. Declaring `pipx` and running
`--mode=pipx` builds the plugin into powerline's own venv and sidesteps that.
Fonts are declarative too:

```nix
fonts.packages = with pkgs; [ powerline-fonts powerline-symbols ];
```

## The configuration

Four files, copied to `~/.config/powerline/`:

| File | What it sets |
| --- | --- |
| [`config.json`](config/config.json) | `shell.theme` = `mine`, truecolor off |
| [`themes/shell/mine.json`](config/themes/shell/mine.json) | the segments, left side only |
| [`themes/shell/__main__.json`](config/themes/shell/__main__.json) | arguments to those segments |
| [`colorschemes/default.json`](config/colorschemes/default.json) | the gitstatus colours |

The prompt reads: hostname (**only over SSH**), user, virtualenv, cwd (**two
levels**), git status with the last tag, and the number of background jobs.

`~/.config/powerline` is powerline's own XDG config path on every platform,
which is the whole reason this repo is OS-agnostic now: nothing is patched
inside the installed package, so a powerline upgrade cannot undo it.

Anything already at one of those four paths is moved to
`~/.powerline-backup-<timestamp>/` first. Nothing is overwritten and nothing is
deleted, so re-running is safe — a file that already matches is left alone and
reported as `unchanged`.

## Fonts

The segment dividers are glyphs in a private-use area, so an unpatched font
renders them as boxes. The patched fonts come from
[`xdaco/powerline-fonts`](https://github.com/xdaco/powerline-fonts), whose own
installer already handles the platform difference (`~/Library/Fonts` on macOS,
`~/.local/share/fonts` plus `fc-cache` elsewhere), so this script delegates to
it rather than keeping a second copy of that logic.

```bash
./install.sh --fonts=Meslo     # just the "Meslo LG * for Powerline" family
./install.sh --fonts=all       # all 30 families, 113 files
./install.sh --no-fonts        # none
```

Interactively, "all" is confirmed before it runs. Non-interactively it is
**skipped** unless `--fonts` says so explicitly — 113 font files is not
something to install because nobody objected.

Then set the font in your terminal: iTerm2 → Profiles → Text, Ghostty →
`font-family`, GNOME Terminal → Profile → Custom font.

### WSL

Fonts installed inside the Linux filesystem are invisible to the Windows
terminal that actually draws the glyphs. The script detects WSL and tells you to
install them on the Windows side instead of "succeeding" and leaving you with a
prompt full of boxes. Clone the fonts repo on Windows, run `install.ps1` in an
elevated PowerShell, then pick the font in Windows Terminal → Settings → your
profile.

## The shell entry

Printed at the end with the real paths resolved for the install that just
happened — bash, zsh and tmux. Roughly:

```bash
# Powerline
[ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"
if [ -r "<bindings>/bash/powerline.sh" ]; then
    "<daemon>" -q
    POWERLINE_BASH_CONTINUATION=1
    POWERLINE_BASH_SELECT=1
    source "<bindings>/bash/powerline.sh"
fi
```

Concrete paths rather than a glob, because they are resolved there and then and
a literal path is something you can read and verify. The cost: the bindings path
contains a python version, so **a python upgrade moves it**. `./install.sh
--check` reports a stale path as a missing binding and prints the current one.

Two things that will cost you an evening otherwise:

- **zsh**: a prompt theme loaded *after* this block wins. Oh My Zsh with
  `ZSH_THEME` set (Powerlevel10k, agnoster, …) replaces the powerline prompt
  entirely. Pick one of the two.
- **tmux**: with [Oh my tmux!](https://github.com/gpakosz/.tmux), put the
  `source` line in `tmux.conf.local` — `tmux.conf` there is the upstream file
  and is overwritten on update.

## Checking it worked

```bash
./install.sh --check
```

Answers the questions a prompt cannot: which of several powerlines is live,
whether `powerline_gitstatus` actually imports in the python that renders the
prompt, whether each shell binding is where the printed entry says, whether the
config under `~` still matches this repo, and whether a patched font is
installed. Exits non-zero on a real problem.

## Portability

`install.sh` and `tests/test-install.sh` are strict POSIX shell: no `local`, no
arrays, no `[[`, no process substitution, no `$'...'`, no `pipefail`. Function
variables are prefixed per function (`_fb_`, `_ac_`, `_d_`…) instead of scoped,
which is the price of dropping `local`.

Verified three ways, not just asserted:

| | |
| --- | --- |
| `checkbashisms -f install.sh` | clean |
| `shellcheck -s sh install.sh` | clean |
| run under `dash`, busybox `ash`, bash | full suite passes |

Only `#!/bin/sh` is required. Everything else used is POSIX plus `mktemp` and
`find`, which every target ships.

## Testing

`tests/test-install.sh` runs eleven checks against a real install: `--check` on
a bare machine, the no-TTY refusal, the install itself, `--check` afterwards,
all four config files byte-compared, **a real prompt rendered**, the printed
shell entry located, and a re-run proving idempotency.

It installs packages and writes to `$HOME`, so run it in a container:

```bash
podman run --rm -v "$PWD:/repo:ro" docker.io/library/ubuntu:24.04 sh -c '
  apt-get update -qq && apt-get install -y -qq git ca-certificates
  cp -R /repo /work && cd /work && sh tests/test-install.sh pipx'
```

Swap `pipx` for `native`, and the image for `debian:12`, `fedora:41` or
`alpine:3`. Current results:

| | pipx | native |
| --- | --- | --- |
| Ubuntu 24.04 | 11/11 | 11/11 |
| Debian 12 | 11/11 | 11/11 |
| Fedora 41 | 11/11 | 11/11 |
| Alpine 3 (busybox ash, no bash) | 11/11 | n/a — no apk recipe |
| macOS | 11/11 | → pipx |
| NixOS | reports declaratively, exits non-zero | same |

Alpine is not a supported target — there is no `apk` branch, so it is detected
as generic `linux` — but `--mode=pipx` works there, which is what the suite
covers.

## Regenerating the screenshot

`powerline-prompt.png` is rendered from powerline's own ANSI output, so it shows
the real prompt rather than a mock-up. After changing the config:

```bash
powerline shell left --last-exit-code=0 --jobnum=0 | python3 tools/screenshot.py > prompt.svg
rsvg-convert -z 2 -o powerline-prompt.png prompt.svg
```

Run it from inside a git repository, or the gitstatus segment will not appear.

## Options

| Flag | Effect |
| --- | --- |
| `--mode=pipx`, `--mode=native` | How to install powerline; required without a TTY |
| `--fonts=PREFIX` | Only fonts whose filename starts with `PREFIX` |
| `--no-fonts` | Skip fonts |
| `--no-config` | Install powerline, leave `~/.config/powerline` alone |
| `--check` | Report state, change nothing, non-zero on a problem |
| `--dry-run`, `-n` | Print every action, change nothing |
| `--yes`, `-y` | Never prompt |
| `--help`, `-h` | Option list |

| Environment | Effect |
| --- | --- |
| `POWERLINE_SPEC` | What pipx installs (default: the py3.14 fork tag) |
| `POWERLINE_FONTS_REPO` | Where the patched fonts come from |
| `XDACO_OS` | Override OS detection |
| `POWERLINE_BIN` | Which install `--check` and the printed entry prefer |

## Already using the dotfiles repo?

[`xdaco/home-directory`](https://github.com/xdaco/home-directory) stows these
same four config files and installs powerline with pipx as part of
`installation.sh`. **Do not point both at the same machine.**

If that repo is already managing this machine, `~/.config/powerline` is a tree
of symlinks into its clone. This script detects that, says whose it is, and asks
before replacing it — decline and the powerline install and fonts still happen
while the config is left alone. `--check` reports the same thing as a note
rather than a fault, because on such a machine that is the correct state.

This repo is written to be the single place that logic lives: it is callable
non-interactively, so `installation.sh` can delegate its powerline step to

```bash
./install.sh --mode=pipx --no-config --no-fonts --yes
```

and keep stowing the config itself. Nothing in `home-directory` has been changed
to do that yet — that hand-off is a separate commit over there.

## Troubleshooting

**Native mode cannot install `powerline-gitstatus`.** Where it lands depends on
the distro, and it is the opposite of what you would expect:

| | `powerline` | `powerline-gitstatus` | Result |
| --- | --- | --- | --- |
| Ubuntu 24.04 | yes | yes, `python3-powerline-gitstatus` | works |
| Debian 12 | yes, 2.8.3-4 | yes, 1.3.2-1 | works |
| Fedora 41 | yes, 2.8.4-5 | **not packaged** | falls back to pip |

On Fedora the fallback is `pip install --user`, which fails for one of two
reasons the script tells apart: PEP 668 (an externally-managed python refusing
to be written to) or no `pip` module at all — the Fedora base image omits
`python3-pip` entirely. Either way the script prints the options, including
`--mode=pipx`, and stops rather than forcing `--break-system-packages` behind
your back.

**The prompt shows a traceback instead of a branch.** `powerline_gitstatus` is
not importable by the python rendering the prompt. `./install.sh --check` says
so explicitly, including which python it tried.

**The config changed but the prompt did not.** The daemon caches it. The script
runs `powerline-daemon --replace` at the end; by hand it is the same command.

**Boxes instead of dividers.** The font. See [Fonts](#fonts).

## Upgrading from the old version of this repo

Until October 2026 this was `ubuntu-powerline-bash`: Ubuntu only, bash only,
`pip install git+git://…` (a protocol GitHub switched off in 2022), hardcoded
`python2.7` paths, and `jq` editing powerline's *own* `config_files/` inside the
installed package — which a powerline upgrade silently reverted.

Nothing is patched in place any more. If you ran the old script, its edits live
inside the old powerline install and go away with it; the config this version
installs to `~/.config/powerline` takes precedence over package defaults
regardless. Remove the old `pip --user` powerline if it is still on your `PATH`,
or set `POWERLINE_BIN` to pick between them.

## Customization

[Powerline's configuration reference](https://powerline.readthedocs.org/en/latest/configuration.html#configuration-and-customization).
Edit the files in `config/` and re-run `./install.sh --no-fonts`, or edit
`~/.config/powerline/` directly and run `powerline-daemon --replace` —
`--check` will then report the two as differing, which is how you find the ones
you meant to keep.

---

*I am not responsible if this script damages your computer; use it at your own
risk and understand what it does first.*
