# AdoServerLabAutoOrchestrator

Automate SQL Server and Azure DevOps Server setup on a Windows lab VM, using either PowerShell or a Windows desktop UI.

The project provides prerequisite checks, product installation and configuration, optional DevOps patches, automatic reboot/resume, and read-only progress monitoring.

> **Lab and evaluation use only.** This is not a production deployment, backup, migration, or upgrade solution. Setup installs software, changes Windows configuration, and can restart the VM automatically. Use a fresh, disposable VM and review the documentation before starting.

## What is included

| Component | Purpose | Documentation |
|---|---|---|
| [GuestSetup](GuestSetup/) | PowerShell launcher, installation worker, shared modules, console monitoring, and offline tests. | [Setup guide](GuestSetup/README.md) |
| [SetupUI](SetupUI/) | Windows x64 WPF launcher using the same setup scripts, with saved status and live log tails. | [UI and build guide](SetupUI/README.md) |

### Key capabilities

- Install SQL only, Azure DevOps Server only, or both.
- Use existing domain membership: the UI detects it automatically; the CLI offers explicit Workgroup mode.
- Select release-specific DevOps patches from the included catalog.
- Resume the saved installation plan through Task Scheduler after required reboots.
- Monitor setup through the desktop UI or a read-only PowerShell dashboard.
- Export a local diagnostic report with best-effort redaction and an editable preview before saving.
- Optionally capture test email locally on supported operating systems.

## Release options

| CLI version | Azure DevOps Server option | SQL pairing for a fresh local installation |
|---|---|---|
| `2020` | 2020 | SQL Server 2019 Developer |
| `2022.1` | 2022 Update 1 | SQL Server 2022 Developer |
| `2022` | 2022 Update 2 | SQL Server 2022 Developer |
| `25H2` | 25H2 | SQL Server 2025 Enterprise Developer |
| `26H2-RC` | 26H2 RC, opt-in preview | SQL Server 2025 Enterprise Developer |

`25H2` is the stable default where supported. The RC is a separate disposable-lab option, has no standalone patches in the included catalog, and must not use 25H2 patches.

Operating-system support depends on the selected release. See the [supported OS matrix and restrictions](GuestSetup/README.md#supported-os-validation) before preparing a VM; these are the automation's selected pairings, not every combination supported by Microsoft.

## Prerequisites

- A supported native x64 Windows VM. Server workflows target Desktop Experience, not Server Core. ARM/x86, Home editions, and domain controllers are not supported.
- Elevated **Windows PowerShell 5.1**, running as the intended setup account.
- A Windows administrator account with a password and permission to register a scheduled task using password logon. Domain administrator privileges are not required.
- For Domain mode: an already joined VM with healthy domain connectivity and AD DNS. For Workgroup mode: a non-domain-joined VM and a local administrator account.
- Suggested capacity: **4 vCPU, 16 GB RAM, and at least 35 GB free on C:** for fresh SQL, plus additional space for SSMS and projects.
- Outbound HTTPS access to the required Microsoft, Visual Studio Installer, and GitHub endpoints.
- Acceptance of the applicable Microsoft Developer/evaluation licenses.

**Company/Dev Box account warning:** Microsoft Entra ID join or company sign-in
alone does not satisfy Domain mode's AD-domain membership requirement. Workgroup
mode requires an organization-approved local administrator account such as
`VMNAME\labadmin`, with a password, not a PIN. Entra ID/AzureAD or domain accounts
on a non-AD-domain-joined VM are not supported by this workflow. Reboot/resume
uses password-based Task Scheduler logon; do not bypass the account check or
weaken your organization's policies.

Client Windows installations are for evaluation or personal use, not production/team hosting or DevOps Proxy. Review the [complete prerequisites](GuestSetup/README.md#prerequisites), including OS lifecycle, IIS, DNS, firewall, and account requirements.

### Setup and service accounts

The setup account is the Windows identity running the elevated EXE or PowerShell
launcher. It must have local administrator privileges on the VM; domain
administrator privileges are not required.

| Purpose | Account used |
|---|---|
| Installation worker | The account running the elevated launcher. |
| Automatic reboot/resume task | The same setup account, using the password entered during setup; not `SYSTEM`. Resume requires the original account/SID. |
| SQL `sysadmin` permission for a fresh SQL installation | The setup account. |
| SQL Database Engine service for a fresh installation | `NT Service\MSSQLSERVER`. |
| SQL Server Agent service for a fresh installation | `NT Service\SQLSERVERAGENT`. |
| Optional smtp4dev startup task | `SYSTEM`. |
| Azure DevOps service identity | Normally `NT AUTHORITY\NETWORK SERVICE`, as supplied by the Microsoft-generated `TfsConfig NewServerBasic` configuration. This project does not explicitly override it or supply a custom service-account password. Verify the generated configuration and installed service/application-pool identities for your installation. |

`NT AUTHORITY\NETWORK SERVICE` is the Azure DevOps service identity, not a
separately configured SMTP login. For local smtp4dev capture, the script sets the
SMTP server, port, and sender address but does not explicitly set an SMTP
authentication account or password; generated authentication defaults are left
unchanged.

For example, launching as `VMNAME\labadmin` runs installation and reboot/resume
under that account, while the SQL services use their separate built-in virtual
accounts. Windows Task Scheduler stores the resume credential; the password is
not written to the saved setup state. Setup does not create a new Windows user
for you. Existing supported SQL installations are preserved, including their
service accounts.

## Quick start

Download or clone this repository and keep each component's scripts and modules together in a trusted, administrator-controlled folder.

### Option 1: Desktop UI

From the repository root, build the launcher on Windows with the .NET Framework 4.x developer/compiler components:

```powershell
.\SetupUI\Build-SetupUI.ps1
```

The build produces `SetupUI\dist\AdoServerLabAutoOrchestrator.exe`, `SetupUI\AdoServerLabAutoOrchestrator.zip`, and the matching `.zip.sha256` checksum file.

1. Extract the **whole ZIP** on the target VM, keeping `SetupBridge.ps1` and the bundled `GuestSetup` folder beside the EXE.
2. Launch `AdoServerLabAutoOrchestrator.exe` and approve administrator elevation.
3. Select the release, components, and optional features. Membership is detected automatically and cannot be changed in the UI; the detected AD domain is read-only.
4. Review the warnings and license terms, then start installation.
5. Enter the original setup account's password in the masked PowerShell console when prompted.

The UI does not read or store the password. Reopen it after a reboot to monitor the saved setup; Task Scheduler resumes installation independently.

See the [UI guide](SetupUI/README.md) for distribution, signing, application-icon permission, and detailed usage requirements.

### Option 2: PowerShell

Open **Windows PowerShell 5.1 as Administrator** on the target VM. From the repository root, start the interactive launcher:

```powershell
.\GuestSetup\Setup-Server.ps1
```

Domain mode is the default. For a fresh Workgroup VM whose OS is supported for `25H2`, an explicit example is:

```powershell
.\GuestSetup\Setup-Server.ps1 -Version 25H2 -JoinMode Workgroup -Components Both -Email None -Patch Latest -AcceptLicenseTerms
```

Use `-AcceptLicenseTerms` only after reviewing and accepting the applicable terms. Setup still prompts for required confirmation and the setup account's password. Expect automatic reboots.

For all parameters, existing local SQL instances, DNS choices, and other examples, see the [PowerShell setup guide](GuestSetup/README.md#start).

## Monitor and resume

Run these commands from the repository root:

```powershell
# Show live progress without changing setup.
.\GuestSetup\Monitor-Setup.ps1 -IntervalSeconds 5 -TailLines 3

# Show one progress snapshot.
.\GuestSetup\Monitor-Setup.ps1 -Once

# After correcting a failure, retry the saved plan as the original account.
# Use only when the scheduled task and previous installers are idle.
.\GuestSetup\Setup-Server.ps1 -Resume
```

Saved state, progress, and worker logs are under `C:\ProgramData\AdoServerLabAutoOrchestrator`. A completed plan cannot be reopened to add products or perform an upgrade. Do not start a second worker or manually edit saved state to bypass a failure.

See [monitoring and logs](GuestSetup/README.md#monitor-and-logs) and [completion and failures](GuestSetup/README.md#completion-and-failures) for troubleshooting.

### Export diagnostics

Click **Export diagnostics** in the UI to generate a local text report containing the application version, setup status, saved error, and the current log tails selected by the existing monitor. No raw state file, full log archive, credentials, or installer payloads are copied. The exporter attempts to redact credential-like assignments, URL credentials/signatures, email/IP addresses, SIDs, user-profile paths, and known saved machine/domain/account identities.

**Redaction is best-effort, not a guarantee.** Inspect and edit the preview to remove any remaining sensitive information before saving or sharing it. Canceling does not save a report. Nothing is uploaded automatically, and exporting does not install software or change saved setup state.

## Development and validation

Run workflow and PowerShell lint from the repository root:

```powershell
powershell.exe -NoProfile -NonInteractive -File .\.github\Test-Lint.ps1
```

The [lint runner](.github/Test-Lint.ps1) downloads actionlint 1.7.12 and
PSScriptAnalyzer 1.25.0 from their official GitHub releases, verifies pinned SHA-256
hashes, and removes its temporary tools afterward. It requires internet access,
Git, and Windows PowerShell 5.1; no modules are installed globally.
It validates workflows and analyzes tracked and new non-ignored PowerShell source
files, excluding ignored build output. It does not execute setup or install products.
The [PowerShell rules](.github/PSScriptAnalyzerSettings.psd1) focus on correctness,
credential-handling mistakes, and Windows PowerShell 5.1 syntax compatibility,
rather than a repository-wide style rewrite. Any selected diagnostic or analyzer
error fails the check. Update tool versions and their pinned hashes together.

With live setup idle, run the offline guest checks from the repository root:

```powershell
.\GuestSetup\Setup-Server.ps1 -ValidateOnly
```

Run the UI tests in Windows PowerShell 5.1 with STA enabled for full runtime coverage:

```powershell
powershell.exe -NoProfile -STA -File .\SetupUI\Test-SetupUI.ps1
```

The guest checks mock installers and reboots. The UI bridge/timer tests use isolated fixtures and do not run installation. See the component guides for details.

The guest module-isolation checks normalize the deployed fixture directory to its long path, so Windows short-format TEMP paths (such as those on GitHub-hosted runners) do not produce false cached-module failures.

## GitHub Actions builds and releases

The [build and release workflow](.github/workflows/build-release.yml) runs on pushes to `main` and pull requests targeting `main`, using a Windows runner and Windows PowerShell 5.1.

1. Lint workflows and PowerShell source; failures block the existing required build check.
2. Run the offline guest tests.
3. Build the UI and distribution ZIP.
4. Run the UI tests in STA mode.
5. Upload the tested ZIP and SHA-256 sidecar as the `AdoServerLabAutoOrchestrator` workflow artifact, retained for 14 days.
6. For a successful non-documentation-only push to `main`, verify the downloaded ZIP against its checksum, then create a GitHub release with both files attached.

### Markdown-only fast path

When every changed file ends in `.md` (case-insensitive), CI still starts and
runs workflow/PowerShell lint, but skips guest/UI tests, the EXE/ZIP build,
artifact upload, and release publication. The required **Build and test Windows
package** check completes normally after lint succeeds; no `[skip ci]` marker
or workflow-level path exclusion is needed.

Pull requests are classified using the complete PR diff, not just the latest
commit. Pushes compare the previous and current commit across the whole push.
Renaming a non-Markdown file to Markdown still requires full validation.
Code, scripts, workflow YAML, mixed changes, initial pushes, and empty diffs
take the full path. Change-detection errors fail the check rather than
silently skipping work.

Documentation bundled in the ZIP is refreshed with the next full release.
Any change to this workflow itself still runs the full pipeline.

### Release publication

Each release uses a unique `main-<run-id>-<run-attempt>` tag pointing to the built commit. Pull requests never publish releases. Failed lint checks, builds, or tests block publication.

Future releases include GitHub-generated release notes listing merged pull
requests, contributor credits where applicable, and a comparison link.
The installation instructions and unsigned-application warning appear above
the generated notes. Existing published releases are not changed automatically.

Release titles use `AdoServerLabAutoOrchestrator-YYYY.MM.DD.<run-number>`, for example `AdoServerLabAutoOrchestrator-2026.11.12.2`. The date is captured once in UTC before the build; the final number is the workflow run number, not a daily build count. The same version is embedded in the EXE product/file/assembly metadata and application manifest, even if publication happens after midnight. Reruns keep the run number, while their tags remain unique.

Local builds default to the UTC date with revision `0`. To stamp a specific version, use `.\SetupUI\Build-SetupUI.ps1 -Version 2026.11.13.5`. Each of the four numeric components must be between 0 and 65534.

Push this workflow to `main` to start the first build. Monitor it in the repository's **Actions** tab, then download the ZIP from **Releases**. Release assets remain available independently of workflow artifact retention.

The workflow uses GitHub's automatic `GITHUB_TOKEN`; no personal access token is required. GitHub Actions must be enabled, and repository/organization policies must allow the release job's `contents: write` permission. Confirm publication and application-icon permissions before pushing, because every successful non-documentation-only push to `main` publishes a release.

### Pull-request protection

This repository's `main` branch requires a pull request, an up-to-date branch, and the successful **Build and test Windows package** check from GitHub Actions. Protection applies to administrators; force-pushes and branch deletion are blocked. No approving review is required, allowing a solo maintainer to merge their own passing PR. The release job is not a required PR check because it only runs after a merge/push to `main`. Forks must configure these GitHub settings separately.

### Verify a release download

Download both release assets into the same folder and run:

```powershell
$expected = (Get-Content .\AdoServerLabAutoOrchestrator.zip.sha256 -Raw).Trim().Split(' ')[0]
$actual = (Get-FileHash .\AdoServerLabAutoOrchestrator.zip -Algorithm SHA256).Hash
if ($actual -ne $expected) { throw 'ZIP checksum mismatch. Do not extract or run this download.' }
```

The checksum detects mismatched bytes; it is not a digital signature or proof of publisher identity. The application remains unsigned.

## Scope and distribution notes

- This project does not provision Azure resources, create or join domains, format disks, create backups, or build VM images.
- Existing-server upgrades, downgrades, and RC-to-final upgrades are outside this workflow.
- Configure external access, name resolution, certificate trust, and network controls yourself.
- The UI build is unsigned. Follow your organization's signing and application-control requirements; do not disable security policies to run it.
- Before public distribution, confirm that permission for the Microsoft Azure DevOps application icon covers that distribution. See the [icon permission notice](SetupUI/README.md#application-icon).
- Original project code is available under the [MIT License](LICENSE), also included in the distribution ZIP. Third-party software, Microsoft artwork, product licenses, and trademark terms remain separate.
- Do not publish credentials, certificates/private keys, saved setup state, or unredacted logs in GitHub issues or commits.
