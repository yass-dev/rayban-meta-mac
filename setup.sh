#!/bin/bash
# setup.sh: from a fresh clone to a Mac that owns your Ray-Ban Meta glasses.
#
#   ./setup.sh             do everything that is not done yet (safe to run again)
#   ./setup.sh --relogin   log in to Meta again (the emulator step)
#   ./setup.sh --repair    take ownership of the glasses again (after a reset, for example)
#   ./setup.sh --cleanup   only remove the Android emulator and tools the login needed
#   ./setup.sh --no-app    skip building Glasses.app
#
# Prefer a guided page in the browser? Double-click Install.command in the Finder instead: it runs this
# same script and turns its questions into buttons.
#
# What it does, in order. Every step checks first whether it is already done.
#   1. checks this Mac (macOS 13+, Xcode command line tools)
#   2. builds the Mac client (Swift, no dependencies)
#   3. takes the Meta app tokens out of Visor's public release APK
#   4. Meta login: downloads Java and the Android tools (no admin rights, no Homebrew), builds Visor with a
#      two-line patch, runs it in an Android emulator, YOU log in there, and the login token comes back
#   5. pairing: makes this Mac the owner of the glasses
#   6. builds and opens Glasses.app, the menu bar app with the web interface
#   7. offers to remove the emulator and the Android tools (several GB) once they are no longer needed
#
# Nothing is sent anywhere but Meta (the login, as the Meta AI app does), GitHub, Google and Adoptium
# (downloads). Your Meta password is typed by you, in the emulator, and never seen by this script.

set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$HOME/Library/Application Support/visor-mac"
WORK="$ROOT/.work"
LOG_DIR="$HOME/Library/Logs/rayban-meta-mac"
mkdir -p "$LOG_DIR" "$WORK"
LOG="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
CLI="$ROOT/.build/release/visor-mac"

VISOR_REPO="${VISOR_REPO:-https://github.com/macedonga/visor.git}"
VISOR_COMMIT="68e45e70b7ca5ca740f937f81ad8582a4db597d8"
VISOR_APK_VERSION="${VISOR_APK_VERSION:-1.4.8}"
VISOR_APK_URL="https://github.com/macedonga/visor/releases/download/v${VISOR_APK_VERSION}/visor-${VISOR_APK_VERSION}.apk"
VISOR_PKG="com.macedonga.visor"
PATCH="$ROOT/patches/visor-export-frla.patch"
AVD_NAME="visor_login"

# Java and the Android tools, downloaded from their publishers into a folder without spaces (Android's
# tools dislike them). ~/Library/Android/sdk is where Android Studio keeps its SDK: an existing one is reused.
TOOLS="$HOME/Library/Android"
OWN_SDK="$TOOLS/sdk"
OWN_SDK_MARKER="$OWN_SDK/.installed-by-rayban-meta-mac"
OWN_JDK="$TOOLS/rayban-meta-mac-jdk21"
LEGACY_BREW_MARKER="$STATE/setup-installed-android-sdk"
JDK_VERSION="21.0.13+9"
CMDLINE_TOOLS_BUILD="15859902"  # cmdline-tools 22.0: the version this setup was tested with end to end

DO_RELOGIN=0; DO_REPAIR=0; ONLY_CLEANUP=0; NO_APP=0
for arg in "$@"; do
  case "$arg" in
    --relogin) DO_RELOGIN=1 ;;
    --repair) DO_REPAIR=1 ;;
    --cleanup) ONLY_CLEANUP=1 ;;
    --no-app) NO_APP=1 ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)"; exit 2 ;;
  esac
done

# Machine mode, for the setup page (SETUP_MACHINE=1): every message is one "@@kind<TAB>field..." line on
# stdout, and answers come back as lines on stdin. The terminal mode below is the same script, for people.
MACHINE=0
[ "${SETUP_MACHINE:-}" = "1" ] && MACHINE=1

# ---------------------------------------------------------------- output

if [ -t 1 ] && [ $MACHINE -eq 0 ]; then
  B=$'\033[1m'; D=$'\033[2m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; C=$'\033[36m'; N=$'\033[0m'
  TTY=1
else
  B=""; D=""; R=""; G=""; Y=""; C=""; N=""
  TTY=0
fi
STEP=0; TOTAL=7
CHILD=""

emit() {  # emit KIND FIELD...: one machine-mode line; tabs and newlines inside fields become spaces
  local kind="$1" f
  shift
  printf '@@%s' "$kind"
  for f in "$@"; do
    f=${f//$'\t'/ }; f=${f//$'\n'/ }; f=${f//$'\r'/ }
    printf '\t%s' "$f"
  done
  printf '\n'
}

log()  { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >> "$LOG"; }
info() { log "  $*"; if [ $MACHINE -eq 1 ]; then emit info "$*"; else printf '  %s\n' "$*"; fi; }
ok()   { log "  OK   $*"; if [ $MACHINE -eq 1 ]; then emit ok "$*"; else printf '  %s✓%s %s\n' "$G" "$N" "$*"; fi; }
warn() { log "  WARN $*"; if [ $MACHINE -eq 1 ]; then emit warn "$*"; else printf '  %s!%s %s\n' "$Y" "$N" "$*"; fi; }
skip() { log "  SKIP $*"; if [ $MACHINE -eq 1 ]; then emit skip "$*"; else printf '  %s✓ %s%s\n' "$D" "$*" "$N"; fi; }
die()  {
  log "FAIL $*"
  if [ $MACHINE -eq 1 ]; then
    emit fail "$*"
  else
    printf '\n  %s✗ %s%s\n' "$R" "$*" "$N"
    printf '  Full log: %s\n  Fix the cause and run ./setup.sh again: finished steps are skipped.\n\n' "$LOG"
  fi
  exit 1
}
declined() {  # the person said no: not an error, the setup just stops here until run again
  log "STOP $*"
  if [ $MACHINE -eq 1 ]; then emit stopped "$*"; else printf '\n  %s%s%s\n\n' "$Y" "$*" "$N"; fi
  exit 1
}
step() {  # step KEY "title"
  local key="$1"
  shift
  STEP=$((STEP + 1))
  log "== [$STEP/$TOTAL] $*"
  if [ $MACHINE -eq 1 ]; then emit step "$STEP" "$TOTAL" "$key" "$*"; else printf '\n%s[%d/%d] %s%s\n' "$B" "$STEP" "$TOTAL" "$*" "$N"; fi
}
action() { [ $MACHINE -eq 1 ] && emit action "$@"; return 0; }  # what the person has to do now, for the page
elapsed() { local s=$1; if [ "$s" -ge 60 ]; then printf '%dm%02ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi; }
last_line() { tr '\r' '\n' < "$1" 2> /dev/null | grep -v '^[[:space:]]*$' | tail -1 | cut -c1-160; }

# progress WHAT START: a live line while something runs: a timer in the terminal, a tick for the page.
LAST_TICK=0
progress() {
  if [ $MACHINE -eq 1 ]; then
    if [ $((SECONDS - LAST_TICK)) -ge 2 ]; then LAST_TICK=$SECONDS; emit tick "$((SECONDS - $2))" "$1" "${3:-}"; fi
  elif [ $TTY -eq 1 ]; then
    printf '\r  %s…%s %s %s%s%s ' "$C" "$N" "$1" "$D" "$(elapsed $((SECONDS - $2)))" "$N"
  fi
}
progress_end() { [ $TTY -eq 1 ] && printf '\r\033[K'; return 0; }

on_interrupt() {
  [ -n "$CHILD" ] && kill "$CHILD" 2> /dev/null
  log "INTERRUPTED"
  if [ $MACHINE -eq 1 ]; then
    emit fail "Stopped."
  else
    printf '\n\n  %sInterrupted.%s Run ./setup.sh again to pick up where it stopped.\n  Log: %s\n\n' "$Y" "$N" "$LOG"
  fi
  exit 130
}
trap on_interrupt INT TERM

# run "what" command...: the command's output goes to the log; the screen shows a timer, then ✓ or ✗
# with the last lines of output. Commands never read the terminal (stdin is /dev/null).
run() {
  local what="$1"; shift
  local out="$WORK/.last-output" start=$SECONDS rc
  : > "$out"
  log "  \$ $*"
  [ $MACHINE -eq 1 ] && emit run "$what"
  LAST_TICK=0
  "$@" < /dev/null > "$out" 2>&1 &
  CHILD=$!
  while kill -0 "$CHILD" 2> /dev/null; do
    progress "$what" "$start" "$(last_line "$out")"
    sleep 1
  done
  progress_end
  wait "$CHILD"; rc=$?
  CHILD=""
  cat "$out" >> "$LOG"
  if [ $rc -eq 0 ]; then ok "$what ($(elapsed $((SECONDS - start))))"; return 0; fi
  log "  exit $rc"
  if [ $MACHINE -eq 1 ]; then
    emit runfail "$what" "$rc"
    tail -n 25 "$out" | while IFS= read -r l; do emit out "$l"; done
  else
    printf '  %s✗%s %s (exit %d). Last lines:\n' "$R" "$N" "$what" "$rc"
    tail -n 25 "$out" | sed 's/^/      /'
  fi
  return $rc
}

# run_live "what" command...: the same, with the command's own progress shown as it comes.
run_live() {
  local what="$1"; shift
  local start=$SECONDS rc
  log "  \$ $*"
  if [ $MACHINE -eq 1 ]; then
    emit run "$what"
    "$@" < /dev/null 2>&1 | tee -a "$LOG" | while IFS= read -r l; do emit out "$l"; done
    rc=${PIPESTATUS[0]}
  else
    printf '  %s…%s %s\n' "$C" "$N" "$what"
    "$@" < /dev/null 2>&1 | tee -a "$LOG" | sed "s/^/      ${D}/;s/\$/${N}/"
    rc=${PIPESTATUS[0]}
  fi
  if [ "$rc" -eq 0 ]; then ok "$what ($(elapsed $((SECONDS - start))))"; return 0; fi
  log "  exit $rc"
  if [ $MACHINE -eq 1 ]; then emit runfail "$what" "$rc"; else printf '  %s✗%s %s (exit %d)\n' "$R" "$N" "$what" "$rc"; fi
  return "$rc"
}

ask() {  # ask KEY "question": 0 for yes. Defaults to no, and to no when nobody can answer.
  local key="$1" q="$2" a=""
  if [ $MACHINE -eq 1 ]; then
    emit ask "$key" "$q"
    IFS= read -r a || a=""
  else
    printf '  %s?%s %s [y/N] ' "$Y" "$N" "$q"
    { read -r a < /dev/tty; } 2> /dev/null || a=""
  fi
  log "  ? $q -> ${a:-no}"
  case "$a" in y | Y | yes | YES | Yes) return 0 ;; *) return 1 ;; esac
}

pause() {  # pause KEY "what to do first"
  if [ $MACHINE -eq 1 ]; then
    emit pause "$1" "$2"
    IFS= read -r _ || true
  else
    printf '  %s→%s %s %s(Enter)%s ' "$C" "$N" "$2" "$D" "$N"
    { read -r _ < /dev/tty; } 2> /dev/null || true
  fi
  log "  > $2"
}

json_get() { plutil -extract "$2" raw -o - "$1" 2> /dev/null; }

write_private() {  # write_private FILE CONTENT
  mkdir -p "$(dirname "$1")"
  chmod 700 "$STATE" 2> /dev/null || true
  (umask 077 && printf '%s' "$2" > "$1")
  chmod 600 "$1"
}

# download URL FILE "label" ALGO SUM: fetch with a progress line, then check the published checksum.
download() {
  local url="$1" file="$2" label="$3" algo="$4" sum="$5" actual
  if [ -s "$file" ] && [ "$(shasum -a "$algo" "$file" | awk '{print $1}')" = "$sum" ]; then
    skip "$label already downloaded"
    return 0
  fi
  rm -f "$file"
  run "Downloading $label" curl -fL --retry 3 -o "$file.part" "$url" || die "Could not download $url"
  actual=$(shasum -a "$algo" "$file.part" | awk '{print $1}')
  if [ "$actual" != "$sum" ]; then rm -f "$file.part"; die "The download of $label does not match its published checksum: deleted. Run again."; fi
  mv "$file.part" "$file"
  ok "$label checksum verified"
}

# ---------------------------------------------------------------- 1. this Mac

check_mac() {
  step mac "Checking this Mac"
  [ $MACHINE -eq 1 ] && emit log "$LOG"
  local v major
  v=$(sw_vers -productVersion)
  major=${v%%.*}
  [ "$major" -ge 13 ] || die "macOS 13 or later is needed (this Mac runs $v)."
  ok "macOS $v"
  case "$(uname -m)" in
    arm64) ABI="arm64-v8a"; JDK_ARCH="aarch64"; TOOLS_ARCH="arm64" ;;
    x86_64) ABI="x86_64"; JDK_ARCH="x64"; TOOLS_ARCH="x86_64" ;;
    *) die "Unsupported processor: $(uname -m)" ;;
  esac
  ok "Processor $(uname -m)"
  if ! xcode-select -p > /dev/null 2>&1; then
    warn "Apple's command line tools are missing: a macOS window now offers to install them."
    xcode-select --install > /dev/null 2>&1 || true
    die "Install the command line tools from that window, then start the setup again."
  fi
  ok "$(swift --version 2> /dev/null | head -1 | sed 's/^.*\(Swift version [0-9.]*\).*$/\1/')"
  BREW="$(command -v brew || true)"
  [ -z "$BREW" ] && [ -x /opt/homebrew/bin/brew ] && BREW=/opt/homebrew/bin/brew
  [ -z "$BREW" ] && [ -x /usr/local/bin/brew ] && BREW=/usr/local/bin/brew
  [ $MACHINE -eq 0 ] && info "Log of this run: $LOG"
  return 0
}

# ---------------------------------------------------------------- 2. the Mac client

build_client() {
  step build "Building the Mac client"
  run "swift build (about a minute the first time)" swift build -c release --package-path "$ROOT" ||
    die "The build failed. Are Apple's command line tools at version 15 or later?"
  [ -x "$CLI" ] || die "The build finished but $CLI is missing."
}

# ---------------------------------------------------------------- 3. Meta app tokens

tokens_ok() {  # tokens_ok [need_frl]
  local f="$STATE/tokens.json"
  [ -s "$f" ] || return 1
  [ -n "$(json_get "$f" hw)" ] && [ -n "$(json_get "$f" ar)" ] || return 1
  [ "${1:-}" != "need_frl" ] || [ -n "$(json_get "$f" frl)" ]
}

fetch_tokens() {
  local apk="$WORK/visor-$VISOR_APK_VERSION.apk" dir="$WORK/apk" all hw ar frl expected actual
  if [ ! -s "$apk" ]; then
    run "Downloading Visor $VISOR_APK_VERSION from GitHub (about 70 MB)" curl -fL --retry 3 -o "$apk.part" "$VISOR_APK_URL" ||
      die "Could not download $VISOR_APK_URL"
    mv "$apk.part" "$apk"
  fi
  if curl -fsL --retry 3 -o "$apk.sha256" "$VISOR_APK_URL.sha256" < /dev/null; then
    expected=$(awk '{print $1}' "$apk.sha256")
    actual=$(shasum -a 256 "$apk" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then rm -f "$apk"; die "The APK's checksum does not match the one published with it: deleted, run again."; fi
    ok "APK checksum matches the published one"
  else
    warn "No checksum published with the APK: not verified"
  fi
  rm -rf "$dir" && mkdir -p "$dir"
  unzip -q -o "$apk" 'classes*.dex' -d "$dir" >> "$LOG" 2>&1 || die "Could not open the APK."
  # The tokens are plain strings in the app's code: "HW|<app id>|<secret>", "AR|...", "FRL|...". Not anchored:
  # in a dex file each string follows its length byte, which `strings` often keeps as a leading character.
  all=$(for f in "$dir"/classes*.dex; do strings -a -n 10 "$f"; done | grep -aoE '(HW|AR|FRL)\|[0-9]+\|[A-Za-z0-9_-]+' | sort -u)
  rm -rf "$dir"
  hw=$(printf '%s\n' "$all" | grep '^HW|' | head -1)
  ar=$(printf '%s\n' "$all" | grep '^AR|' | head -1)
  frl=$(printf '%s\n' "$all" | grep '^FRL|' | head -1)
  [ -n "$hw" ] && [ -n "$ar" ] && [ -n "$frl" ] ||
    die "The tokens were not found in Visor $VISOR_APK_VERSION. Has Visor changed? See README.md, Troubleshooting."
  write_private "$STATE/tokens.json" "{
  \"ar\" : \"$ar\",
  \"frl\" : \"$frl\",
  \"hw\" : \"$hw\"
}
"
  ok "Tokens saved in $STATE/tokens.json (readable by you only)"
}

step_tokens() {
  step tokens "Meta app tokens"
  if tokens_ok; then skip "Already there"; return; fi
  info "The Meta AI app identifies itself to Meta with app tokens. Visor's release APK carries them:"
  info "this step downloads it from Visor's GitHub releases and reads them out. They never go in this repository."
  fetch_tokens
}

# ---------------------------------------------------------------- 4. Meta login (Android emulator)

login_ok() { [ -s "$STATE/meta_login.txt" ] && "$CLI" check-login < /dev/null >> "$LOG" 2>&1; }

java_ok() { [ -x "$1/bin/java" ] && "$1/bin/java" -version 2>&1 | grep -qE 'version "(1[7-9]|2[0-9])'; }

find_java() {
  local h v
  if [ -n "${JAVA_HOME:-}" ] && java_ok "$JAVA_HOME"; then return 0; fi
  java_ok "$OWN_JDK/Contents/Home" && { JAVA_HOME="$OWN_JDK/Contents/Home"; return 0; }
  h=$(/usr/libexec/java_home -v 17+ 2> /dev/null) && java_ok "$h" && { JAVA_HOME="$h"; return 0; }
  if [ -n "$BREW" ]; then
    for v in 21 17; do
      h="$("$BREW" --prefix 2> /dev/null)/opt/openjdk@$v/libexec/openjdk.jdk/Contents/Home"
      java_ok "$h" && { JAVA_HOME="$h"; return 0; }
    done
  fi
  return 1
}

install_java() {
  local sum file tmp
  case "$JDK_ARCH" in
    aarch64) sum="bf036b35b071bfb2f54f2c0af8ee8d88afa95ee6eb3dce02c0f94cfc2524d04a" ;;
    x64) sum="9aa1d1c17ae5467a022679e7e0af5c00797d94ac462ed1a46f4db07a8a34a6dd" ;;
  esac
  file="$WORK/jdk-$JDK_VERSION-$JDK_ARCH.tar.gz"
  download "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-${JDK_VERSION/+/%2B}/OpenJDK21U-jdk_${JDK_ARCH}_mac_hotspot_${JDK_VERSION/+/_}.tar.gz" \
    "$file" "Java $JDK_VERSION (Eclipse Temurin, about 200 MB)" 256 "$sum"
  tmp="$OWN_JDK.tmp"
  rm -rf "$tmp" && mkdir -p "$tmp"
  tar -xzf "$file" -C "$tmp" >> "$LOG" 2>&1 || die "Could not unpack Java."
  rm -rf "$OWN_JDK" && mv "$tmp"/jdk-* "$OWN_JDK" && rm -rf "$tmp" "$file"
  java_ok "$OWN_JDK/Contents/Home" || die "Java was unpacked but does not run."
  JAVA_HOME="$OWN_JDK/Contents/Home"
  ok "Java installed in $OWN_JDK"
}

find_sdk() {
  local d
  for d in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$OWN_SDK"; do
    [ -n "$d" ] && [ -x "$d/cmdline-tools/latest/bin/sdkmanager" ] && { ANDROID_HOME="$d"; return 0; }
  done
  if [ -n "$BREW" ]; then
    d="$("$BREW" --prefix 2> /dev/null)/share/android-commandlinetools"
    [ -x "$d/cmdline-tools/latest/bin/sdkmanager" ] && { ANDROID_HOME="$d"; return 0; }
  fi
  return 1
}

install_cmdline_tools() {
  local sum file tmp
  case "$TOOLS_ARCH" in
    arm64) sum="c4e0dbc53f1a4ce04fc2b11d4e2c4675001a95af" ;;
    x86_64) sum="1a79e61677b99cb0ce622792713cbea7ff2dc5de" ;;
  esac
  file="$WORK/commandlinetools-$CMDLINE_TOOLS_BUILD.zip"
  download "https://dl.google.com/android/repository/commandlinetools-mac_${TOOLS_ARCH}-${CMDLINE_TOOLS_BUILD}_latest.zip" \
    "$file" "the Android command line tools (Google, about 150 MB)" 1 "$sum"
  if [ ! -d "$OWN_SDK" ]; then mkdir -p "$OWN_SDK" && touch "$OWN_SDK_MARKER"; fi
  tmp="$WORK/cmdline-tools.tmp"
  rm -rf "$tmp" && mkdir -p "$tmp"
  unzip -q -o "$file" -d "$tmp" >> "$LOG" 2>&1 || die "Could not unpack the Android command line tools."
  mkdir -p "$OWN_SDK/cmdline-tools"
  rm -rf "$OWN_SDK/cmdline-tools/latest" && mv "$tmp/cmdline-tools" "$OWN_SDK/cmdline-tools/latest" && rm -rf "$tmp" "$file"
  ANDROID_HOME="$OWN_SDK"
  ok "Android command line tools installed in $OWN_SDK"
}

setup_android() {
  find_java || install_java
  export JAVA_HOME
  ok "Java: $JAVA_HOME"

  find_sdk || install_cmdline_tools
  export ANDROID_HOME ANDROID_SDK_ROOT="$ANDROID_HOME"
  ok "Android SDK: $ANDROID_HOME"
  SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
  AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"
  ADB="$ANDROID_HOME/platform-tools/adb"
  EMULATOR="$ANDROID_HOME/emulator/emulator"
  SYSIMG="system-images;android-35;google_apis;$ABI"

  local need=()
  [ -x "$ADB" ] || need+=("platform-tools")
  [ -x "$EMULATOR" ] || need+=("emulator")
  [ -d "$ANDROID_HOME/platforms/android-37.0" ] || need+=("platforms;android-37.0")
  [ -d "$ANDROID_HOME/build-tools/37.0.0" ] || need+=("build-tools;37.0.0")
  [ -d "$ANDROID_HOME/system-images/android-35/google_apis/$ABI" ] || need+=("$SYSIMG")
  if [ ${#need[@]} -gt 0 ]; then
    run "Accepting the Android SDK licenses" bash -c 'yes | "$1" --licenses' _ "$SDKMANAGER" || die "sdkmanager --licenses failed."
    run "Downloading Android components: ${need[*]} (a few GB, takes a while)" "$SDKMANAGER" --install "${need[@]}" ||
      die "sdkmanager could not install ${need[*]}."
  else
    skip "Android SDK components already installed"
  fi
}

build_visor() {
  local src="$WORK/visor" apk="$WORK/visor/app/build/outputs/apk/debug/app-debug.apk"
  if [ ! -d "$src/.git" ]; then
    run "Downloading the Visor source from GitHub" git clone --quiet "$VISOR_REPO" "$src" || die "git clone $VISOR_REPO failed."
  fi
  if [ "$(git -C "$src" rev-parse HEAD 2> /dev/null)" != "$VISOR_COMMIT" ]; then
    git -C "$src" cat-file -e "$VISOR_COMMIT^{commit}" 2> /dev/null ||
      run "Fetching Visor commit ${VISOR_COMMIT:0:10}" git -C "$src" fetch --quiet origin || die "git fetch failed."
    run "Checking out Visor ${VISOR_COMMIT:0:10} (the version this was tested with)" git -C "$src" checkout --quiet --force "$VISOR_COMMIT" ||
      die "Could not check out $VISOR_COMMIT."
    rm -f "$apk"
  fi
  if git -C "$src" apply --reverse --check "$PATCH" 2> /dev/null; then
    skip "Patch already applied (Visor also writes the login token to files/frla.txt)"
  else
    git -C "$src" apply "$PATCH" >> "$LOG" 2>&1 || die "The patch does not apply to Visor ${VISOR_COMMIT:0:10}."
    ok "Patch applied: Visor also writes the login token to files/frla.txt, readable over adb"
    rm -f "$apk"
  fi
  # The Visor build reads the tokens and the SDK path from local.properties (git-ignored, yours only).
  write_private "$src/local.properties" "sdk.dir=$ANDROID_HOME
VISOR_META_HW_TOKEN=$(json_get "$STATE/tokens.json" hw)
VISOR_META_AR_TOKEN=$(json_get "$STATE/tokens.json" ar)
VISOR_META_FRL_TOKEN=$(json_get "$STATE/tokens.json" frl)
"
  if [ -s "$apk" ]; then
    skip "Visor login app already built"
  else
    run "Building the Visor login app with Gradle (5 to 15 minutes the first time)" \
      "$src/gradlew" -p "$src" :app:assembleDebug --console=plain || die "The Visor build failed (see the log)."
  fi
  VISOR_APK="$apk"
}

adb_() { "$ADB" "$@" < /dev/null; }
emulator_serial() { adb_ devices 2> /dev/null | awk '/^emulator-[0-9]+[[:space:]]+device/ {print $1; exit}'; }

boot_emulator() {
  if ! "$EMULATOR" -list-avds < /dev/null 2> /dev/null | grep -qx "$AVD_NAME"; then
    run "Creating the Android emulator \"$AVD_NAME\"" bash -c 'echo no | "$1" create avd -n "$2" -k "$3" -d pixel_7 --force' \
      _ "$AVDMANAGER" "$AVD_NAME" "$SYSIMG" || die "avdmanager could not create the emulator."
  fi
  # The Mac's keyboard types into the emulator only with a hardware keyboard declared (avdmanager says no).
  local cfg="$HOME/.android/avd/$AVD_NAME.avd/config.ini"
  if [ -f "$cfg" ] && ! grep -qx 'hw.keyboard=yes' "$cfg"; then
    sed -i '' '/^hw\.keyboard=/d;/^hw\.ramSize=/d' "$cfg"
    printf 'hw.keyboard=yes\nhw.ramSize=3072\n' >> "$cfg"
    ok "Emulator set up to take the Mac's keyboard"
  fi
  adb_ start-server >> "$LOG" 2>&1
  SERIAL=$(emulator_serial)
  if [ -z "$SERIAL" ]; then
    info "Starting the emulator: its window opens in a moment."
    nohup "$EMULATOR" -avd "$AVD_NAME" -no-snapshot-save -no-boot-anim < /dev/null >> "$LOG" 2>&1 &
    EMU_PID=$!
  fi
  [ $MACHINE -eq 1 ] && emit run "Starting Android in the emulator"
  local start=$SECONDS booted=""
  LAST_TICK=0
  while [ $((SECONDS - start)) -lt 420 ]; do
    SERIAL=$(emulator_serial)
    if [ -n "$SERIAL" ]; then
      booted=$(adb_ -s "$SERIAL" shell getprop sys.boot_completed 2> /dev/null | tr -d '\r')
      [ "$booted" = "1" ] && break
    fi
    if [ -n "${EMU_PID:-}" ] && ! kill -0 "$EMU_PID" 2> /dev/null; then die "The emulator stopped while booting (see the log)."; fi
    progress "Android is booting" "$start"
    sleep 2
  done
  progress_end
  [ "$booted" = "1" ] || die "The emulator did not finish booting in 7 minutes."
  ok "Emulator ready ($SERIAL, $(elapsed $((SECONDS - start))))"
}

read_emulator_frla() { adb_ -s "$SERIAL" exec-out run-as "$VISOR_PKG" cat files/frla.txt 2> /dev/null | tr -d '\r\n'; }

launch_visor() {
  local act
  act=$(adb_ -s "$SERIAL" shell cmd package resolve-activity --brief "$VISOR_PKG" 2> /dev/null | tail -1 | tr -d '\r')
  adb_ -s "$SERIAL" shell am start -n "$act" >> "$LOG" 2>&1 || die "Could not open Visor in the emulator."
}

stop_emulator() { [ -n "${SERIAL:-}" ] && adb_ -s "$SERIAL" emu kill >> "$LOG" 2>&1; sleep 2; }

step_login() {
  step login "Meta login"
  if [ $DO_RELOGIN -eq 0 ] && login_ok; then skip "Already logged in: Meta accepts the stored login"; return; fi
  [ -s "$STATE/meta_login.txt" ] && warn "The stored login is refused by Meta (or --relogin): logging in again."
  info "Meta only gives the login token to its own Android login screen. So this step builds Visor (an"
  info "open-source Android app for these glasses) with a two-line patch, runs it in an Android emulator,"
  info "and lets YOU log in there. Needs about 10 GB of disk and 15 to 30 minutes the first time."
  info "It downloads Java (Eclipse Temurin) and Google's Android tools, and accepts the Android SDK licenses."
  local free_gb
  free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
  [ "${free_gb:-0}" -ge 12 ] || warn "Only ${free_gb} GB free on this disk: the Android tools need about 10 GB."
  ask login-consent "Go ahead?" || declined "Stopped before the Meta login. Start the setup again when ready."

  tokens_ok need_frl || { info "The Visor build also needs the FRL token: reading the APK again."; fetch_tokens; }
  setup_android
  build_visor
  boot_emulator
  run "Installing the Visor login app in the emulator" "$ADB" -s "$SERIAL" install -r "$VISOR_APK" || die "adb install failed."

  local frla
  frla=$(read_emulator_frla)
  if [ -n "$frla" ] && [[ "$frla" != *"No such file"* ]]; then
    write_private "$STATE/meta_login.txt" "$frla"
    if [ $DO_RELOGIN -eq 0 ] && "$CLI" check-login < /dev/null >> "$LOG" 2>&1; then
      ok "The emulator still held a valid login from a previous run"
      stop_emulator
      ok "Emulator closed"
      return
    fi
    info "Clearing the old login in the emulator"
    adb_ -s "$SERIAL" shell pm clear "$VISOR_PKG" >> "$LOG" 2>&1
  fi
  launch_visor

  action login-wait
  if [ $MACHINE -eq 0 ]; then
    printf '\n  %s%sYour turn:%s in the emulator window, log in to Meta in the Visor app.\n' "$B" "$Y" "$N"
    info "Use the Meta account your glasses are set up with. You type your password into Meta's own"
    info "login screen; this script only waits for the resulting token. Take your time."
    echo
  fi
  local start=$SECONDS
  LAST_TICK=0
  frla=""
  while :; do
    frla=$(read_emulator_frla)
    if [ -n "$frla" ] && [[ "$frla" != *"No such file"* ]] && [[ "$frla" != *" "* ]]; then break; fi
    [ -n "$(emulator_serial)" ] || die "The emulator was closed before the login finished."
    [ $((SECONDS - start)) -lt 2700 ] || die "No login after 45 minutes."
    progress "Waiting for you to log in" "$start"
    sleep 3
  done
  progress_end
  action none
  ok "Login token received (${#frla} characters)"
  write_private "$STATE/meta_login.txt" "$frla"
  run "Checking the login with Meta" "$CLI" check-login || die "Meta refuses the login token. Log in again (--relogin)."
  stop_emulator
  ok "Emulator closed"
}

# ---------------------------------------------------------------- 5. pairing

paired() { [ -s "$STATE/glasses.json" ] && [ -s "$STATE/owner_key.pem" ]; }

step_pair() {
  step pair "Pairing: this Mac becomes the owner of the glasses"
  if [ $DO_REPAIR -eq 0 ] && paired; then
    skip "Already paired: serial $(json_get "$STATE/glasses.json" serial), since $(json_get "$STATE/glasses.json" pairedAt)"
    return
  fi
  if [ $MACHINE -eq 0 ]; then
    printf '  %sRead this first.%s The glasses accept one owner. Taking ownership here means the Meta AI app on\n' "$B" "$N"
    info "your phone loses the glasses until you set them up there again (which takes ownership back)."
    info "This is not an official Meta feature and may be against Meta's terms of use."
  fi
  ask pair-consent "Make this Mac the owner of the glasses?" || declined "Stopped before the pairing. Start the setup again when ready."
  action pairing-help
  if [ $MACHINE -eq 0 ]; then
    echo
    info "1. Turn Bluetooth OFF on your phone, so it does not grab the glasses."
    info "2. Take the glasses out of the case, arms open, next to the Mac."
    info "3. Pairing mode: hold the capture button until the LED blinks blue."
    info "macOS may ask to let Terminal use Bluetooth (OK), then show a \"Connection Request\" (Connect)."
  fi
  local attempt
  for attempt in 1 2 3; do
    pause pairing-ready "Glasses blinking blue? Press Enter"
    if run_live "Taking ownership (attempt $attempt of 3)" "$CLI" pair --yes; then
      action none
      ok "This Mac owns the glasses. You can turn Bluetooth back on on your phone."
      return
    fi
    [ $attempt -lt 3 ] && warn "That did not work. Put the glasses back in pairing mode and try again."
  done
  die "Pairing failed 3 times. See Troubleshooting in README.md, then try again (--repair)."
}

# ---------------------------------------------------------------- 6. the app

step_app() {
  step app "Glasses.app, the interface"
  if [ $NO_APP -eq 1 ]; then skip "Skipped (--no-app)"; return; fi
  local app="$HOME/Applications/Glasses.app"
  if pgrep -x Glasses > /dev/null 2>&1; then
    pkill -x Glasses; sleep 1
    info "Glasses was running: it restarts with the new build."
  fi
  run "Building ~/Applications/Glasses.app" "$ROOT/make-app.sh" || die "make-app.sh failed."
  if [ $MACHINE -eq 1 ]; then
    # The setup page takes the person to the app itself: no second browser tab.
    open -a "$app" --args --no-open && ok "Glasses is running: look for the glasses icon in the menu bar."
  else
    open "$app" && ok "Opened: look for the glasses icon in the menu bar; the page opens in your browser."
  fi
  info "First launch: macOS may ask for access to the export folder, and asks for Bluetooth at the first connection."
}

# ---------------------------------------------------------------- 7. cleanup

step_cleanup() {
  step cleanup "Cleaning up"
  local items=() sizes=() brew_sdk="" own_sdk=0 own_jdk=0
  local avd_dir="$HOME/.android/avd/$AVD_NAME.avd"
  [ -d "$avd_dir" ] && items+=("emulator") && sizes+=("$avd_dir")
  local f has_work=0
  for f in "$WORK"/* "$WORK"/.[!.]*; do [ -e "$f" ] && [ "$(basename "$f")" != ".last-output" ] && has_work=1; done
  [ $has_work -eq 1 ] && items+=("Visor source and build") && sizes+=("$WORK")
  [ -f "$OWN_SDK_MARKER" ] && own_sdk=1 && items+=("Android SDK") && sizes+=("$OWN_SDK")
  [ -d "$OWN_JDK" ] && own_jdk=1 && items+=("Java") && sizes+=("$OWN_JDK")
  if [ -f "$LEGACY_BREW_MARKER" ] && [ -n "$BREW" ]; then
    brew_sdk="$("$BREW" --prefix)/share/android-commandlinetools"
    if [ -d "$brew_sdk" ]; then items+=("Android SDK (Homebrew)") && sizes+=("$brew_sdk"); else brew_sdk=""; fi
  fi
  if [ ${#items[@]} -eq 0 ]; then skip "Nothing to clean"; return; fi
  local total list
  total=$(du -sck "${sizes[@]}" 2> /dev/null | tail -1 | awk '{printf "%.1f", $1/1048576}')
  list=$(printf '%s, ' "${items[@]}")
  info "Only the Meta login needed these: ${list%, } (${total} GB)."
  info "Keep them if you expect to log in again soon; the setup downloads them again otherwise."
  if ! ask cleanup "Remove them now? (${total} GB)"; then skip "Kept"; return; fi
  [ -d "$avd_dir" ] && rm -rf "$avd_dir" "$HOME/.android/avd/$AVD_NAME.ini" && ok "Emulator removed"
  rm -rf "$WORK" && mkdir -p "$WORK" && ok "Visor source and build removed"
  [ $own_sdk -eq 1 ] && rm -rf "$OWN_SDK" && ok "Android SDK removed"
  [ $own_jdk -eq 1 ] && rm -rf "$OWN_JDK" && ok "Java removed"
  if [ -n "$brew_sdk" ]; then
    run "Removing the Android command line tools (Homebrew)" "$BREW" uninstall --cask android-commandlinetools
    # The cask only removes its own files: what sdkmanager downloaded (emulator, system image...) stays.
    rm -rf "$brew_sdk" && rm -f "$LEGACY_BREW_MARKER" && ok "Android SDK folder removed"
  fi
  return 0
}

# ---------------------------------------------------------------- main

[ $MACHINE -eq 0 ] && printf '\n%sRay-Ban Meta on the Mac: setup%s\n' "$B" "$N"
log "setup.sh $* in $ROOT (machine mode $MACHINE)"
BREW=""; ABI=""; JDK_ARCH=""; TOOLS_ARCH=""

if [ $ONLY_CLEANUP -eq 1 ]; then
  TOTAL=2; check_mac; step_cleanup
  [ $MACHINE -eq 1 ] && emit "done" ""
  printf '\n'; exit 0
fi

check_mac
build_client
step_tokens
step_login
step_pair
step_app
step_cleanup

EXPORTS=$(json_get "$STATE/web_prefs.json" exportDir 2> /dev/null || echo "$HOME/Pictures/Ray-Ban Meta")
if [ $MACHINE -eq 1 ]; then
  emit "done" "$EXPORTS"
else
  printf '\n%s%sAll set.%s\n' "$B" "$G" "$N"
  info "App:      Glasses in the menu bar (~/Applications/Glasses.app). Spotlight finds it as \"Glasses\"."
  info "Exports:  $EXPORTS"
  info "Terminal: $CLI help"
  info "Log:      $LOG"
  echo
fi
