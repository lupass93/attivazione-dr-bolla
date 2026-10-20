#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for tool in bash cat chmod cp curl dirname find grep jq ln mkdir mktemp mv openssl rm tar unzip xmllint zip zipinfo; do
    command -v "$tool" >/dev/null 2>&1 || { printf 'Missing test dependency: %s\n' "$tool" >&2; exit 1; }
done
work=$(mktemp -d)
cleanup() {
    local result=$?
    trap - EXIT
    rm -r -- "${work:?}"
    exit "$result"
}
trap cleanup EXIT
fixture="$work/checkout with spaces"
bin="$work/native-bin"
gallery="$work/gallery"
mkdir -p -- "$fixture/scripts" "$fixture/function-app" "$fixture/terraform" "$bin" "$gallery"
cp -- "$root/scripts/build.sh" "$root/scripts/deploy.sh" "$fixture/scripts/"
tar -C "$root/function-app" --exclude='Modules/Az.*' -cf - . | tar -C "$fixture/function-app" -xf -
for tool in bash cat chmod cp dirname find grep jq ln mkdir mktemp mv openssl rm tar unzip xmllint zip zipinfo; do
    ln -s -- "$(command -v "$tool")" "$bin/$tool"
done
export TEST_LOG="$work/commands.log" TEST_GALLERY="$gallery"
export TEST_TERRAFORM_DIRECTORY="$fixture/terraform" TEST_PACKAGE="$fixture/out/function-app.zip"
export TEST_FAILURE=

cat > "$bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "$TEST_LOG"
output=
url=
previous=
for argument in "$@"; do
    if [[ "$previous" == --output ]]; then output=$argument; fi
    if [[ "$argument" == https://* ]]; then url=$argument; fi
    previous=$argument
done
if [[ "$url" == https://www.powershellgallery.com/* ]]; then
    [[ "$TEST_FAILURE" != download ]] || exit 22
    case "$url" in
        *"Packages(Id='Az.Accounts',Version='1.0.0')"*) cp "$TEST_GALLERY/Az.Accounts.xml" "$output" ;;
        *"Packages(Id='Az.Compute',Version='1.0.0')"*) cp "$TEST_GALLERY/Az.Compute.xml" "$output" ;;
        */package/Az.Accounts/1.0.0) cp "$TEST_GALLERY/Az.Accounts.nupkg" "$output" ;;
        */package/Az.Compute/1.0.0) cp "$TEST_GALLERY/Az.Compute.nupkg" "$output" ;;
        *) printf 'Unexpected Gallery URL: %s\n' "$url" >&2; exit 91 ;;
    esac
else
    configuration=$(cat)
    [[ "$configuration" == 'header = "x-functions-key: test-key-only"' ]] || exit 92
    [[ "$*" != *test-key-only* ]] || exit 93
    [[ "$TEST_FAILURE" != transport ]] || exit 7
    if [[ "$*" == *'--request POST'* ]]; then
        if [[ "$TEST_FAILURE" == invoke ]]; then printf 500; else printf 400; fi
    else
        if [[ "$TEST_FAILURE" == status ]]; then printf 404; else printf 400; fi
    fi
fi
STUB
cat > "$bin/terraform" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'terraform %s\n' "$*" >> "$TEST_LOG"
[[ "$1" == "-chdir=$TEST_TERRAFORM_DIRECTORY" && "$2" == output && "$3" == -json ]] || exit 91
[[ "$TEST_FAILURE" != terraform ]] || exit 1
if [[ "$TEST_FAILURE" == output ]]; then printf '{}'; exit 0; fi
cat <<'JSON'
{"hosting_subscription_id":{"value":"test-subscription"},"resource_group_name":{"value":"test-group"},"function_app_name":{"value":"test-function"},"api_url":{"value":"https://test-function.azurewebsites.net/api"}}
JSON
STUB
cat > "$bin/az" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'az %s\n' "$*" >> "$TEST_LOG"
previous=
for argument in "$@"; do
    case "$previous" in
        --subscription) [[ "$argument" == test-subscription ]] || exit 91 ;;
        --resource-group) [[ "$argument" == test-group ]] || exit 91 ;;
        --name) [[ "$argument" == test-function ]] || exit 91 ;;
        --src) [[ "$argument" == "$TEST_PACKAGE" ]] || exit 91 ;;
    esac
    previous=$argument
done
case "$*" in
    'functionapp config appsettings delete '*)
        [[ "$TEST_FAILURE" != settings ]] || exit 1 ;;
    'functionapp deployment source config-zip '*)
        [[ "$TEST_FAILURE" != deploy ]] || exit 1 ;;
    'functionapp function list '*)
        [[ "$TEST_FAILURE" != functions ]] || exit 1
        if [[ "$TEST_FAILURE" == worker ]]; then
            printf '["test-function/Invoke-DRReplication","test-function/Get-DRStatus"]'
        else
            printf '["test-function/Invoke-DRReplication","test-function/Get-DRStatus","test-function/Process-DRSession"]'
        fi ;;
    'functionapp keys list '*)
        [[ "$TEST_FAILURE" != key ]] || exit 1
        if [[ "$TEST_FAILURE" == emptykey ]]; then printf null; else printf test-key-only; fi ;;
    *) printf 'Unexpected Azure command.\n' >&2; exit 91 ;;
esac
STUB
chmod +x "$bin/curl" "$bin/terraform" "$bin/az"
export PATH="$bin"
if command -v pwsh >/dev/null 2>&1 || command -v powershell >/dev/null 2>&1; then
    printf '%s\n' 'Test isolation failed: PowerShell must not be available.' >&2
    exit 1
fi
cd -- "$work"
cases=0
run_case() {
    local expected=$1 message=$2 actual text
    shift 2
    : > "$TEST_LOG"
    if text=$("$@" 2>&1); then actual=0; else actual=$?; fi
    if [[ "$actual" != "$expected" || "$text" != *"$message"* ]]; then
        printf 'FAIL: expected exit %s and "%s"; got exit %s:\n%s\n' "$expected" "$message" "$actual" "$text" >&2
        exit 1
    fi
    cases=$((cases + 1))
}
no_azure() {
    if grep -q '^az ' "$TEST_LOG"; then printf '%s\n' 'Unexpected Azure mutation.' >&2; exit 1; fi
}
reset_cache() {
    rm -f -- "$fixture/out/module-cache/Az.Accounts.1.0.0.nupkg" "$fixture/out/module-cache/Az.Accounts.1.0.0.xml" \
        "$fixture/out/module-cache/Az.Compute.1.0.0.nupkg" "$fixture/out/module-cache/Az.Compute.1.0.0.xml"
}
make_module() {
    local name=$1 dependency=${2:-} range=${3:-} directory="$work/package $1" checksum
    mkdir -p "$directory"
    printf "ModuleVersion = '1.0.0'\n" > "$directory/$name.psd1"
    printf '<package><metadata><id>%s</id><version>1.0.0</version><dependencies>' "$name" > "$directory/$name.nuspec"
    if [[ -n "$dependency" ]]; then
        printf '<dependency id="%s" version="%s"/>' "$dependency" "$range" >> "$directory/$name.nuspec"
    fi
    printf '</dependencies></metadata></package>' >> "$directory/$name.nuspec"
    rm -f -- "$gallery/$name.nupkg"
    (cd -- "$directory" && zip -q "$gallery/$name.nupkg" "$name.psd1" "$name.nuspec")
    checksum=$(openssl dgst -sha512 -binary "$gallery/$name.nupkg" | openssl base64 -A)
    printf '<entry><properties><Id>%s</Id><Version>1.0.0</Version><PackageHashAlgorithm>SHA512</PackageHashAlgorithm><PackageHash>%s</PackageHash></properties></entry>' \
        "$name" "$checksum" > "$gallery/$name.xml"
}
printf "@{\n'Az.Accounts' = '1.0.0'\n'Az.Compute' = '1.0.0'\n}\n" > "$fixture/function-app/requirements.psd1"
printf 'must-not-be-deployed' > "$fixture/function-app/local.settings.json"
mkdir -p "$fixture/function-app/Modules/Az.Obsolete/99.0.0"
printf 'obsolete' > "$fixture/function-app/Modules/Az.Obsolete/99.0.0/Az.Obsolete.psd1"
make_module Az.Accounts
make_module Az.Compute Az.Accounts '[1.0.0,2.0.0)'

run_case 0 'No PowerShell interpreter' bash "$fixture/scripts/build.sh" --help
no_azure
[[ ! -s "$TEST_LOG" ]] || exit 1
run_case 2 'unknown build argument' bash "$fixture/scripts/build.sh" --unknown
run_case 1 'Missing cached package' bash "$fixture/scripts/build.sh" --skip-module-download
no_azure
TEST_FAILURE=download run_case 1 'metadata download failed' bash "$fixture/scripts/build.sh"
no_azure
run_case 0 'Build completed:' bash "$fixture/scripts/build.sh"
no_azure
unzip -Z -1 "$TEST_PACKAGE" > "$work/entries.txt"
grep -qx host.json "$work/entries.txt"
grep -qx Modules/Az.Accounts/1.0.0/Az.Accounts.psd1 "$work/entries.txt"
if grep -Eq 'local.settings.json|Az.Obsolete|\.nuspec$|Content_Types|^function-app/' "$work/entries.txt"; then
    printf '%s\n' 'Deployment ZIP contains excluded files or an incorrect root.' >&2
    exit 1
fi
run_case 0 'Build completed:' bash "$fixture/scripts/build.sh" --skip-module-download
[[ ! -s "$TEST_LOG" ]] || { printf '%s\n' 'Offline build made a network call.' >&2; exit 1; }
previous_package=$(openssl dgst -sha256 "$TEST_PACKAGE")
printf corrupted >> "$fixture/out/module-cache/Az.Accounts.1.0.0.nupkg"
run_case 1 'checksum mismatch' bash "$fixture/scripts/build.sh" --skip-module-download
[[ $(openssl dgst -sha256 "$TEST_PACKAGE") == "$previous_package" ]] || exit 1
reset_cache
make_module Az.Compute Az.Missing 1.0.0
run_case 1 'Unpinned dependency' bash "$fixture/scripts/build.sh"
reset_cache
make_module Az.Compute Az.Accounts 2.0.0
run_case 1 'does not satisfy' bash "$fixture/scripts/build.sh"
reset_cache
make_module Az.Compute Az.Accounts '(1.0.0,2.0.0]'
run_case 1 'does not satisfy' bash "$fixture/scripts/build.sh"
reset_cache
make_module Az.Compute Az.Accounts '[0.5.0,1.0.0)'
run_case 1 'does not satisfy' bash "$fixture/scripts/build.sh"
reset_cache
make_module Az.Compute Az.Accounts '[1.0.0]'
run_case 0 'Build completed:' bash "$fixture/scripts/build.sh"
printf '[]' > "$fixture/function-app/host.json"
run_case 1 'Invalid JSON object' bash "$fixture/scripts/build.sh" --skip-module-download
cp -- "$root/function-app/host.json" "$fixture/function-app/host.json"
mv -- "$fixture/function-app/profile.ps1" "$work/profile.ps1"
run_case 1 'missing profile.ps1' bash "$fixture/scripts/build.sh" --skip-module-download
mv -- "$work/profile.ps1" "$fixture/function-app/profile.ps1"
ln -s -- "$work/profile.ps1" "$fixture/function-app/unexpected-link"
run_case 1 'must not contain symlinks' bash "$fixture/scripts/build.sh" --skip-module-download
rm -- "$fixture/function-app/unexpected-link"
printf "& 'pwsh' -File malicious.ps1\n" >> "$fixture/function-app/requirements.psd1"
run_case 1 'Unsupported requirements.psd1' bash "$fixture/scripts/build.sh"
no_azure

run_case 0 'Usage:' bash "$fixture/scripts/deploy.sh" --help
[[ ! -s "$TEST_LOG" ]] || exit 1
run_case 2 'Unknown deploy option' bash "$fixture/scripts/deploy.sh" --unknown
run_case 2 'requires a directory' bash "$fixture/scripts/deploy.sh" --terraform-directory
run_case 2 'requires a ZIP path' bash "$fixture/scripts/deploy.sh" --package-path
run_case 2 'requires a ZIP path' bash "$fixture/scripts/deploy.sh" --package-path --help
run_case 2 'more than once' bash "$fixture/scripts/deploy.sh" --package-path one --package-path two
run_case 2 'Do not mix' bash "$fixture/scripts/deploy.sh" --terraform-directory one two
run_case 2 'At most two' bash "$fixture/scripts/deploy.sh" one two three
run_case 1 'provide an existing ZIP' bash "$fixture/scripts/deploy.sh" --package-path "$work/missing.zip"
no_azure
run_case 0 'Deployment verified.' bash "$fixture/scripts/deploy.sh"
run_case 0 'Deployment verified.' bash "$fixture/scripts/deploy.sh" \
    --terraform-directory "$TEST_TERRAFORM_DIRECTORY" --package-path "$TEST_PACKAGE"
run_case 0 'Deployment verified.' bash "$fixture/scripts/deploy.sh" "$TEST_TERRAFORM_DIRECTORY" "$TEST_PACKAGE"
TEST_TERRAFORM_DIRECTORY='checkout with spaces/terraform' TEST_PACKAGE='checkout with spaces/out/function-app.zip' \
    run_case 0 'Deployment verified.' bash "$fixture/scripts/deploy.sh" --terraform-directory 'checkout with spaces/terraform' \
    --package-path 'checkout with spaces/out/function-app.zip'
TEST_FAILURE=terraform run_case 1 'Terraform outputs unavailable' bash "$fixture/scripts/deploy.sh"
no_azure
TEST_FAILURE=output run_case 1 'Missing hosting_subscription_id' bash "$fixture/scripts/deploy.sh"
no_azure
TEST_FAILURE=settings run_case 1 'Unable to select identity-based' bash "$fixture/scripts/deploy.sh"
if grep -q 'source config-zip' "$TEST_LOG"; then exit 1; fi
TEST_FAILURE=deploy run_case 1 'Deployment failed' bash "$fixture/scripts/deploy.sh"
if grep -q 'function list' "$TEST_LOG"; then exit 1; fi
TEST_FAILURE=functions run_case 1 'Unable to list indexed functions' bash "$fixture/scripts/deploy.sh"
TEST_FAILURE=worker run_case 1 'All three functions must be indexed' bash "$fixture/scripts/deploy.sh"
if grep -q 'keys list' "$TEST_LOG"; then exit 1; fi
TEST_FAILURE=key run_case 1 'Function key unavailable' bash "$fixture/scripts/deploy.sh"
TEST_FAILURE=emptykey run_case 1 'Function key unavailable' bash "$fixture/scripts/deploy.sh"
TEST_FAILURE=invoke run_case 1 'received 500/400' bash "$fixture/scripts/deploy.sh"
TEST_FAILURE=status run_case 1 'received 400/404' bash "$fixture/scripts/deploy.sh"
TEST_FAILURE=transport run_case 1 'Verify private network access' bash "$fixture/scripts/deploy.sh"
printf 'PASS: %s Bash build/deploy cases; pwsh and powershell are absent from PATH; no real Azure calls.\n' "$cases"
