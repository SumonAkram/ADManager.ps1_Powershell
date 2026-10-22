# AD Manager

A menu-driven PowerShell tool for managing Active Directory users and security groups. It asks for domain admin credentials once per session and confirms every change before making it.

## Features

- Create a user, with an optional security group step
- Add a user to one or more security groups
- Remove a user from security groups
- Disable a user, with an optional group removal step
- Delete a user, saving their group list to a log first
- Create a security group in a defined OU
- Delete a security group, saving its member list to a log first and refusing protected groups

## Requirements

- Windows 10/11 or Windows Server, joined to the target domain
- PowerShell 5.1 or later (included with Windows)
- RSAT: Active Directory module (see below)
- A domain account with permission to create users and modify groups in the target OUs

Local administrator rights on the PC are **not** needed to run the script. The script authenticates to Active Directory with the domain account you enter at the prompt.

## Installing RSAT

RSAT (Remote Server Administration Tools) provides the ActiveDirectory PowerShell module.

**Windows 10/11:** Open PowerShell **as administrator** and run:

```powershell
Add-WindowsCapability -Online -Name "Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0"
```

Wait for it to finish. The download can take several minutes.

**Windows Server:** Run:

```powershell
Install-WindowsFeature RSAT-AD-PowerShell
```

Confirm the module is available:

```powershell
Get-Module -ListAvailable ActiveDirectory
```

## Setup

1. Clone or download this repository to a folder, for example `C:\Scripts\ADManager`.
2. Open `ADManager.ps1` in a text editor and edit the **configuration** block at the top:
```powershell
   $Domain      = "corp.example.com"
   $UserOUPath  = "OU=Domainusers,DC=corp,DC=example,DC=com"
   $GroupOUPath = "OU=Security Groups,DC=corp,DC=example,DC=com"
   $LogFolder   = "C:\Scripts\DeletedUserLogs"
```
   - `$Domain`: your DNS domain name.
   - `$UserOUPath`: the full distinguished name of the OU where users are created.
   - `$GroupOUPath`: the full distinguished name of the OU where security groups are created.
   - `$LogFolder`: where deleted user and group records are saved.
3. Do not commit your edited values back to a public repository.

## Running

Double-click `Run-ADManager.bat`, or run it from a PowerShell window:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\ADManager.ps1
```

You'll be asked for the domain admin login first (`DOMAIN\username` and password). The script verifies it before showing the menu.

### Desktop shortcut

1. Right-click `Run-ADManager.bat` and choose **Send to → Desktop (create shortcut)**.
2. Right-click the new shortcut and choose **Properties**.
3. Leave **Run as administrator** unticked under **Advanced**. The script doesn't need local admin rights.

## Menu

| Option | Action |
|---|---|
| 1 | Create user |
| 2 | Add user to security groups |
| 3 | Remove user from security groups |
| 4 | Disable user |
| 5 | Delete user |
| 6 | Create security group |
| 7 | Delete security group |
| 0 | Exit |

Users are only found inside `$UserOUPath`, so the script can't change accounts elsewhere in the domain by accident.

## Safety

- Credentials are held in memory for the session and never written to disk.
- Create, disable, and delete ask for confirmation first.
- Deleting a user or group requires retyping the name and answering Y.
- Deleted user and group member lists are saved to `$LogFolder` before removal.
- Protected groups (`AdminCount = 1`), such as Domain Admins, can't be deleted from this tool.

## Logs

Records of deleted users and groups are saved to `$LogFolder` with a timestamp. These files contain real account and group names, so keep the folder restricted to administrators. The `.gitignore` file already excludes them from Git.

## Troubleshooting

| Message | Likely cause |
|---|---|
| `The script cannot be run because ... ActiveDirectory` | RSAT is not installed. See Installing RSAT. |
| `Authentication failed` | Wrong password or wrong domain. Check before retrying, because repeated failures can lock the account. |
| `Unable to contact the server` | The PC can't reach a domain controller. Check the network and that the PC is joined to the domain. |
| `Access is denied` | The account lacks permission on the target OU or group. |
| Window closes immediately | Run it through `Run-ADManager.bat`, which keeps the window open. |

## Disclaimer

Test in a lab or with a non-production account before using this against live directory data. Deleting users and groups can break access to files, mailboxes, and applications.
