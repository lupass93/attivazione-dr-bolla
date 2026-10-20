#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

if (( $# > 2 )); then
    fail 'Usage: bash scripts/deploy.sh [terraform-directory] [package-path]'
fi

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
terraform_directory=${1:-"$root/terraform"}
package_path=${2:-"$root/out/function-app.zip"}

for executable in terraform az jq curl; do
    command -v "$executable" >/dev/null 2>&1 || fail "Required command not found: $executable"
done
[[ -f "$package_path" ]] || fail 'Run scripts/build.ps1 before deploying, or provide an existing ZIP.'

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