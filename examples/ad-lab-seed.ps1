# Seed a fresh Active Directory lab with OUs, groups and test users.
#
#   winserver create dc01 --domain lab.local --script examples/ad-lab-seed.ps1
#
# Runs at the end of setup, after the domain controller is up. The test users
# share one random password, written to C:\ProgramData\winserver\lab-users.csv.
# Lab use only.

Import-Module ActiveDirectory

$domain = Get-ADDomain
$root = "OU=Lab,$($domain.DistinguishedName)"

if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$root'" -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name 'Lab' -Path $domain.DistinguishedName
}
foreach ($ou in 'Users', 'Groups', 'Servers', 'Workstations', 'Service Accounts') {
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$ou'" -SearchBase $root -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $ou -Path $root
    }
}

$departments = 'IT', 'HR', 'Finance', 'Sales', 'Engineering'
foreach ($dept in $departments) {
    if (-not (Get-ADGroup -Filter "Name -eq 'GG-$dept'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name "GG-$dept" -GroupScope Global -GroupCategory Security -Path "OU=Groups,$root"
    }
}

# One readable random password for every test user, e.g. "Lab-k3Fq9xTz-2026".
$chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
$plain = 'Lab-' + (-join (1..8 | ForEach-Object { $chars | Get-Random })) + '-' + (Get-Date).Year
$secure = ConvertTo-SecureString $plain -AsPlainText -Force

$people = @(
    'Ada Lovelace', 'Alan Turing', 'Grace Hopper', 'Katherine Johnson', 'Linus Torvalds',
    'Margaret Hamilton', 'Dennis Ritchie', 'Barbara Liskov', 'Ken Thompson', 'Radia Perlman',
    'Tim Berners-Lee', 'Frances Allen', 'Vint Cerf', 'Hedy Lamarr', 'John McCarthy'
)
$rows = @()
$i = 0
foreach ($person in $people) {
    $first, $last = $person -split ' ', 2
    $sam = ($first.Substring(0, 1) + $last -replace '[^A-Za-z]', '').ToLower()
    $dept = $departments[$i % $departments.Count]
    $i++
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name $person -GivenName $first -Surname $last -SamAccountName $sam `
            -UserPrincipalName "$sam@$($domain.DNSRoot)" -Department $dept `
            -Path "OU=Users,$root" -AccountPassword $secure -Enabled $true -PasswordNeverExpires $true
        Add-ADGroupMember -Identity "GG-$dept" -Members $sam
    }
    $rows += [pscustomobject]@{ User = "$($domain.NetBIOSName)\$sam"; Name = $person; Department = $dept }
}

New-ADUser -Name 'svc-sql' -SamAccountName 'svc-sql' -Path "OU=Service Accounts,$root" `
    -AccountPassword $secure -Enabled $true -PasswordNeverExpires $true -ErrorAction SilentlyContinue

$csv = Join-Path $env:ProgramData 'winserver\lab-users.csv'
$rows | Export-Csv -Path $csv -NoTypeInformation
Add-Content -Path $csv -Value "# Password for all lab users: $plain"
Write-Host "[winserver] Created $($people.Count) users in $root. Details: $csv"
