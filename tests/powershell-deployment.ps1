$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$work = Join-Path ([System.IO.Path]::GetTempPath()) "dr-deployment-$([guid]::NewGuid().ToString('N'))"
$fixture = Join-Path $work 'checkout with spaces'
$bin = Join-Path $work 'bin'
$originalPath = $env:PATH
$engine = (Get-Process -Id $PID).Path
$count = 0
$global:DeploymentTest = @{
    Commands = [System.Collections.Generic.List[string]]::new()
    Failure = ''; Hostname = 'test-function.azurewebsites.net'
    TerraformDirectory = (Join-Path $fixture 'terraform')
    Package = (Join-Path $fixture 'out/function-app.zip')
}

function Assert-DeploymentTest {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-DeploymentCase {
    param([scriptblock]$Action, [string]$ExpectedError)
    $global:DeploymentTest.Commands.Clear()
    $failure = $null
    try { & $Action | Out-Null } catch { $failure = $_ }
    if ($ExpectedError) {
        Assert-DeploymentTest ($null -ne $failure -and $failure.Exception.Message -like "*$ExpectedError*") `
            "Expected '$ExpectedError'; observed '$failure'."
    } else {
        if ($failure) { throw $failure }
    }
    $script:count++
}

function global:az {
    $arguments = @($args)
    $operation = $arguments -join ' '
    $global:DeploymentTest.Commands.Add("az $operation")
    foreach ($option in @{ '--subscription' = 'test-subscription'; '--resource-group' = 'test-group'; '--name' = 'test-function' }.GetEnumerator()) {
        $index = [array]::IndexOf($arguments, $option.Key)
        if ($index -lt 0 -or $arguments[$index + 1] -ne $option.Value) { throw "Wrong Azure target: $operation" }
    }
    $global:LASTEXITCODE = 0
    switch -Wildcard ($operation) {
        'functionapp show *' {
            if ($global:DeploymentTest.Failure -eq 'target') { $global:LASTEXITCODE = 3; return }
            if ($global:DeploymentTest.Failure -eq 'hostname') { return 'None' }
            if ($global:DeploymentTest.Failure -eq 'badhostname') { return 'https://invalid-host/path' }
            return $global:DeploymentTest.Hostname
        }
        'functionapp config appsettings delete *' {
            if ($global:DeploymentTest.Failure -eq 'settings') { $global:LASTEXITCODE = 1 }
        }
        'functionapp deployment source config-zip *' {
            $index = [array]::IndexOf($arguments, '--src')
            if ($index -lt 0 -or $arguments[$index + 1] -ne $global:DeploymentTest.Package) { throw 'Wrong deployment package.' }
            if ($global:DeploymentTest.Failure -eq 'deploy') { $global:LASTEXITCODE = 1 }
        }
        'functionapp function list *' {
            if ($global:DeploymentTest.Failure -eq 'functions') { $global:LASTEXITCODE = 1; return }
            'test-function/Invoke-DRReplication'
            'test-function/Get-DRStatus'
            if ($global:DeploymentTest.Failure -ne 'worker') { 'test-function/Process-DRSession' }
        }
        'functionapp keys list *' {
            if ($global:DeploymentTest.Failure -eq 'key') { $global:LASTEXITCODE = 1; return }
            if ($global:DeploymentTest.Failure -eq 'emptykey') { return '' }
            'test-key-only'
        }
        default { throw "Unexpected Azure command: $operation" }
    }
}

function global:terraform {
    $global:DeploymentTest.Commands.Add("terraform $($args -join ' ')")
    if ($args[0] -ne "-chdir=$($global:DeploymentTest.TerraformDirectory)") { throw 'Wrong Terraform directory.' }
    $global:LASTEXITCODE = 0
    if ($global:DeploymentTest.Failure -eq 'terraform') { $global:LASTEXITCODE = 1; return }
    if ($global:DeploymentTest.Failure -eq 'outputs') { return '{}' }
    @{
        hosting_subscription_id = @{ value = 'test-subscription' }
        resource_group_name = @{ value = 'test-group' }
        function_app_name = @{ value = 'test-function' }
        api_url = @{ value = 'https://test-function.azurewebsites.net/api' }
    } | ConvertTo-Json -Compress
}

function global:Invoke-RestMethod {
    param(
        [string]$Method, [string]$Uri, [hashtable]$Headers, [string]$ContentType,
        [string]$Body, [switch]$SkipHttpErrorCheck, [string]$StatusCodeVariable, [int]$TimeoutSec
    )
    $global:DeploymentTest.Commands.Add("http ${Method}:$Uri")
    $expected = "https://$($global:DeploymentTest.Hostname)/api/"
    if (-not $Uri.StartsWith($expected) -or $Headers['x-functions-key'] -ne 'test-key-only') { throw 'Wrong API URL or function key.' }
    if ($Method -eq 'Post' -and ($Body -ne '{}' -or $ContentType -ne 'application/json')) { throw 'Smoke check must not submit a DR session.' }
    if ($global:DeploymentTest.Failure -eq 'transport') { throw 'Test HTTP transport failure.' }
    $code = if (($Method -eq 'Post' -and $global:DeploymentTest.Failure -eq 'invoke') -or
        ($Method -eq 'Get' -and $global:DeploymentTest.Failure -eq 'status')) { 500 } else { 400 }
    Set-Variable -Name $StatusCodeVariable -Value $code -Scope 1
    @{ error = 'Missing sessionId' }
}

function global:Save-Module {
    param([string]$Name, [string]$RequiredVersion, [string]$Path, [switch]$Force)
    $global:DeploymentTest.Commands.Add("Save-Module $Name $RequiredVersion")
    if ($global:DeploymentTest.Failure -eq 'download') { throw 'Test module download failure.' }
    $directory = Join-Path $Path "$Name/$RequiredVersion"
    New-Item $directory -ItemType Directory -Force | Out-Null
    "@{ ModuleVersion = '$RequiredVersion' }" | Set-Content (Join-Path $directory "$Name.psd1")
}

try {
    New-Item $fixture, $bin -ItemType Directory -Force | Out-Null
    foreach ($source in Get-ChildItem (Join-Path $root 'function-app') -File -Recurse |
        Where-Object { $_.FullName -notmatch '[/\\]Modules[/\\]Az[.]' }) {
        $relative = [System.IO.Path]::GetRelativePath($root, $source.FullName)
        $destination = Join-Path $fixture $relative
        New-Item (Split-Path $destination -Parent) -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath $source.FullName -Destination $destination
    }
    New-Item (Join-Path $fixture 'scripts') -ItemType Directory | Out-Null
    Copy-Item (Join-Path $root 'scripts/build.ps1'), (Join-Path $root 'scripts/deploy.ps1') (Join-Path $fixture 'scripts')
    $zip = (Get-Command zip -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    New-Item (Join-Path $bin 'zip') -ItemType SymbolicLink -Target $zip | Out-Null
    $env:PATH = $bin
    $app = Join-Path $fixture 'function-app'
    "@{ 'Az.Test' = '1.0.0' }" | Set-Content (Join-Path $app 'requirements.psd1')
    '{"mustNotBeDeployed":true}' | Set-Content (Join-Path $app 'local.settings.json')
    $obsolete = Join-Path $app 'Modules/Az.Test/99.0.0'
    New-Item $obsolete -ItemType Directory -Force | Out-Null
    'obsolete' | Set-Content (Join-Path $obsolete 'Az.Test.psd1')
    $build = Join-Path $fixture 'scripts/build.ps1'
    $deploy = Join-Path $fixture 'scripts/deploy.ps1'
    $module = Join-Path $app 'Modules/Az.Test/1.0.0/Az.Test.psd1'
    $explicit = @{ SubscriptionId = 'test-subscription'; ResourceGroupName = 'test-group'; FunctionAppName = 'test-function' }

    Invoke-DeploymentCase { & $build -SkipModuleDownload 6>$null } 'Missing module'
    Assert-DeploymentTest ($global:DeploymentTest.Commands.Count -eq 0) 'Offline build must not download.'
    $global:DeploymentTest.Failure = 'download'
    Invoke-DeploymentCase { & $build 6>$null } 'Test module download failure'
    $global:DeploymentTest.Failure = ''
    Invoke-DeploymentCase { & $build 6>$null }
    Assert-DeploymentTest (Test-Path -LiteralPath $module) 'Pinned module must be acquired.'
    Assert-DeploymentTest (-not (Test-Path -LiteralPath $obsolete)) 'Obsolete module versions must not be packaged.'
    $archive = [System.IO.Compression.ZipFile]::OpenRead($global:DeploymentTest.Package)
    try {
        Assert-DeploymentTest ($archive.Entries.FullName -contains 'host.json') 'host.json must be at the package root.'
        Assert-DeploymentTest ($archive.Entries.FullName -notcontains 'local.settings.json') 'Local settings must not be deployed.'
        Assert-DeploymentTest ($archive.Entries.FullName -contains 'Modules/Az.Test/1.0.0/Az.Test.psd1') 'Pinned manifest missing from ZIP.'
        foreach ($entry in $archive.Entries) {
            $expectedMode = if ($entry.FullName.EndsWith('/')) { 493 } else { 420 }
            Assert-DeploymentTest ((($entry.ExternalAttributes -shr 16) -band 4095) -eq $expectedMode) 'Incorrect Linux ZIP permissions.'
        }
    } finally { $archive.Dispose() }
    Invoke-DeploymentCase { & $build -SkipModuleDownload 6>$null }
    Assert-DeploymentTest ($global:DeploymentTest.Commands.Count -eq 0) 'Cached build must not call Azure, Terraform or Save-Module.'
    Push-Location $work
    try {
        Invoke-DeploymentCase { & $build -SkipModuleDownload -PackagePath 'artifacts with spaces/customer package.zip' 6>$null }
    } finally { Pop-Location }
    $customPackage = Join-Path $work 'artifacts with spaces/customer package.zip'
    Assert-DeploymentTest (Test-Path -LiteralPath $customPackage) 'Custom relative package must use the caller directory.'
    Invoke-DeploymentCase { & $build -PackagePath 'not-a-zip.txt' 6>$null } 'must be a ZIP file path'
    Invoke-DeploymentCase { & $build -PackagePath (Join-Path $app 'invalid.zip') 6>$null } 'must be outside function-app'
    New-Item (Join-Path $work 'directory.zip') -ItemType Directory | Out-Null
    Invoke-DeploymentCase { & $build -PackagePath (Join-Path $work 'directory.zip') 6>$null } 'must be a ZIP file path'
    Invoke-DeploymentCase { & $build -PackagePath '   ' 6>$null } "Cannot validate argument on parameter 'PackagePath'"
    'function Invalid-Source {' | Set-Content (Join-Path $app 'invalid.ps1')
    Invoke-DeploymentCase { & $build -SkipModuleDownload 6>$null } 'Missing closing'
    Remove-Item -LiteralPath (Join-Path $app 'invalid.ps1')

    Invoke-DeploymentCase { & $deploy 6>$null }
    Assert-DeploymentTest ($global:DeploymentTest.Commands[0] -like 'terraform *') 'Default deployment must retain Terraform compatibility.'
    $global:DeploymentTest.TerraformDirectory = Join-Path $work 'external state'
    $global:DeploymentTest.Package = $customPackage
    Invoke-DeploymentCase {
        & $deploy -TerraformDirectory $global:DeploymentTest.TerraformDirectory -PackagePath $customPackage 6>$null
    }
    foreach ($scenario in @(
            @('terraform', 'Terraform outputs unavailable'), @('outputs', 'Missing Terraform output'),
            @('settings', 'Unable to select identity-based'), @('deploy', 'Deployment failed'),
            @('functions', 'All three functions must be indexed'), @('worker', 'All three functions must be indexed'),
            @('key', 'Function key unavailable'), @('emptykey', 'Function key unavailable'),
            @('invoke', 'Expected HTTP 400'), @('status', 'Expected HTTP 400'), @('transport', 'Test HTTP transport failure'))) {
        $global:DeploymentTest.Failure = $scenario[0]
        Invoke-DeploymentCase {
            & $deploy -TerraformDirectory $global:DeploymentTest.TerraformDirectory -PackagePath $customPackage 6>$null
        } $scenario[1]
        if ($scenario[0] -in @('terraform', 'outputs')) {
            Assert-DeploymentTest (-not ($global:DeploymentTest.Commands -like 'az *')) 'Invalid outputs must stop before Azure.'
        }
        if ($scenario[0] -eq 'settings') {
            Assert-DeploymentTest (-not ($global:DeploymentTest.Commands -like '*config-zip*')) 'Settings failure must stop before upload.'
        }
    }
    $global:DeploymentTest.Failure = ''
    Remove-Item Function:\terraform
    Assert-DeploymentTest (-not (Get-Command terraform -ErrorAction SilentlyContinue)) 'Terraform must be unavailable for direct-target tests.'
    Invoke-DeploymentCase { & $build -SkipModuleDownload -PackagePath $customPackage 6>$null }
    Assert-DeploymentTest ($global:DeploymentTest.Commands.Count -eq 0) 'Build must remain independent of Terraform and Azure.'
    $global:DeploymentTest.Hostname = 'test-function-unique.westeurope-01.azurewebsites.net'
    Invoke-DeploymentCase { & $deploy @explicit -PackagePath $customPackage 6>$null }
    Assert-DeploymentTest ($global:DeploymentTest.Commands[0] -like 'az functionapp show *') 'Explicit mode must discover the actual Azure hostname first.'
    Assert-DeploymentTest (($global:DeploymentTest.Commands -like 'http *').Count -eq 2) 'Both smoke checks must run.'
    $global:DeploymentTest.Package = Join-Path $fixture 'out/function-app.zip'
    Invoke-DeploymentCase { & $deploy @explicit 6>$null }
    Invoke-DeploymentCase { & $deploy @explicit -PackagePath (Join-Path $work 'missing.zip') 6>$null } 'provide an existing ZIP'
    Assert-DeploymentTest ($global:DeploymentTest.Commands.Count -eq 0) 'Missing ZIP must stop before discovery.'
    Invoke-DeploymentCase { & $deploy @explicit -TerraformDirectory $work 6>$null } 'Parameter set cannot be resolved'
    Assert-DeploymentTest ($global:DeploymentTest.Commands.Count -eq 0) 'Mixed modes must stop before Azure.'
    foreach ($scenario in @(
            @('target', 'Unable to read the target Function App'), @('hostname', 'no valid default hostname'),
            @('badhostname', 'no valid default hostname'), @('deploy', 'Deployment failed'),
            @('worker', 'All three functions must be indexed'), @('transport', 'Test HTTP transport failure'))) {
        $global:DeploymentTest.Failure = $scenario[0]
        Invoke-DeploymentCase { & $deploy @explicit 6>$null } $scenario[1]
        if ($scenario[0] -in @('target', 'hostname', 'badhostname')) {
            Assert-DeploymentTest (-not ($global:DeploymentTest.Commands -like 'az functionapp config *')) 'Discovery failure must not mutate settings.'
        }
    }
    foreach ($arguments in @(
            @('-SubscriptionId', 'test-subscription'),
            @('-ResourceGroupName', 'test-group', '-FunctionAppName', 'test-function'),
            @('-SubscriptionId', 'test-subscription', '-ResourceGroupName', ' ', '-FunctionAppName', 'test-function'))) {
        $text = & $engine -NoLogo -NoProfile -NonInteractive -File $deploy @arguments 2>&1 | Out-String
        Assert-DeploymentTest ($LASTEXITCODE -ne 0 -and $text -match 'mandatory parameters|white-space') `
            "Partial/blank targets must fail parameter binding without Terraform or Azure: $text"
        $script:count++
    }
    Write-Host "PASS: $count PowerShell build/deploy cases, including explicit targets with Terraform absent; no real Azure calls."
} finally {
    $env:PATH = $originalPath
    foreach ($function in @('az', 'terraform', 'Invoke-RestMethod', 'Save-Module')) {
        if (Test-Path "Function:\$function") { Remove-Item "Function:\$function" }
    }
    Remove-Variable DeploymentTest -Scope Global
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
