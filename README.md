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
- Use an existing domain membership or explicitly select Workgroup mode.
- Select release-specific DevOps patches from the included catalog.
- Resume the saved installation plan through Task Scheduler after required reboots.
- Monitor setup through the desktop UI or a read-only PowerShell dashboard.
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

Client Windows installations are for evaluation or personal use, not production/team hosting or DevOps Proxy. Review the [complete prerequisites](GuestSetup/README.md#prerequisites), including OS lifecycle, IIS, DNS, firewall, and account requirements.

## Quick start

Download or clone this repository and keep each component's scripts and modules together in a trusted, administrator-controlled folder.

### Option 1: Desktop UI

From the repository root, build the launcher on Windows with the .NET Framework 4.x developer/compiler components:

```powershell
.\SetupUI\Build-SetupUI.ps1
```

The build produces `SetupUI\dist\AdoServerLabAutoOrchestrator.exe` and `SetupUI\AdoServerLabAutoOrchestrator.zip`.

1. Extract the **whole ZIP** on the target VM, keeping `SetupBridge.ps1` and the bundled `GuestSetup` folder beside the EXE.
2. Launch `AdoServerLabAutoOrchestrator.exe` and approve administrator elevation.
3. Select the release, components, membership mode, and optional features.
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

## Development and validation

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

1. Run the offline guest tests.
2. Build the UI and distribution ZIP.
3. Run the UI tests in STA mode.
4. Upload the tested ZIP as the `AdoServerLabAutoOrchestrator` workflow artifact, retained for 14 days.
5. For a successful push to `main` only, create a GitHub release and attach `AdoServerLabAutoOrchestrator.zip`.

Each release uses a unique `main-<run-id>-<run-attempt>` tag pointing to the built commit. Pull requests never publish releases. Failed builds or tests block publication.

Release titles use `AdoServerLabAutoOrchestrator-YYYY.MM.DD.<run-number>`, for example `AdoServerLabAutoOrchestrator-2026.11.12.2`. The date is the UTC publication date; the final number is the workflow run number, not a daily build count. Reruns keep the run number, while their tags remain unique.

Push this workflow to `main` to start the first build. Monitor it in the repository's **Actions** tab, then download the ZIP from **Releases**. Release assets remain available independently of workflow artifact retention.

The workflow uses GitHub's automatic `GITHUB_TOKEN`; no personal access token is required. GitHub Actions must be enabled, and repository/organization policies must allow the release job's `contents: write` permission. Confirm publication and application-icon permissions before pushing, because every successful push to `main` publishes a release.

## Scope and distribution notes

- This project does not provision Azure resources, create or join domains, format disks, create backups, or build VM images.
- Existing-server upgrades, downgrades, and RC-to-final upgrades are outside this workflow.
- Configure external access, name resolution, certificate trust, and network controls yourself.
- The UI build is unsigned. Follow your organization's signing and application-control requirements; do not disable security policies to run it.
- Before public distribution, confirm that permission for the Microsoft Azure DevOps application icon covers that distribution. See the [icon permission notice](SetupUI/README.md#application-icon).
- Original project code is available under the [MIT License](LICENSE), also included in the distribution ZIP. Third-party software, Microsoft artwork, product licenses, and trademark terms remain separate.
- Do not publish credentials, certificates/private keys, saved setup state, or unredacted logs in GitHub issues or commits.
