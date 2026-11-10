# Record the default Windows microphone as a 16 kHz mono WAV for transcription.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Send-RecorderCommand([string]$command, [string]$action) {
    $result = [T3Wow.AudioRecorder]::mciSendString($command, $null, 0, [IntPtr]::Zero)
    if ($result -ne 0) {
        $message = [Text.StringBuilder]::new(256)
        if (-not [T3Wow.AudioRecorder]::mciGetErrorString($result, $message, $message.Capacity)) {
            [void]$message.Append("Windows audio error $result")
        }
        throw "Could not ${action}. $message"
    }
}

try {
    # Keep this path short for the legacy waveaudio driver.
    $wave = $env:T3WOW_DICTATION_WAV
    if (-not $wave) { throw 'Missing dictation WAV path.' }

    Add-Type -Namespace T3Wow -Name AudioRecorder -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("winmm.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern uint mciSendString(string command, System.Text.StringBuilder buffer, uint length, System.IntPtr callback);

[System.Runtime.InteropServices.DllImport("winmm.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool mciGetErrorString(uint code, System.Text.StringBuilder buffer, uint length);
'@

    Send-RecorderCommand 'open new type waveaudio alias t3wow' 'open the Windows audio recorder'
    try {
        Send-RecorderCommand 'set t3wow format tag pcm channels 1 samplespersec 16000 bitspersample 16 alignment 2 bytespersec 32000' 'set the microphone recording format'
        Send-RecorderCommand 'record t3wow' 'start recording. Check the default input device and desktop microphone access in Windows Settings'
        # A closed pipe or any command other than "stop" discards the recording.
        if ([Console]::ReadLine() -ceq 'stop') {
            Send-RecorderCommand 'stop t3wow wait' 'stop recording'
            Send-RecorderCommand ('save t3wow "{0}" wait' -f $wave) 'save the recording'
        }
    } finally {
        [void][T3Wow.AudioRecorder]::mciSendString('close t3wow', $null, 0, [IntPtr]::Zero)
    }
} catch {
    [Console]::Error.WriteLine($_.Exception.GetBaseException().Message)
    exit 1
}
