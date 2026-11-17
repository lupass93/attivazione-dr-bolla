<#
.SYNOPSIS
Build a local deployment ZIP without Terraform or Azure access.
.PARAMETER PackagePath
ZIP to create. Relative paths use the caller's directory; the default is out/function-app.zip in this repository.
.PARAMETER SkipModuleDownload
Require the pinned modules to already exist in function-app/Modules instead of downloading them.
#>
[CmdletBinding()]
param(
    [switch]$SkipModuleDownload,
    [ValidateNotNullOrWhiteSpace()]
    [string]$PackagePath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'out/function-app.zip')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$app = Join-Path $root 'function-app'
$package = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PackagePath)
if ([System.IO.Path]::GetExtension($package) -ine '.zip' -or (Test-Path -LiteralPath $package -PathType Container)) {
    throw 'PackagePath must be a ZIP file path, not a directory.'
}
$comparison = if ($IsWindows) { [System.StringComparison]::OrdinalIgnoreCase } else { [System.StringComparison]::Ordinal }
if ($package.StartsWith($app + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
    throw 'PackagePath must be outside function-app to avoid packaging the output itself.'
}
$output = Split-Path $package -Parent
$versions = Import-PowerShellDataFile (Join-Path $app 'requirements.psd1')

foreach ($module in $versions.GetEnumerator()) {
    $manifest = Join-Path $app "Modules/$($module.Key)/$($module.Value)/$($module.Key).psd1"
    if (-not (Test-Path $manifest)) {
        if ($SkipModuleDownload) { throw "Missing module $($module.Key) $($module.Value)." }
        Save-Module -Name $module.Key -RequiredVersion $module.Value -Path (Join-Path $app 'Modules') -Force
    }
}

foreach ($module in $versions.GetEnumerator()) {
    $moduleRoot = Join-Path $app "Modules/$($module.Key)"
    Get-ChildItem $moduleRoot -Directory | Where-Object { $_.Name -match '^\d+\.\d+\.' -and $_.Name -ne $module.Value } |
        Remove-Item -Recurse -Force
}

foreach ($source in Get-ChildItem $app -Recurse -File -Include *.ps1, *.psm1 | Where-Object { $_.FullName -notmatch '[/\\]Modules[/\\]Az\.' }) {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($source.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) { throw ($parseErrors.Message -join '; ') }
}

New-Item -ItemType Directory -Path $output -Force | Out-Null
if (Test-Path $package) { Remove-Item $package -Force }
Push-Location $app
try {
    if (Get-Command zip -ErrorAction SilentlyContinue) {
        zip -q -r $package . -x 'local.settings.json' '*.DS_Store'
        if ($LASTEXITCODE -ne 0) { throw 'ZIP creation failed.' }
    } else {
        $files = Get-ChildItem -Force | Where-Object { $_.Name -ne 'local.settings.json' }
        Compress-Archive -Path $files.FullName -DestinationPath $package -CompressionLevel Optimal
    }
} finally {
    Pop-Location
}

$archive = [System.IO.Compression.ZipFile]::Open($package, [System.IO.Compression.ZipArchiveMode]::Update)
try {
    foreach ($entry in $archive.Entries) {
        $mode = if ($entry.FullName.EndsWith('/')) { [Convert]::ToInt32('40755', 8) } else { [Convert]::ToInt32('100644', 8) }
        $entry.ExternalAttributes = ($mode -shl 16) -bor $(if ($entry.FullName.EndsWith('/')) { 16 } else { 0 })
    }
    $entries = @($archive.Entries.FullName)
    foreach ($required in @('host.json', 'profile.ps1', 'Invoke-DRReplication/run.ps1', 'Get-DRStatus/run.ps1',
            'Process-DRSession/run.ps1', 'Process-DRSession/function.json', 'Modules/DRCore/DRCore.psm1', 'Modules/DRSessions/DRSessions.psm1',
            'Modules/DRAudit/DRAudit.psm1')) {
        if ($entries -notcontains $required) { throw "Deployment package is missing $required." }
    }
    if ($entries -contains 'local.settings.json') { throw 'Local settings must not be deployed.' }
} finally {
    $archive.Dispose()
}

Write-Host "Build completed: $package"
Get-FileHash $package -Algorithm SHA256 | Select-Object Path, Hash