#!/usr/bin/env bash
set -euo pipefail

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: bash scripts/deploy.sh --subscription-id ID --resource-group-name GROUP --function-app-name NAME [--package-path ZIP]
   or: bash scripts/deploy.sh [--terraform-directory DIRECTORY] [--package-path ZIP]
   or: bash scripts/deploy.sh [terraform-directory] [package-path]

Deploy an existing package. All three target parameters select Terraform-free mode.

Options:
  --subscription-id ID             Hosting subscription, used with both target names.
  --resource-group-name GROUP       Resource Group of the existing Function App.
  --function-app-name NAME          Existing Function App. API hostname is read from Azure.
  --terraform-directory DIRECTORY  Terraform root/state used to select the target.
                                  Alternative to explicit targets; default: <repository>/terraform
  --package-path ZIP               Existing deployment ZIP.
                                  Default: <repository>/out/function-app.zip
  -h, --help                       Show help without deploying.

Named and positional arguments cannot be mixed. Custom relative paths are
relative to the caller's directory; default paths are relative to this script.
Explicit targets cannot be mixed with a Terraform directory.
This command does not build, provision infrastructure or start DR replication.
Requires az, jq, curl and private connectivity; terraform only in Terraform mode.
USAGE
}

usage_error() {
    printf 'Error: %s\n' "$1" >&2
    usage >&2
    exit 2
}

terraform_directory=
package_path=
subscription=
resource_group=
name=
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
        --subscription-id|--resource-group-name|--function-app-name)
            if (( $# < 2 )) || [[ -z "${2//[[:space:]]/}" || "$2" == -* ]]; then
                usage_error "$1 requires a value."
            fi
            case "$1" in
                --subscription-id)
                    [[ -z "$subscription" ]] || usage_error "$1 was specified more than once."
                    subscription=$2 ;;
                --resource-group-name)
                    [[ -z "$resource_group" ]] || usage_error "$1 was specified more than once."
                    resource_group=$2 ;;
                --function-app-name)
                    [[ -z "$name" ]] || usage_error "$1 was specified more than once."
                    name=$2 ;;
            esac
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
package_path=${package_path:-"$root/out/function-app.zip"}
if [[ -n "$subscription$resource_group$name" ]]; then
    [[ -n "$subscription" && -n "$resource_group" && -n "$name" ]] ||
        usage_error 'Specify --subscription-id, --resource-group-name and --function-app-name together.'
    [[ -z "$terraform_directory" ]] || usage_error 'Do not mix explicit targets with --terraform-directory.'
fi

for executable in az jq curl; do
    command -v "$executable" >/dev/null 2>&1 || fail "Required command not found: $executable"
done
[[ -f "$package_path" ]] || fail 'Run scripts/build.sh (or scripts/build.ps1) before deploying, or provide an existing ZIP.'

if [[ -n "$subscription" ]]; then
    target=(--subscription "$subscription" --resource-group "$resource_group" --name "$name")
    hostname=$(az functionapp show "${target[@]}" --query 'defaultHostName || properties.defaultHostName' --output tsv --only-show-errors) ||
        fail 'Unable to read the target Function App. Check its name, subscription and access.'
    [[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z0-9-]+$ ]] || fail 'The target Function App has no valid default hostname.'
    api="https://$hostname/api"
else
    command -v terraform >/dev/null 2>&1 || fail 'Required command not found: terraform. Alternatively, provide all three explicit target parameters.'
    terraform_directory=${terraform_directory:-"$root/terraform"}
    outputs=$(terraform "-chdir=$terraform_directory" output -json) || fail 'Terraform outputs unavailable. Select an existing state, or use the three explicit target parameters.'
    subscription=$(jq -er '.hosting_subscription_id.value | strings | select(length > 0)' <<< "$outputs") || fail 'Missing hosting_subscription_id output.'
    resource_group=$(jq -er '.resource_group_name.value | strings | select(length > 0)' <<< "$outputs") || fail 'Missing resource_group_name output.'
    name=$(jq -er '.function_app_name.value | strings | select(length > 0)' <<< "$outputs") || fail 'Missing function_app_name output.'
    api=$(jq -er '.api_url.value | strings | select(length > 0)' <<< "$outputs") || fail 'Missing api_url output.'
    target=(--subscription "$subscription" --resource-group "$resource_group" --name "$name")
fi
printf 'Deploying %s to subscription %s, Resource Group %s, Function App %s.\n' "$package_path" "$subscription" "$resource_group" "$name"

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