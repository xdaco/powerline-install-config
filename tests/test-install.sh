#!/bin/sh
#title          :test-install.sh
#description    :Exercise install.sh end to end inside a throwaway container
#author         :Musarraf Hossain
#email          :xdaco.xinu@gmail.com
#date           :20261003
#version        :1.0
#usage          :sh tests/test-install.sh pipx|native
#notes          :Destructive — installs into $HOME. Run in a container, not on a real machine.
#shell          :POSIX sh — no bashisms
#==============================================================================
# Eleven checks against a real install, from "--check on a bare machine" through
# to rendering a prompt and sourcing the entry install.sh prints.
#
# Meant to run inside a disposable container:
#
#   podman run --rm -v "$PWD:/repo:ro" docker.io/library/ubuntu:24.04 sh -c '
#       apt-get update -qq && apt-get install -y -qq git ca-certificates
#       cp -R /repo /work && cd /work && sh tests/test-install.sh pipx'
#
# It installs packages and writes to $HOME, so do not run it on a machine you
# care about.

MODE="${1:-pipx}"
pass=0
fail=0

ok_()   { echo "PASS  $1"; pass=$((pass + 1)); }
bad_()  { echo "FAIL  $1"; fail=$((fail + 1)); }

# Run a command, compare its exit status with what was expected.
expect() {
    _name="$1"; _want="$2"; shift 2
    _out="$("$@" 2>&1)"; _rc=$?
    if [ "$_rc" -eq "$_want" ]; then
        ok_ "$_name (exit $_rc)"
    else
        bad_ "$_name (exit $_rc, wanted $_want)"
        echo "$_out" | tail -n 25 | sed 's/^/        | /'
    fi
}

# cksum rather than cmp: diffutils is absent from a minimal Fedora image, and
# "cmp: command not found" is a non-zero exit, which would read as "differs".
same_file() {
    [ -f "$1" ] && [ -f "$2" ] || return 1
    [ "$(cksum < "$1")" = "$(cksum < "$2")" ]
}

echo "### 1. --check on a bare machine (must fail: nothing installed yet)"
expect "check-before" 1 sh ./install.sh --check

echo
echo "### 2. no TTY and no --mode (must refuse rather than guess)"
expect "refuse-without-mode" 1 sh ./install.sh --no-fonts --no-config

echo
echo "### 3. install, mode=$MODE"
if sh ./install.sh --mode="$MODE" --fonts=Meslo -y; then
    ok_ "install"
else
    bad_ "install (exit $?)"
fi

echo
echo "### 4. --check after installing"
expect "check-after" 0 sh ./install.sh --check

echo
echo "### 5. the config really landed in ~/.config/powerline"
for f in config.json colorschemes/default.json themes/shell/mine.json themes/shell/__main__.json; do
    if same_file "config/$f" "$HOME/.config/powerline/$f"; then
        ok_ "config $f matches the repo"
    else
        bad_ "config $f missing or differs"
    fi
done

echo
echo "### 6. the prompt renders, with the gitstatus segment the theme needs"
git init -q /tmp/demo 2>/dev/null
( cd /tmp/demo \
  && git config user.email t@example.com && git config user.name tester \
  && echo hi > a.txt && git add a.txt \
  && git -c commit.gpgsign=false commit -qm init ) >/dev/null 2>&1
PL="$(command -v powerline || echo "$HOME/.local/bin/powerline")"
out="$(cd /tmp/demo && "$PL" shell left --last-exit-code=0 --jobnum=0 2>&1)"
if echo "$out" | grep -qiE 'traceback|exception'; then
    bad_ "prompt renders"
    echo "$out" | tail -n 15 | sed 's/^/        | /'
elif echo "$out" | grep -qE 'master|main'; then
    ok_ "prompt renders with a git branch"
else
    bad_ "prompt rendered but no branch segment (is powerline-gitstatus installed?)"
fi

echo
echo "### 7. the entry install.sh prints is sourceable"
# Ask pipx where its home is rather than guessing: Debian 12's pipx 1.1.0 uses
# ~/.local/pipx, newer ones ~/.local/share/pipx. And the distro layouts differ:
# Debian keeps bindings under .../powerline/bindings/, Fedora under
# /usr/share/powerline/ with no bindings component.
B=""
# Ubuntu 22.04 ships pipx 1.0.0, which has no "environment" subcommand at all,
# so this has to fall back the same way install.sh's pipx_venv() does -- older
# pipx keeps venvs in ~/.local/pipx, newer in ~/.local/share/pipx.
PH="$(pipx environment --value PIPX_HOME 2>/dev/null || true)"
if [ -z "$PH" ]; then
    for cand in "${PIPX_HOME:-}" "$HOME/.local/share/pipx" "$HOME/.local/pipx"; do
        [ -n "$cand" ] && [ -d "$cand/venvs" ] && { PH="$cand"; break; }
    done
fi
# A glob, not ls: the quoted "$PH" keeps a pipx home containing spaces whole
# (macOS defaults to ~/Library/Application Support/pipx) while python3* still
# expands. Last match wins, which is the highest python version.
if [ -n "$PH" ]; then
    for d in "$PH"/venvs/powerline-status/lib/python3*/site-packages/powerline/bindings; do
        [ -d "$d" ] && B="$d"
    done
fi
if [ -z "$B" ]; then
    for cand in /usr/share/powerline/bindings /usr/share/powerline; do
        [ -r "$cand/bash/powerline.sh" ] && { B="$cand"; break; }
    done
fi
if [ -n "$B" ] && [ -r "$B/bash/powerline.sh" ]; then
    ok_ "bash binding found and readable ($B)"
else
    bad_ "no bash binding found (looked in '${B:-nowhere}')"
fi

echo
echo "### 8. re-running changes nothing"
out="$(sh ./install.sh --mode="$MODE" --no-fonts -y 2>&1)"
if echo "$out" | grep -q 'unchanged  config.json' && ! echo "$out" | grep -q 'backed up'; then
    ok_ "idempotent (config unchanged, no backup made)"
else
    bad_ "not idempotent"
    echo "$out" | grep -E 'unchanged|backed up|installed' | sed 's/^/        | /'
fi

echo
echo "======== $pass passed, $fail failed ========"
[ "$fail" -eq 0 ]
