#!/usr/bin/env bash
#title          :install.sh
#description    :Install powerline, apply this repo's config, print the shell entry
#author         :Musarraf Hossain
#email          :xdaco.xinu@gmail.com
#date           :20261003
#version        :2.0
#usage          :./install.sh [--mode=pipx|native] [--fonts=PREFIX] [--dry-run|--check]
#notes          :Safe to re-run; anything in the way is backed up, never overwritten
#shell          :bash 3.2+ (macOS ships 3.2)
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

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    C_RST=$'\033[0m'; C_B=$'\033[1m'; C_GRN=$'\033[32m'
    C_YLW=$'\033[33m'; C_RED=$'\033[31m'; C_CYN=$'\033[36m'
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
    local reply
    printf '%s [y/N] ' "$1" >&2
    read -r reply || return 1
    case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
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
            local id="" line v
            if [ -r /etc/os-release ]; then
                while IFS= read -r line; do
                    case "$line" in
                        ID=*|ID_LIKE=*)
                            v="${line#*=}"; v="${v%\"}"; v="${v#\"}"
                            id="$id $v" ;;
                    esac
                done < /etc/os-release
            fi
            case " $id " in
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
    local home
    home="$(pipx environment --value PIPX_HOME 2>/dev/null)" || home=""
    [ -n "$home" ] || home="${PIPX_HOME:-$HOME/.local/share/pipx}"
    printf '%s/venvs/%s\n' "$home" "$1"
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
    local p="$1" link hops=0
    while [ -L "$p" ] && [ "$hops" -lt 10 ]; do
        link="$(readlink "$p")"
        case "$link" in
            /*) p="$link" ;;
            *)  p="$(dirname "$p")/$link" ;;
        esac
        hops=$((hops + 1))
    done
    printf '%s' "$p"
}

# Which powerline-daemon will actually run, preferring the one we just
# installed over whatever else is on PATH.
find_daemon() {
    if [ -n "${POWERLINE_BIN:-}" ] && [ -x "$POWERLINE_BIN/powerline-daemon" ]; then
        printf '%s' "$POWERLINE_BIN/powerline-daemon"; return 0
    fi
    local venv
    venv="$(pipx_venv powerline-status)"
    if [ -x "$venv/bin/powerline-daemon" ]; then
        printf '%s' "$venv/bin/powerline-daemon"; return 0
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
    local root=""
    local daemon; daemon="$(find_daemon)" || daemon=""
    if [ -n "$daemon" ]; then
        root="$(dirname "$(dirname "$(resolve_real "$daemon")")")"
    fi
    # Emitted as whole lines rather than through a ${root:+...} inside an
    # unquoted printf list: a pipx home can contain spaces (macOS pipx defaults
    # to ~/Library/Application Support/pipx), and word splitting there dropped
    # the owning install from the list entirely.
    if [ -n "$root" ]; then
        printf '%s\n' "$root/lib/python3*/site-packages/powerline/bindings"
        printf '%s\n' "$root/share/powerline/bindings"
        printf '%s\n' "$root/share/powerline"
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
    local rel="$1" pat hit c oldifs
    while IFS= read -r pat; do
        [ -n "$pat" ] || continue
        hit=""
        # IFS emptied around the glob: the pattern must still undergo pathname
        # expansion but must NOT be split on whitespace. With the default IFS,
        # a venv under "Application Support" split into two broken words, every
        # candidate failed, and the search fell through to whatever OTHER
        # powerline was on the box -- pairing one install's daemon with another
        # install's bindings. Measured on macOS with a pipx home under
        # ~/Library/Application Support.
        oldifs="$IFS"; IFS=''
        for c in $pat/$rel; do
            [ -r "$c" ] && hit="$c"
        done
        IFS="$oldifs"
        if [ -n "$hit" ]; then printf '%s' "$hit"; return 0; fi
    done < <(binding_dirs)
    return 1
}

# The python that imports the powerline segments -- which is the one that has to
# be able to import powerline_gitstatus. For a pipx install that is the venv's
# python; for a distro package it is the system python the daemon's shebang names.
powerline_python() {
    local venv daemon first
    venv="$(pipx_venv powerline-status)"
    [ -x "$venv/bin/python" ] && { printf '%s' "$venv/bin/python"; return 0; }
    daemon="$(find_daemon)" || return 1
    first="$(head -1 "$(resolve_real "$daemon")" 2>/dev/null || true)"
    case "$first" in
        '#!'*)
            first="${first#\#!}"
            # "#!/usr/bin/env python3" -> take the argument, not /usr/bin/env
            case "$first" in */env\ *) first="${first#*env }" ;; esac
            # Unquoted on purpose: a shebang's interpreter and its argument
            # are one string here and have to be split back apart.
            # shellcheck disable=SC2086
            set -- $first
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
    local rc=0 notes=0 daemon py binding fontdir

    head2 "system"
    step "detected OS          $OS$(is_wsl && printf ' (WSL)' || true)"
    step "powerline spec       $POWERLINE_SPEC"

    head2 "powerline"
    if daemon="$(find_daemon)"; then
        ok "powerline-daemon     $daemon"
        step "resolves to          $(resolve_real "$daemon")"
    else
        warn "no powerline-daemon on PATH or in a pipx venv"; rc=1
    fi
    if [ -d "$(pipx_venv powerline-status)" ]; then
        ok "pipx venv            $(pipx_venv powerline-status)"
    else
        step "pipx venv            not present"
    fi

    head2 "powerline-gitstatus"
    # The theme references powerline_gitstatus.gitstatus, so this is not
    # optional: without it every prompt renders an exception instead of a branch.
    if py="$(powerline_python)"; then
        step "python               $py"
        if "$py" -c 'import powerline_gitstatus' 2>/dev/null; then
            ok "importable           yes"
        else
            warn "powerline_gitstatus is NOT importable by the python that renders the prompt"
            step "the theme in this repo needs it; the prompt will show an error without it"
            rc=1
        fi
    else
        warn "could not work out which python renders the prompt"; rc=1
    fi

    head2 "bindings"
    # A missing tmux binding is a note, not a fault: Fedora's powerline package
    # ships bash and zsh only (measured on fedora:41), and someone who does not
    # use tmux has nothing wrong with their install. What WOULD be broken is
    # having no shell binding at all, so that is what sets rc.
    local shell_bindings=0 found
    for binding in bash/powerline.sh zsh/powerline.zsh; do
        if found="$(find_binding "$binding")"; then
            ok "$(printf '%-20s' "${binding%%/*}")$found"
            shell_bindings=$((shell_bindings + 1))
        else
            warn "no binding found for ${binding%%/*}"
            notes=1
        fi
    done
    if [ "$shell_bindings" -eq 0 ]; then
        warn "no shell binding at all — the prompt cannot be wired up"; rc=1
    fi
    if found="$(find_binding tmux/powerline.conf)"; then
        ok "$(printf '%-20s' tmux)$found"
    else
        step "tmux                 not shipped by this powerline (fine unless you use tmux)"
    fi

    head2 "configuration"
    if [ -L "$CONFIG_DST" ] || [ -L "$CONFIG_DST/config.json" ]; then
        local target="$CONFIG_DST"
        [ -L "$CONFIG_DST/config.json" ] && target="$CONFIG_DST/config.json"
        warn "$target is a symlink -> $(readlink "$target")"
        step "something else manages this config; see 'Already using the dotfiles repo' in the README"
        notes=1
    elif [ -f "$CONFIG_DST/config.json" ]; then
        ok "config.json          $CONFIG_DST/config.json"
    else
        warn "no config at $CONFIG_DST"; rc=1
    fi
    local rel
    for rel in config.json colorschemes/default.json themes/shell/mine.json themes/shell/__main__.json; do
        if [ ! -e "$CONFIG_DST/$rel" ]; then
            warn "missing              $rel"; rc=1
        elif ! files_same "$CONFIG_SRC/$rel" "$CONFIG_DST/$rel"; then
            warn "differs from repo    $rel"; rc=1
        fi
    done

    head2 "fonts"
    case "$OS" in
        macos) fontdir="$HOME/Library/Fonts" ;;
        *)     fontdir="$HOME/.local/share/fonts" ;;
    esac
    # Counted with a glob rather than "ls | grep": ls fails on a missing
    # directory, and the patched filenames contain spaces ("Meslo LG S DZ
    # Regular for Powerline.ttf"), which a pipeline would split.
    local n=0 f
    for f in "$fontdir"/*[Pp]owerline*; do [ -e "$f" ] && n=$((n + 1)); done
    if [ "$n" -gt 0 ]; then
        ok "patched fonts        $n in $fontdir"
    else
        warn "no 'for Powerline' fonts in $fontdir"
        is_wsl && step "under WSL the fonts belong on the Windows host, not here"
        rc=1
    fi

    printf '\n'
    if [ "$rc" -ne 0 ]; then
        warn "see the warnings above"
    elif [ "$notes" -ne 0 ]; then
        ok "powerline is healthy; the config is managed from somewhere else (see above)"
    else
        ok "everything checks out"
    fi
    return $rc
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

    local reply
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
    read -r reply || reply=""
    case "$reply" in
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
    local pkgs="$1"
    cat >&2 <<NIXHELP

    NixOS installs packages declaratively; this script will not do it for you.

    System-wide — /etc/nixos/configuration.nix:

        environment.systemPackages = with pkgs; [ $pkgs ];

      then:  sudo nixos-rebuild switch

    Per-user — Home Manager, ~/.config/home-manager/home.nix:

        home.packages = with pkgs; [ $pkgs ];

      then:  home-manager switch

    Just this once, declaring nothing:

        nix-shell -p $pkgs --run '$0 --no-fonts'

NIXHELP
}

# ---------------------------------------------------------------- pipx -------
install_pipx() {
    command -v pipx >/dev/null 2>&1 && { ok "pipx already installed"; return 0; }

    local SUDO; SUDO="$(sudo_prefix)"
    info "installing pipx"
    case "$OS" in
        macos)
            command -v brew >/dev/null 2>&1 \
                || die "Homebrew is required on macOS. Install it from https://brew.sh, then re-run."
            run brew install pipx ;;
        debian|ubuntu)
            # bookworm+ has "pipx"; bullseye and older only "python3-pipx".
            run ${SUDO:+$SUDO} apt-get update || true
            run ${SUDO:+$SUDO} apt-get install -y pipx \
                || run ${SUDO:+$SUDO} apt-get install -y python3-pipx || true ;;
        fedora)
            run ${SUDO:+$SUDO} dnf install -y pipx || true ;;
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
    local venv; venv="$(pipx_venv powerline-status)"
    if [ -d "$venv" ]; then
        ok "powerline already installed with pipx ($venv)"
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
    ok "powerline installed into $venv"
}

# powerline-gitstatus is a powerline *plugin*: the segment is imported by
# powerline itself, so it has to land in the same environment. Which command
# that is depends entirely on how powerline was installed, which is why this is
# not just "pip install".
install_gitstatus_pipx() {
    local venv; venv="$(pipx_venv powerline-status)"
    if [ -x "$venv/bin/python" ] && "$venv/bin/python" -c 'import powerline_gitstatus' 2>/dev/null; then
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
    local SUDO; SUDO="$(sudo_prefix)"
    case "$OS" in
        debian|ubuntu)
            info "installing powerline with apt"
            run ${SUDO:+$SUDO} apt-get update || true
            run ${SUDO:+$SUDO} apt-get install -y powerline \
                || { warn "apt could not install powerline"; return 1; } ;;
        fedora)
            info "installing powerline with dnf"
            run ${SUDO:+$SUDO} dnf install -y powerline \
                || { warn "dnf could not install powerline"; return 1; } ;;
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
    local py; py="$(powerline_python)" || py="python3"
    if "$py" -c 'import powerline_gitstatus' 2>/dev/null; then
        ok "powerline-gitstatus already importable by $py"
        return 0
    fi
    local SUDO; SUDO="$(sudo_prefix)"

    # Measured, because it is the opposite of what you would guess: Debian 12
    # and Ubuntu 24.04 DO package it (python3-powerline-gitstatus 1.3.2-1),
    # Fedora 41 does NOT -- it ships powerline and powerline-fonts only. So apt
    # usually succeeds here and dnf usually falls through to pip below. Both are
    # attempted regardless; a distro package is the only version that survives a
    # python upgrade.
    case "$OS" in
        fedora)        run ${SUDO:+$SUDO} dnf install -y powerline-gitstatus 2>/dev/null || true ;;
        debian|ubuntu) run ${SUDO:+$SUDO} apt-get install -y python3-powerline-gitstatus 2>/dev/null || true ;;
    esac
    if [ "$DRY_RUN" -eq 0 ] && "$py" -c 'import powerline_gitstatus' 2>/dev/null; then
        ok "powerline-gitstatus installed from the distro"
        return 0
    fi

    # No pip at all is a fixable state, not a dead end: Fedora's base image
    # simply omits python3-pip, and once it is there "pip install --user"
    # succeeds -- Fedora does not refuse --user installs the way Debian does.
    # Measured on fedora:41, where this is the difference between native mode
    # working and native mode giving up.
    if ! "$py" -m pip --version >/dev/null 2>&1; then
        # Announced only where there is actually a package manager to do it
        # with: on NixOS this said "installing the distro's pip package" and
        # then installed nothing, which is a plain untruth in the output.
        case "$OS" in
            fedora)
                info "that python has no pip; installing python3-pip"
                run ${SUDO:+$SUDO} dnf install -y python3-pip || true ;;
            debian|ubuntu)
                info "that python has no pip; installing python3-pip"
                run ${SUDO:+$SUDO} apt-get install -y python3-pip || true ;;
            *)
                step "that python has no pip, and there is no package recipe for '$OS'" ;;
        esac
    fi

    info "installing powerline-gitstatus with pip --user"
    if run "$py" -m pip install --user powerline-gitstatus 2>/dev/null; then
        ok "powerline-gitstatus installed"
        return 0
    fi

    warn "pip would not install powerline-gitstatus into the system python"
    if ! "$py" -m pip --version >/dev/null 2>&1; then
        # Fedora splits pip into python3-pip and the base image omits it.
        step "That python has no pip at all ($py -m pip is missing)."
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
    step "       $py -m pip install --user --break-system-packages powerline-gitstatus"
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
    local link_target=""
    if [ -L "$CONFIG_DST" ]; then link_target="$(readlink "$CONFIG_DST")"
    elif [ -L "$CONFIG_DST/config.json" ]; then link_target="$(readlink "$CONFIG_DST/config.json")"
    fi
    if [ -n "$link_target" ]; then
        warn "$CONFIG_DST is managed by symlinks into $link_target"
        step "that is another repo's stow (see the README); replacing it here would"
        step "detach this machine from it, and a later 'stow' there would fight back"
        if ! confirm "Replace the symlinked config with a copy from this repo?"; then
            step "leaving the existing config alone — powerline install and fonts still done"
            return 0
        fi
    fi

    info "installing config into $CONFIG_DST"
    local rel src dst
    while IFS= read -r rel; do
        rel="${rel#./}"
        [ -n "$rel" ] || continue
        src="$CONFIG_SRC/$rel"
        dst="$CONFIG_DST/$rel"
        if [ -e "$dst" ] || [ -L "$dst" ]; then
            if [ ! -L "$dst" ] && files_same "$src" "$dst"; then
                step "unchanged  $rel"
                continue
            fi
            run mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
            run mv "$dst" "$BACKUP_DIR/$rel"
            step "backed up  $rel -> $BACKUP_DIR/$rel"
        fi
        run mkdir -p "$(dirname "$dst")"
        run cp "$src" "$dst"
        step "installed  $rel"
    done < <(cd "$CONFIG_SRC" && find . -type f -name '*.json')
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
    local tmp
    if [ "$DRY_RUN" -eq 1 ]; then
        step "would run: git clone --depth=1 $FONTS_REPO <tmp> && <tmp>/install.sh ${FONTS:-(all)}"
        return 0
    fi
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/powerline-fonts.XXXXXX")" || { warn "could not create a temp dir"; return 1; }
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
    if ! git clone --depth=1 --quiet "$FONTS_REPO" "$tmp/fonts"; then
        warn "could not clone $FONTS_REPO — skipping fonts"
        rm -rf "$tmp"; trap - EXIT
        return 1
    fi
    # The fonts repo's own installer creates the directory on Linux but not on
    # Darwin, so a home without ~/Library/Fonts yet got "fonts installed" and no
    # fonts. Create it here rather than patching their script.
    case "$OS" in
        macos) mkdir -p "$HOME/Library/Fonts" ;;
        *)     mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/fonts" ;;
    esac
    sh "$tmp/fonts/install.sh" "$FONTS" || warn "the font installer reported a problem"
    rm -rf "$tmp"; trap - EXIT
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
    local daemon bash_b zsh_b tmux_b
    daemon="$(find_daemon)" || daemon=""
    bash_b="$(find_binding bash/powerline.sh)" || bash_b=""
    zsh_b="$(find_binding zsh/powerline.zsh)" || zsh_b=""
    tmux_b="$(find_binding tmux/powerline.conf)" || tmux_b=""

    if [ -z "$daemon" ] || { [ -z "$bash_b" ] && [ -z "$zsh_b" ]; }; then
        head2 "Next step"
        warn "powerline's shell bindings were not found, so there is no entry to suggest yet"
        step "run './install.sh --check' once powerline is installed to get it"
        return 0
    fi

    head2 "Add this to your shell"
    cat <<'INTRO'
Nothing was written to any rc file. Paste the block for the shell you use.
INTRO

    if [ -z "$bash_b" ]; then
        printf '\n%s# bash: no bash binding found in this install%s\n' "$C_YLW" "$C_RST"
    else
        printf '\n%s~/.bashrc%s\n\n' "$C_B" "$C_RST"
        printf '    # Powerline\n'
        # shellcheck disable=SC2016  # $HOME stays literal: this is printed, not run
        [ "$MODE" = pipx ] && printf '    [ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"\n'
        printf '    if [ -r "%s" ]; then\n' "$bash_b"
        printf '        "%s" -q\n' "$daemon"
        printf '        POWERLINE_BASH_CONTINUATION=1\n'
        printf '        POWERLINE_BASH_SELECT=1\n'
        printf '        source "%s"\n' "$bash_b"
        printf '    fi\n'
    fi

    if [ -z "$zsh_b" ]; then
        printf '\n%s# zsh: no zsh binding found in this install%s\n' "$C_YLW" "$C_RST"
    else
        printf '\n%s~/.zshrc%s\n\n' "$C_B" "$C_RST"
        printf '    # Powerline\n'
        # shellcheck disable=SC2016  # $HOME stays literal: this is printed, not run
        [ "$MODE" = pipx ] && printf '    [ -d "$HOME/.local/bin" ] && export PATH="$HOME/.local/bin:$PATH"\n'
        printf '    if [ -r "%s" ]; then\n' "$zsh_b"
        printf '        "%s" -q\n' "$daemon"
        printf '        source "%s"\n' "$zsh_b"
        printf '    fi\n'
        printf '\n    %s# zsh only: a prompt theme loaded AFTER this wins. Oh My Zsh with%s\n' "$C_YLW" "$C_RST"
        printf '    %s# ZSH_THEME set (Powerlevel10k, agnoster, ...) replaces the powerline%s\n' "$C_YLW" "$C_RST"
        printf '    %s# prompt, so put this block after oh-my-zsh.sh and unset ZSH_THEME,%s\n' "$C_YLW" "$C_RST"
        printf '    %s# or pick one of the two.%s\n' "$C_YLW" "$C_RST"
    fi

    if [ -n "$tmux_b" ]; then
        printf '\n%s~/.config/tmux/tmux.conf%s   (or ~/.tmux.conf)\n\n' "$C_B" "$C_RST"
        printf '    source "%s"\n' "$tmux_b"
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
    local daemon; daemon="$(find_daemon)" || return 0
    info "restarting the powerline daemon"
    # --replace rather than a bare start: a daemon from a previous install is
    # already running with the OLD config cached, so without this the prompt
    # keeps rendering the pre-install theme and the script looks like it failed.
    run "$daemon" --replace -q || warn "could not restart the daemon — it starts on your next shell anyway"
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
    local pl_ok=1
    case "$MODE" in
        pipx)
            install_pipx       && install_powerline_pipx   && install_gitstatus_pipx   || pl_ok=0 ;;
        native)
            install_powerline_native && install_gitstatus_native || pl_ok=0 ;;
    esac
    [ "$pl_ok" -eq 1 ] || warn "powerline is not fully installed — see above; the rest still runs"

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
    elif [ "$pl_ok" -eq 1 ]; then
        ok "done. './install.sh --check' verifies the result."
    else
        warn "finished with problems — './install.sh --check' lists what is still missing"
        return 1
    fi
}

main "$@"
