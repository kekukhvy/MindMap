#!/bin/zsh
# xcodebuild wrapper for MindMap (macOS + iOS). Usage: Tools/xcb/xcb.sh <xcodebuild args...>
#
# The project is team-signed (YS72WYPK4V, Apple Development, iCloud/CloudKit + push + shared
# keychain entitlements). macOS builds need a "Mac App Development" provisioning profile for
# com.kekukh.MindMap, which Xcode creates once an Apple ID is added in Xcode ▸ Settings ▸ Accounts.
# Without it this wrapper falls back to a LOCAL ad-hoc macOS build (Config/MindMap-macOS-local.entitlements,
# no CloudKit: the app reports "iCloud Sync unavailable") so builds, tests and the DMG keep working.
# Force a mode with MINDMAP_SIGNING=team|local. iOS Simulator builds never need a profile.
set -uo pipefail
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOCAL_ARGS=(CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= "CODE_SIGN_ENTITLEMENTS=$ROOT/Config/MindMap-macOS-local.entitlements" MINDMAP_CLOUDKIT_CONTAINER=)

has_mac_profile() {
  local dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  [[ -d "$dir" ]] || return 1
  for f in "$dir"/*.provisionprofile(N); do
    security cms -D -i "$f" 2>/dev/null | grep -q "YS72WYPK4V.com.kekukh.MindMap</string>" && return 0
  done
  return 1
}

is_mac=0
for a in "$@"; do [[ "$a" == *"platform=macOS"* ]] && is_mac=1; done
mode="${MINDMAP_SIGNING:-auto}"
if [[ $is_mac == 0 || $mode == team ]]; then
  exec xcodebuild -allowProvisioningUpdates "$@"
fi
if [[ $mode == local ]]; then
  exec xcodebuild "$@" "${LOCAL_ARGS[@]}"
fi
if has_mac_profile; then
  exec xcodebuild -allowProvisioningUpdates "$@"
fi
# No profile yet (no Apple ID in Xcode, or the project was never built signed): build locally.
# After adding the account, build once in Xcode or run with MINDMAP_SIGNING=team to create the profile.
echo "xcb.sh: no macOS provisioning profile for com.kekukh.MindMap -> LOCAL ad-hoc signing (CloudKit off)" >&2
exec xcodebuild "$@" "${LOCAL_ARGS[@]}"
