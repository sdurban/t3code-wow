param(
    [string] $StateHome = (Join-Path $env:LOCALAPPDATA 'T3CodeWoW\state')
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$stateDir = [IO.Path]::GetFullPath((Join-Path $StateHome 't3code-wow'))
$destination = Join-Path $stateDir 'whisper'
$model = 'ggml-base-q5_1.bin'
if ((Test-Path -LiteralPath (Join-Path $destination 'whisper-cli.exe') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $destination $model) -PathType Leaf)) {
    Write-Host 'Windows dictation is already installed. Restart the bridge to use it.'
    return
}
if (Test-Path -LiteralPath $destination) { throw "Move the incomplete dictation folder out of the way and run setup again: $destination" }

$architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
switch ($architecture) {
    'AMD64' {
        $archive = 'whisper-bin-x64.zip'
        $archiveHash = '6ba69e3482d7826214f90a6a9c84ca07782aec1e1d0c6a7c30c994fd5d816ccb'
    }
    'ARM64' {
        $archive = 'whisper-bin-win-cpu-arm64.zip'
        $archiveHash = '28c37e7b598c3d9bbfef94f3bd67f2ee6f12b7c86f3da5edcf5e4308d615ff6d'
    }
    default { throw 'Windows dictation requires 64-bit Windows (x64 or ARM64).' }
}

function Get-VerifiedDownload([string] $Url, [string] $File, [string] $Sha256) {
    Invoke-WebRequest -Uri $Url -OutFile $File -UseBasicParsing -TimeoutSec 180
    if ((Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash -ne $Sha256) {
        throw "The download failed its SHA-256 check: $Url"
    }
}

$staging = Join-Path $stateDir ('.whisper-setup-' + [Guid]::NewGuid().ToString('N'))
New-Item -Path $staging -ItemType Directory -Force | Out-Null
try {
    Write-Host 'Downloading whisper.cpp and the multilingual model (about 70 MB)...'
    $zip = Join-Path $staging $archive
    Get-VerifiedDownload "https://github.com/ggml-org/whisper.cpp/releases/download/b5454/$archive" $zip $archiveHash
    $expanded = Join-Path $staging 'expanded'
    Expand-Archive -LiteralPath $zip -DestinationPath $expanded
    $cli = Get-ChildItem -LiteralPath $expanded -Recurse -Filter 'whisper-cli.exe' -File | Select-Object -First 1
    if (-not $cli) { throw 'whisper-cli.exe was missing from the archive.' }
    Get-VerifiedDownload "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$model" (Join-Path $cli.DirectoryName $model) `
        '422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898'
    if (-not $cli.DirectoryName.StartsWith($expanded + '\', [StringComparison]::OrdinalIgnoreCase) -and $cli.DirectoryName -ne $expanded) {
        throw 'The extracted whisper.cpp folder was outside the staging directory.'
    }
    [IO.Directory]::Move($cli.DirectoryName, $destination)
    Write-Host 'Windows dictation is installed. Restart the bridge to use it.'
} finally {
    $resolved = (Resolve-Path -LiteralPath $staging).ProviderPath
    if ([IO.Path]::GetDirectoryName($resolved) -eq $stateDir -and [IO.Path]::GetFileName($resolved) -match '^\.whisper-setup-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
