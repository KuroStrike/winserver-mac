# winserver post-setup script.
#
# Last stage of the install: runs your custom script, then enables OpenSSH.
# The SSH banner on the forwarded port is how `winserver wait` on the Mac
# knows the VM is ready, so sshd must be the very last thing to come up.

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$dst = Join-Path $env:ProgramData 'winserver'
Start-Transcript -Path (Join-Path $dst 'post-setup.log') -Append | Out-Null
. (Join-Path $dst 'settings.ps1')

function Step([string]$Message) { Write-Host "[winserver] $Message" -ForegroundColor Cyan }

if ($WS_Role -eq 'ad-dc') {
    Step 'Waiting for Active Directory Web Services'
    $deadline = (Get-Date).AddMinutes(15)
    $ready = $false
    while (-not $ready -and (Get-Date) -lt $deadline) {
        try { Get-ADDomain -ErrorAction Stop | Out-Null; $ready = $true }
        catch { Start-Sleep -Seconds 10 }
    }
    if ($ready) { Set-ADUser -Identity Administrator -PasswordNeverExpires $true }
    else { Write-Warning 'Active Directory did not come up within 15 minutes' }

    # The first DC of a forest is the domain's time source, and by default it
    # trusts only its own clock. Sync it from the internet instead.
    Step 'Syncing the domain clock with time.windows.com'
    w32tm.exe /config /manualpeerlist:time.windows.com,0x8 /syncfromflags:manual /reliable:yes /update | Out-Null
    Restart-Service -Name w32time
}

$custom = Join-Path $dst 'custom.ps1'
if (Test-Path $custom) {
    Step 'Running your custom script'
    try { & $custom } catch { Write-Warning "custom script failed: $_" }
}

Step 'Enabling OpenSSH Server'
if (-not (Get-Service -Name sshd -ErrorAction SilentlyContinue)) {
    # Built into Windows Server 2025. Older builds fetch it from Windows Update.
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
}
$sshKey = 'HKLM:\SOFTWARE\OpenSSH'
if (-not (Test-Path $sshKey)) { New-Item -Path $sshKey | Out-Null }
New-ItemProperty -Path $sshKey -Name DefaultShell -PropertyType String -Force `
    -Value (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') | Out-Null

$keys = Join-Path $dst 'authorized_keys'
if (Test-Path $keys) {
    $sshDir = Join-Path $env:ProgramData 'ssh'
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
    $adminKeys = Join-Path $sshDir 'administrators_authorized_keys'
    Copy-Item -Path $keys -Destination $adminKeys -Force
    # sshd ignores this file unless only Administrators and SYSTEM can touch it.
    icacls.exe $adminKeys /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
}
# Windows Server 2025 ships this rule for the Private profile only, while VM
# networks usually come up as Public: open it everywhere, or sshd is unreachable.
$sshRule = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if ($sshRule) {
    $sshRule | Set-NetFirewallRule -Enabled True -Profile Any
} else {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Profile Any `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}
Set-Service -Name sshd -StartupType Automatic
if ($WS_Role -eq 'ad-dc') {
    # After a reboot, a DC accepts SSH connections before it can log anyone on,
    # and `winserver wait` would report it ready too early. Start sshd later.
    sc.exe config sshd start= delayed-auto | Out-Null
}
Start-Service -Name sshd

Step 'Cleaning up'
Unregister-ScheduledTask -TaskName 'winserver-post-setup' -Confirm:$false -ErrorAction SilentlyContinue
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '0'
Remove-ItemProperty -Path $winlogon -Name DefaultPassword -ErrorAction SilentlyContinue
# settings.ps1 may hold the password (domain controllers); it is no longer needed.
Remove-Item -Path (Join-Path $dst 'settings.ps1') -Force -ErrorAction SilentlyContinue
# Setup keeps a copy of the answer file with the Administrator password, merely
# base64-encoded and readable by every local user.
Remove-Item -Path (Join-Path $env:WINDIR 'Panther\unattend-original.xml') -Force -ErrorAction SilentlyContinue
Set-Content -Path (Join-Path $dst 'done') -Value (Get-Date -Format o)

Step 'Done. This server is ready.'
Stop-Transcript | Out-Null
