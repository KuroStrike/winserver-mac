# winserver first-boot script.
#
# Runs once, as the built-in Administrator, at the first logon after Windows
# Setup (FirstLogonCommands in autounattend.xml). It installs drivers and the
# hypervisor's guest tools, turns on remote access, adds features, optionally
# promotes the server to a domain controller, then hands over to post-setup.ps1.

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$dst = Join-Path $env:ProgramData 'winserver'
New-Item -ItemType Directory -Force -Path $dst | Out-Null
# Administrators and SYSTEM only: settings.ps1 holds the password on a domain controller.
icacls.exe $dst /inheritance:r /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-18:(OI)(CI)F' | Out-Null
Start-Transcript -Path (Join-Path $dst 'firstboot.log') -Append | Out-Null

function Step([string]$Message) { Write-Host "[winserver] $Message" -ForegroundColor Cyan }

# First path that exists at the root of any CD drive, e.g. Find-OnCd 'PTAgent.exe'.
function Find-OnCd([string]$Relative) {
    $cds = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' | Where-Object VolumeName
    foreach ($cd in $cds) {
        $path = Join-Path "$($cd.DeviceID)\" $Relative
        if (Test-Path $path) { return $path }
    }
}

# VMware Tools, Parallels Tools or VirtualBox Guest Additions, from whichever
# tools disc the hypervisor attached. They bring the network driver on ARM64.
function Install-GuestTools {
    $cs = Get-CimInstance Win32_ComputerSystem
    $platform = "$($cs.Manufacturer) $($cs.Model)"
    Write-Host "[winserver] Platform: $platform"

    if ($platform -match 'VMware') {
        $vmxnet3 = Find-OnCd 'vmxnet3'
        if ($vmxnet3) {
            Step 'Installing VMware Tools'
            $root = Split-Path -Parent $vmxnet3
            # Drivers from the folders only: autorun.inf at the root is not one.
            Get-ChildItem -Path $root -Directory | ForEach-Object {
                pnputil.exe /add-driver (Join-Path $_.FullName '*.inf') /subdirs /install | Out-Host
            }
            $setup = $null
            foreach ($exe in 'setup64.exe', 'setup.exe') {
                if (-not $setup -and (Test-Path (Join-Path $root $exe))) { $setup = Join-Path $root $exe }
            }
            if ($setup) { Start-Process -FilePath $setup -ArgumentList '/S /v"/qn REBOOT=R"' -Wait }
        }
    }
    elseif ($platform -match 'Parallels') {
        $agent = Find-OnCd 'PTAgent.exe'
        if ($agent) {
            Step 'Installing Parallels Tools'
            Start-Process -FilePath $agent -ArgumentList '/install_silent' -Wait
        }
    }
    elseif ($platform -match 'VirtualBox|innotek|ORCL') {   # ARM64: "ORCL__ VBOXDSDT"
        $exe = $null
        if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $exe = Find-OnCd 'VBoxWindowsAdditions-arm64.exe' }
        if (-not $exe) { $exe = Find-OnCd 'VBoxWindowsAdditions.exe' }
        if ($exe) {
            Step 'Installing VirtualBox Guest Additions'
            # Trust Oracle's driver certificates first, or the silent install stops at a prompt.
            $cert = Join-Path (Split-Path -Parent $exe) 'cert'
            $util = Join-Path $cert 'VBoxCertUtil.exe'
            if (Test-Path $util) {
                Get-ChildItem -Path $cert -Filter 'vbox*.cer' | ForEach-Object {
                    & $util add-trusted-publisher $_.FullName --root $_.FullName | Out-Null
                }
            }
            Start-Process -FilePath $exe -ArgumentList '/S' -Wait
            # Otherwise it waits for a reboot, and `winserver stop` needs it.
            Start-Service -Name VBoxService -ErrorAction SilentlyContinue
        }
    }
}

# The first usable IPv4 address, waiting for DHCP if needed.
function Wait-Network([int]$Seconds = 180) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
            Select-Object -First 1
        if ($ip) { return $ip }
        Start-Sleep -Seconds 5
    }
}

# The setup discs are detached once the install is done, so keep the payload on C:.
# (On an all-in-one ISO the payload sits next to the Windows media: copy only ours.)
'firstboot.ps1', 'post-setup.ps1', 'settings.ps1', 'custom.ps1', 'authorized_keys' |
    ForEach-Object { Join-Path $src $_ } | Where-Object { Test-Path $_ } |
    Copy-Item -Destination $dst -Force
. (Join-Path $dst 'settings.ps1')

if (Test-Path (Join-Path $src 'drivers')) {
    Step 'Installing virtio drivers'
    pnputil.exe /add-driver (Join-Path $src 'drivers\*.inf') /subdirs /install | Out-Host
}
Install-GuestTools

Step 'Applying lab defaults'
# The built-in Administrator is renamed in some languages; find it by its well-known RID.
$admin = Get-LocalUser | Where-Object { $_.SID.Value -like 'S-1-5-*-500' }
if ($admin) { Set-LocalUser -SID $admin.SID -PasswordNeverExpires $true }
Enable-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -ErrorAction SilentlyContinue   # Remote Desktop
Get-NetFirewallRule -Name 'FPS-ICMP4-ERQ-In*', 'CoreNet-Diag-ICMP4-EchoRequest-In*' -ErrorAction SilentlyContinue |
    Set-NetFirewallRule -Enabled True -Profile Any   # VM networks usually come up as Public
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
# A lab VM must stay reachable: no sleep, no hibernation, no blank screen.
'standby-timeout-ac', 'hibernate-timeout-ac', 'monitor-timeout-ac' | ForEach-Object { powercfg.exe /change $_ 0 }

$ip = Wait-Network
if ($ip) { Step "Network is up: $($ip.IPAddress)" } else { Write-Warning 'No IPv4 address after 3 minutes' }

if ($WS_Features.Count -gt 0) {
    Step "Installing features: $($WS_Features -join ', ')"
    Install-WindowsFeature -Name $WS_Features -IncludeManagementTools | Out-Host
}

if ($WS_Role -eq 'ad-dc') {
    Step "Promoting this server to the first domain controller of $WS_Domain"

    # A DC wants a fixed address: pin the one DHCP handed out, with its gateway and DNS.
    if ($ip) {
        $i = $ip.InterfaceIndex
        $gateway = (Get-NetRoute -InterfaceIndex $i -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Select-Object -First 1).NextHop
        $dns = (Get-DnsClientServerAddress -InterfaceIndex $i -AddressFamily IPv4).ServerAddresses
        Set-NetIPInterface -InterfaceIndex $i -Dhcp Disabled
        Get-NetIPAddress -InterfaceIndex $i -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
        Get-NetRoute -InterfaceIndex $i -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
        $static = @{ InterfaceIndex = $i; IPAddress = $ip.IPAddress; PrefixLength = $ip.PrefixLength }
        if ($gateway) { $static.DefaultGateway = $gateway }
        New-NetIPAddress @static | Out-Null
        if ($dns) { Set-DnsClientServerAddress -InterfaceIndex $i -ServerAddresses $dns }
    }

    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Host

    # After the promotion reboot, log on once as DOMAIN\Administrator and let a
    # logon task finish the job (Run keys are not processed on Server Core).
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $winlogon -Name AutoAdminLogon -Value '1'
    Set-ItemProperty -Path $winlogon -Name DefaultUserName -Value 'Administrator'
    Set-ItemProperty -Path $winlogon -Name DefaultDomainName -Value $WS_Netbios
    Set-ItemProperty -Path $winlogon -Name DefaultPassword -Value $WS_Password
    New-ItemProperty -Path $winlogon -Name AutoLogonCount -Value 1 -PropertyType DWord -Force | Out-Null

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dst\post-setup.ps1`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-544' -RunLevel Highest
    Register-ScheduledTask -TaskName 'winserver-post-setup' -Action $action -Trigger $trigger `
        -Principal $principal -Force | Out-Null

    $dsrm = ConvertTo-SecureString $WS_Password -AsPlainText -Force
    # Reboots when it is done.
    Install-ADDSForest -DomainName $WS_Domain -DomainNetbiosName $WS_Netbios -InstallDns `
        -SafeModeAdministratorPassword $dsrm -Force -WarningAction SilentlyContinue | Out-Host
    Stop-Transcript | Out-Null
    exit 0
}

Stop-Transcript | Out-Null
& (Join-Path $dst 'post-setup.ps1')
