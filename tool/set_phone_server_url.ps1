# Sets the phone's signaling server URL to the PC's embedded server
# (ws://10.84.188.119:8080), preserving the existing device id/secret.
$ErrorActionPreference = 'Stop'
$adb = 'C:\Users\muhdb\AppData\Local\Android\Sdk\platform-tools\adb.exe'

$xml = @'
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <string name="flutter.peerm_device_secret">138e882888efa3a8d489225ecc75aa945974c7f7b225414a</string>
    <string name="flutter.peerm_device_id">bdc33e9b-8b63-45ae-9dd8-2c37aa1d7b36</string>
    <string name="flutter.peerm_server_url">ws://10.84.188.119:8080</string>
</map>
'@

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($xml))
& $adb shell "run-as com.peerm.peerm_app sh -c 'echo $b64 | base64 -d > shared_prefs/FlutterSharedPreferences.xml'"
Write-Output '--- verify written prefs ---'
& $adb shell "run-as com.peerm.peerm_app cat shared_prefs/FlutterSharedPreferences.xml 2>&1"
