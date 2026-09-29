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
APP_DIR="${MMM_HOME:-$HOME/Applications/mini-meeting-minutes}"
BIN_DIR="$HOME/.local/bin"
SHORTCUT="$HOME/Desktop/Mini Meeting Minutes.command"
LOG="$HOME/Library/Logs/mini-meeting-minutes-install.log"
PATH_MARKER="# Added by the Mini Meeting Minutes installer"

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
run() {
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
    printf '\r  %s✗%s %s\n\n' "$R" "$N" "$label"
    tail -n 15 "$LOG" | sed 's/^/    /'
    fail "$label didn't finish."
  fi
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
say "This takes about 10 minutes the first time. You can leave it running."

# 1. Check this Mac.
[[ "$(uname -m)" == "arm64" ]] || fail "Mini Meeting Minutes needs a Mac with Apple silicon (M1 or newer)."
os_major="$(sw_vers -productVersion | cut -d. -f1)"
[[ "$os_major" -ge 15 ]] ||
  fail "Mini Meeting Minutes needs macOS 15 or newer. Update in System Settings › General › Software Update, then try again."
free_gb="$(df -g "$HOME" | awk 'NR == 2 { print $4 }')"
[[ "$free_gb" -ge 3 ]] || fail "It needs about 3 GB of free disk space, and this Mac has ${free_gb} GB."

# 2. Apple's command line developer tools include Swift, which builds the app.
if ! xcode-select -p >/dev/null 2>&1; then
  step "Installing Apple's developer tools"
  say "  A window will ask to install the command line developer tools."
  say "  Click ${B}Install${N}, then ${B}Agree${N}. It takes 5 to 15 minutes; this installer continues by itself."
  xcode-select --install </dev/null >/dev/null 2>&1
  until xcode-select -p >/dev/null 2>&1; do sleep 5; done
  say "  ${G}✓${N} Developer tools installed"
fi
swift_version="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)"
[[ -n "$swift_version" ]] ||
  fail "Swift isn't working. If you use Xcode, open it once so it can finish setting up, then try again."
swift_major="${swift_version%%.*}"
swift_minor="${swift_version#*.}"
if ((swift_major < 6 || (swift_major == 6 && swift_minor < 2))); then
  fail "Your developer tools are too old (Swift $swift_version; 6.2 or newer is needed). Install the Command Line Tools update in System Settings › General › Software Update, then try again."
fi

# 3. Download, or update an earlier install.
step "Getting Mini Meeting Minutes"
if [[ -d "$APP_DIR/.git" ]]; then
  run "Updating" git -C "$APP_DIR" pull --ff-only
elif [[ -e "$APP_DIR" ]]; then
  fail "$APP_DIR already exists but isn't a Mini Meeting Minutes install. Move it away and try again."
else
  mkdir -p "$(dirname "$APP_DIR")" || fail "Couldn't create $(dirname "$APP_DIR")."
  run "Downloading (about 270 MB)" git clone --depth 1 --branch "$BRANCH" "$REPO" "$APP_DIR"
fi

# Use the same resolved path as the ./mmm launcher, or SwiftPM sees two packages and rebuilds.
APP_DIR="$(cd -P "$APP_DIR" && pwd)"

# 4. Build it and check the speech models.
run "Building (3 to 5 minutes the first time)" swift build --package-path "$APP_DIR" -c release --disable-keychain
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
