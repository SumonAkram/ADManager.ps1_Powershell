#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Menu-driven management of AD users and security groups.
    Asks for domain admin credentials once per session.
.NOTES
    Credentials are held in memory only and are never written to disk.
    Deleted user and group records are saved to the folder set in $LogFolder.
#>

Import-Module ActiveDirectory -ErrorAction Stop

# ---------- configuration (edit for your environment) ----------

$Domain      = "corp.example.com"
$UserOUPath  = "OU=Domainusers,DC=corp,DC=example,DC=com"
$GroupOUPath = "OU=Security Groups,DC=corp,DC=example,DC=com"
$LogFolder   = "C:\Scripts\DeletedUserLogs"

# ---------- helpers ----------

function Read-Required {
    param([string]$Prompt)
    do {
        $value = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Warning "This field is required."
        }
    } while ([string]::IsNullOrWhiteSpace($value))
    return $value.Trim()
}

function Read-YesNo {
    param([string]$Prompt)
    $answer = (Read-Host "$Prompt (Y/N)").Trim()
    return ($answer -match '^[Yy]$')
}

function Get-TargetUser {
    param($Cred, [string]$Logon)
    Get-ADUser -Filter "SamAccountName -eq '$Logon'" -SearchBase $UserOUPath -SearchScope OneLevel `
               -Properties Enabled, Description, MemberOf, ProtectedFromAccidentalDeletion `
               -Credential $Cred -Server $Domain -ErrorAction SilentlyContinue
}

function Read-LogonName {
    param([string]$Action)
    $logon = (Read-Host "Logon name to $Action").Trim()
    if ([string]::IsNullOrWhiteSpace($logon)) {
        Write-Warning "No logon name entered."
        return $null
    }
    return $logon
}

function Show-UserSummary {
    param($User)
    Write-Host "`nName        : $($User.Name)"
    Write-Host "Logon name  : $($User.SamAccountName)"
    Write-Host "Description : $($User.Description)"
    Write-Host "Enabled     : $($User.Enabled)"
    Write-Host "Groups      : $($User.MemberOf.Count)"
}

function Select-SecurityGroup {
    param($Cred)
    $groups = Get-ADGroup -Filter 'GroupCategory -eq "Security"' -Credential $Cred -Server $Domain |
              Sort-Object Name
    if (-not $groups) {
        Write-Warning "No security groups found in the domain."
        return @()
    }

    Write-Host "`n=== Security Groups ===" -ForegroundColor Cyan
    for ($i = 0; $i -lt $groups.Count; $i++) {
        "{0,3}. {1}" -f ($i + 1), $groups[$i].Name | Write-Host
    }

    $selection = Read-Host "Enter group numbers (comma-separated, e.g. 1,4,7) or press Enter to skip"
    if ([string]::IsNullOrWhiteSpace($selection)) { return @() }

    $indexes = $selection -split ',' |
               ForEach-Object { $_.Trim() } |
               Where-Object { $_ -match '^\d+$' } |
               ForEach-Object { [int]$_ } |
               Sort-Object -Unique

    $chosen = @()
    foreach ($idx in $indexes) {
        if ($idx -lt 1 -or $idx -gt $groups.Count) {
            Write-Warning "Skipping invalid selection: $idx"
            continue
        }
        $chosen += $groups[$idx - 1]
    }
    return $chosen
}

# ---------- user actions ----------

function New-OneUser {
    param($Cred)

    Write-Host "`n=== Create New AD User ===" -ForegroundColor Cyan
    $firstName = Read-Required "First name"
    $lastName  = Read-Required "Last name"
    $logon     = Read-Required "User logon name (sAMAccountName, e.g. jsmith)"
    $fullName  = "$firstName $lastName"
    $upn       = "$logon@$Domain"

    $existing = Get-ADUser -Filter "SamAccountName -eq '$logon' -or UserPrincipalName -eq '$upn'" `
                           -Credential $Cred -Server $Domain -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warning "A user with logon '$logon' already exists. Skipping."
        return
    }

    $securePwd = Read-Host "Initial password" -AsSecureString

    try {
        New-ADUser `
            -Name $fullName `
            -GivenName $firstName `
            -Surname $lastName `
            -DisplayName $fullName `
            -SamAccountName $logon `
            -UserPrincipalName $upn `
            -Path $UserOUPath `
            -AccountPassword $securePwd `
            -ChangePasswordAtLogon $true `
            -Enabled $true `
            -Credential $Cred `
            -Server $Domain `
            -ErrorAction Stop
        Write-Host "User '$fullName' created in $UserOUPath" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to create '$logon': $($_.Exception.Message)"
        return
    }

    if (Read-YesNo "`nAdd '$logon' to security groups now?") {
        $groups = @(Select-SecurityGroup -Cred $Cred)
        foreach ($group in $groups) {
            try {
                Add-ADGroupMember -Identity $group.DistinguishedName -Members $logon `
                                  -Credential $Cred -Server $Domain -ErrorAction Stop
                Write-Host "Added to: $($group.Name)" -ForegroundColor Green
            }
            catch {
                Write-Warning "Could not add to $($group.Name): $($_.Exception.Message)"
            }
        }
    }
}

function Add-UserToGroups {
    param($Cred)

    Write-Host "`n=== Add User to Security Groups ===" -ForegroundColor Cyan
    $logon = Read-LogonName "add to groups"
    if (-not $logon) { return }

    $user = Get-TargetUser -Cred $Cred -Logon $logon
    if (-not $user) {
        Write-Warning "No user '$logon' found in $UserOUPath."
        return
    }
    Show-UserSummary $user

    $groups = @(Select-SecurityGroup -Cred $Cred)
    if ($groups.Count -eq 0) { return }

    foreach ($group in $groups) {
        try {
            Add-ADGroupMember -Identity $group.DistinguishedName -Members $user.DistinguishedName `
                              -Credential $Cred -Server $Domain -ErrorAction Stop
            Write-Host "Added to: $($group.Name)" -ForegroundColor Green
        }
        catch {
            Write-Warning "Could not add to $($group.Name): $($_.Exception.Message)"
        }
    }
}

function Remove-UserFromGroups {
    param($Cred)

    Write-Host "`n=== Remove User from Security Groups ===" -ForegroundColor Cyan
    $logon = Read-LogonName "remove from groups"
    if (-not $logon) { return }

    $user = Get-TargetUser -Cred $Cred -Logon $logon
    if (-not $user) {
        Write-Warning "No user '$logon' found in $UserOUPath."
        return
    }
    Show-UserSummary $user

    if ($user.MemberOf.Count -eq 0) {
        Write-Host "'$logon' is not in any groups." -ForegroundColor DarkGray
        return
    }

    $groupList = foreach ($dn in $user.MemberOf) {
        Get-ADGroup -Identity $dn -Credential $Cred -Server $Domain
    }
    $groupList = @($groupList | Sort-Object Name)

    Write-Host "`nCurrent groups:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $groupList.Count; $i++) {
        "{0,3}. {1}" -f ($i + 1), $groupList[$i].Name | Write-Host
    }

    $selection = Read-Host "Enter numbers to REMOVE from (comma-separated), 'all', or press Enter to cancel"
    if ([string]::IsNullOrWhiteSpace($selection)) { return }

    if ($selection.Trim() -match '^all$') {
        $toRemove = $groupList
    }
    else {
        $indexes = $selection -split ',' |
                   ForEach-Object { $_.Trim() } |
                   Where-Object { $_ -match '^\d+$' } |
                   ForEach-Object { [int]$_ } |
                   Sort-Object -Unique
        $toRemove = @()
        foreach ($idx in $indexes) {
            if ($idx -lt 1 -or $idx -gt $groupList.Count) {
                Write-Warning "Skipping invalid selection: $idx"
                continue
            }
            $toRemove += $groupList[$idx - 1]
        }
    }

    if ($toRemove.Count -eq 0) { return }

    if (-not (Read-YesNo "Remove '$logon' from $($toRemove.Count) group(s)?")) {
        Write-Host "Not confirmed. Nothing was changed." -ForegroundColor DarkGray
        return
    }

    foreach ($group in $toRemove) {
        try {
            Remove-ADGroupMember -Identity $group.DistinguishedName -Members $user.DistinguishedName `
                                 -Credential $Cred -Server $Domain -Confirm:$false -ErrorAction Stop
            Write-Host "Removed from: $($group.Name)" -ForegroundColor Green
        }
        catch {
            Write-Warning "Could not remove from $($group.Name): $($_.Exception.Message)"
        }
    }
}

function Disable-OneUser {
    param($Cred)

    Write-Host "`n=== Disable AD User ===" -ForegroundColor Cyan
    $logon = Read-LogonName "DISABLE"
    if (-not $logon) { return }

    $user = Get-TargetUser -Cred $Cred -Logon $logon
    if (-not $user) {
        Write-Warning "No user '$logon' found in $UserOUPath."
        return
    }
    Show-UserSummary $user

    if (-not $user.Enabled) {
        Write-Warning "'$logon' is already disabled."
        return
    }

    if (-not (Read-YesNo "`nDisable '$logon'?")) {
        Write-Host "Not confirmed. Nothing was changed." -ForegroundColor DarkGray
        return
    }

    try {
        Disable-ADAccount -Identity $user.DistinguishedName -Credential $Cred -Server $Domain -ErrorAction Stop
        Write-Host "Account '$logon' is now disabled." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to disable '$logon': $($_.Exception.Message)"
        return
    }

    if ($user.MemberOf.Count -gt 0 -and (Read-YesNo "Also remove '$logon' from all $($user.MemberOf.Count) group(s)?")) {
        foreach ($groupDN in $user.MemberOf) {
            try {
                Remove-ADGroupMember -Identity $groupDN -Members $user.DistinguishedName `
                                     -Credential $Cred -Server $Domain -Confirm:$false -ErrorAction Stop
                Write-Host "Removed from: $groupDN" -ForegroundColor Green
            }
            catch {
                Write-Warning "Could not remove from ${groupDN}: $($_.Exception.Message)"
            }
        }
    }
}

function Remove-OneUser {
    param($Cred)

    Write-Host "`n=== Delete AD User ===" -ForegroundColor Red
    $logon = Read-LogonName "DELETE"
    if (-not $logon) { return }

    $user = Get-TargetUser -Cred $Cred -Logon $logon
    if (-not $user) {
        Write-Warning "No user '$logon' found in $UserOUPath."
        return
    }
    Show-UserSummary $user

    if (-not (Test-Path $LogFolder)) {
        New-Item -Path $LogFolder -ItemType Directory | Out-Null
    }
    $stamp   = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $logFile = Join-Path $LogFolder "$($logon)_$stamp.txt"

    $logLines = @(
        "Deleted AD user record"
        "Date        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Name        : $($user.Name)"
        "Logon name  : $($user.SamAccountName)"
        "Description : $($user.Description)"
        "Was enabled : $($user.Enabled)"
        "DN          : $($user.DistinguishedName)"
        ""
        "Group memberships:"
    )
    if ($user.MemberOf.Count -eq 0) {
        $logLines += "  (none)"
    }
    else {
        $logLines += $user.MemberOf | ForEach-Object { "  $_" }
    }
    $logLines | Set-Content -Path $logFile -Encoding UTF8
    Write-Host "`nRecord saved to: $logFile" -ForegroundColor DarkGray

    $confirm1 = (Read-Host "`nType the logon name again to confirm").Trim()
    if ($confirm1 -ne $logon) {
        Write-Warning "Logon name did not match. Nothing was deleted."
        return
    }

    if (-not (Read-YesNo "Permanently delete '$logon'?")) {
        Write-Host "Not confirmed. Nothing was deleted." -ForegroundColor DarkGray
        return
    }

    if ($user.ProtectedFromAccidentalDeletion) {
        try {
            Set-ADObject -Identity $user.DistinguishedName -ProtectedFromAccidentalDeletion $false `
                         -Credential $Cred -Server $Domain -ErrorAction Stop
        }
        catch {
            Write-Error "Could not remove deletion protection on '$logon': $($_.Exception.Message)"
            return
        }
    }

    try {
        Remove-ADUser -Identity $user.DistinguishedName -Credential $Cred -Server $Domain `
                      -Confirm:$false -ErrorAction Stop
        Write-Host "Account '$logon' has been deleted." -ForegroundColor Green
        Write-Host "Group list kept in: $logFile"
    }
    catch {
        Write-Error "Failed to delete '$logon': $($_.Exception.Message)"
    }
}

# ---------- group actions ----------

function New-OneGroup {
    param($Cred)

    Write-Host "`n=== Create Security Group ===" -ForegroundColor Cyan
    $name = Read-Required "Group name (e.g. FileShare-Finance)"

    $existing = Get-ADGroup -Filter "SamAccountName -eq '$name'" `
                            -Credential $Cred -Server $Domain -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warning "A group named '$name' already exists. Skipping."
        return
    }

    Write-Host "Scope: 1. Global   2. Universal   3. DomainLocal"
    $scopeChoice = (Read-Host "Choose scope (Enter = Global)").Trim()
    $scope = switch ($scopeChoice) {
        "2"     { "Universal" }
        "3"     { "DomainLocal" }
        default { "Global" }
    }

    $desc = (Read-Host "Description (optional)").Trim()

    try {
        New-ADGroup -Name $name -SamAccountName $name -GroupCategory Security `
                    -GroupScope $scope -Description $desc -Path $GroupOUPath `
                    -Credential $Cred -Server $Domain -ErrorAction Stop
        Write-Host "Created $scope security group '$name' in $GroupOUPath" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to create '$name': $($_.Exception.Message)"
    }
}

function Remove-OneGroup {
    param($Cred)

    Write-Host "`n=== Delete Security Group ===" -ForegroundColor Red
    $name = (Read-Host "Name of the group to DELETE").Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-Warning "No group name entered."
        return
    }

    $group = Get-ADGroup -Filter "SamAccountName -eq '$name'" -SearchBase $GroupOUPath -SearchScope OneLevel `
                         -Properties Description, AdminCount `
                         -Credential $Cred -Server $Domain -ErrorAction SilentlyContinue
    if (-not $group) {
        Write-Warning "No group '$name' found in $GroupOUPath."
        return
    }

    # AdminCount = 1 marks built-in privileged groups
    if ($group.AdminCount -eq 1) {
        Write-Error "'$name' is a protected group. Refusing to delete it here."
        return
    }

    $members = @(Get-ADGroupMember -Identity $group.DistinguishedName `
                 -Credential $Cred -Server $Domain -ErrorAction SilentlyContinue)

    Write-Host "`nName        : $($group.Name)"
    Write-Host "Description : $($group.Description)"
    Write-Host "Members     : $($members.Count)"

    if (-not (Test-Path $LogFolder)) {
        New-Item -Path $LogFolder -ItemType Directory | Out-Null
    }
    $stamp   = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $logFile = Join-Path $LogFolder "GROUP_$($name)_$stamp.txt"

    $logLines = @(
        "Deleted AD security group record"
        "Date        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Name        : $($group.Name)"
        "Description : $($group.Description)"
        "DN          : $($group.DistinguishedName)"
        ""
        "Members:"
    )
    if ($members.Count -eq 0) {
        $logLines += "  (none)"
    }
    else {
        $logLines += $members | ForEach-Object { "  $($_.SamAccountName)" }
    }
    $logLines | Set-Content -Path $logFile -Encoding UTF8
    Write-Host "`nRecord saved to: $logFile" -ForegroundColor DarkGray

    $confirm1 = (Read-Host "`nType the group name again to confirm").Trim()
    if ($confirm1 -ne $name) {
        Write-Warning "Group name did not match. Nothing was deleted."
        return
    }

    if (-not (Read-YesNo "Permanently delete group '$name'?")) {
        Write-Host "Not confirmed. Nothing was deleted." -ForegroundColor DarkGray
        return
    }

    try {
        Remove-ADGroup -Identity $group.DistinguishedName -Credential $Cred -Server $Domain `
                       -Confirm:$false -ErrorAction Stop
        Write-Host "Group '$name' has been deleted." -ForegroundColor Green
        Write-Host "Member list kept in: $logFile"
    }
    catch {
        Write-Error "Failed to delete '$name': $($_.Exception.Message)"
    }
}

# ---------- menu ----------

function Show-Menu {
    Write-Host "`n=============================" -ForegroundColor Cyan
    Write-Host " AD Manager  ($Domain)"        -ForegroundColor Cyan
    Write-Host "=============================" -ForegroundColor Cyan
    Write-Host " 1. Create user"
    Write-Host " 2. Add user to security groups"
    Write-Host " 3. Remove user from security groups"
    Write-Host " 4. Disable user"
    Write-Host " 5. Delete user"
    Write-Host " 6. Create security group"
    Write-Host " 7. Delete security group"
    Write-Host " 0. Exit"
}

# ---------- main ----------

# Step 1: admin login, asked once for the whole session
$cred = Get-Credential -Message "Domain admin login required (enter as DOMAIN\username)"
if (-not $cred) { exit 1 }

# Step 2: verify the login
try {
    $null = Get-ADDomain -Credential $cred -Server $Domain -ErrorAction Stop
}
catch {
    Write-Error "Authentication failed. Nothing was changed."
    Read-Host "Press Enter to close"
    exit 1
}

# Step 3: menu loop
do {
    Show-Menu
    $choice = (Read-Host "`nChoose an option").Trim()

    switch ($choice) {
        "1" { New-OneUser -Cred $cred }
        "2" { Add-UserToGroups -Cred $cred }
        "3" { Remove-UserFromGroups -Cred $cred }
        "4" { Disable-OneUser -Cred $cred }
        "5" { Remove-OneUser -Cred $cred }
        "6" { New-OneGroup -Cred $cred }
        "7" { Remove-OneGroup -Cred $cred }
        "0" { }
        default { Write-Warning "Invalid option '$choice'. Enter 0 to 7." }
    }
} while ($choice -ne "0")

Write-Host "`nDone." -ForegroundColor Cyan
Read-Host "Press Enter to close"
