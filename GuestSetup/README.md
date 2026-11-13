# AdoServerLabAutoOrchestrator guest setup

For a **non-production Windows Server or supported Windows 10/11 VM in Domain or Workgroup mode**. No Azure deployment,
domain creation/join, disk formatting, backups or VM images.

## Scripts

| Script | Purpose |
|---|---|
| [Setup-Server.ps1](Setup-Server.ps1) | Select options, validate prerequisites and start/resume setup. |
| [Resume-Setup.ps1](Resume-Setup.ps1) | Worker run by Task Scheduler; installs, configures and resumes after reboots. |
| [Setup-Releases.psm1](Setup-Releases.psm1) | Shared PowerShell module for product pairings, OS requirements, download URLs and patch catalogs; required beside the worker. |
| [Setup-State.psm1](Setup-State.psm1) | Shared module for plan validation, patch selection, stage lists, saved-state I/O and schema migration; required beside the worker and release module. |
| [Monitor-Setup.ps1](Monitor-Setup.ps1) | Read-only dashboard showing the current stage's logs. |
| [Setup-Monitoring.psm1](Setup-Monitoring.psm1) | Shared read-only log selection/tails for the console monitor and setup UI; keep beside the monitor. Not needed by the reboot worker. |
| [Test-GuestSetup.ps1](Test-GuestSetup.ps1) | Offline tests with mocked installers/reboots; used by `-ValidateOnly` or run directly. |

The worker imports both modules automatically; no manual `Import-Module`
or machine-wide module installation is needed. The release module exports only
`Get-SetupRelease`, `Assert-SetupOperatingSystem` and `Get-SetupPatchCatalog`.
The state module exports its eleven public plan/state/hostname/OS-acknowledgement functions and imports its
release dependency from the same folder. Installer and reboot orchestration
remain in the worker. Keep both `.psm1` files with the updated scripts. Existing setup commands are unchanged;
the old `.ps1` release helper is no longer used.

## Prerequisites

| Requirement | Details |
|---|---|
| OS | Native x64 Windows and x64 PowerShell; supported pairings are listed below. Server workflows target Desktop Experience, not Server Core. No ARM/x86, Home editions or domain controllers. |
| Membership | Domain (default): already joined, healthy secure channel, AD DNS configured. Workgroup: explicitly choose `-JoinMode Workgroup` on a non-domain-joined VM. Domain controllers are rejected. |
| Account | Local administrator; elevated Windows PowerShell 5.1. Domain administrator not required. Workgroup requires a local Windows account such as `VMNAME\tfsadmin`, with a password, not a PIN. |
| Resources | Suggested 4 vCPU / 16 GB RAM; at least 35 GB free on C: for fresh SQL, plus space for SSMS/projects. |
| Network | Outbound HTTPS to Microsoft, Visual Studio Installer endpoints and GitHub. Configure NSGs/private access yourself. |
| Resume permissions | Task Scheduler password logon and log on as a batch job; do not weaken domain policies. |
| Licensing | SQL Developer and DevOps evaluation are lab-only; accept applicable terms. No trial extension/bypass. |

### Supported OS validation

The CLI, UI and reboot/resume worker use the same OS guard. Setup detects the OS;
strict validation is the default. An explicit lab-only OS version/build override
is described below; it does not change the supported pairings.

| Version option | Windows Server pairing | Client Windows pairing | Local SQL | SSMS |
|---|---|---|---|---|
| `2020` | Server 2019 | Windows 10 Enterprise 1803; Pro/Enterprise 1809 through 22H2 | SQL 2019 Developer | 22 on Server; archived 20.2.1 on Windows 10 |
| `2022.1` (Update 1) | Server 2022 | Windows 11 24H2 Pro/Enterprise/Education, non-LTSC | SQL 2022 Developer | 22 |
| `2022` (Update 2) | Server 2022 | Windows 11 24H2 Pro/Enterprise/Education, non-LTSC | SQL 2022 Developer | 22 |
| `25H2` | Server 2022 or Server 2025 | Windows 11 24H2 Pro/Enterprise/Education, non-LTSC | SQL 2025 Enterprise Developer | 22 |

These are this automation's selected pairings, not every combination Microsoft
supports. Existing older-release server pairings remain deliberately narrower.
25H2 accepts only the explicitly listed Server 2022/2025 builds, not arbitrary
future Windows Server versions. Windows 11 25H2/26H1 and Insider builds are not
automatically accepted in strict mode. Windows editions are checked using their SKU, not a
localized product caption. Pro N/Workstation/Pro Education and Enterprise N
variants follow their parent edition; Windows 10 Education is not offered.

**Client installations are for evaluation or personal use only**, not a
production/team hosting recommendation. Azure DevOps Server Proxy is not
supported on client Windows. Windows/IIS concurrency limits still apply.
An OS appearing in an Azure DevOps compatibility table does not restore its
Windows lifecycle support. Review lifecycle/ESU requirements before using older
Windows 10 images; older Windows and SSMS releases can lack current security fixes.

For client DevOps installations, read-only preflight requires the IIS feature
set including Windows Authentication and ASP.NET 4.x. The worker enables these
features with dependencies and no immediate restart. When Windows requires a
restart, setup saves its boot timestamp and reboots **without advancing the
installation stage**; the startup task rechecks prerequisites and continues.
Feature-source/policy failures are reported rather than bypassed. `SqlOnly`
does not enable IIS. Domain/Workgroup, DNS, certificate, Private-network
firewall and original-account/password requirements are unchanged.

Windows 10 uses the Microsoft-signed **SSMS 20.2.1** installer (build 20.2.37.0),
not the current SSMS 22. Its legacy installer switches and installed version
are verified separately; other SSMS versions are not removed. Local SMTP capture
is **not offered on Windows 10**: the pinned smtp4dev 3.15.0 uses .NET 10, whose
OS matrix does not cover every documented Windows 10 lab version. The UI shows
None and disables capture; the CLI defaults to None and rejects explicit
`-Email Capture` rather than silently accepting it. Configure external test
mail separately if needed. Windows 11 and Server retain optional local capture.

Sources: [Azure DevOps OS/SQL requirements](https://learn.microsoft.com/en-us/azure/devops/server/requirements),
[SQL 2019 requirements](https://learn.microsoft.com/en-us/sql/sql-server/install/hardware-and-software-requirements-for-installing-sql-server-2019),
[SQL 2022 requirements](https://learn.microsoft.com/en-us/sql/sql-server/install/hardware-and-software-requirements-for-installing-sql-server-2022),
[SQL 2025 requirements](https://learn.microsoft.com/en-us/sql/sql-server/install/hardware-and-software-requirements-for-installing-sql-server-2025),
[SSMS 22 requirements](https://learn.microsoft.com/en-us/ssms/system-requirements),
[SSMS 20.2.1 release/download](https://learn.microsoft.com/en-us/ssms/release-notes-20)
and [.NET 10 OS support](https://github.com/dotnet/core/blob/main/release-notes/10.0/supported-os.md).

### Trying an unsupported OS version/build

For disposable lab reproduction only, explicitly choose **Try unsupported OS
(lab only; may fail)** in the UI, or supply `-AllowUnsupportedOs` for a **new**
CLI plan:

```powershell
.\Setup-Server.ps1 -Version 2022 -JoinMode Workgroup -Components Both -Email Capture -Patch Latest -AllowUnsupportedOs -AcceptLicenseTerms
```

This bypasses only the Windows version/build pairing check. It can allow older,
newer or otherwise unlisted Windows builds; it does **not** make them supported,
guarantee compatibility, or bypass the Microsoft installers' own checks.
Setup displays a warning and saves the Boolean acknowledgement in schema 6.
The UI repeats the warning before launching and displays the saved acknowledgement
on subsequent opens. Reboots and `-Resume` reuse that saved choice without a
new prompt; both OS radio buttons are locked for an existing plan.

Architecture/native x64 PowerShell, client edition, domain-controller,
membership/account, DNS, firewall, IIS, SQL and data-protection checks still
apply. Home/unsupported client editions cannot be overridden. Windows 10 SMTP
capture remains unavailable, even with this switch. Other components such as
SQL, SSMS or smtp4dev may still fail on an unlisted OS; failures are reported
normally, not treated as success. No Proxy support is added to client Windows.

The switch is not accepted with `-Resume`: the saved acknowledgement cannot
be enabled/changed through resume. Legacy schema 1-5 plans migrate with
`AllowUnsupportedOs = false`; migration never grants an override or reopens
completed setup. Use a fresh lab plan rather than overwriting installed
software/data or manually weakening an existing plan.

Example on a fresh Windows 11 24H2 Pro/Enterprise/Education workgroup VM:

```powershell
.\Setup-Server.ps1 -Version 2022 -JoinMode Workgroup -Components Both -Email Capture -Patch Latest -AcceptLicenseTerms
```

Example on a fresh supported Windows 10 Pro/Enterprise workgroup VM:

```powershell
.\Setup-Server.ps1 -Version 2020 -JoinMode Workgroup -Components Both -Email None -Patch Latest -AcceptLicenseTerms
```

## Start

### Azure DevOps Server 26H2 RC (preview / lab)

`-Version 26H2-RC` installs the **October 27, 2026 Release Candidate**, not
the final release. It is an explicit opt-in; the default remains stable `25H2`.
Use a fresh disposable test VM. The selected pairing is SQL 2025 Enterprise
Developer with Windows Server 2022/2025, or Windows 11 24H2 with the same
edition/prerequisite checks as `25H2`. OS override, Domain/Workgroup, HTTPS,
SMTP capture and reboot/resume retain their existing rules.

```powershell
.\Setup-Server.ps1 -Version 26H2-RC -JoinMode Workgroup -Components Both -Email Capture -Patch Skip -AcceptLicenseTerms
```

The RC uses its own official installer (`LinkId=2383605`). Its standalone
patch catalog is currently empty: omitted `-Patch` and `-Patch Latest` resolve
to saved `Skip`; numeric patches are rejected. **25H2 patches do not apply.**
The UI labels this option as preview/lab and disables its patch selector.
No state-schema change is required. Saved plans retain `26H2-RC` and its
prerelease warning across monitoring/reboot/resume.

This automation still supports **fresh installations only**, not upgrades
of existing servers or RC-to-final upgrades. Offline tests do not establish
live RC installation compatibility.

Sources: [26H2 RC release notes](https://learn.microsoft.com/en-us/azure/devops/server/release-notes/azuredevopsserver26h2),
[official download catalog](https://learn.microsoft.com/en-us/azure/devops/server/download/azuredevopsserver)
and [current OS/SQL requirements](https://learn.microsoft.com/en-us/azure/devops/server/requirements).

```powershell
.\Setup-Server.ps1 -AcceptLicenseTerms
```

**2020.1.2 + SQL 2019 + Both**, on a fresh Windows Server 2019 member VM:

```powershell
.\Setup-Server.ps1 -Version 2020 -Components Both -DomainName ak.com -Email Capture -Patch Latest -AcceptLicenseTerms
```

This selects SQL Server 2019 Developer (15.x), DevOps Server 2020.1.2,
optional local mail capture and latest stable SSMS 22. SSMS 22 supports Windows
Server 2019 and SQL Server 2019. The existing `2022` and `25H2` pairings are unchanged.
Compatibility source: [Microsoft's archived 2020 requirements](https://learn.microsoft.com/en-us/previous-versions/azure/devops/server/requirements?view=azure-devops-2020).

**2022 + Both** (replace `ak.com` with the VM's joined domain):

```powershell
.\Setup-Server.ps1 -Version 2022 -Components Both -DomainName ak.com -Email Capture -AcceptLicenseTerms
```

**2022 Update 1 + SQL 2022**, for controlled lab reproduction on a fresh Windows
Server 2022 VM:

```powershell
.\Setup-Server.ps1 -Version 2022.1 -Components Both -DomainName ak.com -Email Capture -Patch Latest -AcceptLicenseTerms
```

`2022.1` selects **Update 1**, with its own executable patches 1-4 (Latest = 4).
`2022` continues to select **Update 2**, patches 1-12 (Latest = 12). These patch
families are not interchangeable. Update 1 is older and lacks later Update 2
security fixes; use it for reproduction rather than a new production deployment.
This option is a fresh installation, not an upgrade/downgrade of an existing
server. Domain and Workgroup options both apply.
Sources: [Update 1 release notes](https://learn.microsoft.com/en-us/azure/devops/server/release-notes/azuredevops2022u1),
[official downloads](https://learn.microsoft.com/en-us/azure/devops/server/download/azuredevopsserver)
and [published patch hashes](https://learn.microsoft.com/en-us/azure/devops/server/release-notes/azuredevops2022-sha).

**25H2 + Both**, on a separate fresh VM:

```powershell
.\Setup-Server.ps1 -Version 25H2 -Components Both -DomainName ak.com -Email Capture -AcceptLicenseTerms
```

### Workgroup (no AD domain)

Use the same OS/product pairing on a fresh non-domain-joined server:

```powershell
# URL/certificate default to this VM's hostname.
.\Setup-Server.ps1 -JoinMode Workgroup -Version 2022 -Components Both -Email Capture -Patch Latest -AcceptLicenseTerms

# Optional existing DNS record; replace with a name you control pointing to this VM.
.\Setup-Server.ps1 -JoinMode Workgroup -DnsHostName devops.lab.example.com -Version 2022 -Components Both -Email Capture -Patch Latest -AcceptLicenseTerms
```

`Domain` remains the default; neither mode joins/unjoins a domain or creates user
accounts/DNS records. In Workgroup mode, `-DomainName` is not accepted. The saved
workgroup name is detected separately from the selected web hostname.

The default workgroup URL is `https://<vm-name>/tfs`; custom DNS produces
`https://<custom-name>/tfs`. Alternative HTTPS ports are included in the URL.
The same saved hostname supplies the certificate SAN, IIS binding, DevOps public
URL and authenticated health checks. Custom DNS must resolve **only to this VM's
non-loopback IP addresses** before installation and again before configuration.
No IP-literal URLs, wildcards or `localhost` are accepted. Remote engineers must
also be able to resolve the selected name; the script does not distribute hosts
entries or change DNS.

Self-signed certificates are trusted on the server only. Remote clients need
approved certificate trust; do not disable TLS validation. For custom workgroup
names, setup preserves existing `BackConnectionHostNames` and adds only the
selected name as `REG_MULTI_SZ` for local Windows-authenticated verification.
It does **not** set `DisableLoopbackCheck`. A successful custom-host configuration
requests a reboot before later stages; this uses the normal saved-stage resume
workflow.

Workgroup HTTPS/Git SSH firewall rules apply to **Private / LocalSubnet** only.
Before starting DevOps setup, review `Get-NetConnectionProfile` and set only your
trusted intended interface to Private through approved network administration.
No Public profile rules or network-profile changes are made by setup. `SqlOnly`
does not require DevOps firewall/DNS preflight.

Workgroup access uses suitable local Windows accounts and Azure DevOps
permissions; accounts on clients do not provide AD single sign-on. Create/grant
remote engineers' accounts/permissions separately and follow your NTLM policies.
Resume uses the original local account's saved password/SID. Existing saved
domain plans cannot be converted to workgroup or another hostname by resume.

## Options and user input

| Parameter | Values / default | When to use |
|---|---|---|
| `-Version` | `2020`, `2022.1`, `2022`, `25H2`, `26H2-RC`; prompt defaults to `25H2` | New plan's product pairing. `2020` means 2020.1.2; `2022.1` means Update 1; `2022` remains Update 2; `26H2-RC` is the opt-in Release Candidate. |
| `-Components` | `Both`, `SqlOnly`, `DevOpsOnly`; prompt defaults to `Both` | New plan's installation scope. |
| `-AllowUnsupportedOs` | Off by default; new plans only | Explicit lab acknowledgement to bypass OS version/build pairing only. Saved for reboot/resume; all other prerequisite checks remain active. |
| `-JoinMode` | `Domain` (default), `Workgroup` | Match existing VM membership; does not join/unjoin. |
| `-DnsHostName` | Domain: `<vm>.<joined-domain>`; Workgroup: `<vm>` | Workgroup optionally accepts an existing custom DNS hostname pointing to this VM. Saved choice is immutable on resume. |
| `-DomainName` | Existing AD domain; prompt defaults to detected domain | Domain mode only; does not join/change it. |
| `-SqlInstance` | `localhost`; `DevOpsOnly` also accepts a local named instance | Existing local SQL. `Both`/`SqlOnly` require `localhost`. |
| `-Email` | `Capture`, `None`; prompt defaults to `Capture` | Local test email capture or disabled notifications. `SqlOnly` forces `None`. |
| `-Patch` | `Latest`, `Skip`, or listed patch number; prompt defaults to `Latest` | New DevOps plan only. `SqlOnly` forces `Skip`. |
| `-ListPatches` | Switch; specify `-Version` or select it | Display all catalog patch numbers, download links and applicability notes; no installation, elevation or credential required. |
| `-Credential` | Same setup account's `PSCredential`; masked console password prompt if omitted | New plan's startup-task credential. Never put passwords in commands/logs. |
| `-AcceptLicenseTerms` | Switch | Required for a new installation, not resume/cancel/validation. |
| `-Resume` | Switch | Retry a repaired failure/interruption using the saved plan and original account. |
| `-CancelResume` | Switch | Remove resume task/credential; not uninstall, rollback or installer termination. |
| `-ValidateOnly` | Switch | Run [Test-GuestSetup.ps1](Test-GuestSetup.ps1); keep it beside the launcher/worker. Run only while live setup is idle. |
| `-WhatIf` | PowerShell switch | Preview install/resume action; prerequisite checks/prompts still run. |
| `-Confirm` | PowerShell option | Install/resume prompts by default. `-Confirm:$false` suppresses confirmation only. |
| Common parameters | `-Verbose`, `-Debug`, `-ErrorAction`, etc. | PowerShell diagnostics, not product selections. Avoid credential tracing. |
| Worker `-StatePath` | `C:\ProgramData\AdoServerLabAutoOrchestrator\state.json` | Scheduled-task use; protected location required. Do not run a second worker. |

**Interactive input:** missing product/domain/email/patch choices, confirmation, then
the **same setup account's password**. Enter accepts displayed defaults.
`DevOpsOnly` also prompts for SQL. Windows stores the task credential; do not
enable transcription or credential/terminal recording in the launcher.
The password prompt appears directly in PowerShell using `Read-Host
-AsSecureString`, not a `Get-Credential` dialog. Enter the account's Windows
password, not a PIN. Empty/cancelled input stops setup before task registration.
If you have an approved secret-store PSCredential, pass it with `-Credential`
to skip the prompt; the same-account SID check still applies.

| Selection | Installs / configures |
|---|---|
| `2020` | DevOps Server 2020.1.2; SQL Server 2019 Developer (15.x); optional server Patch 1-9/11-19, Latest = 19. Patch 10 is task-only/manual. |
| `2022.1` | DevOps Server 2022 Update 1; SQL Server 2022 Developer (16.x); optional Patch 1-4, Latest = 4. Windows Server 2022 or supported Windows 11 24H2; older lab release. |
| `2022` | DevOps Server 2022.2; SQL Server 2022 Developer (16.x); optional Patch 1-12, Latest = 12. |
| `25H2` | DevOps Server 25H2 GA; SQL Server 2025 Enterprise Developer (17.x); optional Patch 1-9, Latest = 9. |
| `Both` | SQL if absent, DevOps, optional SMTP, TFS configuration, optional selected patch, SSMS, verification. |
| `SqlOnly` | SQL if absent, SSMS, verification; no DevOps/SMTP. |
| `DevOpsOnly` | Existing supported local SQL; DevOps, optional SMTP, configuration, optional selected patch, verification; no SSMS. |
| `Capture` | Loopback-only smtp4dev; no real email relay. |
| `None` | DevOps email notifications disabled. |

## Optional DevOps patches

List every patch/download link for the selected base release:

```powershell
.\Setup-Server.ps1 -Version 2020 -ListPatches
.\Setup-Server.ps1 -Version 2022 -ListPatches
.\Setup-Server.ps1 -Version 25H2 -ListPatches
```

For a **new** setup, use one of these (other options can still prompt):

```powershell
.\Setup-Server.ps1 -Version 25H2 -Patch Skip -AcceptLicenseTerms
.\Setup-Server.ps1 -Version 25H2 -Patch Latest -AcceptLicenseTerms
.\Setup-Server.ps1 -Version 2022 -Patch 8 -AcceptLicenseTerms
```

Omitting `-Patch` displays the catalog and prompts for Latest, Skip, or a number.
Skip does not download/run a patch or require a patch completion marker.
Latest resolves to a concrete number saved as `PatchSelection` in state; reboots
and `-Resume` retain it. Resume rejects `-Patch` overrides; this is not an
existing-server patch/rollback tool. Old plans retain their original mandatory
Patch 12 (2022.2) / Patch 9 (25H2) stage without shifting progress.

Standalone server patches are cumulative: select **one**, not every patch in sequence. Latest is
recommended; Skip/older choices may omit later security fixes. Catalog numbers
belong only to 2020.1.2, 2022.2 or 25H2 GA, not other updates or preview releases.
Skip/older patches cannot remove fixes already included in republished base media:
2022.2 Patch 1 and 25H2 Patch 2 fixes are already included in current fresh media,
so those patch tools may report that no update is applicable. Installation errors
are recorded, not ignored. This workflow does not reproduce older base media.
The catalog flags the 2022.2 Patch 3 re-release, Patch 4/5 CDN prerequisites and
Patch 6 known-issue warning.

Sources: [2022.2 release notes](https://learn.microsoft.com/en-us/azure/devops/server/release-notes/azuredevops2022u2)
and [25H2 release notes](https://learn.microsoft.com/en-us/azure/devops/server/release-notes/azuredevopsserver).
Hashes are pinned alongside URLs in [Get-SetupPatchCatalog](Setup-Releases.psm1).
The unpublished 2022.2 Patch 1 hash was computed from the official download after
validating its Microsoft Authenticode signature. Catalog snapshot: November 2026;
Latest means latest **in this catalog**, not a live web lookup.

For 2020.1.2, [Microsoft's release notes](https://learn.microsoft.com/en-us/azure/devops/server/release-notes/azuredevops2020u1)
describe Patch 10 as `Tasks20231103.zip` plus manual TFX task uploads.
It is listed for reference but `-Patch 10` is rejected; setup does not treat a ZIP
as a server installer or silently substitute another patch. Review the agent/task
prerequisites documented for patches 8 onward and CDN changes in 15/16 separately.
This script installs server patches only, not pipeline agents or task ZIP uploads.
Patch 1-9 hashes were derived from the official downloads after validating their
Microsoft Authenticode signatures; Patch 11-19 hashes are published by Microsoft.

## When to run which command

| Situation | Action |
|---|---|
| New installation; no saved plan | `.\Setup-Server.ps1 -AcceptLicenseTerms` |
| Normal setup-requested reboot | **Run nothing**; startup task resumes automatically without login. |
| Task/installer running | **Do not start another plan or run `-Resume`.** |
| Failure repaired; task/installers idle | `.\Setup-Server.ps1 -Resume` under original account; resume task must exist. |
| Completed | **Run nothing**; `-Resume` does not reopen/add products. |
| Remove automatic resume | `.\Setup-Server.ps1 -CancelResume` |
| Offline checks, setup idle | `.\Setup-Server.ps1 -ValidateOnly` |
| Direct offline checks, setup idle | `.\Test-GuestSetup.ps1` |
| Monitor live progress | `.\Monitor-Setup.ps1 -IntervalSeconds 5 -TailLines 3` |
| One progress snapshot | `.\Monitor-Setup.ps1 -Once` |
| Inspect task | `Get-ScheduledTask -TaskName AdoServerLabAutoOrchestrator-Resume` |

- Use one mode at a time: new installation, resume, cancellation or validation.
- Resume preserves choices/stage and copies the updated worker and matching modules;
  keep the launcher, worker and both modules together. All required source files are
  checked before copying; both modules are deployed before the worker.
- Automatic reboot/resume imports `Setup-Releases.psm1` and `Setup-State.psm1` beside the deployed worker in
  ProgramData. The test script is not copied or required by the startup task.
- Never replace the live worker or manually edit/delete state/stage indices.
- Resume after fixing the cause, not merely because logs are quiet.
- If credentials/policy prevent task logon, use approved Windows administration.
- For an old unsupported SQL bootstrap: stop the specific task and confirmed
  failed bootstrap by PID before resuming; preserve state and installed data.

## Automatic TCP port selection

Before starting a new background installation, the launcher checks the ports
needed by the selected components. It checks TCP listeners (reporting owning
PIDs), IIS site bindings including stopped sites, and exclusive IPv4/IPv6 bind
availability. It leaves existing services running and picks the first available
candidate:

| Service | Preferred port | Alternatives |
|---|---|---|
| DevOps HTTPS | 443 | 8443-8452 |
| DevOps Git SSH | 22 | 2222-2232 |
| Local SMTP capture | 25 | 2525-2534 |
| Local mail capture UI | 5000 | 5001-5010 |

Git SSH and Windows OpenSSH are separate services that can both request port 22;
if Windows OpenSSH occupies it, DevOps Git SSH uses an available alternative. SQL uses
local protocols; the script does not enable or allocate a SQL TCP port.
`SqlOnly` skips these checks; `Email None` skips the SMTP/UI checks.
Random ports are not necessary: bounded ranges make firewall/NSG configuration
and troubleshooting predictable. If no candidate is available, setup stops.

Selections are saved as `Ports` in `state.json`, shown by the launcher/dashboard
and written to `progress.log`. The worker uses them for DevOps INI HTTPS/SSH/SMTP,
smtp4dev settings, Windows HTTPS/Git SSH firewall rules, health checks and
completion URLs. Use the **reported URL**, including `:port` for alternate HTTPS.
Azure NSGs are not changed; allow the selected HTTPS/Git SSH ports on your
approved private network as needed. SMTP/UI remain loopback-only.

Ports are rechecked before the corresponding configuration stage. A check
cannot reserve a port across installation/reboots; if another service takes a
saved port later, setup fails explicitly rather than moving configured endpoints.
It permits existing listeners only for the exact smtp4dev process path on a
capture-stage retry. No other process is stopped or reconfigured.

Old schema-1/2/3/4 plans migrate through schema 5 in Domain mode without changing stage indices or
patch intent. Ports are selected only for stages not yet completed; already
configured legacy endpoints keep their original defaults (including the legacy
script's Git SSH port 2222). Previously saved ports are never reselected merely
because the preferred first-time port changed. A resume is not a
repair for partially created DevOps databases/sites. Do not overwrite a running
worker or edit state manually; use updated scripts with `-Resume` only when the
task/installers are idle and the failure cause is understood.

## Monitor and logs

| Monitor option | Default | Purpose |
|---|---|---|
| `-IntervalSeconds` | `10` | Refresh interval, 1-3600 seconds. |
| `-TailLines` | `10` | Latest script progress/transcript lines, 1-1000; installer tails are capped at 10 lines. |
| `-Once` | Off | Snapshot and exit. |

- Refreshing dashboard; only current-stage logs, not completed stages/old failures.
- Filters logs by the current stage's latest start timestamp.
- Run elevated under the setup account; keep the worker beside the monitor.
- Ctrl+C stops **monitoring only**. Restart the monitor after reboot.
- Stops on `Completed`/`Failed`; never installs, resumes or edits state.
- Missing/unchanged logs do not prove a stall; downloads may precede installer logs.
- Shared Visual Studio logs may belong to other products; check names/timestamps.
- Stages are not completion percentages.

The UI and console use the same `Setup-Monitoring.psm1` reader. The UI tails up
to 40 lines of script progress/transcript first, followed by installer details
with at most 10 lines per file. Installer files must have been updated within
the last 10 minutes as well as since the current stage started. This is a
file last-write-time filter, not a per-line timestamp filter. Script output is
not subject to the 10-minute filter. The display replaces its snapshot every refresh; it does
not append repeated tails. Each selected file path appears once, with its last
write time. Installer sources are gated by the most recent current-stage start
marker; if it is absent, old installer logs are hidden until the stage starts.
Only the current account's TEMP and Windows TEMP are checked, not other users'
profiles. Installer text files may end in `.log` or `.txt`, including
`dd_devops_server_*.txt`. Numbered session directories such as `Temp\2` are
checked one level deep; a numbered `%TEMP%` also includes its parent TEMP and
numbered siblings. No arbitrary TEMP-directory recursion is performed except
inside dedicated SSMS folders. Missing-log messages list the TEMP paths searched.
Run as the setup account. Read/access failures are surfaced, not
silently treated as empty logs. When no recent installer log matches, a neutral
message explains that setup may still be downloading or working. Full logs on
disk are not modified or deleted. Completed setup retains final progress/transcript.
The worker transcript is checked during every stage. DevOps installation and
patch monitoring show the newest top-level bundle log (`dd_devops*`/`dd_tfs*`
with a timestamp, `.log` or `.txt`) plus up to three recent matching component
logs, rather than only the newest file, subject to the 10-minute filter.
The bundle can contain download activity while component logs remain unchanged.
CAB files are installer payload archives,
not text logs; they are not read or extracted by the monitor. Thirty minutes
without new log output alone does not establish that an installer has stalled.

During DevOps installation/patching, an additional **Installer payload activity**
summary checks `%ProgramData%\Package Cache\{GUID}vVERSION\packages\DevOpsServer\Core`
and `Web`. It shows at most the newest CAB/MSI per component across cache entries:
full path, size in bytes and last-write time. The same current-stage/last-10-minute
filter applies. Only file metadata is inspected, never CAB/MSI contents; no
archives are extracted or changed. Discovery uses fixed directory levels, skips
reparse points, and does not recurse through other cached products. GUIDs and
versions are discovered, not hardcoded. Cache timestamps are best-effort activity
indicators, not proof of a running download or installation completion. The
summary is omitted if no recent matching payload exists.

| Source | Location |
|---|---|
| Saved status/error | `C:\ProgramData\AdoServerLabAutoOrchestrator\state.json` |
| Stage/download/error messages | `C:\ProgramData\AdoServerLabAutoOrchestrator\progress.log` |
| Worker transcript | `C:\ProgramData\AdoServerLabAutoOrchestrator\Logs\setup-*.log` |
| TFS readiness/configuration | `C:\ProgramData\Microsoft\Azure DevOps\Server Configuration\Logs` |
| DevOps installation | Setup account's `%TEMP%` and Windows TEMP; matching DevOps/TFS logs. |
| DevOps payload activity | `%ProgramData%\Package Cache\{GUID}vVERSION\packages\DevOpsServer\Core` / `Web`; CAB/MSI metadata only. |
| DevOps patch | `C:\ProgramData\Microsoft\Azure DevOps\Server Configuration\Logs\Patch_*.log`; also matching TEMP logs. |
| SSMS / Visual Studio Installer | `%TEMP%\dd_*.log`, legacy `SSMS*Setup*.log`, Windows TEMP; `%TEMP%\SSMS` is shown only if a current matching log exists. |
| SQL 2022 installation | `C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log` |
| SQL 2019 installation | `C:\Program Files\Microsoft SQL Server\150\Setup Bootstrap\Log` |
| SQL 2025 installation | Equivalent `170\Setup Bootstrap\Log` folder. |

SQL monitoring includes `Summary.txt`, newest timestamped run's `Detail.txt`,
newest component log and matching SQL/bootstrap TEMP logs. TFS transcripts print
the exact product log path.

```powershell
Get-Content 'C:\ProgramData\AdoServerLabAutoOrchestrator\state.json' -Raw |
    ConvertFrom-Json | Select-Object Status, StageIndex, LastError
```

## Completion and failures

| Result | Behavior |
|---|---|
| Launcher returns | Task started, **not installation completion**. |
| Installer exit `3010` | Save next stage, reboot, automatically continue; saved boot timestamp prevents skipping restart. |
| Failure | Save `LastError`, disable automatic retries; inspect product logs and repair before resume. |
| Success | `Status: Completed`, transcript `COMPLETED`, resume task/credential removed. |
| SMTP capture | Separate capture task remains active intentionally. |

Final verification checks SQL, SSMS where selected, collection databases,
authenticated DevOps projects API, the saved Git SSH TCP listener,
selected patch marker (unless Skip) and optional SMTP submission.
After reboot, SSH readiness is polled every 15 seconds for up to 10 minutes;
waiting/success messages appear in `progress.log`. A timeout fails verification
explicitly and preserves the current stage for resume; it never switches ports
or reconfigures the server. TCP-listener readiness is not a Git authentication test.
`SqlOnly` does not perform this SSH check.
Database checks accept a matching `AzureDevOps_Configuration` /
`AzureDevOps_DefaultCollection` pair or legacy `Tfs_` equivalents; both must be
ONLINE. The configuration guard detects both prefixes to protect existing data.
Offline tests cover syntax, plans, SQL guards, INI handling and mocked
reboot/resume/failure paths; they do not prove every live installer scenario.
They also validate module exports/deployment and legacy state migration. Patch
tests run once after syntax checks, not repeatedly for every script/module file.

## Installation safeguards

| Area | Behavior |
|---|---|
| Existing SQL | Validate and preserve; no version upgrade, collation change or missing-feature installation. |
| SQL requirements | Matching major version, Full-Text, `SQL_Latin1_General_CP1_CI_AS`, sysadmin access; Developer/Standard/Enterprise accepted, Express rejected. |
| Fresh SQL | One default local instance, virtual service accounts, 4-GB memory cap, remote TCP/named pipes disabled; standard OS-disk paths. |
| SQL media | 2022 direct Microsoft ISO, 2019/2025 Microsoft bootstraps; mounted temporarily. Two-hour HTTP timeout; PowerShell download progress suppressed for performance. |
| Retained downloads | SQL ISOs in `C:\ProgramData\AdoServerLabAutoOrchestrator\SqlMedia`; SQL bootstrap, `DevOpsSetup.exe`, `DevOpsPatch.exe`, `vs_SSMS.exe` (or `SSMS20-Setup.exe` on Windows 10) and `smtp4dev.zip` in `C:\ProgramData\AdoServerLabAutoOrchestrator`. Retained after setup for reference; SQL ISOs are still unmounted. No extra cleanup is needed to keep them. |
| Download validation | Microsoft executable signatures; pinned patch/smtp4dev hashes. Never disable validation after mismatch. |
| Patch command | `Patch -force -nowait` avoids confirmation and completion keypress prompts; `/quiet /norestart` are not this tool's switches. |
| SSMS | Latest stable SSMS 22 [release bootstrap](https://aka.ms/ssms/22/release/vs_SSMS.exe) on Server/Windows 11; updates existing 22, preserves older versions side-by-side. Windows 10 uses archived signed SSMS 20.2.1 and verifies build 20.2.37.0 or a later 20.x build. |
| Existing DevOps | Rejected for a fresh plan; not an upgrade/repair tool. Existing databases are not overwritten on configuration retry. |
| Old schema-1/2/3/4/5 plans | Migrate to schema 6 with strict OS validation by default; older domain plans preserve their original domain hostname, without repeating SQL/DevOps stages or changing original patch intent; completed plans stay completed. |
| Release selection | Media in [Get-SetupRelease](Setup-Releases.psm1), patch links/hashes in [Get-SetupPatchCatalog](Setup-Releases.psm1) reflect November 2026 selection; review release notes before future use. |

Retaining media uses additional OS-disk space and is not a backup. Files that fail
SHA-256 validation are still deleted and setup fails explicitly. Retention does
not provide an offline/reuse mode: a stage retry can download to the same path
again. Media deleted by an earlier script version cannot be recovered by this change.

## Access and scope

| Item | Details |
|---|---|
| DevOps URL | Domain: `https://<vm-name>.<your-domain>/tfs/DefaultCollection`; Workgroup: `https://<vm-name-or-custom-DNS>/tfs/DefaultCollection`; alternate HTTPS adds `:<saved-port>`. |
| SMTP capture UI | `http://localhost:<saved-MailUi-port>` on the setup VM; default 5000. |
| HTTPS certificate | One-year self-signed certificate trusted locally; other clients need verified/approved trust. Do not disable TLS validation. |
| Firewall/network | Script HTTPS/Git SSH rules use saved ports and local subnet: Domain profile in Domain mode, Private profile in Workgroup mode. Public is not opened. Configure Azure NSGs/private access yourself. |
| SMTP | Loopback-only, locked settings, relay disabled, Internet outbound blocked. Test actual DevOps notifications separately; setup submission is a health test. |
| Configuration INI | `C:\ProgramData\AdoServerLabAutoOrchestrator\devops.ini`; unsupported generated keys fail explicitly. |
| Not included | Search, SSRS/SSAS, pipeline agents, AD provisioning/join, Azure deployment, backups, image capture or production hardening. |
