# Speak plain UTF-8 text supplied on stdin using the current Windows voice.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

try {
    $reader = [IO.StreamReader]::new([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)
    try {
        $text = $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
    }

    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $synthType = [Windows.Media.SpeechSynthesis.SpeechSynthesizer,Windows.Media.SpeechSynthesis,ContentType=WindowsRuntime]
    $streamType = [Windows.Media.SpeechSynthesis.SpeechSynthesisStream,Windows.Media.SpeechSynthesis,ContentType=WindowsRuntime]
    # Windows PowerShell needs the .NET task adapter to await a WinRT operation.
    $asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and
        $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1

    $synth = $synthType::new()
    try {
        $rate = 0.0
        if ([double]::TryParse($env:T3WOW_SPEECH_RATE, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$rate) -and
            $rate -ne 0 -and -not [double]::IsNaN($rate)) {
            $synth.Options.SpeakingRate = [Math]::Max(0.5, [Math]::Min(6.0, 1 + $rate / 175))
        }
        $operation = $synth.SynthesizeTextToStreamAsync($text)
        $task = $asTask.MakeGenericMethod($streamType).Invoke($null, @($operation))
        $speech = $task.GetAwaiter().GetResult()
        $wave = [IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($speech)
        try {
            $player = [Media.SoundPlayer]::new($wave)
            try {
                $player.PlaySync()
            } finally {
                $player.Dispose()
            }
        } finally {
            $wave.Dispose()
        }
    } finally {
        $synth.Dispose()
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.GetBaseException().Message)
    exit 1
}
