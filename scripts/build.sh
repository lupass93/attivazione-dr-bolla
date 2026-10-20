#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: bash scripts/build.sh [--skip-module-download]

Build out/function-app.zip from the current checkout.
No PowerShell interpreter is used or required.

Options:
  --skip-module-download  Use only the existing out/module-cache NuGet packages
                         and Gallery metadata. Fail if a pinned package is absent.
  -h, --help             Show this help without building.

Paths are resolved from this script's repository, not the caller's directory.
Requires curl, jq, zip, unzip, zipinfo, xmllint, openssl and standard Linux tools.
Pinned versions come from function-app/requirements.psd1.
This command does not provision Azure resources or deploy code.
USAGE
}

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

skip_module_download=false
while (( $# )); do
    case "$1" in
        --skip-module-download) skip_module_download=true ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Error: unknown build argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
app="$root/function-app"
output="$root/out"
cache="$output/module-cache"
for executable in curl jq zip unzip zipinfo xmllint openssl tar find chmod mktemp; do
    command -v "$executable" >/dev/null 2>&1 || fail "Required command not found: $executable"
done
[[ -f "$app/requirements.psd1" ]] || fail 'Missing function-app/requirements.psd1.'

names=()
versions=()
opened=false
closed=false
pin_pattern="^[[:space:]]*'(Az[.][A-Za-z0-9_.-]+)'[[:space:]]*=[[:space:]]*'([0-9]+([.][0-9]+){2,3})'[[:space:]]*(#.*)?$"
while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    if [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then continue; fi
    if [[ "$line" =~ ^[[:space:]]*@\{[[:space:]]*$ && "$opened" == false ]]; then
        opened=true
    elif [[ "$line" =~ ^[[:space:]]*\}[[:space:]]*$ && "$opened" == true && "$closed" == false ]]; then
        closed=true
    elif [[ "$line" =~ $pin_pattern && "$opened" == true && "$closed" == false ]]; then
        name=${BASH_REMATCH[1]}
        version=${BASH_REMATCH[2]}
        for existing in "${names[@]}"; do
            [[ "$existing" != "$name" ]] || fail "Duplicate module pin: $name"
        done
        names+=("$name")
        versions+=("$version")
    else
        fail 'Unsupported requirements.psd1 entry. Use one quoted, exact Az module version per line; expressions are not evaluated.'
    fi
done < "$app/requirements.psd1"
[[ "$closed" == true && ${#names[@]} -gt 0 ]] || fail 'No complete module version table found in requirements.psd1.'

mkdir -p -- "$cache"
work=$(mktemp -d "$output/.bash-build.XXXXXX")
cleanup() {
    local result=$?
    trap - EXIT
    if [[ "$work" == "$output"/.bash-build.* && -d "$work" ]]; then
        rm -r -- "$work" || { printf '%s\n' "Error: could not remove temporary build directory: $work" >&2; exit 1; }
    fi
    exit "$result"
}
trap cleanup EXIT
stage="$work/app"
mkdir -- "$stage"
tar -C "$app" --exclude='local.settings.json' --exclude='*.DS_Store' --exclude='Modules/Az.*' -cf - . |
    tar -C "$stage" -xf -

xml_value() {
    xmllint --nonet --xpath "$2" "$1"
}

compare_versions() {
    local left right index a b
    IFS=. read -r -a left <<< "$1"
    IFS=. read -r -a right <<< "$2"
    for (( index=0; index<4; index++ )); do
        a=$((10#${left[index]:-0}))
        b=$((10#${right[index]:-0}))
        if (( a < b )); then printf '%s' -1; return; fi
        if (( a > b )); then printf '%s' 1; return; fi
    done
    printf '%s' 0
}

satisfies_version() {
    local selected=$1 range=${2//[[:space:]]/} comparison lower upper
    local number='[0-9]+([.][0-9]+){1,3}'
    if [[ "$range" =~ ^$number$ ]]; then
        comparison=$(compare_versions "$selected" "$range")
        (( comparison >= 0 ))
    elif [[ "$range" =~ ^\[($number)\]$ ]]; then
        [[ $(compare_versions "$selected" "${BASH_REMATCH[1]}") == 0 ]]
    elif [[ "$range" == [\[\(]*,*[\]\)] ]]; then
        lower=${range:1}
        lower=${lower%%,*}
        upper=${range#*,}
        upper=${upper%?}
        [[ -z "$lower" || "$lower" =~ ^$number$ ]] || fail "Unsupported dependency range: $range"
        [[ -z "$upper" || "$upper" =~ ^$number$ ]] || fail "Unsupported dependency range: $range"
        if [[ -n "$lower" ]]; then
            comparison=$(compare_versions "$selected" "$lower")
            (( comparison >= 0 )) || return 1
            [[ "${range:0:1}" != '(' || "$comparison" != 0 ]] || return 1
        fi
        if [[ -n "$upper" ]]; then
            comparison=$(compare_versions "$selected" "$upper")
            (( comparison <= 0 )) || return 1
            [[ "${range: -1}" != ')' || "$comparison" != 0 ]] || return 1
        fi
    else
        fail "Unsupported dependency range: $range"
    fi
}

for (( module_index=0; module_index<${#names[@]}; module_index++ )); do
    name=${names[module_index]}
    version=${versions[module_index]}
    archive="$cache/$name.$version.nupkg"
    metadata="$cache/$name.$version.xml"
    if [[ ! -f "$archive" || ! -f "$metadata" ]]; then
        [[ "$skip_module_download" == false ]] || fail "Missing cached package or metadata for $name $version. Run build.sh without --skip-module-download first."
        printf 'Downloading %s %s from PowerShell Gallery.\n' "$name" "$version"
        curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
            --connect-timeout 30 --max-time 300 --retry 2 \
            "https://www.powershellgallery.com/api/v2/Packages(Id='$name',Version='$version')" \
            --output "$work/metadata.xml" || fail "Gallery metadata download failed for $name $version."
        curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
            --connect-timeout 30 --max-time 300 --retry 2 \
            "https://www.powershellgallery.com/api/v2/package/$name/$version" \
            --output "$work/module.nupkg" || fail "Module download failed for $name $version."
        mv -- "$work/metadata.xml" "$metadata"
        mv -- "$work/module.nupkg" "$archive"
    fi
    property="//*[local-name()='properties']"
    [[ $(xml_value "$metadata" "string($property/*[local-name()='Id'])") == "$name" ]] || fail "Unexpected Gallery module identity: $name"
    [[ $(xml_value "$metadata" "string($property/*[local-name()='Version'])") == "$version" ]] || fail "Unexpected Gallery module version: $name"
    [[ $(xml_value "$metadata" "string($property/*[local-name()='PackageHashAlgorithm'])") == SHA512 ]] || fail "Unsupported Gallery checksum algorithm: $name"
    expected_hash=$(xml_value "$metadata" "string($property/*[local-name()='PackageHash'])")
    actual_hash=$(openssl dgst -sha512 -binary "$archive" | openssl base64 -A)
    [[ -n "$expected_hash" && "$actual_hash" == "$expected_hash" ]] || fail "Package checksum mismatch for $name $version. Remove its two out/module-cache files and retry."
    unzip -tq "$archive" > "$work/unzip-check.log" || { cat "$work/unzip-check.log" >&2; fail "Invalid NuGet ZIP: $name"; }
    unzip -Z -1 "$archive" > "$work/entries.txt"
    while IFS= read -r entry; do
        case "$entry" in
            /*|[A-Za-z]:*|*\\*|..|../*|*/../*|*/..) fail "Unsafe NuGet archive path: $entry" ;;
        esac
    done < "$work/entries.txt"
    zipinfo -l "$archive" > "$work/modes.txt"
    if grep -q '^l' "$work/modes.txt"; then fail "Symlinks are not supported in module packages: $name"; fi
    module="$stage/Modules/$name/$version"
    mkdir -p -- "$module"
    unzip -q "$archive" -d "$module"
    nuspec="$module/$name.nuspec"
    [[ -f "$module/$name.psd1" && -f "$nuspec" ]] || fail "Missing module manifest or NuGet metadata: $name"
    [[ $(xml_value "$nuspec" "string(//*[local-name()='metadata']/*[local-name()='id'])") == "$name" &&
       $(xml_value "$nuspec" "string(//*[local-name()='metadata']/*[local-name()='version'])") == "$version" ]] ||
        fail "NuGet identity/version does not match the pin: $name $version"
    dependency_count=$(xml_value "$nuspec" "count(//*[local-name()='dependency'])")
    for (( dependency_index=1; dependency_index<=dependency_count; dependency_index++ )); do
        dependency="(//*[local-name()='dependency'])[$dependency_index]"
        dependency_name=$(xml_value "$nuspec" "string($dependency/@id)")
        dependency_range=$(xml_value "$nuspec" "string($dependency/@version)")
        selected=
        for (( pin_index=0; pin_index<${#names[@]}; pin_index++ )); do
            if [[ "${names[pin_index]}" == "$dependency_name" ]]; then selected=${versions[pin_index]}; break; fi
        done
        [[ -n "$selected" ]] || fail "Unpinned dependency of $name: $dependency_name. Add an exact version to requirements.psd1."
        satisfies_version "$selected" "$dependency_range" || fail "Pinned $dependency_name $selected does not satisfy $name dependency $dependency_range."
    done
    rm -f -- "$nuspec" "$module/[Content_Types].xml"
    for extra in _rels package; do
        if [[ -d "$module/$extra" ]]; then rm -r -- "${module:?}/$extra"; fi
    done
done

for required in host.json profile.ps1 requirements.psd1 \
    Invoke-DRReplication/run.ps1 Invoke-DRReplication/function.json \
    Get-DRStatus/run.ps1 Get-DRStatus/function.json \
    Process-DRSession/run.ps1 Process-DRSession/function.json \
    Modules/DRCore/DRCore.psm1 Modules/DRSessions/DRSessions.psm1; do
    [[ -f "$stage/$required" ]] || fail "Deployment package is missing $required."
done
for configuration in host.json Invoke-DRReplication/function.json Get-DRStatus/function.json Process-DRSession/function.json; do
    jq -e 'type == "object"' "$stage/$configuration" >/dev/null || fail "Invalid JSON object: $configuration"
done
[[ -z $(find "$stage" -type l -print -quit) ]] || fail 'Deployment source must not contain symlinks.'
find "$stage" -type d -exec chmod 755 {} +
find "$stage" -type f -exec chmod 644 {} +
(cd -- "$stage" && zip -X -q -r "$work/function-app.zip" .) || fail 'ZIP creation failed.'
unzip -tq "$work/function-app.zip" > "$work/unzip-check.log" || { cat "$work/unzip-check.log" >&2; fail 'Deployment ZIP integrity check failed.'; }
mv -f -- "$work/function-app.zip" "$output/function-app.zip"
printf 'Build completed: %s\n' "$output/function-app.zip"
openssl dgst -sha256 "$output/function-app.zip"
