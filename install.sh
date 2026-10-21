#!/bin/bash
# Installs or updates Mini Meeting Minutes. Paste this line into Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/dudgeon/mini-meeting-minutes/main/install.sh | bash
#
# Uninstall with:  curl -fsSL https://raw.githubusercontent.com/dudgeon/mini-meeting-minutes/main/install.sh | bash -s -- --uninstall
#
# Everything goes into your home folder, so no administrator password is needed:
#   ~/Applications/mini-meeting-minutes     the app and its speech models
#   ~/Desktop/Mini Meeting Minutes          double-click to record
#   ~/.local/bin/mmm                        the `mmm` command for Terminal
set -uo pipefail

REPO="${MMM_REPO:-https://github.com/dudgeon/mini-meeting-minutes.git}"
BRANCH="${MMM_BRANCH:-main}"
DEFAULT_APP_DIR="$HOME/Applications/mini-meeting-minutes"
APP_DIR="${MMM_HOME:-$DEFAULT_APP_DIR}"
APP_DIR="${APP_DIR%/}"
BIN_DIR="$HOME/.local/bin"
SHORTCUT="$HOME/Desktop/Mini Meeting Minutes.command"
LOG="$HOME/Library/Logs/mini-meeting-minutes-install.log"
PATH_MARKER="# Added by the Mini Meeting Minutes installer"
# Every push to main is built by .github/workflows/prebuilt.yml and published as a release, so
# most Macs build nothing and need no developer tools. Without git, the source code comes as an
# archive. Another repository or branch is built on this Mac.
if [[ -z "${MMM_REPO:-}${MMM_BRANCH:-}" ]]; then
  PREBUILT_URL="${MMM_PREBUILT_URL-https://github.com/dudgeon/mini-meeting-minutes/releases/download/prebuilt}"
  ARCHIVE_URL="${MMM_ARCHIVE_URL-https://codeload.github.com/dudgeon/mini-meeting-minutes/tar.gz}"
else
  PREBUILT_URL="${MMM_PREBUILT_URL:-}"
  ARCHIVE_URL="${MMM_ARCHIVE_URL:-}"
fi

if [[ -t 1 ]]; then
  B=$'\033[1m' G=$'\033[32m' R=$'\033[31m' D=$'\033[2m' N=$'\033[0m'
else
  B="" G="" R="" D="" N=""
fi

say() { printf '%s\n' "$*"; }
step() { printf '\n%s%s%s\n' "$B" "$*" "$N"; }
fail() {
  printf '\n%sSorry, something went wrong.%s %s\n' "$R$B" "$N" "$1"
  [[ -s "$LOG" ]] && printf '%sThe details are in %s%s\n' "$D" "$LOG" "$N"
  exit 1
}

# Runs a command with its output going to the log, showing a spinner and the time taken.
# Returns the command's status; `run` below stops the installer if it fails.
attempt() {
  local label="$1"
  shift
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0 start=$SECONDS
  printf '\n=== %s\n' "$label" >>"$LOG"
  # stdin from /dev/null: when piped from curl, stdin is the rest of this script.
  "$@" </dev/null >>"$LOG" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s %s %s%ds%s ' "${frames[i % 10]}" "$label" "$D" $((SECONDS - start)) "$N"
    i=$((i + 1))
    sleep 0.2
  done
  if wait "$pid"; then
    printf '\r  %s✓%s %s %s%ds%s   \n' "$G" "$N" "$label" "$D" $((SECONDS - start)) "$N"
  else
    printf '\r  %s✗%s %s\n' "$R" "$N" "$label"
    return 1
  fi
}

run() {
  attempt "$@" && return
  printf '\n'
  tail -n 15 "$LOG" | sed 's/^/    /'
  fail "$1 didn't finish."
}

# Git comes with Apple's developer tools. Without them, /usr/bin/git only offers to install them.
has_git() {
  xcode-select -p >/dev/null 2>&1 && git --version >/dev/null 2>&1
}

# The version in the app's folder: its git commit, or the one an archive download recorded.
version() {
  if [[ -d "$APP_DIR/.git" ]]; then
    has_git && git -C "$APP_DIR" rev-parse HEAD 2>/dev/null
  else
    cat "$APP_DIR/.mmm-version" 2>/dev/null
  fi
}

# Downloads $target, the version the prebuilt app was built from (or the branch when there's none).
clone() {
  git init --quiet "$APP_DIR" &&
    git -C "$APP_DIR" fetch --quiet --depth 1 "$REPO" "$target" &&
    git -C "$APP_DIR" reset --quiet --hard FETCH_HEAD
}

# Moves an earlier install to $target. Nothing in the app's folder is yours (minutes live in
# Documents), so it's made to match the new version exactly: files an older build rewrote, such as
# Package.resolved, can't block the update. Built files and joined models are kept. A folder chosen
# with MMM_HOME may be someone's own copy, so it only ever moves forward.
update() {
  if [[ -f "$APP_DIR/.git/shallow" ]]; then
    git -C "$APP_DIR" fetch --quiet --depth 1 "$REPO" "$target" || return
  else
    git -C "$APP_DIR" fetch --quiet "$REPO" "$target" || return
  fi
  if [[ "$APP_DIR" == "$DEFAULT_APP_DIR" ]]; then
    git -C "$APP_DIR" reset --quiet --hard FETCH_HEAD
  else
    git -C "$APP_DIR" merge --quiet --ff-only FETCH_HEAD
  fi
}

# Without git, downloads $target as an archive and swaps it in, keeping built files.
download() {
  local new="$APP_DIR.new"
  rm -rf "$new" && mkdir -p "$new" &&
    curl -fsSL --retry 3 "$ARCHIVE_URL/$target" | tar -xzf - -C "$new" --strip-components 1 &&
    printf '%s\n' "$target" >"$new/.mmm-version" || return
  if [[ -d "$APP_DIR" ]]; then
    [[ -d "$APP_DIR/.build" ]] && mv "$APP_DIR/.build" "$new/.build"
    rm -rf "$APP_DIR"
  fi
  mv "$new" "$APP_DIR"
}

# Downloads the prebuilt app into $staged, before the source is touched: if that fails, an
# earlier install is left as it was.
stage_prebuilt() {
  local built
  curl -fsSL --retry 3 "$PREBUILT_URL/mmm-$prebuilt.tar.gz" | tar -xzf - -C "$staged" || return
  built="$(cat "$staged/COMMIT" 2>/dev/null)"
  if [[ "$built" != "$prebuilt" ]]; then
    echo "The download was built from ${built:-an unknown version}, not $prebuilt."
    return 1
  fi
}

# Moves the staged app to where the ./mmm launcher looks for it. The installer's own folder has
# no use for an earlier build any more, which can take a few GB.
install_prebuilt() {
  local dir="$APP_DIR/.build/prebuilt"
  if [[ "$APP_DIR" == "$DEFAULT_APP_DIR" ]]; then
    rm -rf "$APP_DIR/.build"
  fi
  mkdir -p "$APP_DIR/.build" && rm -rf "$dir" && mv "$staged" "$dir" &&
    # Newer than every source file, so the launcher runs it instead of building.
    find "$dir" -exec touch {} +
}

# Finds a Swift that can build the app: the selected developer tools, or else Xcode, through
# DEVELOPER_DIR, which needs no administrator password. `swift --version` isn't enough of a check:
# an update that only partly installed can leave `swift build` crashing as it starts.
swift_ready=0
via_xcode=0
find_swift() {
  # In subshells, so a crash is reported in the log rather than on screen.
  if xcode-select -p >/dev/null 2>&1 && (swift build --version; exit) >>"$LOG" 2>&1; then
    return
  fi
  local xcode
  for xcode in /Applications/Xcode*.app/Contents/Developer; do
    if [[ -d "$xcode" ]] && (DEVELOPER_DIR="$xcode" swift build --version; exit) >>"$LOG" 2>&1; then
      export DEVELOPER_DIR="$xcode"
      via_xcode=1
      return
    fi
  done
  return 1
}

require_swift() {
  ((swift_ready)) && return
  if ! find_swift; then
    local tools
    tools="$(xcode-select -p 2>/dev/null)"
    if [[ -d /Applications/Xcode.app ]]; then
      fail "Building it needs Swift, and neither the command line developer tools nor Xcode's start. Open Xcode once, so it can finish setting up and you can accept its license, then run this installer again."
    elif [[ "$tools" == /Library/Developer/CommandLineTools ]]; then
      fail "Building it needs Apple's developer tools, and the ones on this Mac are damaged: part of an update didn't install. Install Xcode from the App Store and run this installer again, or ask whoever looks after this Mac to reinstall the command line developer tools."
    elif [[ -n "$tools" ]]; then
      fail "Building it needs Swift, and the one in $tools doesn't start. If you use Xcode, open it once so it can finish setting up, then run this installer again."
    fi
    fail "Building it needs Apple's developer tools. Run ${B}xcode-select --install${N}, or install Xcode from the App Store, then run this installer again."
  fi
  local swift_version swift_major swift_minor
  swift_version="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)"
  swift_major="${swift_version%%.*}"
  swift_minor="${swift_version#*.}"
  if [[ -z "$swift_version" ]] || ((swift_major < 6 || (swift_major == 6 && swift_minor < 2))); then
    fail "Your developer tools are too old (Swift ${swift_version:-unknown}; 6.2 or newer is needed). Install the Command Line Tools update in System Settings › General › Software Update, then try again."
  fi
  swift_ready=1
}

build() {
  swift build --package-path "$APP_DIR" -c release --disable-keychain
}

# Builds left by older developer tools can trip up a newer compiler; starting afresh fixes that.
build_from_scratch() {
  rm -rf "$APP_DIR/.build" && build
}

uninstall() {
  step "Removing Mini Meeting Minutes"
  if [[ -f "$APP_DIR/mmm" && -f "$APP_DIR/Package.swift" ]]; then
    rm -rf "$APP_DIR"
  fi
  rm -f "$BIN_DIR/mmm" "$SHORTCUT"
  for profile in "$HOME/.zprofile" "$HOME/.bash_profile"; do
    if [[ -f "$profile" ]] && grep -q "$PATH_MARKER" "$profile"; then
      awk -v marker="$PATH_MARKER" '$0 == marker { skip = 2 } skip > 0 { skip--; next } { print }' "$profile" \
        >"$profile.mmm-tmp" && mv "$profile.mmm-tmp" "$profile"
    fi
  done
  say "  ${G}✓${N} Removed. Your minutes are still in Documents › Minutes."
  exit 0
}

[[ "${1:-}" == "--uninstall" ]] && uninstall

mkdir -p "$(dirname "$LOG")" && : >"$LOG"
say "${B}Mini Meeting Minutes installer${N}"
say "This takes a few minutes the first time. You can leave it running."

# 1. Check this Mac.
[[ "$(uname -m)" == "arm64" ]] || fail "Mini Meeting Minutes needs a Mac with Apple silicon (M1 or newer)."
os_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$os_major" -ge 15 ]] ||
  fail "Mini Meeting Minutes needs macOS 15 or newer. Update in System Settings › General › Software Update, then try again."
free_gb="$(df -g "$HOME" | awk 'NR == 2 { print $4 }')"
[[ "$free_gb" -ge 3 ]] || fail "It needs about 3 GB of free disk space, and this Mac has ${free_gb} GB."

# 2. Get the newest prebuilt app. Without one, it's built here, which needs Apple's developer
# tools: check for them before downloading anything else.
step "Getting Mini Meeting Minutes"
prebuilt=""
if [[ -n "$PREBUILT_URL" ]]; then
  prebuilt="$(curl -fsSL --retry 3 "$PREBUILT_URL/commit.txt" 2>>"$LOG" | tr -d '[:space:]')"
  [[ "$prebuilt" =~ ^[0-9a-f]{40}$ ]] || prebuilt=""
fi
if [[ -n "$prebuilt" ]]; then
  staged="$(mktemp -d "${TMPDIR:-/tmp}/mmm-prebuilt.XXXXXX")" || fail "Couldn't make a temporary folder."
  trap 'rm -rf "$staged"' EXIT
  if ! attempt "Downloading the app" stage_prebuilt; then
    say "  ${D}It will be built on this Mac instead.${N}"
    prebuilt=""
  fi
fi
[[ -n "$prebuilt" ]] || require_swift
target="${prebuilt:-$BRANCH}"

# 3. Download, or update an earlier install.
if [[ -d "$APP_DIR/.git" || -f "$APP_DIR/.mmm-version" ]]; then
  if pgrep -xq mmm; then
    say "  Mini Meeting Minutes is open. It's fine to carry on: the update is used the next time it starts."
  fi
  before="$(version | cut -c 1-7)"
  if [[ -d "$APP_DIR/.git" ]] && has_git; then
    # A folder chosen with MMM_HOME may be someone's own copy: don't overwrite their changes.
    if [[ "$APP_DIR" != "$DEFAULT_APP_DIR" && -n "$(git -C "$APP_DIR" status --porcelain --untracked-files=no)" ]]; then
      fail "$APP_DIR has changes of its own, so it wasn't updated. Commit or discard them, then try again."
    fi
    run "Downloading the update" update
  elif [[ "$APP_DIR" == "$DEFAULT_APP_DIR" && -n "$ARCHIVE_URL" ]]; then
    run "Downloading the update (about 270 MB)" download
  else
    fail "Updating $APP_DIR needs git, which comes with Apple's developer tools. Run ${B}xcode-select --install${N}, then try again."
  fi
  after="$(version | cut -c 1-7)"
  if [[ "$before" == "$after" ]]; then
    say "  ${D}Already the newest version ($after).${N}"
  else
    say "  ${D}Updated from ${before:-unknown} to $after.${N}"
  fi
elif [[ -e "$APP_DIR" ]]; then
  fail "$APP_DIR already exists but isn't a Mini Meeting Minutes install. Move it away and try again."
else
  mkdir -p "$(dirname "$APP_DIR")" || fail "Couldn't create $(dirname "$APP_DIR")."
  if has_git; then
    run "Downloading (about 270 MB)" clone
  elif [[ -n "$ARCHIVE_URL" ]]; then
    run "Downloading (about 270 MB)" download
  else
    fail "Downloading from $REPO needs git, which comes with Apple's developer tools. Run ${B}xcode-select --install${N}, then try again."
  fi
fi

# Use the same resolved path as the ./mmm launcher, or SwiftPM sees two packages and rebuilds.
APP_DIR="$(cd -P "$APP_DIR" && pwd)"

# 4. Put the prebuilt app in place, or build it here, then check the speech models. A folder
# chosen with MMM_HOME can be ahead of the prebuilt app, and is built.
if [[ -n "$prebuilt" && "$(version)" == "$prebuilt" ]]; then
  install_prebuilt || fail "Couldn't put the app in $APP_DIR/.build."
else
  require_swift
  ((via_xcode)) && say "  ${D}Building with Xcode, since the command line developer tools don't work.${N}"
  rm -rf "$APP_DIR/.build/prebuilt"
  if ! attempt "Building (3 to 5 minutes the first time)" build; then
    say "  ${D}Trying again from scratch…${N}"
    run "Building from scratch (3 to 5 minutes)" build_from_scratch
  fi
fi
run "Checking the speech models" "$APP_DIR/mmm" doctor --full

# 5. Shortcuts: a double-clickable launcher on the Desktop and the `mmm` command.
mkdir -p "$BIN_DIR" "$HOME/Desktop"
ln -sf "$APP_DIR/mmm" "$BIN_DIR/mmm"
profile="$HOME/.zprofile"
[[ "${SHELL:-}" == */bash ]] && profile="$HOME/.bash_profile"
if ! grep -qs "$PATH_MARKER" "$profile"; then
  printf '\n%s\nexport PATH="$HOME/.local/bin:$PATH"\n' "$PATH_MARKER" >>"$profile"
fi
cat >"$SHORTCUT" <<EOF
#!/bin/bash
# Double-click to record a meeting with Mini Meeting Minutes.
printf '\033]0;Mini Meeting Minutes\007\033[8;42;120t'
exec "$APP_DIR/mmm"
EOF
chmod +x "$SHORTCUT"
SetFile -a E "$SHORTCUT" 2>/dev/null || true
say "  ${G}✓${N} Added ${B}Mini Meeting Minutes${N} to your Desktop"

step "${G}All set!${N}"
say "  To record a meeting, double-click ${B}Mini Meeting Minutes${N} on your Desktop."
say "  Your minutes will be saved in Documents › Minutes."
say "  ${D}To update later, run this installer again.${N}"
