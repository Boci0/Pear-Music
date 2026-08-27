# Sets the phone's signaling server URL via adb.
param (
    [Parameter(Mandatory=$true)]
    [string]$ServerUrl,
    [string]$DeviceId = [System.Guid]::NewGuid().ToString(),
    [string]$DeviceSecret = ""
)

$ErrorActionPreference = 'Stop'
$adb = if ($env:LOCALAPPDATA) { "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe" } else { "adb" }

$xml = @"
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <string name="flutter.peerm_device_secret">$DeviceSecret</string>
    <string name="flutter.peerm_device_id">$DeviceId</string>
    <string name="flutter.peerm_server_url">$ServerUrl</string>
</map>
"@

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($xml))
& $adb shell "run-as com.peerm.peerm_app sh -c 'echo $b64 | base64 -d > shared_prefs/FlutterSharedPreferences.xml'"
Write-Output '--- verify written prefs ---'
& $adb shell "run-as com.peerm.peerm_app cat shared_prefs/FlutterSharedPreferences.xml 2>&1"
