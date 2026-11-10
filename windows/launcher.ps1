param(
    [ValidateSet('menu', 'install', 'start', 'status', 'probe', 'uninstall', 'dictation')]
    [string] $Action = 'menu',
    [string] $WowPath
)

$ErrorActionPreference = 'Stop'
$bridge = Join-Path (Split-Path -Parent $PSScriptRoot) 'bridge\bin\t3code-wow.js'
$data = Join-Path $env:LOCALAPPDATA 'T3CodeWoW'
$env:XDG_CONFIG_HOME = Join-Path $data 'config'
$env:XDG_STATE_HOME = Join-Path $data 'state'
$configDir = Join-Path $env:XDG_CONFIG_HOME 't3code-wow'
$configFile = Join-Path $configDir 'config.json'
$sessionFile = Join-Path $configDir 'windows-pairing.json'

function Read-SecretText([System.Security.SecureString] $Secret) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer).Trim()
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        $Secret.Dispose()
    }
}

function Test-LocalAddress([uri] $Origin) {
    if ($Origin.IsLoopback) { return $true }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($Origin.DnsSafeHost, [ref]$ip)) { return $false }
    if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
    $bytes = $ip.GetAddressBytes()
    if ($bytes.Length -eq 16) { return ($bytes[0] -band 254) -eq 252 }
    return $bytes[0] -eq 10 -or ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)
}

function Install-Addon {
    $folder = $WowPath
    if (-not $folder) {
        $detected = & $node $bridge locate
        if ($LASTEXITCODE -ne 0) { $detected = $null }
        $hint = if ($detected) { " [Enter for $detected]" } else { '' }
        $folder = (Read-Host "World of Warcraft folder$hint").Trim().Trim('"')
        if (-not $folder) { $folder = $detected }
    }
    if (-not $folder) { throw 'Enter the World of Warcraft, _forever_, or Interface\AddOns folder.' }
    & $node $bridge install --wow $folder
    if ($LASTEXITCODE -eq 0) { Write-Host 'Select Start bridge when you are ready to connect to T3 Code.' }
}

function Start-Bridge {
    if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) {
        throw 'Select Install or update first to set up the addon in WoW: Forever.'
    }

    $saved = $null
    if (Test-Path -LiteralPath $sessionFile -PathType Leaf) {
        try { $saved = Get-Content -LiteralPath $sessionFile -Raw | ConvertFrom-Json } catch {
            Write-Warning 'The saved session could not be read. Paste a fresh pairing link.'
        }
    }
    $hint = if ($saved.origin -and $saved.session) { ' [Enter to reconnect]' } else { '' }
    if (-not $hint) { Write-Host 'Create a pairing link on the T3 Code host with network access enabled.' }
    $entered = Read-SecretText (Read-Host "Paste the T3 Code pairing link or server URL$hint" -AsSecureString)
    $reuse = -not $entered -and $saved.origin -and $saved.session
    $address = if ($reuse) { $saved.origin } else { $entered }
    $origin = $null
    if (-not [uri]::TryCreate($address, [UriKind]::Absolute, [ref]$origin) -or $origin.UserInfo -or $origin.Query) {
        throw 'Enter a complete T3 Code pairing link or server URL.'
    }
    if ($origin.Scheme -ne 'https' -and -not ($origin.Scheme -eq 'http' -and (Test-LocalAddress $origin))) {
        throw 'Use HTTPS or an HTTP URL with a private IP address on your local network.'
    }

    $pairingCode = $null
    if (-not $reuse -and $origin.AbsolutePath -eq '/pair' -and $origin.Fragment -cmatch '^#token=([A-Za-z0-9_-]+)$') {
        $pairingCode = $Matches[1]
    } elseif ($origin.AbsolutePath -ne '/' -or $origin.Fragment) {
        throw 'Paste the full pairing link with its code, or use just the server URL.'
    }

    $env:T3_ORIGIN = $origin.GetLeftPart([UriPartial]::Authority)
    try {
        $server = Invoke-RestMethod -Uri "$env:T3_ORIGIN/.well-known/t3/environment" -UseBasicParsing -TimeoutSec 8 -MaximumRedirection 0
    } catch {
        throw 'T3 Code could not be reached. Check that it is open and that network access is enabled on its host.'
    }
    if ($server.orchestrationProtocolVersion -ne 2) { throw 'This bridge needs T3 Code orchestration protocol 2.' }
    Write-Host 'T3 Code server found.'

    if ($pairingCode -or $reuse) {
        $securityModule = Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1'
        Import-Module -Name $securityModule
    }
    if ($pairingCode) {
        $env:T3_PAIRING_CODE = $pairingCode
        try {
            $token = & $node $bridge redeem-pairing
            if ($LASTEXITCODE -ne 0 -or -not $token) { throw 'Create a fresh pairing link with permission to read and operate threads.' }
            $env:T3_TOKEN = $token
        } finally {
            Remove-Item Env:T3_PAIRING_CODE -ErrorAction SilentlyContinue
        }

        $temporary = "$sessionFile.tmp"
        try {
            $secret = ConvertTo-SecureString -String $env:T3_TOKEN -AsPlainText -Force
            try {
                $saved = @{ origin = $env:T3_ORIGIN; session = (ConvertFrom-SecureString -SecureString $secret) }
            } finally {
                $secret.Dispose()
            }
            [IO.File]::WriteAllText($temporary, ($saved | ConvertTo-Json -Compress))
            Move-Item -LiteralPath $temporary -Destination $sessionFile -Force
            Write-Host 'Session saved for this Windows account. Press Enter next time to reconnect.'
        } catch {
            Write-Warning 'The session could not be saved. Use a fresh pairing link the next time you start the bridge.'
        } finally {
            Remove-Item -LiteralPath $temporary -ErrorAction SilentlyContinue
        }
    } elseif ($reuse) {
        try { $env:T3_TOKEN = Read-SecretText (ConvertTo-SecureString -String $saved.session) } catch {
            throw 'Windows could not read the saved session. Start again and paste a fresh pairing link.'
        }
    } else {
        $env:T3_TOKEN = Read-SecretText (Read-Host 'Paste a scoped T3 Code session token' -AsSecureString)
    }
    if (-not $env:T3_TOKEN) { throw 'A T3 Code session token is required.' }

    Write-Host 'Keep this window open while you play. Type /t3 in WoW. Press Ctrl+C to stop the bridge.'
    & $node $bridge run
}

function Invoke-Action([string] $Selected) {
    if ($Selected -in @('status', 'probe')) {
        & $node $bridge $Selected
        return
    }

    $mutex = [System.Threading.Mutex]::new($false, 'Local\T3CodeWowBridge')
    $ownsMutex = $false
    try {
        try { $ownsMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw 'T3 Code for WoW is already running in another window.' }

        switch ($Selected) {
            'install' { Install-Addon }
            'start' { Start-Bridge }
            'dictation' { & (Join-Path $PSScriptRoot 'install-dictation.ps1') -StateHome $env:XDG_STATE_HOME }
            'uninstall' {
                if (-not (Test-Path -LiteralPath $configFile -PathType Leaf)) { throw 'No installation is recorded for this launcher.' }
                & $node $bridge uninstall
            }
        }
    } finally {
        Remove-Item Env:T3_TOKEN, Env:T3_ORIGIN, Env:T3_PAIRING_CODE -ErrorAction SilentlyContinue
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

try {
    $node = (Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    $version = if ($node) { & $node --version }
    if ($LASTEXITCODE -ne 0 -or $version -notmatch '^v(\d+)\.' -or [int]$Matches[1] -lt 22) {
        throw 'Install Node.js 22 or newer from nodejs.org, then reopen this launcher.'
    }
    if (-not (Test-Path -LiteralPath $bridge -PathType Leaf)) { throw 'The bridge is missing. Keep this launcher in the complete t3code-wow checkout.' }

    if ($Action -ne 'menu') {
        Invoke-Action $Action
        exit $LASTEXITCODE
    }

    $choices = @{ '1' = 'install'; '2' = 'start'; '3' = 'status'; '4' = 'uninstall'; '5' = 'dictation' }
    while ($true) {
        Write-Host "`nT3 Code for WoW"
        Write-Host "1. Install or update`n2. Start bridge`n3. Status`n4. Uninstall`n5. Install dictation`nQ. Quit"
        $default = if (Test-Path -LiteralPath $configFile -PathType Leaf) { '2' } else { '1' }
        $choice = (Read-Host "Choose an action [Enter for $default]").Trim()
        if ($choice -eq 'q') { exit 0 }
        if (-not $choice) { $choice = $default }
        if (-not $choices.ContainsKey($choice)) { continue }
        try { Invoke-Action $choices[$choice] } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
    }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
