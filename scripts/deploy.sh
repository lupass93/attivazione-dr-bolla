#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: bash scripts/deploy.sh [--terraform-directory DIRECTORY] [--package-path ZIP]
   or: bash scripts/deploy.sh [terraform-directory] [package-path]

Deploy an existing package using the selected Terraform outputs.

Options:
  --terraform-directory DIRECTORY  Terraform root/state used to select the target.
                                  Default: <repository>/terraform
  --package-path ZIP               Existing deployment ZIP.
                                  Default: <repository>/out/function-app.zip
  -h, --help                       Show help without deploying.

Named and positional arguments cannot be mixed. Custom relative paths are
relative to the caller's directory; default paths are relative to this script.
This command does not build, provision infrastructure or start DR replication.
Requires terraform, az, jq, curl and private connectivity.
USAGE
}

usage_error() {
    printf 'Error: %s\n' "$1" >&2
    usage >&2
    exit 2
}

terraform_directory=
package_path=
named=false
positional=()
while (( $# )); do
    case "$1" in
        --terraform-directory)
            if (( $# < 2 )) || [[ -z "$2" || "$2" == -* ]]; then
                usage_error '--terraform-directory requires a directory.'
            fi
            [[ -z "$terraform_directory" ]] || usage_error '--terraform-directory was specified more than once.'
            terraform_directory=$2
            named=true
            shift 2
            ;;
        --package-path)
            if (( $# < 2 )) || [[ -z "$2" || "$2" == -* ]]; then
                usage_error '--package-path requires a ZIP path.'
            fi
            [[ -z "$package_path" ]] || usage_error '--package-path was specified more than once.'
            package_path=$2
            named=true
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        --)
            shift
            positional+=("$@")
            break
            ;;
        -*) usage_error "Unknown deploy option: $1" ;;
        *) positional+=("$1"); shift ;;
    esac
done
(( ${#positional[@]} <= 2 )) || usage_error 'At most two positional paths are supported.'
if [[ "$named" == true ]] && (( ${#positional[@]} )); then
    usage_error 'Do not mix named and positional paths.'
fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if (( ${#positional[@]} >= 1 )); then terraform_directory=${positional[0]}; fi
if (( ${#positional[@]} == 2 )); then package_path=${positional[1]}; fi
terraform_directory=${terraform_directory:-"$root/terraform"}
package_path=${package_path:-"$root/out/function-app.zip"}

for executable in terraform az jq curl; do
    command -v "$executable" >/dev/null 2>&1 || fail "Required command not found: $executable"
done
[[ -f "$package_path" ]] || fail 'Run scripts/build.sh (or scripts/build.ps1) before deploying, or provide an existing ZIP.'

outputs=$(terraform "-chdir=$terraform_directory" output -json) || fail 'Terraform outputs unavailable. Apply the infrastructure first.'
subscription=$(jq -er '.hosting_subscription_id.value | strings | select(length > 0)' <<< "$outputs") || fail 'Missing hosting_subscription_id output.'
resource_group=$(jq -er '.resource_group_name.value | strings | select(length > 0)' <<< "$outputs") || fail 'Missing resource_group_name output.'
name=$(jq -er '.function_app_name.value | strings | select(length > 0)' <<< "$outputs") || fail 'Missing function_app_name output.'
api=$(jq -er '.api_url.value | strings | select(length > 0)' <<< "$outputs") || fail 'Missing api_url output.'
target=(--subscription "$subscription" --resource-group "$resource_group" --name "$name")

az functionapp config appsettings delete "${target[@]}" --setting-names AzureWebJobsStorage --output none --only-show-errors ||
    fail 'Unable to select identity-based host storage. Deployment stopped.'

az functionapp deployment source config-zip "${target[@]}" --src "$package_path" --only-show-errors ||
    fail 'Deployment failed. Inspect the Azure error before retrying.'

functions=$(az functionapp function list "${target[@]}" --query '[].name' -o json --only-show-errors) || fail 'Unable to list indexed functions.'
jq -e 'any(.[]; endswith("/Invoke-DRReplication")) and any(.[]; endswith("/Get-DRStatus")) and any(.[]; endswith("/Process-DRSession"))' <<< "$functions" >/dev/null ||
    fail 'All three functions must be indexed. Check host startup, queue identity and private storage access.'

set +x
key=$(az functionapp keys list "${target[@]}" --query functionKeys.default -o tsv --only-show-errors) || fail 'Function key unavailable.'
trap 'unset key' EXIT
[[ -n "$key" && "$key" != 'null' && "$key" != 'None' ]] || fail 'Function key unavailable.'

http_code() {
    printf 'header = "x-functions-key: %s"\n' "$key" |
        curl --config - --silent --show-error --output /dev/null --write-out '%{http_code}' --max-time 60 "$@"
}

invoke_code=$(http_code --request POST --header 'Content-Type: application/json' --data '{}' "${api%/}/Invoke-DRReplication") ||
    fail 'Invoke smoke check failed. Verify private network access and DNS.'
status_code=$(http_code "${api%/}/Get-DRStatus") ||
    fail 'Status smoke check failed. Verify private network access and DNS.'
[[ "$invoke_code" == '400' && "$status_code" == '400' ]] ||
    fail "Expected HTTP 400 for missing sessionId on both endpoints; received $invoke_code/$status_code."

printf '%s\n' 'Deployment verified. Invoke and Get-DRStatus respond correctly; no replication was started.'