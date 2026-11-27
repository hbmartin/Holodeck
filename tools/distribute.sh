#!/bin/bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  tools/distribute.sh <tvos|macos|all> --build-number N [--archive-only | --internal-only]
  tools/distribute.sh <tvos|macos> --archive PATH [--internal-only]

Set SENTRY_ORG, SENTRY_AUTH_TOKEN, SENTRY_DSN_{TVOS,MACOS},
SENTRY_PROJECT_{TVOS,MACOS}, ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID for upload.
--archive-only uses local signing or the optional App Store Connect key.
--internal-only restricts the upload to internal TestFlight testers.
EOF
}

fail() {
    printf 'Distribution error: %s\n' "$*" >&2
    exit 1
}

require_variable() {
    [[ -n "${!1:-}" ]] || fail "Set $1 before distributing."
}

run_logged() {
    local log=$1 action=$2
    shift 2
    printf '%s\n' "$action"
    if ! "$@" >"$log" 2>&1; then
        printf 'Distribution error: %s failed. See %s.\n' "$action" "$log" >&2
        return 1
    fi
}

plist_value() {
    /usr/bin/plutil -extract "$1" raw -o - "$2"
}

uuids() {
    xcrun dwarfdump --uuid "$1" | awk '/^UUID: / { print toupper($2), $3 }' | LC_ALL=C sort -u
}

valid_dsn() {
    local pattern='^https://[^/@:[:space:]]+@[^/@[:space:]]+/([^[:space:]?#]*/)?[0-9]+/?$'
    [[ $1 =~ $pattern ]]
}

if [[ $# == 0 || $1 == --help || $1 == -h ]]; then
    usage
    exit 0
fi

case $1 in
    tvos|macos) platforms=("$1") ;;
    all) platforms=(tvos macos) ;;
    *) fail "Select tvos, macos, or all. See --help." ;;
esac
shift

build_number=''
existing_archive=''
archive_only=false
internal_only=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --build-number)
            [[ $# -gt 1 && -z $build_number && $2 =~ ^[1-9][0-9]*$ ]] || fail "Use --build-number with a positive integer."
            build_number=$2
            shift 2 ;;
        --archive)
            [[ $# -gt 1 && -z $existing_archive ]] || fail "Pass an existing .xcarchive directory to --archive."
            archive_argument=$2
            while [[ $archive_argument == */ ]]; do archive_argument=${archive_argument%/}; done
            [[ -d $archive_argument && $archive_argument == *.xcarchive ]] || fail "Pass an existing .xcarchive directory to --archive."
            existing_archive=$(cd -- "$archive_argument" && pwd -P)
            shift 2 ;;
        --archive-only) archive_only=true; shift ;;
        --internal-only) internal_only=true; shift ;;
        *) fail "Unknown argument $1. See --help." ;;
    esac
done

if [[ -n $existing_archive ]]; then
    [[ ${#platforms[@]} == 1 && -z $build_number && $archive_only == false ]] || fail "Use --archive with one platform and no build options."
else
    [[ -n $build_number ]] || fail "Supply --build-number for a new archive."
fi
[[ $archive_only == false || $internal_only == false ]] || fail "Choose either --archive-only or --internal-only."

command -v xcodebuild >/dev/null || fail "Install Xcode and select it with xcode-select."
command -v xcrun >/dev/null || fail "Install the Xcode command-line tools."

if [[ $archive_only == false || -n ${ASC_KEY_PATH:-}${ASC_KEY_ID:-}${ASC_ISSUER_ID:-} ]]; then
    require_variable ASC_KEY_PATH
    require_variable ASC_KEY_ID
    require_variable ASC_ISSUER_ID
    [[ -f $ASC_KEY_PATH && -r $ASC_KEY_PATH ]] || fail "ASC_KEY_PATH must point to a readable App Store Connect private key."
    key_dir=$(cd -- "$(dirname -- "$ASC_KEY_PATH")" && pwd -P)
    apple_auth=(-allowProvisioningUpdates -authenticationKeyPath "$key_dir/$(basename -- "$ASC_KEY_PATH")"
                -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
    unset ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID
fi

if [[ $archive_only == false ]]; then
    command -v sentry-cli >/dev/null || fail "Install sentry-cli to upload dSYMs."
    require_variable SENTRY_ORG
    require_variable SENTRY_AUTH_TOKEN
fi

# Validate the settings for every selected platform before archiving or uploading.
for platform in "${platforms[@]}"; do
    suffix=TVOS
    [[ $platform != macos ]] || suffix=MACOS
    dsn_variable="SENTRY_DSN_$suffix"
    dsn=${!dsn_variable:-}
    if [[ $archive_only == false ]]; then
        require_variable "$dsn_variable"
        require_variable "SENTRY_PROJECT_$suffix"
    fi
    if [[ -n $dsn ]] && ! valid_dsn "$dsn"; then
        fail "$dsn_variable must contain an HTTPS Sentry DSN with a public key and project ID."
    fi
done

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$repo_root"
output="$repo_root/.build/distribution"
mkdir -p "$output"

archives=() run_dirs=() schemes=() versions=() builds=() projects=()

prepare_archive() {
    local index=$1
    local platform=${platforms[$index]} scheme=Holodeck configuration=Release suffix=TVOS destination='generic/platform=tvOS'
    local platform_name=appletvos
    local dsn_variable project_variable dsn run_dir archive app info executable executable_path
    local archived_build archived_version app_uuids dsym dsym_uuids entitlement_log
    if [[ $platform == macos ]]; then
        scheme=HolodeckMac
        configuration=TestFlight
        suffix=MACOS
        destination='generic/platform=macOS'
        platform_name=macosx
    fi
    dsn_variable="SENTRY_DSN_$suffix"
    project_variable="SENTRY_PROJECT_$suffix"
    dsn=${!dsn_variable:-}
    run_dir=$(mktemp -d "$output/$platform.XXXXXX")
    archive=${existing_archive:-$run_dir/$scheme.xcarchive}
    printf '%s archive: %s\n' "$platform" "$archive"

    if [[ -z $existing_archive ]]; then
        run_logged "$run_dir/archive.log" "Archiving $scheme" \
            env -u SENTRY_AUTH_TOKEN xcodebuild -project "$repo_root/Holodeck.xcodeproj" \
            -scheme "$scheme" -configuration "$configuration" -destination "$destination" \
            -derivedDataPath "$output/DerivedData-$platform" -archivePath "$archive" \
            -disableAutomaticPackageResolution ${apple_auth[@]+"${apple_auth[@]}"} \
            "CURRENT_PROJECT_VERSION=$build_number" HOLODECK_TEST_BUNDLE_SUFFIX= \
            "HOLODECK_SENTRY_DSN=$dsn" HOLODECK_SENTRY_ENVIRONMENT=testflight archive
    fi

    app="$archive/Products/Applications/$scheme.app"
    info="$app/Info.plist"
    executable_path=$app
    if [[ $platform == macos ]]; then
        info="$app/Contents/Info.plist"
        executable_path="$app/Contents/MacOS"
    fi
    [[ -f $info && $(plist_value CFBundleIdentifier "$info") == "me.haroldmartin.$scheme" &&
        $(plist_value DTPlatformName "$info") == "$platform_name" ]] \
        || fail "Expected the distribution bundle for $scheme in $archive."
    executable=$(plist_value CFBundleExecutable "$info")
    [[ $executable == "$scheme" ]] || fail "Unexpected app executable in $archive."
    archived_build=$(plist_value CFBundleVersion "$info")
    archived_version=$(plist_value CFBundleShortVersionString "$info")
    [[ -n $archived_version && $archived_build =~ ^[1-9][0-9]*$ && ( -z $build_number || $archived_build == "$build_number" ) ]] \
        || fail "Unexpected version or build number in $archive."
    [[ $(plist_value HolodeckSentryDSN "$info") == "$dsn" && $(plist_value HolodeckSentryEnvironment "$info") == testflight ]] \
        || fail "The Sentry DSN or environment in $archive does not match this release."

    run_logged "$run_dir/signing.log" "Verifying the $scheme archive signature" codesign --verify --strict "$app"

    if [[ $platform == macos ]]; then
        entitlement_log="$run_dir/entitlements.log"
        if ! codesign --display --entitlements - --xml "$app" >"$run_dir/entitlements.plist" 2>"$entitlement_log"; then
            fail "Could not read the Mac archive's signing entitlements. See $entitlement_log."
        fi
        [[ $(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$run_dir/entitlements.plist") == true ]] \
            || fail "The Mac archive needs App Sandbox. Archive the TestFlight configuration."
        [[ ! -e $app/Contents/Resources/Tools/holodeck-shader-tool ]] \
            || fail "The Mac archive includes the local Shader Requests helper."
    fi

    dsym="$archive/dSYMs/$scheme.app.dSYM/Contents/Resources/DWARF/$executable"
    [[ -f "$executable_path/$executable" && -f $dsym ]] || fail "Missing app executable or dSYM in $archive."
    if ! app_uuids=$(uuids "$executable_path/$executable") || ! dsym_uuids=$(uuids "$dsym") ||
        [[ -z $app_uuids || $app_uuids != "$dsym_uuids" ]]; then
        fail "App and dSYM UUIDs do not match in $archive."
    fi
    printf 'Verified %s %s (%s) and its dSYM.\n' "$platform" "$archived_version" "$archived_build"
    [[ $archive_only == false ]] || return 0

    archives[$index]=$archive
    run_dirs[$index]=$run_dir
    schemes[$index]=$scheme
    versions[$index]=$archived_version
    builds[$index]=$archived_build
    projects[$index]=${!project_variable}

    /usr/bin/plutil -create xml1 "$run_dir/ExportOptions.plist"
    local options="$run_dir/ExportOptions.plist"
    /usr/bin/plutil -insert method -string app-store-connect "$options"
    /usr/bin/plutil -insert destination -string upload "$options"
    /usr/bin/plutil -insert signingStyle -string automatic "$options"
    /usr/bin/plutil -insert manageAppVersionAndBuildNumber -bool NO "$options"
    /usr/bin/plutil -insert uploadSymbols -bool YES "$options"
    /usr/bin/plutil -insert testFlightInternalTestingOnly -bool "$internal_only" "$options"
}

report_upload_failure() {
    local failed_index=$1 apple_attempted=$2 index
    if (( failed_index > 0 )); then
        printf 'Submitted to App Store Connect:' >&2
        printf ' %s' "${platforms[@]:0:failed_index}" >&2
        printf '\n' >&2
    else
        printf 'No platform submission was confirmed.\n' >&2
    fi
    if [[ $apple_attempted == true ]]; then
        printf 'Check whether App Store Connect already received %s before retrying it.\n' "${platforms[$failed_index]}" >&2
    fi
    printf 'Resume the failed or pending platforms with their verified archives:\n' >&2
    for ((index = failed_index; index < ${#platforms[@]}; index++)); do
        printf '  %q %s --archive %q' "$repo_root/tools/distribute.sh" "${platforms[$index]}" "${archives[$index]}" >&2
        if [[ $internal_only == true ]]; then printf ' --internal-only' >&2; fi
        printf '\n' >&2
    done
    exit 1
}

upload_archive() {
    local index=$1
    local platform=${platforms[$index]} scheme=${schemes[$index]} archive=${archives[$index]} run_dir=${run_dirs[$index]}
    run_logged "$run_dir/sentry.log" "Uploading $scheme dSYMs to Sentry" \
        env -u SENTRY_ALLOW_FAILURE sentry-cli debug-files upload --type dsym --no-sources --wait \
        --org "$SENTRY_ORG" --project "${projects[$index]}" "$archive/dSYMs" || report_upload_failure "$index" false

    run_logged "$run_dir/testflight.log" "Uploading $scheme to App Store Connect" \
        env -u SENTRY_AUTH_TOKEN xcodebuild -exportArchive -archivePath "$archive" \
        -exportPath "$run_dir/export" -exportOptionsPlist "$run_dir/ExportOptions.plist" "${apple_auth[@]}" \
        || report_upload_failure "$index" true
    printf 'Submitted %s %s (%s) for App Store Connect processing. Logs: %s\n' \
        "$platform" "${versions[$index]}" "${builds[$index]}" "$run_dir"
}

for index in "${!platforms[@]}"; do
    prepare_archive "$index"
done
if [[ $archive_only == false ]]; then
    for index in "${!platforms[@]}"; do
        upload_archive "$index"
    done
fi
