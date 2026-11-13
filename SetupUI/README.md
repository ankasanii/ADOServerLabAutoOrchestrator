# AdoServerLabAutoOrchestrator setup UI

This is a Windows x64 WPF launcher for the existing [guest scripts](../GuestSetup/README.md).
It adds no installer logic and does not include the standalone security-maintenance
script. The supported combinations, prerequisites, patch restrictions and
reboot/resume behavior remain those of the guest scripts.

## Build and distribute

On Windows with .NET Framework 4.x developer/compiler components:

```powershell
.\SetupUI\Build-SetupUI.ps1
.\SetupUI\Test-SetupUI.ps1
```

For full validation, run tests in Windows PowerShell 5.1 with `-STA`, matching
the EXE's .NET Framework runtime. The live bridge/timer tests use isolated
fixtures and never run setup. PowerShell 7 runs the compatible checks but
explicitly skips that integration block because its runtime lacks the
`System.Web` dependencies used by the EXE.

The build produces `SetupUI\dist\AdoServerLabAutoOrchestrator.exe` and `SetupUI\AdoServerLabAutoOrchestrator.zip`.
Distribute the ZIP only through channels covered by your distribution permissions.
The [GitHub Actions workflow](../.github/workflows/build-release.yml) builds and tests
the package, then attaches the ZIP to a GitHub release after each successful push
to `main`; pull requests build and test without publishing. See the
[repository release guide](../README.md#github-actions-builds-and-releases).
Extract **the whole
ZIP** into a trusted, administrator-controlled folder on the target supported Windows VM,
then double-click `AdoServerLabAutoOrchestrator.exe`. Keep `SetupBridge.ps1` and `GuestSetup` beside
the EXE. No separate modern .NET runtime is required; it uses Windows' .NET
Framework and Windows PowerShell 5.1.

### Application icon

The EXE and window/taskbar icon embed the official Azure DevOps artwork from
[Microsoft's Azure architecture icon pack](https://learn.microsoft.com/en-us/azure/architecture/icons/).
`Assets/AzureDevOps.svg` preserves the original V25 asset
`Icons/devops/10261-icon-service-Azure-DevOps.svg`. `Assets/AzureDevOps.ico`
faithfully renders its shape and gradient with transparent 16, 24, 32, 48, 64,
128 and 256 pixel frames. The icon is embedded; no extra icon file is needed
beside the distributed EXE.

**Permission is required for this use.** Microsoft's standard architecture-icon
terms cover diagrams, training and documentation, not representing a custom
application. This icon was added following confirmation of explicit permission.
Confirm that your permission covers the intended distribution; do not assume
the standard download terms grant application-icon rights. See Microsoft's
[trademark guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks).

The executable requests administrator elevation. This build is **unsigned**;
obtain organisation-approved signing for the EXE/scripts before wider use.
SmartScreen/AppLocker/WDAC policies can block it. Do not disable organisation
security policies to run it. Like the original task workflow, the launcher uses
PowerShell's process-scoped `ExecutionPolicy Bypass`; it does not change machine
policy or bypass application-control policy.

## Use

**26H2 RC (preview / lab)** is a separate opt-in release using SQL 2025.
Stable `25H2` remains the default where supported. The RC shows an amber
prerelease notice and offers only a disabled "No RC patches published in this
catalog" choice, saved as `Skip`. It never uses 25H2 patches. Current selected
OS pairings match `25H2`; existing OS override and other prerequisite checks
still apply. Use a fresh disposable test deployment; this workflow does not
upgrade existing servers or provide RC-to-final upgrades. See the
[RC release notes](https://learn.microsoft.com/en-us/azure/devops/server/release-notes/azuredevopsserver26h2).

1. Create the VM yourself (domain-join it only for Domain mode), reboot, and sign in with the intended setup
   account. Review the Microsoft Developer/evaluation licenses and guest README.
2. Choose DevOps/SQL version, components, executable patch and SMTP capture/none.
   Only supported OS pairings can be started by default. SQL installs use `localhost`;
   DevOps-only can target an existing local named instance.
   The OS is detected automatically using the same validation as the CLI/worker.
   Windows 11 24H2 Pro/Enterprise/Education (non-LTSC) is offered for 2022/25H2.
   Documented Windows 10 Pro/Enterprise combinations are offered for 2020:
   Enterprise 1803, or Pro/Enterprise 1809-22H2. Client installations are for
   evaluation/personal use, not production or DevOps Proxy. Home, ARM/x86,
   unlisted newer/Insider builds are rejected by default. Domain controllers
   and unsupported editions/architectures cannot be overridden.
   Windows 10 uses archived SSMS 20.2.1 rather than SSMS 22 and disables local
   SMTP capture because its .NET 10 runtime does not cover every Windows 10
   lab version. Review Windows lifecycle/ESU and older-software security risks.
   Windows 11/Server keep SSMS 22 and optional capture. Client IIS prerequisites
   are checked before setup and enabled by the worker; a required reboot does
   not skip any installation stage.
   To deliberately try an unlisted Windows version/build, select **Try unsupported
   OS (lab only; may fail)**. The default radio button is **Require supported OS
   (recommended)**. This option is available only for OS version/build restrictions.
   The UI shows a warning and repeats it in the launch confirmation; installation
   may fail or be unsupported. Architecture, edition, domain-controller, IIS,
   SQL, account, membership, firewall and data-protection checks remain active.
   Microsoft installers may still reject the OS. Selecting the option does not
   itself start installation. The acknowledgement is saved for automatic
   reboot/resume and appears in saved status. Both radio buttons are locked
   once a plan exists; old plans default to strict validation.
   **2022 Update 1** is a separate older lab option with SQL 2022 and its own
   patches 1-4. **2022 Update 2** remains the existing `2022` option with patches
   1-12. Neither option upgrades/downgrades an existing DevOps installation.
   Choose **Domain / Workgroup** to match existing membership. Domain is the
   default; a workgroup VM requires explicit Workgroup selection and a local
   Windows administrator with a password. Domain controllers remain unsupported.
   Workgroup's DNS hostname defaults to the VM name; optionally enter an existing
   custom record pointing only to this VM. DNS is not created automatically.
   HTTPS URL/certificate/binding all use the chosen name. Remote clients need
   name resolution and certificate trust. A trusted Private network is required
   for workgroup DevOps firewall rules; Public is never opened automatically.
3. Check license acceptance, click **Start installation**, and approve the warning.
4. Enter the same Windows account's password in the **masked PowerShell console**
   that opens. The UI never reads or stores the password. Review console errors.
   When it reports that the launcher has finished, close that console.
5. The UI refreshes saved status and log tails every 10 seconds until setup is
   **Completed**, then stops automatic refresh and keeps the final view visible.
   The **Refresh** button remains available, including when reopening an already
   completed setup. A manual refresh that finds a non-completed state restarts
   automatic monitoring. Failed setup and monitoring errors continue polling.
   Progress is
   **completed stages**, not byte progress or estimated install time.
   The setup/options area scrolls when warnings or status text are long; the
   log panel keeps at least 120 device-independent pixels of height, including
   at the minimum window size. Scroll the upper area to reach all controls.
   Notices have spaced, bold headings: red for override/blocking warnings,
   amber for compatibility/security cautions, and blue for prerequisites and
   information. Text labels identify severity as well as color.
6. After an automatic VM reboot, the existing scheduled task resumes setup.
   Reopen the EXE to monitor; the UI itself is not registered at startup.
7. For failure, repair the reported issue first. **Resume saved setup** preserves
   the plan/patch/ports and is available only to the original account when the
   task is idle. A completed plan cannot be overwritten.
   Saved membership and DNS hostname are also preserved. Legacy plans stay Domain.

Closing the UI or monitoring window does not stop the worker. Opening a console
is **not** proof that setup started or completed; saved state/logs are authoritative.
The worker can be running while the UI is closed. No cancel/install-stop button
is provided in this first version.

2020 Patch 10 is excluded because it requires manual task ZIP uploads, not an
executable server patch. Latest/Skip/numeric choices are read from the existing
release module, not copied into the C# UI.

The UI and console monitor use the shared `GuestSetup/Setup-Monitoring.psm1`
log reader. The main view shows up to 40 lines of current-stage script progress
and worker transcript, even if they have not changed in the last 10 minutes.
Installer details follow below, with at most 10 lines per file and only files
updated within the last 10 minutes (based on file last-write time, not each
line's timestamp):

- DevOps/patch/SSMS installer logs in the current setup account's `%TEMP%`
  and `C:\Windows\Temp` (the actual Windows directory is detected), with
  `.log` or `.txt` extensions, including `dd_devops_server_*.txt`.
- Nested `%TEMP%\SSMS` logs, including `.log` and `.txt` files.
- DevOps configuration/patch product logs under ProgramData.
- SQL setup `Summary.txt`, newest timestamped run's `Detail.txt`, newest
  component log, and matching SQL/bootstrap TEMP logs.
- Current-stage progress and worker transcript during every stage; completed
  setup retains its final progress/transcript view.

For DevOps installation and patching, the reader retains the newest top-level
bundle log and up to three recent component logs, each subject to these limits.
This keeps bundle download messages visible even when a component log is newer.
Both `.log` and `.txt` bundle files are supported. CAB files are installer
payload archives, not readable logs; the monitor does not extract them.
No new output for 30 minutes by itself does not prove the installer is stalled.

During DevOps installation/patching, **Installer payload activity** appears
between the script output and installer log details when recent CAB/MSI files
exist under `%ProgramData%\Package Cache\{GUID}vVERSION\packages\DevOpsServer\Core`
or `Web`. It shows the newest file per component (across cache entries), its
full path, size in bytes and modified time. Only files updated within the last
10 minutes and since the current stage started are included. GUIDs/versions are
discovered without hardcoding; fixed-depth discovery excludes other products,
nested payload folders and reparse points. Only metadata is read: no CAB/MSI
contents are opened, extracted, modified or deleted. Recent cache writes suggest
downloading/staging, not a completion percentage or proof of a running download.
No payload section is shown when no recent matching file exists.

Each file section shows its full path and last-write time. Installer files must
also have been updated since the most recent current-stage start marker. Before that
marker exists, the monitor reports that it is waiting instead of showing old
installer output. Shared Visual Studio logs can belong to another product;
filename/time filtering is best-effort correlation, not an installer activity ID.
Numbered TEMP session directories (for example `Temp\2`) are checked one level
deep. If `%TEMP%` points at such a session directory, its parent TEMP and numbered
siblings are included. Arbitrary TEMP subfolders and other users' profiles are
not scanned (except the dedicated nested SSMS log folder). Reopen under the
setup account. If no recent installer log matches, the view reports
"No recent installer log activity (last 10 minutes). Setup may still be
downloading or working." It also lists the TEMP folders searched where applicable.
Full logs on disk are left unchanged.

Refresh replaces the displayed snapshot, not an append-only stream. Unchanged
files therefore show the same tail, not accumulating duplicates; each selected
path appears once per refresh. Progress and a transcript can describe the same
event in separate source sections. Monitoring is read-only. Missing logs are
reported where expected; access/read failures are displayed explicitly and
disable start/resume until the next successful refresh. Full product logs
remain authoritative for deeper diagnostics.
