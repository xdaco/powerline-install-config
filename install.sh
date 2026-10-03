#!/bin/sh
#title          :install.sh
#description    :Install powerline, apply this repo's config, print the shell entry
#author         :Musarraf Hossain
#email          :xdaco.xinu@gmail.com
#date           :20261003
#version        :2.0
#usage          :./install.sh [--mode=pipx|native] [--fonts=PREFIX] [--dry-run|--check]
#notes          :Safe to re-run; anything in the way is backed up, never overwritten
#shell          :POSIX sh — no bashisms (runs under dash, busybox ash, ksh, bash)
#==============================================================================
# install.sh — set up powerline on macOS, Ubuntu, Debian, Fedora or NixOS.
#
#   ./install.sh                      detect the OS, ask how to install, then do it
#   ./install.sh --mode=pipx          powerline in its own pipx venv (our fork)
#   ./install.sh --mode=native        the system package manager's powerline
#   ./install.sh --check              report what is installed, change nothing
#   ./install.sh --dry-run            print every action, change nothing
#   ./install.sh --no-fonts           skip the patched fonts
#   ./install.sh --help               full option list
#
# Three things happen, in this order: powerline (plus the powerline-gitstatus
# plugin the theme needs) is installed, this repo's config is copied into
# ~/.config/powerline, and the line to add to your shell is printed. Nothing is
# ever written to a shell rc file — the last step is a suggestion, not an edit.
#
# Re-running is safe. Anything in ~/.config/powerline that would be overwritten
# is moved to ~/.powerline-backup-<timestamp>/ first; nothing is deleted.

set -eu

# shellcheck disable=SC1007  # CDPATH= is a deliberate per-command assignment
REPO_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
CONFIG_SRC="$REPO_DIR/config"
CONFIG_DST="${XDG_CONFIG_HOME:-$HOME/.config}/powerline"
BACKUP_DIR="$HOME/.powerline-backup-$(date +%Y%m%d-%H%M%S)"
LOCAL_BIN="$HOME/.local/bin"

# Powerline comes from our own fork, not from PyPI. The released 2.8.4 dies on
# python 3.14 with "argument groups cannot be nested" (its daemon nests an
# argparse group, which 3.14 forbids); upstream fixed it in PR 2271 but has cut
# no release carrying it, so the tag below is that commit, tagged by us.
# Override to install something else -- a plain PyPI install on python 3.14
# brings the crash back:
#
#     POWERLINE_SPEC=powerline-status ./install.sh --mode=pipx
POWERLINE_SPEC="${POWERLINE_SPEC:-git+https://github.com/xdaco/powerline.git@2.8.4-py314}"
FONTS_REPO="${POWERLINE_FONTS_REPO:-https://github.com/xdaco/powerline-fonts.git}"

# ------------------------------------------------------------- output --------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    _esc=$(printf '\033')
    C_RST="${_esc}[0m";  C_B="${_esc}[1m";   C_GRN="${_esc}[32m"
    C_YLW="${_esc}[33m"; C_RED="${_esc}[31m"; C_CYN="${_esc}[36m"
    unset _esc
else
    C_RST=''; C_B=''; C_GRN=''; C_YLW=''; C_RED=''; C_CYN=''
fi

info() { printf '%s==>%s %s\n' "$C_CYN" "$C_RST" "$*"; }
ok()   { printf '%sok  %s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
step() { printf '     %s\n' "$*"; }
die()  { printf '%serr %s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
head2() { printf '\n%s%s%s\n' "$C_B" "$*" "$C_RST"; }

# Every state-changing command goes through this, so --dry-run is one place
# rather than a conditional at each call site.
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '     would run: %s\n' "$*"
        return 0
    fi
    "$@"
}

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    [ "$INTERACTIVE" -eq 1 ] || return 1
    _cf_reply=""
    printf '%s [y/N] ' "$1" >&2
    read -r _cf_reply || return 1
    case "$_cf_reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------- detection --------
# The same detection the dotfiles repo uses, so this script and the resulting
# shell always agree about which system this is. Parsed with the shell, not sed:
# detection has to work before anything has been installed, and a minimal NixOS
# image ships neither sed nor awk -- without them the obvious "sed -n" version
# silently returns "linux" on a box whose os-release says nixos, which then
# picks the Debian defaults.
detect_os() {
    [ -n "${XDACO_OS:-}" ] && { printf '%s' "$XDACO_OS"; return; }
    case "$(uname -s)" in
        Darwin) printf 'macos' ;;
        Linux)
            _do_id=""; _do_line=""; _do_v=""
            if [ -r /etc/os-release ]; then
                while IFS= read -r _do_line; do
                    case "$_do_line" in
                        ID=*|ID_LIKE=*)
                            _do_v="${_do_line#*=}"; _do_v="${_do_v%\"}"; _do_v="${_do_v#\"}"
                            _do_id="$_do_id $_do_v" ;;
                    esac
                done < /etc/os-release
            fi
            case " $_do_id " in
                *nixos*)           printf 'nixos'  ;;
                *fedora*|*rhel*)   printf 'fedora' ;;
                *ubuntu*)          printf 'ubuntu' ;;
                *debian*)          printf 'debian' ;;
                *)                 printf 'linux'  ;;
            esac ;;
        *) printf 'unknown' ;;
    esac
}

# WSL is not a separate target -- it is Ubuntu or Debian as far as packages go.
# It is detected for exactly one reason: fonts installed into the Linux
# filesystem are invisible to the Windows terminal that draws the glyphs, so the
# font step has to say "do this on the Windows side" instead of quietly
# succeeding and leaving you with a prompt full of boxes.
is_wsl() {
    [ -n "${WSL_DISTRO_NAME:-}" ] && return 0
    [ -n "${WSLENV:-}" ] && return 0
    [ -r /proc/version ] && case "$(cat /proc/version 2>/dev/null)" in
        *icrosoft*|*WSL*) return 0 ;;
    esac
    return 1
}

OS="$(detect_os)"

# pipx's home is asked for rather than assumed: it is ~/.local/pipx on a current
# pipx and ~/.local/share/pipx on older ones. Guessing wrong is not loud -- it
# makes every "is it already installed?" check below answer no. Resolved at call
# time because pipx itself may be installed by this script.
pipx_venv() {
    _pv_home=""
    _pv_home="$(pipx environment --value PIPX_HOME 2>/dev/null)" || _pv_home=""
    [ -n "$_pv_home" ] || _pv_home="${PIPX_HOME:-$HOME/.local/share/pipx}"
    printf '%s/venvs/%s\n' "$_pv_home" "$1"
}

# ------------------------------------------------------------ options --------
MODE=""
FONTS="all"
# Whether --fonts was actually passed, as opposed to defaulting to "all". A
# non-interactive run must not install 113 font files because nobody said
# otherwise -- same reasoning as --mode below.
FONTS_EXPLICIT=0
DO_FONTS=1
DO_CONFIG=1
DRY_RUN=0
CHECK=0
ASSUME_YES=0
if [ -t 0 ] && [ -t 1 ]; then INTERACTIVE=1; else INTERACTIVE=0; fi

usage() {
    cat <<'USAGE'
install.sh — install powerline and apply this repo's configuration.

  --mode=pipx       powerline in its own pipx venv, from our fork (recommended)
  --mode=native     the system package manager's powerline
                    (macOS has no Homebrew powerline formula; there it means
                     brew install pipx, then the pipx path)
  --fonts=PREFIX    install only fonts whose filename starts with PREFIX,
                    e.g. --fonts=Meslo. Default: all of them
  --no-fonts        skip the patched fonts entirely
  --no-config       install powerline but do not touch ~/.config/powerline
  --check           report what is installed and which config is live, then exit
  --dry-run, -n     print every action, change nothing
  --yes, -y         never prompt
  --help, -h        this message

Environment:
  POWERLINE_SPEC          what pipx installs (default: our py3.14 fork tag)
  POWERLINE_FONTS_REPO    where the patched fonts come from
  XDACO_OS                override OS detection

A non-interactive run (piped, CI, called from another script) must pass --mode:
guessing how to install python software on someone's machine is not a decision
this script makes silently.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mode=*)    MODE="${1#*=}" ;;
        --mode)      shift; [ $# -gt 0 ] || die "--mode needs a value"; MODE="$1" ;;
        --fonts=*)   FONTS="${1#*=}"; FONTS_EXPLICIT=1 ;;
        --no-fonts)  DO_FONTS=0; FONTS_EXPLICIT=1 ;;
        --no-config) DO_CONFIG=0 ;;
        --check)     CHECK=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --yes|-y)    ASSUME_YES=1 ;;
        --help|-h)   usage; exit 0 ;;
        *)           usage >&2; die "unknown option '$1'" ;;
    esac
    shift
done

case "$FONTS" in
    all|ALL) FONTS="" ;;          # empty prefix matches every font file
    none)    DO_FONTS=0 ;;
esac

case "$MODE" in
    ""|pipx|native) ;;
    *) die "--mode must be 'pipx' or 'native', not '$MODE'" ;;
esac

# Does cmp exist? It lives in diffutils, which a minimal Fedora image does NOT
# ship -- measured on fedora:41, where every file came back "differs" because
# "command not found" is a non-zero exit, so a correct install looked entirely
# wrong and nothing was ever idempotent. cksum is coreutils and is always there,
# so it is the fallback rather than the primary: cmp compares bytes and stops at
# the first difference, cksum reads both files whole and compares a checksum.
if command -v cmp >/dev/null 2>&1; then HAVE_CMP=1; else HAVE_CMP=0; fi
files_same() {
    [ -f "$1" ] && [ -f "$2" ] || return 1
    if [ "$HAVE_CMP" -eq 1 ]; then
        cmp -s "$1" "$2"
        return $?
    fi
    [ "$(cksum < "$1")" = "$(cksum < "$2")" ]
}

# ------------------------------------------------- finding what we built -----
# Follow symlinks by hand: "readlink -f" is GNU only and macOS ships BSD
# readlink, which has no -f. Bounded rather than loop-detecting -- ten hops is
# already absurd for a shim.
resolve_real() {
    _rr_p="$1"; _rr_link=""; _rr_hops=0
    while [ -L "$_rr_p" ] && [ "$_rr_hops" -lt 10 ]; do
        _rr_link="$(readlink "$_rr_p")"
        case "$_rr_link" in
            /*) _rr_p="$_rr_link" ;;
            *)  _rr_p="$(dirname "$_rr_p")/$_rr_link" ;;
        esac
        _rr_hops=$((_rr_hops + 1))
    done
    printf '%s' "$_rr_p"
}

# Which powerline-daemon will actually run, preferring the one we just
# installed over whatever else is on PATH.
find_daemon() {
    if [ -n "${POWERLINE_BIN:-}" ] && [ -x "$POWERLINE_BIN/powerline-daemon" ]; then
        printf '%s' "$POWERLINE_BIN/powerline-daemon"; return 0
    fi
    _fd_venv=""
    _fd_venv="$(pipx_venv powerline-status)"
    if [ -x "$_fd_venv/bin/powerline-daemon" ]; then
        printf '%s' "$_fd_venv/bin/powerline-daemon"; return 0
    fi
    if [ -x "$LOCAL_BIN/powerline-daemon" ]; then
        printf '%s' "$LOCAL_BIN/powerline-daemon"; return 0
    fi
    command -v powerline-daemon 2>/dev/null || return 1
}

# The bindings directory holds one file per shell (bash/powerline.sh,
# zsh/powerline.zsh, tmux/powerline.conf) and its path embeds the python
# version, so it cannot be hardcoded. Candidates are ordered: the install that
# owns the daemon first, so the binding always matches the binary that renders
# the prompt. /usr/share/powerline/bindings is where Debian and Ubuntu put them
# for the distro package -- it is NOT under site-packages, which is why a
# site-packages-only search finds nothing in native mode on those systems.
binding_dirs() {
    _bd_root=""
    _bd_daemon=""
    _bd_daemon="$(find_daemon)" || _bd_daemon=""
    if [ -n "$_bd_daemon" ]; then
        _bd_root="$(dirname "$(dirname "$(resolve_real "$_bd_daemon")")")"
    fi
    # Emitted as whole lines rather than through a ${root:+...} inside an
    # unquoted printf list: a pipx home can contain spaces (macOS pipx defaults
    # to ~/Library/Application Support/pipx), and word splitting there dropped
    # the owning install from the list entirely.
    if [ -n "$_bd_root" ]; then
        printf '%s\n' "$_bd_root/lib/python3*/site-packages/powerline/bindings"
        printf '%s\n' "$_bd_root/share/powerline/bindings"
        printf '%s\n' "$_bd_root/share/powerline"
    fi
    printf '%s\n' \
        "$HOME/.local/pipx/venvs/powerline-status/lib/python3*/site-packages/powerline/bindings" \
        "$HOME/.local/share/pipx/venvs/powerline-status/lib/python3*/site-packages/powerline/bindings" \
        "$HOME/.local/lib/python3*/site-packages/powerline/bindings" \
        "/usr/share/powerline/bindings" \
        "/usr/share/powerline" \
        "/usr/lib/python3*/site-packages/powerline/bindings" \
        "/usr/lib/python3*/dist-packages/powerline/bindings" \
        "/usr/local/lib/python3*/site-packages/powerline/bindings" \
        "/usr/local/lib/python3*/dist-packages/powerline/bindings" \
        "/opt/homebrew/lib/python3*/site-packages/powerline/bindings" \
        "$HOME/.nix-profile/lib/python3*/site-packages/powerline/bindings" \
        "/run/current-system/sw/lib/python3*/site-packages/powerline/bindings"
}

# Print the readable path to one binding file, e.g. find_binding bash/powerline.sh.
# An unmatched glob stays literal in bash and simply fails the -r test. No break
# in the inner loop on purpose: within one directory the LAST match wins, and a
# glob sorts ascending, so that is the highest python version rather than the
# oldest interpreter on the box.
find_binding() {
    _fb_rel="$1"
    _fb_hit=""
    _fb_oldifs="$IFS"

    # Two opposite expansion rules are needed in the same function, which is why
    # this is fiddly. Splitting the candidate list: split on newlines and do NOT
    # glob, because the patterns contain * and must reach the inner loop intact.
    set -f
    IFS='
'
    # shellcheck disable=SC2046  # splitting on newlines is exactly the intent
    set -- $(binding_dirs)
    IFS="$_fb_oldifs"
    set +f

    for _fb_pat in "$@"; do
        [ -n "$_fb_pat" ] || continue
        # Matching one entry: glob, but do NOT split. IFS is emptied because the
        # pattern must still undergo pathname expansion while a path containing
        # a space stays one word. With the default IFS a venv under "Application
        # Support" split into two broken words, every candidate failed, and the
        # search fell through to whatever OTHER powerline was on the box --
        # pairing one install's daemon with another install's bindings.
        IFS=''
        # No break in the inner loop on purpose: within one directory the LAST
        # match wins, and a glob sorts ascending, so that is the highest python
        # version rather than the oldest interpreter on the box.
        for _fb_c in $_fb_pat/$_fb_rel; do
            [ -r "$_fb_c" ] && _fb_hit="$_fb_c"
        done
        IFS="$_fb_oldifs"
        [ -n "$_fb_hit" ] && break
    done

    [ -n "$_fb_hit" ] || return 1
    printf '%s' "$_fb_hit"
}

# The python that imports the powerline segments -- which is the one that has to
# be able to import powerline_gitstatus. For a pipx install that is the venv's
# python; for a distro package it is the system python the daemon's shebang names.
powerline_python() {
    _pp_venv=""; _pp_daemon=""; _pp_first=""
    _pp_venv="$(pipx_venv powerline-status)"
    [ -x "$_pp_venv/bin/python" ] && { printf '%s' "$_pp_venv/bin/python"; return 0; }
    _pp_daemon="$(find_daemon)" || return 1
    _pp_first="$(head -n 1 "$(resolve_real "$_pp_daemon")" 2>/dev/null || true)"
    case "$_pp_first" in
        '#!'*)
            _pp_first="${_pp_first#\#!}"
            # "#!/usr/bin/env python3" -> take the argument, not /usr/bin/env
            case "$_pp_first" in */env\ *) _pp_first="${_pp_first#*env }" ;; esac
            # Unquoted on purpose: a shebang's interpreter and its argument
            # are one string here and have to be split back apart.
            # shellcheck disable=SC2086
            set -- $_pp_first
            [ -x "${1:-}" ] && { printf '%s' "$1"; return 0; } ;;
    esac
    command -v python3 2>/dev/null || return 1
}

# ------------------------------------------------------------- doctor --------
# --check answers the questions you cannot answer by looking at a prompt: which
# of several powerlines is live, whether the theme's plugin actually imports,
# and whether the config under ~ is this repo's or something else's.
doctor() {
    # Two counters, not one: rc is "something is broken", notes is "something is
    # true that you should know". A config stowed from the dotfiles repo is the
    # second kind, and reporting it as the first would make --check fail on every
    # machine that is set up correctly.
    _d_rc=0; _d_notes=0; _d_daemon=""; _d_py=""; _d_binding=""; _d_fontdir=""

    head2 "system"
    step "detected OS          $OS$(is_wsl && printf ' (WSL)' || true)"
    step "powerline spec       $POWERLINE_SPEC"

    head2 "powerline"
    if _d_daemon="$(find_daemon)"; then
        ok "powerline-daemon     $_d_daemon"
        step "resolves to          $(resolve_real "$_d_daemon")"
    else
        warn "no powerline-daemon on PATH or in a pipx venv"; _d_rc=1
    fi
    if [ -d "$(pipx_venv powerline-status)" ]; then
        ok "pipx venv            $(pipx_venv powerline-status)"
    else
        step "pipx venv            not present"
    fi

    head2 "powerline-gitstatus"
    # The theme references powerline_gitstatus.gitstatus, so this is not
    # optional: without it every prompt renders an exception instead of a branch.
    if _d_py="$(powerline_python)"; then
        step "python               $_d_py"
        if "$_d_py" -c 'import powerline_gitstatus' 2>/dev/null; then
            ok "importable           yes"
        else
            warn "powerline_gitstatus is NOT importable by the python that renders the prompt"
            step "the theme in this repo needs it; the prompt will show an error without it"
            _d_rc=1
        fi
    else
        warn "could not work out which python renders the prompt"; _d_rc=1
    fi

    head2 "bindings"
    # A missing tmux binding is a note, not a fault: Fedora's powerline package
    # ships bash and zsh only (measured on fedora:41), and someone who does not
    # use tmux has nothing wrong with their install. What WOULD be broken is
    # having no shell binding at all, so that is what sets rc.
    _d_shell_bindings=0; _d_found=""
    for _d_binding in bash/powerline.sh zsh/powerline.zsh; do
        if _d_found="$(find_binding "$_d_binding")"; then
            ok "$(printf '%-20s' "${_d_binding%%/*}")$_d_found"
            _d_shell_bindings=$((_d_shell_bindings + 1))
        else
            warn "no binding found for ${_d_binding%%/*}"
            _d_notes=1
        fi
    done
    if [ "$_d_shell_bindings" -eq 0 ]; then
        warn "no shell binding at all — the prompt cannot be wired up"; _d_rc=1
    fi
    if _d_found="$(find_binding tmux/powerline.conf)"; then
        ok "$(printf '%-20s' tmux)$_d_found"
    else
        step "tmux                 not shipped by this powerline (fine unless you use tmux)"
    fi

    head2 "configuration"
    if [ -L "$CONFIG_DST" ] || [ -L "$CONFIG_DST/config.json" ]; then
        _d_target="$CONFIG_DST"
        [ -L "$CONFIG_DST/config.json" ] && _d_target="$CONFIG_DST/config.json"
        warn "$_d_target is a symlink -> $(readlink "$_d_target")"
        step "something else manages this config; see 'Already using the dotfiles repo' in the README"
        _d_notes=1
    elif [ -f "$CONFIG_DST/config.json" ]; then
        ok "config.json          $CONFIG_DST/config.json"
    else
        warn "no config at $CONFIG_DST"; _d_rc=1
    fi
    _d_rel=""
    for _d_rel in config.json colorschemes/default.json themes/shell/mine.json themes/shell/__main__.json; do
        if [ ! -e "$CONFIG_DST/$_d_rel" ]; then
            warn "missing              $_d_rel"; _d_rc=1
        elif ! files_same "$CONFIG_SRC/$_d_rel" "$CONFIG_DST/$_d_rel"; then
            warn "differs from repo    $_d_rel"; _d_rc=1
        fi
    done

    head2 "fonts"
    case "$OS" in
        macos) _d_fontdir="$HOME/Library/Fonts" ;;
        *)     _d_fontdir="$HOME/.local/share/fonts" ;;
    esac
    # Counted with a glob rather than "ls | grep": ls fails on a missing
    # directory, and the patched filenames contain spaces ("Meslo LG S DZ
    # Regular for Powerline.ttf"), which a pipeline would split.
    _d_n=0; _d_f=""
    for _d_f in "$_d_fontdir"/*[Pp]owerline*; do [ -e "$_d_f" ] && _d_n=$((_d_n + 1)); done
    if [ "$_d_n" -gt 0 ]; then
        ok "patched fonts        $_d_n in $_d_fontdir"
    else
        warn "no 'for Powerline' fonts in $_d_fontdir"
        is_wsl && step "under WSL the fonts belong on the Windows host, not here"
        _d_rc=1
    fi

    printf '\n'
    if [ "$_d_rc" -ne 0 ]; then
        warn "see the warnings above"
    elif [ "$_d_notes" -ne 0 ]; then
        ok "powerline is healthy; the config is managed from somewhere else (see above)"
    else
        ok "everything checks out"
    fi
    return $_d_rc
}

# -------------------------------------------------------- choosing how -------
# macOS is not a choice: Homebrew has no powerline formula at all. The only
# thing called "powerline" in homebrew-core is powerline-go, an unrelated Go
# reimplementation that does not read config.json or themes, so the theme in
# this repo would not apply to it. "native" on macOS therefore means what brew
# can actually provide -- pipx -- and the two modes converge.
select_mode() {
    if [ -z "$MODE" ] && [ "$INTERACTIVE" -eq 0 ]; then
        usage >&2
        die "no TTY and no --mode: pass --mode=pipx or --mode=native"
    fi

    if [ "$OS" = macos ]; then
        info "macOS: Homebrew has no powerline formula (only the unrelated powerline-go)"
        step "brew supplies pipx, pipx supplies powerline — both --mode values do this here"
        # Resolved to pipx, not merely described as equivalent. Leaving MODE as
        # "native" sent main() into install_powerline_native, which has no macos
        # case and fell through to "no package recipe for 'macos'" -- so
        # --mode=native on a Mac installed nothing at all.
        MODE=pipx
        return 0
    fi

    [ -n "$MODE" ] && return 0

    _sm_reply=""
    head2 "How should powerline be installed?"
    cat <<MENU

  1) pipx     powerline in its own venv, from our fork
              ($POWERLINE_SPEC)
              Does not touch the system python. The gitstatus plugin is
              injected into the same venv. Recommended.

  2) native   $(native_pkg_cmd_label)
              The distribution's powerline, upstream rather than our fork.
              The gitstatus plugin then has to reach the SYSTEM python, which
              on this kind of system pip may refuse (PEP 668).

MENU
    printf 'Choose [1/2] (default 1): ' >&2
    read -r _sm_reply || _sm_reply=""
    case "$_sm_reply" in
        2) MODE=native ;;
        *) MODE=pipx ;;
    esac
    ok "mode: $MODE"
}

native_pkg_cmd_label() {
    case "$OS" in
        debian|ubuntu) printf 'apt-get install powerline' ;;
        fedora)        printf 'dnf install powerline' ;;
        nixos)         printf 'pkgs.powerline (declared, not installed by this script)' ;;
        *)             printf 'your package manager'"'"'s powerline' ;;
    esac
}

# Rocky, AlmaLinux, CentOS Stream and RHEL itself are detected as "fedora",
# because their ID_LIKE says rhel and dnf is indeed the right tool -- but their
# BASE repositories carry neither powerline nor pipx. Both are in EPEL, which is
# itself packaged in base as epel-release. Measured on rockylinux:9 and
# almalinux:9, where every install failed with "No matching Packages to list"
# until EPEL was enabled; with it, powerline 2.8.4-1.el9 and pipx 1.2.1-2.el9
# are both there. Fedora proper needs none of this, hence the ID != fedora test.
is_rhel_rebuild() {
    [ "$OS" = fedora ] || return 1
    [ -r /etc/os-release ] || return 1
    _irr_id=""; _irr_line=""
    while IFS= read -r _irr_line; do
        case "$_irr_line" in
            ID=*) _irr_id="${_irr_line#ID=}"
                  _irr_id="${_irr_id%\"}"; _irr_id="${_irr_id#\"}" ;;
        esac
    done < /etc/os-release
    [ -n "$_irr_id" ] && [ "$_irr_id" != fedora ]
}

# Enabling EPEL is itself a plain dnf install from a repository that IS enabled,
# so this needs no third-party URL and nothing is fetched from outside the
# distribution.
ensure_epel() {
    is_rhel_rebuild || return 0
    if dnf repolist enabled 2>/dev/null | grep -qi epel; then
        ok "EPEL already enabled"
        return 0
    fi
    _ee_SUDO="$(sudo_prefix)"
    info "enabling EPEL — powerline and pipx are not in this system's base repositories"
    if run ${_ee_SUDO:+$_ee_SUDO} dnf install -y epel-release; then
        ok "EPEL enabled"
        return 0
    fi
    warn "could not install epel-release"
    step "on this distribution powerline and pipx live in EPEL. Enable it with:"
    step "    sudo dnf install epel-release"
    step "or re-run with --mode=pipx once pipx is available another way."
    return 1
}

# sudo is needed for the distro package manager, and only there. NixOS installs
# nothing imperatively and macOS uses brew, which refuses to run under sudo.
sudo_prefix() {
    case "$OS" in macos|nixos) return 0 ;; esac
    [ "$(id -u)" -eq 0 ] && return 0
    command -v sudo >/dev/null 2>&1 && printf 'sudo'
}

# ------------------------------------------------------- nixos is special ----
# NixOS is declarative: telling the user what to declare is the whole job. Doing
# it for them would mean editing configuration.nix, which is theirs.
nixos_help() {
    _nh_pkgs="$1"
    cat >&2 <<NIXHELP

    NixOS installs packages declaratively; this script will not do it for you.

    System-wide — /etc/nixos/configuration.nix:

        environment.systemPackages = with pkgs; [ $_nh_pkgs ];

      then:  sudo nixos-rebuild switch

    Per-user — Home Manager, ~/.config/home-manager/home.nix:

        home.packages = with pkgs; [ $_nh_pkgs ];

      then:  home-manager switch

    Just this once, declaring nothing:

        nix-shell -p $_nh_pkgs --run '$0 --no-fonts'

NIXHELP
}

# ---------------------------------------------------------------- pipx -------
install_pipx() {
    command -v pipx >/dev/null 2>&1 && { ok "pipx already installed"; return 0; }

    _ipx_SUDO="$(sudo_prefix)"
    info "installing pipx"
    case "$OS" in
        macos)
            command -v brew >/dev/null 2>&1 \
                || die "Homebrew is required on macOS. Install it from https://brew.sh, then re-run."
            run brew install pipx ;;
        debian|ubuntu)
            # bookworm+ has "pipx"; bullseye and older only "python3-pipx".
            run ${_ipx_SUDO:+$_ipx_SUDO} apt-get update || true
            run ${_ipx_SUDO:+$_ipx_SUDO} apt-get install -y pipx \
                || run ${_ipx_SUDO:+$_ipx_SUDO} apt-get install -y python3-pipx || true ;;
        fedora)
            ensure_epel || true
            run ${_ipx_SUDO:+$_ipx_SUDO} dnf install -y pipx || true
            # RHEL rebuilds ship python3 without the pip module, so the generic
            # "python3 -m pip install --user pipx" fallback below cannot run
            # either unless pip is installed first.
            command -v pipx >/dev/null 2>&1 \
                || run ${_ipx_SUDO:+$_ipx_SUDO} dnf install -y python3-pip || true ;;
        nixos)
            warn "pipx is not installed and NixOS installs declaratively"
            nixos_help "pipx"
            return 1 ;;
        *)
            warn "unrecognised system '$OS' — install pipx with your package manager" ;;
    esac

    command -v pipx >/dev/null 2>&1 && { ok "pipx installed"; return 0; }
    [ "$DRY_RUN" -eq 1 ] && return 0

    # Last resort. On PEP 668 systems (Debian 12+, Fedora 38+) a plain --user
    # install is refused as "externally-managed-environment"; say so rather than
    # forcing --break-system-packages behind the user's back.
    info "falling back to pip"
    if run python3 -m pip install --user pipx 2>/dev/null; then
        ok "pipx installed with pip --user"
        return 0
    fi
    warn "could not install pipx automatically"
    step "your python is probably externally managed. Either install the distro"
    step "package, or if you accept the risk:"
    step "    python3 -m pip install --user --break-system-packages pipx"
    return 1
}

install_powerline_pipx() {
    _ipp_venv="$(pipx_venv powerline-status)"
    if [ -d "$_ipp_venv" ]; then
        ok "powerline already installed with pipx ($_ipp_venv)"
        return 0
    fi
    command -v pipx >/dev/null 2>&1 || { [ "$DRY_RUN" -eq 1 ] || return 1; }

    if command -v powerline-daemon >/dev/null 2>&1; then
        step "a powerline is already on PATH; the pipx one is installed alongside it"
        step "set POWERLINE_BIN in your shell to choose which of the two renders the prompt"
    fi

    info "installing powerline with pipx from $POWERLINE_SPEC"
    # Deliberately NOT running "pipx ensurepath": it appends a PATH line to your
    # rc files, and editing those is exactly what this script promises not to do.
    # The printed shell entry puts ~/.local/bin on PATH instead.
    run pipx install "$POWERLINE_SPEC" || { warn "pipx install failed"; return 1; }
    ok "powerline installed into $_ipp_venv"
}

# powerline-gitstatus is a powerline *plugin*: the segment is imported by
# powerline itself, so it has to land in the same environment. Which command
# that is depends entirely on how powerline was installed, which is why this is
# not just "pip install".
install_gitstatus_pipx() {
    _igp_venv="$(pipx_venv powerline-status)"
    if [ -x "$_igp_venv/bin/python" ] && "$_igp_venv/bin/python" -c 'import powerline_gitstatus' 2>/dev/null; then
        ok "powerline-gitstatus already in the pipx venv"
        return 0
    fi
    info "injecting powerline-gitstatus into the powerline venv"
    run pipx inject powerline-status powerline-gitstatus \
        || { warn "pipx inject failed — run it by hand:"; step "pipx inject powerline-status powerline-gitstatus"; return 1; }
    ok "powerline-gitstatus injected"
}

# -------------------------------------------------------------- native ------
install_powerline_native() {
    if command -v powerline-daemon >/dev/null 2>&1; then
        ok "powerline already on PATH ($(command -v powerline-daemon))"
        return 0
    fi
    _ipn_SUDO="$(sudo_prefix)"
    case "$OS" in
        debian|ubuntu)
            info "installing powerline with apt"
            run ${_ipn_SUDO:+$_ipn_SUDO} apt-get update || true
            run ${_ipn_SUDO:+$_ipn_SUDO} apt-get install -y powerline \
                || { warn "apt could not install powerline"; return 1; } ;;
        fedora)
            ensure_epel || true
            info "installing powerline with dnf"
            run ${_ipn_SUDO:+$_ipn_SUDO} dnf install -y powerline \
                || { warn "dnf could not install powerline"
                     is_rhel_rebuild && step "powerline is in EPEL on this distribution — see above"
                     return 1; } ;;
        nixos)
            warn "powerline is not installed and NixOS installs declaratively"
            nixos_help "powerline"
            # Verified against nixpkgs: powerline, powerline-fonts,
            # powerline-symbols and pipx all exist; powerline-gitstatus does
            # NOT, under any attribute (nixpkgs.gitstatus is romkatv's unrelated
            # tool). So native mode cannot produce a working prompt here,
            # because the theme imports powerline_gitstatus.
            warn "powerline-gitstatus is not in nixpkgs, and this theme requires it"
            step "native mode therefore cannot give you a working prompt on NixOS."
            step "Declare pipx instead and re-run with --mode=pipx, which builds"
            step "the plugin into powerline's own venv:"
            step ""
            step "    environment.systemPackages = with pkgs; [ pipx ];"
            return 1 ;;
        *)
            warn "no package recipe for '$OS' — install powerline with your package manager,"
            step "or re-run with --mode=pipx, which needs no distro support"
            return 1 ;;
    esac
    ok "powerline installed"
}

# In native mode the plugin has to be importable by the SYSTEM python, because
# that is what the distro's powerline runs. Distro packages for it are rare, so
# this usually ends at pip --user -- which PEP 668 systems (Debian 12+,
# Fedora 38+) refuse. We say what to do and stop; writing into a
# system-managed site-packages is the user's call, not this script's.
install_gitstatus_native() {
    _ign_py="$(powerline_python)" || _ign_py="python3"
    if "$_ign_py" -c 'import powerline_gitstatus' 2>/dev/null; then
        ok "powerline-gitstatus already importable by $_ign_py"
        return 0
    fi
    _ign_SUDO="$(sudo_prefix)"

    # Measured, because it is the opposite of what you would guess: Debian 12
    # and Ubuntu 24.04 DO package it (python3-powerline-gitstatus 1.3.2-1),
    # Fedora 41 does NOT -- it ships powerline and powerline-fonts only. So apt
    # usually succeeds here and dnf usually falls through to pip below. Both are
    # attempted regardless; a distro package is the only version that survives a
    # python upgrade.
    case "$OS" in
        fedora)        run ${_ign_SUDO:+$_ign_SUDO} dnf install -y powerline-gitstatus 2>/dev/null || true ;;
        debian|ubuntu) run ${_ign_SUDO:+$_ign_SUDO} apt-get install -y python3-powerline-gitstatus 2>/dev/null || true ;;
    esac
    if [ "$DRY_RUN" -eq 0 ] && "$_ign_py" -c 'import powerline_gitstatus' 2>/dev/null; then
        ok "powerline-gitstatus installed from the distro"
        return 0
    fi

    # No pip at all is a fixable state, not a dead end: Fedora's base image
    # simply omits python3-pip, and once it is there "pip install --user"
    # succeeds -- Fedora does not refuse --user installs the way Debian does.
    # Measured on fedora:41, where this is the difference between native mode
    # working and native mode giving up.
    if ! "$_ign_py" -m pip --version >/dev/null 2>&1; then
        # Announced only where there is actually a package manager to do it
        # with: on NixOS this said "installing the distro's pip package" and
        # then installed nothing, which is a plain untruth in the output.
        case "$OS" in
            fedora)
                info "that python has no pip; installing python3-pip"
                run ${_ign_SUDO:+$_ign_SUDO} dnf install -y python3-pip || true ;;
            debian|ubuntu)
                info "that python has no pip; installing python3-pip"
                run ${_ign_SUDO:+$_ign_SUDO} apt-get install -y python3-pip || true ;;
            *)
                step "that python has no pip, and there is no package recipe for '$OS'" ;;
        esac
    fi

    info "installing powerline-gitstatus with pip --user"
    if run "$_ign_py" -m pip install --user powerline-gitstatus 2>/dev/null; then
        ok "powerline-gitstatus installed"
        return 0
    fi

    warn "pip would not install powerline-gitstatus into the system python"
    if ! "$_ign_py" -m pip --version >/dev/null 2>&1; then
        # Fedora splits pip into python3-pip and the base image omits it.
        step "That python has no pip at all ($_ign_py -m pip is missing)."
        step "Install your distro's python3-pip, or use --mode=pipx."
    else
        step "This is PEP 668: your python is externally managed, so pip refuses to"
        step "write to it."
    fi
    step "The theme in this repo NEEDS this plugin — without it every prompt"
    step "renders an exception instead of your git branch."
    step ""
    step "Three ways out, best first:"
    step "  1. re-run with --mode=pipx, which sidesteps the system python entirely"
    step "  2. install your distro's package for it, if it has one"
    step "  3. accept the risk and override pip:"
    step "       $_ign_py -m pip install --user --break-system-packages powerline-gitstatus"
    return 1
}

# --------------------------------------------------------------- config ------
# Copied rather than symlinked: this clone can then be deleted or moved without
# breaking the prompt. Anything in the way is moved to a timestamped backup, so
# re-running never costs you a hand-edited file.
apply_config() {
    [ -d "$CONFIG_SRC" ] || die "no config/ directory in $REPO_DIR"

    # A symlinked config means something ELSE owns it -- the dotfiles repo stows
    # exactly these four files. Moving that link aside would silently detach the
    # machine from its dotfiles, so it needs saying out loud first.
    _ac_link_target=""
    if [ -L "$CONFIG_DST" ]; then _ac_link_target="$(readlink "$CONFIG_DST")"
    elif [ -L "$CONFIG_DST/config.json" ]; then _ac_link_target="$(readlink "$CONFIG_DST/config.json")"
    fi
    if [ -n "$_ac_link_target" ]; then
        warn "$CONFIG_DST is managed by symlinks into $_ac_link_target"
        step "that is another repo's stow (see the README); replacing it here would"
        step "detach this machine from it, and a later 'stow' there would fight back"
        if ! confirm "Replace the symlinked config with a copy from this repo?"; then
            step "leaving the existing config alone — powerline install and fonts still done"
            return 0
        fi
    fi

    info "installing config into $CONFIG_DST"
    _ac_rel=""; _ac_src=""; _ac_dst=""
    while IFS= read -r _ac_rel; do
        _ac_rel="${_ac_rel#./}"
        [ -n "$_ac_rel" ] || continue
        _ac_src="$CONFIG_SRC/$_ac_rel"
        _ac_dst="$CONFIG_DST/$_ac_rel"
        if [ -e "$_ac_dst" ] || [ -L "$_ac_dst" ]; then
            if [ ! -L "$_ac_dst" ] && files_same "$_ac_src" "$_ac_dst"; then
                step "unchanged  $_ac_rel"
                continue
            fi
            run mkdir -p "$BACKUP_DIR/$(dirname "$_ac_rel")"
            run mv "$_ac_dst" "$BACKUP_DIR/$_ac_rel"
            step "backed up  $_ac_rel -> $BACKUP_DIR/$_ac_rel"
        fi
        run mkdir -p "$(dirname "$_ac_dst")"
        run cp "$_ac_src" "$_ac_dst"
        step "installed  $_ac_rel"
    done <<EOF
$( cd "$CONFIG_SRC" && find . -type f -name '*.json' )
EOF
    ok "config applied"
    [ -d "$BACKUP_DIR" ] && step "what was there before is in $BACKUP_DIR"
    return 0
}

# ---------------------------------------------------------------- fonts ------
# Delegated to the fonts repo's own install.sh, which already does the only
# OS-specific part correctly: ~/Library/Fonts on Darwin, ~/.local/share/fonts
# plus fc-cache elsewhere. Reimplementing that here would be a second copy to
# keep in step. Its argument is a filename PREFIX, so "Meslo" means the
# "Meslo LG * for Powerline" family and empty means all of them.
install_fonts() {
    [ "$DO_FONTS" -eq 1 ] || { step "skipping fonts (--no-fonts)"; return 0; }

    # Under WSL the glyphs are drawn by the Windows terminal, which cannot see a
    # font installed into the Linux filesystem. Installing them here would
    # "succeed" and leave a prompt full of boxes, so don't.
    if is_wsl; then
        warn "WSL detected — fonts installed in Linux are invisible to the Windows terminal"
        step "install them on the Windows side instead:"
        step "  1. clone $FONTS_REPO on Windows (or copy it out of \\\\wsl\$)"
        step "  2. run install.ps1 in an elevated PowerShell, or right-click the"
        step "     .ttf/.otf files and choose Install"
        step "  3. pick the installed font in Windows Terminal → Settings → your profile"
        return 0
    fi

    if [ "$OS" = nixos ]; then
        warn "NixOS manages fonts declaratively — not cloning them into your home"
        step "add to /etc/nixos/configuration.nix:"
        step ""
        step "    fonts.packages = with pkgs; [ powerline-fonts powerline-symbols ];"
        step ""
        step "then:  sudo nixos-rebuild switch"
        return 0
    fi

    command -v git >/dev/null 2>&1 || { warn "git is not installed — skipping fonts"; return 0; }

    # "All of them" is 113 files across 30 families, so it is confirmed rather
    # than assumed. Without a TTY there is nobody to confirm, and confirm()
    # returning false must mean "don't" -- not "nobody objected, go ahead".
    if [ -z "$FONTS" ] && [ "$FONTS_EXPLICIT" -eq 0 ]; then
        if [ "$INTERACTIVE" -eq 0 ]; then
            warn "not installing fonts: that would be all 113 files and nothing asked for them"
            step "pass --fonts=all to install every family, --fonts=Meslo for one, or"
            step "--no-fonts to say so explicitly"
            return 0
        fi
        if ! confirm "That is every family in the repo (~113 files). Continue?"; then
            step "skipping fonts; re-run with --fonts=Meslo for just one family"
            return 0
        fi
    fi

    if [ -n "$FONTS" ]; then
        info "installing patched fonts matching '$FONTS*' from $FONTS_REPO"
    else
        info "installing all patched fonts from $FONTS_REPO"
    fi
    _if_tmp=""
    if [ "$DRY_RUN" -eq 1 ]; then
        step "would run: git clone --depth=1 $FONTS_REPO <tmp> && <tmp>/install.sh ${FONTS:-(all)}"
        return 0
    fi
    _if_tmp="$(mktemp -d "${TMPDIR:-/tmp}/powerline-fonts.XXXXXX")" || { warn "could not create a temp dir"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -rf '$_if_tmp'" EXIT
    if ! git clone --depth=1 --quiet "$FONTS_REPO" "$_if_tmp/fonts"; then
        warn "could not clone $FONTS_REPO — skipping fonts"
        rm -rf "$_if_tmp"; trap - EXIT
        return 1
    fi
    # The fonts repo's own installer creates the directory on Linux but not on
    # Darwin, so a home without ~/Library/Fonts yet got "fonts installed" and no
    # fonts. Create it here rather than patching their script.
    case "$OS" in
        macos) mkdir -p "$HOME/Library/Fonts" ;;
        *)     mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/fonts" ;;
    esac
    sh "$_if_tmp/fonts/install.sh" "$FONTS" || warn "the font installer reported a problem"
    rm -rf "$_if_tmp"; trap - EXIT
    ok "fonts installed"
}

# -------------------------------------------------------- the shell entry ----
# Printed, never written. Editing someone's rc file is the one thing an
# installer cannot undo cleanly, and these files are frequently symlinks into a
# dotfiles repo -- appending to one of those edits tracked source.
#
# Concrete paths rather than a glob, because they are resolved here and now and
# a literal path is something you can read and verify. The cost is that the
# bindings path embeds the python version, so a python upgrade moves it; the
# note below says so, and --check reports it.
print_shell_entry() {
    _pse_daemon=""; _pse_bash_b=""; _pse_zsh_b=""; _pse_tmux_b=""
    _pse_daemon="$(find_daemon)" || _pse_daemon=""
    _pse_bash_b="$(find_binding bash/powerline.sh)" || _pse_bash_b=""
    _pse_zsh_b="$(find_binding zsh/powerline.zsh)" || _pse_zsh_b=""
    _pse_tmux_b="$(find_binding tmux/powerline.conf)" || _pse_tmux_b=""

    if [ -z "$_pse_daemon" ] || { [ -z "$_pse_bash_b" ] && [ -z "$_pse_zsh_b" ]; }; then
        head2 "Next step"
        warn "powerline's shell bindings were not found, so there is no entry to suggest yet"
        step "run './install.sh --check' once powerline is installed to get it"
        return 0
    fi

    head2 "Add this to your shell"
    cat <<'INTRO'
Nothing was written to any rc file. Paste the block for the shell you use.
INTRO

    if [ -z "$_pse_bash_b" ]; then
        printf '\n%s# bash: no bash binding found in this install%s\n' "$C_YLW" "$C_RST"
    else
        printf '\n%s~/.bashrc%s\n\n' "$C_B" "$C_RST"
        printf '    # Powerline\n'
        # shellcheck disable=SC2016  # $HOME stays literal: this is printed, not run
        [ "$MODE" = pipx ] && printf '    [ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"\n'
        printf '    if [ -r "%s" ]; then\n' "$_pse_bash_b"
        printf '        "%s" -q\n' "$_pse_daemon"
        printf '        POWERLINE_BASH_CONTINUATION=1\n'
        printf '        POWERLINE_BASH_SELECT=1\n'
        printf '        source "%s"\n' "$_pse_bash_b"
        printf '    fi\n'
    fi

    if [ -z "$_pse_zsh_b" ]; then
        printf '\n%s# zsh: no zsh binding found in this install%s\n' "$C_YLW" "$C_RST"
    else
        printf '\n%s~/.zshrc%s\n\n' "$C_B" "$C_RST"
        printf '    # Powerline\n'
        # shellcheck disable=SC2016  # $HOME stays literal: this is printed, not run
        [ "$MODE" = pipx ] && printf '    [ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"\n'
        printf '    if [ -r "%s" ]; then\n' "$_pse_zsh_b"
        printf '        "%s" -q\n' "$_pse_daemon"
        printf '        source "%s"\n' "$_pse_zsh_b"
        printf '    fi\n'
        printf '\n    %s# zsh only: a prompt theme loaded AFTER this wins. Oh My Zsh with%s\n' "$C_YLW" "$C_RST"
        printf '    %s# ZSH_THEME set (Powerlevel10k, agnoster, ...) replaces the powerline%s\n' "$C_YLW" "$C_RST"
        printf '    %s# prompt, so put this block after oh-my-zsh.sh and unset ZSH_THEME,%s\n' "$C_YLW" "$C_RST"
        printf '    %s# or pick one of the two.%s\n' "$C_YLW" "$C_RST"
    fi

    if [ -n "$_pse_tmux_b" ]; then
        printf '\n%s~/.config/tmux/tmux.conf%s   (or ~/.tmux.conf)\n\n' "$C_B" "$C_RST"
        printf '    source "%s"\n' "$_pse_tmux_b"
        printf '\n    %s# Using Oh my tmux!? Put it in tmux.conf.local instead — tmux.conf there%s\n' "$C_YLW" "$C_RST"
        printf '    %s# is the upstream file and is overwritten on update.%s\n' "$C_YLW" "$C_RST"
    fi

    cat <<'OUTRO'

Then open a new shell, or source the file you edited.

The bindings path above contains a python version, so a python upgrade will
move it. Re-run ./install.sh --check to get the current one; it reports a stale
path as a missing binding.
OUTRO
}

restart_daemon() {
    _rd_daemon="$(find_daemon)" || return 0
    info "restarting the powerline daemon"
    # --replace rather than a bare start: a daemon from a previous install is
    # already running with the OLD config cached, so without this the prompt
    # keeps rendering the pre-install theme and the script looks like it failed.
    run "$_rd_daemon" --replace -q || warn "could not restart the daemon — it starts on your next shell anyway"
}

# ----------------------------------------------------------------- main ------
main() {
    head2 "powerline-install-config"
    step "detected $OS$(is_wsl && printf ' (WSL)' || true)"

    if [ "$CHECK" -eq 1 ]; then
        doctor
        return $?
    fi

    select_mode

    head2 "powerline"
    _m_pl_ok=1
    case "$MODE" in
        pipx)
            install_pipx       && install_powerline_pipx   && install_gitstatus_pipx   || _m_pl_ok=0 ;;
        native)
            install_powerline_native && install_gitstatus_native || _m_pl_ok=0 ;;
    esac
    [ "$_m_pl_ok" -eq 1 ] || warn "powerline is not fully installed — see above; the rest still runs"

    if [ "$DO_CONFIG" -eq 1 ]; then
        head2 "configuration"
        apply_config
    else
        step "skipping config (--no-config)"
    fi

    head2 "fonts"
    install_fonts || true

    [ "$DRY_RUN" -eq 1 ] || restart_daemon

    print_shell_entry

    printf '\n'
    if [ "$DRY_RUN" -eq 1 ]; then
        ok "dry run finished — nothing was changed"
    elif [ "$_m_pl_ok" -eq 1 ]; then
        ok "done. './install.sh --check' verifies the result."
    else
        warn "finished with problems — './install.sh --check' lists what is still missing"
        return 1
    fi
}

main "$@"
