#!/usr/bin/env bash
#
# Runs Pocket LLM on macOS, keeping the development provisioning profile fresh.
#
# Why this exists
# ---------------
# macos/Runner.xcodeproj signs the Runner target with an Apple Development
# identity using automatic signing. Apple only issues provisioning profiles for a
# Personal Team for seven days, while the Flutter macOS builder never passes
# -allowProvisioningUpdates to xcodebuild (only the iOS path does). Once the
# profile lapses, `flutter run -d macos` stops with
#
#   error: No profiles for 'com.prady.pocketllm' were found
#
# instead of renewing it. Xcode's own Run button renews the profile silently, so
# the failure only shows up on the command line, about once a week.
#
# This script looks up the profile issued for the app's bundle identifier and,
# when it is missing or about to lapse, asks Xcode to re-issue it before handing
# over to `flutter run`. A paid Apple Developer Program membership replaces the
# seven-day profile with a twelve-month one and makes this script unnecessary.
#
# Usage
#   scripts/run_macos.sh                  ensure a fresh profile, then run the app
#   scripts/run_macos.sh --ensure-only    check/renew the profile and stop
#   scripts/run_macos.sh --force-refresh  renew even when the profile looks valid
#   scripts/run_macos.sh --help
#   scripts/run_macos.sh <args...>        remaining args are passed to `flutter run`
#
# Exits non-zero when the profile cannot be renewed or when `flutter run` fails.
# Run it from a terminal, not a pipe, if you want flutter's hot-reload keys.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="$REPO_ROOT/macos"
APP_INFO="$MACOS_DIR/Runner/Configs/AppInfo.xcconfig"
FLUTTER_BUILD_DIR="$REPO_ROOT/build/macos"

# Renew while there is still this much time left, so a renewal is never racing
# the expiry.
RENEW_WITHIN_SECONDS=$((48 * 60 * 60))

say() { printf '%s\n' "$*"; }
fail() { printf 'error: %s\n' "$*" >&2; }

decoded_plist=""

# Must not end on a failing test: under `set -e` a false status here would
# replace the script's own exit status.
cleanup() {
  if [ -n "$decoded_plist" ]; then
    rm -f "$decoded_plist"
  fi
  return 0
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage
  scripts/run_macos.sh                  ensure a fresh profile, then run the app
  scripts/run_macos.sh --ensure-only    check/renew the profile and stop
  scripts/run_macos.sh --force-refresh  renew even when the profile looks valid
  scripts/run_macos.sh --help
  scripts/run_macos.sh <args...>        remaining args are passed to `flutter run`
USAGE
}

human_time() { date -j -f "%s" "$1" "+%Y-%m-%d %H:%M %Z"; }

bundle_identifier() {
  sed -n 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' \
    "$APP_INFO" | head -1
}

plist_value() { # $1 decoded plist, $2 key
  plutil -extract "$2" raw -o - "$1" 2>/dev/null || true
}

# Prints "<expiry epoch>\t<path>" for the newest profile issued to bundle
# identifier $1, or nothing when there is no such profile. The caller reads it
# through a command substitution, so the result has to travel on stdout.
newest_profile_for() {
  local id="$1" dir profile app_id profile_name expiry epoch
  local best_epoch="" best_path=""

  for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
             "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [ -d "$dir" ] || continue
    for profile in "$dir"/*.provisionprofile; do
      [ -e "$profile" ] || continue

      decoded_plist="$(mktemp -t pocketllm-profile)"
      security cms -D -i "$profile" > "$decoded_plist" 2>/dev/null || continue

      app_id="$(plutil -p "$decoded_plist" |
        sed -n 's/.*"com\.apple\.application-identifier" => "\([^"]*\)".*/\1/p' | head -1)"
      profile_name="$(plist_value "$decoded_plist" Name)"

      # Profiles for this app end in its bundle identifier, either as the
      # application identifier (<team>.<bundle id>) or in the profile name.
      case "$app_id" in
        *".$id") ;;
        *)
          case "$profile_name" in
            *": $id") ;;
            *) continue ;;
          esac
          ;;
      esac

      expiry="$(plist_value "$decoded_plist" ExpirationDate)"
      [ -n "$expiry" ] || continue
      epoch="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$expiry" +%s 2>/dev/null || echo 0)"

      if [ -z "$best_epoch" ] || [ "$epoch" -gt "$best_epoch" ]; then
        best_epoch="$epoch"
        best_path="$profile"
      fi
    done
  done

  if [ -n "$best_epoch" ]; then
    printf '%s\t%s\n' "$best_epoch" "$best_path"
  fi
  return 0
}

# Asks Xcode to (re-)issue the profile. Mirrors the arguments the Flutter macOS
# builder uses for a debug build so the work is reused by the `flutter run` that
# follows.
renew_profile() {
  ( cd "$MACOS_DIR" &&
    /usr/bin/env xcodebuild \
      -workspace Runner.xcworkspace \
      -configuration Debug \
      -scheme Runner \
      -derivedDataPath "$FLUTTER_BUILD_DIR" \
      -destination 'platform=macOS' \
      OBJROOT="$FLUTTER_BUILD_DIR/Build/Intermediates.noindex" \
      SYMROOT="$FLUTTER_BUILD_DIR/Build/Products" \
      COMPILER_INDEX_STORE_ENABLE=NO \
      -allowProvisioningUpdates \
      -quiet \
      build )
}

ensure_profile() { # $1 non-zero to renew regardless of the current expiry
  local force="$1" id epoch path record deadline

  id="$(bundle_identifier)"
  if [ -z "$id" ]; then
    fail "could not read PRODUCT_BUNDLE_IDENTIFIER from $APP_INFO"
    exit 1
  fi

  record="$(newest_profile_for "$id")"
  epoch="${record%%$'\t'*}"
  path="${record#*$'\t'}"

  if [ "$force" -eq 0 ] && [ -n "$epoch" ]; then
    deadline=$(( $(date +%s) + RENEW_WITHIN_SECONDS ))
    if [ "$epoch" -gt "$deadline" ]; then
      say "Provisioning profile for $id is valid until $(human_time "$epoch")."
      say "Nothing to renew: $(basename "$path")"
      return 0
    fi
    say "Provisioning profile for $id expires $(human_time "$epoch"); renewing it."
  elif [ -n "$epoch" ]; then
    say "Renewing the provisioning profile for $id even though it is valid until $(human_time "$epoch")."
  else
    say "No provisioning profile for $id on this machine; asking Xcode for one."
  fi

  if ! renew_profile; then
    fail "could not renew the provisioning profile for $id."
    fail "Connect to the internet and try again, or open macos/Runner.xcworkspace"
    fail "in Xcode and press Run once: Xcode renews the profile itself when it is"
    fail "signed in with the Apple ID that owns the signing team."
    exit 1
  fi

  record="$(newest_profile_for "$id")"
  epoch="${record%%$'\t'*}"
  path="${record#*$'\t'}"
  if [ -z "$epoch" ] || [ "$epoch" -le "$(date +%s)" ]; then
    fail "Xcode built the app but there is still no valid provisioning profile for $id."
    exit 1
  fi

  say "Provisioning profile for $id is now valid until $(human_time "$epoch")."
  say "Profile: $path"
}

ensure_only=0
force_refresh=0
flutter_args=()

for arg in "$@"; do
  case "$arg" in
    --ensure-only) ensure_only=1 ;;
    --force-refresh) force_refresh=1 ;;
    -h|--help) usage; exit 0 ;;
    *) flutter_args+=("$arg") ;;
  esac
done

ensure_profile "$force_refresh"

if [ "$ensure_only" -eq 1 ]; then
  exit 0
fi

if ! command -v flutter >/dev/null 2>&1; then
  fail "flutter is not on PATH"
  exit 1
fi

# ${flutter_args[@]+...} keeps this working under `set -u` on bash 3.2, which is
# what /bin/bash still is on macOS.
exec flutter run -d macos ${flutter_args[@]+"${flutter_args[@]}"}
