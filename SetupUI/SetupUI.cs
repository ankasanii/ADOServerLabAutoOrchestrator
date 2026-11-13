using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace AdoServerLabAutoOrchestrator
{
    public static class Program
    {
        [STAThread]
        public static void Main()
        {
            var app = new Application();
            app.DispatcherUnhandledException += delegate(object sender, DispatcherUnhandledExceptionEventArgs e)
            {
                MessageBox.Show(e.Exception.Message, "Setup UI error", MessageBoxButton.OK, MessageBoxImage.Error);
                e.Handled = true;
            };
            app.Run(new SetupWindow());
        }
    }

    public sealed class Choice
    {
        public string Value { get; private set; }
        public string Label { get; private set; }
        public Choice(string value, string label) { Value = value; Label = label; }
        public override string ToString() { return Label; }
    }

    public sealed class SetupWindow : Window
    {
        private const string AutoRefreshMessage = "Stage progress, not download percentage. Refreshes every 10 seconds until setup completes. Closing this UI does not stop setup.";
        private static readonly Brush NoticeInfo = new SolidColorBrush(Color.FromRgb(7, 89, 133));
        private static readonly Brush NoticeWarning = new SolidColorBrush(Color.FromRgb(138, 75, 8));
        private static readonly Brush NoticeDanger = new SolidColorBrush(Color.FromRgb(185, 28, 28));
        private readonly string folder = AppDomain.CurrentDomain.BaseDirectory;
        private readonly string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            @"System32\WindowsPowerShell\v1.0\powershell.exe");
        private readonly ComboBox version = new ComboBox();
        private readonly ComboBox components = new ComboBox();
        private readonly ComboBox patch = new ComboBox();
        private readonly ComboBox email = new ComboBox();
        private readonly ComboBox joinMode = new ComboBox();
        private readonly TextBox domain = new TextBox();
        private readonly TextBox dnsHostName = new TextBox();
        private readonly TextBox instance = new TextBox { Text = "localhost" };
        private readonly CheckBox license = new CheckBox { Content = "I accept the Microsoft Developer/evaluation license terms." };
        private readonly RadioButton strictOs = new RadioButton { Content = "Require supported OS (recommended)", GroupName = "OsValidation", IsChecked = true };
        private readonly RadioButton unsupportedOs = new RadioButton { Content = "Try unsupported OS (lab only; may fail)", GroupName = "OsValidation" };
        private readonly TextBlock machine = new TextBlock { TextWrapping = TextWrapping.Wrap };
        private readonly TextBlock notes = new TextBlock { TextWrapping = TextWrapping.Wrap, LineHeight = 19,
            Foreground = new SolidColorBrush(Color.FromRgb(51, 65, 85)) };
        private readonly TextBlock status = new TextBlock { Text = "Loading VM information...", TextWrapping = TextWrapping.Wrap };
        private readonly TextBlock errors = new TextBlock { Foreground = Brushes.Firebrick, TextWrapping = TextWrapping.Wrap };
        private readonly TextBox logs = new TextBox { IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontFamily = new FontFamily("Consolas"), FontSize = 12 };
        private readonly ProgressBar progress = new ProgressBar { Minimum = 0, Maximum = 100, Height = 15 };
        private readonly Button start = new Button { Content = "Start installation" };
        private readonly Button resume = new Button { Content = "Resume saved setup" };
        private readonly Button refresh = new Button { Content = "Refresh" };
        private readonly TextBlock refreshNote = new TextBlock { Text = AutoRefreshMessage,
            TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 6) };
        private readonly DispatcherTimer timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(10) };
        private readonly Dictionary<string, Dictionary<string, object>> releases = new Dictionary<string, Dictionary<string, object>>();
        private bool metadataReady, serverAllowed, joinedDomain, snapshotReady, hasState, canResume, refreshing, clientOs, legacySsms, windowClosed;
        private string detectedDomain = "", computerName = "";
        private Process console;

        public SetupWindow()
        {
            Title = "AdoServerLabAutoOrchestrator";
            using (var stream = typeof(SetupWindow).Assembly.GetManifestResourceStream("AdoServerLabAutoOrchestrator.AppIcon.ico"))
            {
                if (stream == null) throw new InvalidDataException("Embedded application icon is missing.");
                var decoder = new IconBitmapDecoder(stream, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                Icon = decoder.Frames[decoder.Frames.Count - 1];
            }
            Width = 980; Height = 920; MinWidth = 800; MinHeight = 780;
            var root = new Grid { Margin = new Thickness(18) };
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(3, GridUnitType.Star) });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star), MinHeight = 120 });
            var panel = new StackPanel();
            root.Children.Add(new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
            panel.Children.Add(new TextBlock { Text = "AdoServerLabAutoOrchestrator", FontSize = 24, FontWeight = FontWeights.SemiBold });
            panel.Children.Add(machine);
            panel.Children.Add(new TextBlock { Text = "Windows Server or supported Windows 10/11 lab: Domain or Workgroup; no domain controllers. Automatic reboots; no backups or Azure provisioning.",
                TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 10) });
            var form = new Grid();
            form.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(150) });
            form.ColumnDefinitions.Add(new ColumnDefinition());
            AddField(form, 0, "DevOps / SQL version", version);
            AddField(form, 1, "Components", components);
            AddField(form, 2, "DevOps patch", patch);
            AddField(form, 3, "Email", email);
            AddField(form, 4, "Membership mode", joinMode);
            AddField(form, 5, "Existing AD domain", domain);
            AddField(form, 6, "DNS hostname", dnsHostName);
            AddField(form, 7, "Local SQL instance", instance);
            panel.Children.Add(form);
            var osChoices = new WrapPanel { Margin = new Thickness(0, 8, 0, 8) };
            strictOs.Margin = new Thickness(0, 0, 16, 0);
            osChoices.Children.Add(strictOs); osChoices.Children.Add(unsupportedOs);
            panel.Children.Add(osChoices);
            joinMode.Items.Add(new Choice("Domain", "Domain (already joined)"));
            joinMode.Items.Add(new Choice("Workgroup", "Workgroup (local Windows account)"));
            joinMode.SelectedIndex = 0;
            components.Items.Add(new Choice("Both", "SQL + Azure DevOps"));
            components.Items.Add(new Choice("SqlOnly", "SQL only (includes SSMS)"));
            components.Items.Add(new Choice("DevOpsOnly", "Azure DevOps only (existing local SQL)"));
            components.SelectedIndex = 0;
            email.Items.Add(new Choice("Capture", "Local SMTP capture"));
            email.Items.Add(new Choice("None", "No SMTP setup"));
            email.SelectedIndex = 0;
            panel.Children.Add(new Border { Child = notes, Padding = new Thickness(12), CornerRadius = new CornerRadius(6),
                Margin = new Thickness(0, 4, 0, 0), BorderThickness = new Thickness(1),
                BorderBrush = new SolidColorBrush(Color.FromRgb(203, 213, 225)),
                Background = new SolidColorBrush(Color.FromRgb(248, 250, 252)) });
            license.Margin = new Thickness(0, 10, 0, 8); panel.Children.Add(license);
            var buttons = new WrapPanel();
            foreach (var button in new[] { start, resume, refresh })
            {
                button.Margin = new Thickness(0, 0, 8, 8); button.Padding = new Thickness(12, 6, 12, 6);
                buttons.Children.Add(button);
            }
            var docs = new Button { Content = "License / setup documentation", Padding = new Thickness(12, 6, 12, 6) };
            docs.Click += delegate { OpenPath(Path.Combine(folder, @"GuestSetup\README.md")); };
            buttons.Children.Add(docs); panel.Children.Add(buttons);
            panel.Children.Add(status); panel.Children.Add(progress); panel.Children.Add(errors);
            panel.Children.Add(refreshNote);
            Grid.SetRow(logs, 1); root.Children.Add(logs); Content = root;
            version.SelectionChanged += delegate { UpdateOptions(); };
            components.SelectionChanged += delegate { UpdateOptions(); };
            joinMode.SelectionChanged += delegate { UpdateMembership(); };
            patch.SelectionChanged += delegate { UpdateNotes(); };
            license.Checked += delegate { UpdateButtons(); };
            license.Unchecked += delegate { UpdateButtons(); };
            strictOs.Checked += delegate { UpdateNotes(); UpdateButtons(); };
            unsupportedOs.Checked += delegate { UpdateNotes(); UpdateButtons(); };
            start.Click += delegate { Launch(false); };
            resume.Click += delegate { Launch(true); };
            refresh.Click += async delegate { await RefreshSnapshot(); };
            timer.Tick += async delegate { await RefreshSnapshot(); };
            Loaded += async delegate
            {
                await LoadMetadata();
                if (!windowClosed) { timer.Start(); await RefreshSnapshot(); }
            };
            Closed += delegate { windowClosed = true; timer.Stop(); if (console != null) console.Dispose(); };
            UpdateButtons();
        }

        private static void AddField(Grid grid, int row, string title, Control control)
        {
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var label = new TextBlock { Text = title, VerticalAlignment = VerticalAlignment.Center };
            control.Margin = new Thickness(0, 3, 0, 3);
            control.MinHeight = 27;
            Grid.SetRow(label, row); Grid.SetRow(control, row); Grid.SetColumn(control, 1);
            grid.Children.Add(label); grid.Children.Add(control);
        }

        private static string Value(ComboBox box)
        {
            var selected = box.SelectedItem as Choice;
            return selected == null ? "" : selected.Value;
        }

        private static void SelectChoice(ComboBox box, string value)
        {
            foreach (Choice choice in box.Items)
                if (choice.Value == value) { box.SelectedItem = choice; return; }
            throw new InvalidDataException("Saved choice is not present in the UI: " + value);
        }

        public static string Quote(string text) { return "'" + text.Replace("'", "''") + "'"; }
        public static string Encode(string text) { return Convert.ToBase64String(Encoding.Unicode.GetBytes(text)); }

        private static string Text(Dictionary<string, object> data, string key)
        {
            object value;
            if (!data.TryGetValue(key, out value)) throw new InvalidDataException("Missing bridge field: " + key);
            return Convert.ToString(value);
        }

        private static bool Flag(Dictionary<string, object> data, string key)
        {
            object value;
            if (!data.TryGetValue(key, out value) || !(value is bool)) throw new InvalidDataException("Invalid bridge flag: " + key);
            return (bool)value;
        }

        private async Task<Dictionary<string, object>> ReadBridge(string mode)
        {
            return await Task.Run(async delegate
            {
                var command = "& " + Quote(Path.Combine(folder, "SetupBridge.ps1")) + " -Mode " + Quote(mode);
                var info = new ProcessStartInfo(powershell, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + Encode(command));
                info.UseShellExecute = false; info.CreateNoWindow = true;
                info.RedirectStandardOutput = true; info.RedirectStandardError = true;
                info.StandardOutputEncoding = Encoding.UTF8; info.StandardErrorEncoding = Encoding.UTF8;
                using (var process = Process.Start(info))
                {
                    if (process == null) throw new InvalidOperationException("Could not start PowerShell bridge.");
                    var outputTask = process.StandardOutput.ReadToEndAsync();
                    var errorTask = process.StandardError.ReadToEndAsync();
                    if (!process.WaitForExit(60000))
                    {
                        process.Kill();
                        throw new TimeoutException("PowerShell bridge exceeded 60 seconds. Refresh to retry.");
                    }
                    var output = await outputTask;
                    var error = await errorTask;
                    if (process.ExitCode != 0) throw new InvalidOperationException("PowerShell bridge failed:\n" + error);
                    var data = new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024 }.DeserializeObject(output) as Dictionary<string, object>;
                    if (data == null) throw new InvalidDataException("Invalid bridge JSON.");
                    return data;
                }
            });
        }

        private async Task LoadMetadata()
        {
            try
            {
                foreach (var name in new[] { "SetupBridge.ps1", @"GuestSetup\Setup-Server.ps1", @"GuestSetup\Resume-Setup.ps1",
                    @"GuestSetup\Setup-Releases.psm1", @"GuestSetup\Setup-State.psm1", @"GuestSetup\Setup-Monitoring.psm1", @"GuestSetup\README.md" })
                    if (!File.Exists(Path.Combine(folder, name))) throw new FileNotFoundException("Keep the full extracted package together: " + name);
                var data = await ReadBridge("Metadata");
                serverAllowed = Flag(data, "ServerAllowed");
                clientOs = Flag(data, "ClientOs");
                legacySsms = Flag(data, "LegacySsms");
                joinedDomain = Flag(data, "JoinedDomain");
                detectedDomain = Text(data, "Domain");
                computerName = Text(data, "ComputerName");
                domain.Text = joinedDomain ? detectedDomain : "";
                machine.Text = Text(data, "Os") + " | " + Text(data, "Account");
                var items = data["Releases"] as IEnumerable;
                if (items == null) throw new InvalidDataException("Missing release metadata.");
                foreach (var item in items)
                {
                    var release = item as Dictionary<string, object>;
                    if (release == null) throw new InvalidDataException("Invalid release metadata.");
                    var key = Text(release, "Version");
                    releases.Add(key, release);
                    string label = key == "2022.1" ? "2022 Update 1" : key == "2022" ? "2022 Update 2" :
                        key == "26H2-RC" ? "26H2 RC (preview / lab)" : key;
                    version.Items.Add(new Choice(key, "DevOps " + label + " / SQL " + Text(release, "SqlYear") +
                        (Flag(release, "Supported") ? "" : " (not supported on this OS)")));
                }
                metadataReady = true;
                foreach (Choice choice in version.Items)
                    if (Flag(releases[choice.Value], "Supported")) version.SelectedItem = choice;
                if (version.SelectedIndex < 0) version.SelectedIndex = 0;
                UpdateMembership();
                if (!serverAllowed) errors.Text = "A supported Windows Server or Windows 10/11 lab VM (not a domain controller) is required.";
            }
            catch (Exception ex) { errors.Text = "VM metadata could not be loaded: " + ex.Message; }
            UpdateButtons();
        }

        private void UpdateOptions()
        {
            if (!metadataReady) return;
            string oldPatch = Value(patch);
            patch.Items.Clear();
            bool releaseCandidate = Value(version) == "26H2-RC";
            if (!releaseCandidate) patch.Items.Add(new Choice("Latest", "Latest executable patch"));
            patch.Items.Add(new Choice("Skip", releaseCandidate ? "No RC patches published in this catalog" : "Skip patch (security gaps possible)"));
            Dictionary<string, object> release;
            if (releases.TryGetValue(Value(version), out release))
            {
                foreach (Dictionary<string, object> item in (IEnumerable)release["Patches"])
                    if (Flag(item, "Installable")) patch.Items.Add(new Choice(Text(item, "Number"), "Patch " + Text(item, "Number")));
            }
            patch.SelectedIndex = 0;
            foreach (Choice choice in patch.Items) if (choice.Value == oldPatch) patch.SelectedItem = choice;
            if (Value(components) == "SqlOnly") { SelectChoice(patch, "Skip"); email.SelectedIndex = 1; }
            if (legacySsms) email.SelectedIndex = 1;
            instance.IsEnabled = !hasState && Value(components) == "DevOpsOnly";
            if (Value(components) != "DevOpsOnly") instance.Text = "localhost";
            patch.IsEnabled = !hasState && Value(components) != "SqlOnly" && !releaseCandidate;
            email.IsEnabled = !hasState && Value(components) != "SqlOnly" && !legacySsms;
            UpdateNotes(); UpdateButtons();
        }

        private void UpdateNotes()
        {
            notes.Inlines.Clear();
            if (unsupportedOs.IsChecked == true)
                AddNotice("WARNING - Unsupported OS override", "You accept an unsupported OS version/build. Installation may fail or be unsupported. This acknowledgement is saved for reboot/resume. Architecture, edition, domain-controller, IIS, SQL and account checks still apply.", NoticeDanger);
            Dictionary<string, object> release;
            bool found = releases.TryGetValue(Value(version), out release);
            if (found && !Flag(release, "Supported"))
            {
                AddNotice("ATTENTION - OS compatibility", Text(release, "UnsupportedReason"), NoticeWarning);
                if (!Flag(release, "CanOverrideOs"))
                    AddNotice("BLOCKED - Prerequisite cannot be overridden", Text(release, "OverrideBlockedReason"), NoticeDanger);
            }
            if (Value(version) == "26H2-RC")
                AddNotice("CAUTION - 26H2 Release Candidate", "Pre-release for disposable test deployments, not the final release. No standalone RC patches are cataloged; 25H2 patches do not apply. This workflow supports fresh setup only, not RC-to-final upgrades.", NoticeWarning);
            else if (Value(patch) == "Skip")
                AddNotice("CAUTION - Security patches skipped", "Skipping patches can leave security fixes missing.", NoticeWarning);
            if (Value(version) == "2022.1")
                AddNotice("CAUTION - Older Update 1 release", "Older Update 1 release for controlled lab reproduction; later Update 2 security fixes are not included.", NoticeWarning);
            if (legacySsms)
                AddNotice("CAUTION - Windows 10 limitations", "Windows 10 uses archived SSMS 20.2.1, not SSMS 22; review security requirements. SMTP capture is unavailable because its .NET 10 runtime does not support every Windows 10 lab version.", NoticeWarning);
            if (clientOs)
                AddNotice("INFO - Client Windows lab", "Client Windows: evaluation/personal use only; no DevOps Proxy. Check Windows lifecycle/ESU requirements. IIS prerequisites can require a reboot.", NoticeInfo);
            if (Value(joinMode) == "Workgroup")
                AddNotice("INFO - Workgroup prerequisites", "Workgroup: a local account and trusted Private network are required. Custom DNS must already point to this VM; remote clients must trust the certificate.", NoticeInfo);
            if (found)
            {
                foreach (Dictionary<string, object> item in (IEnumerable)release["Patches"])
                    if (Text(item, "Number") == Value(patch) && !String.IsNullOrWhiteSpace(Text(item, "Notes")))
                        AddNotice("CAUTION - Selected patch", Text(item, "Notes"), NoticeWarning);
            }
            AddNotice("INFO - Patch selection", "Only supported executable patches are offered. 2020 Patch 10 requires manual task uploads and is excluded.", NoticeInfo);
        }

        private void AddNotice(string title, string message, Brush accent)
        {
            if (notes.Inlines.Count != 0)
            {
                notes.Inlines.Add(new LineBreak());
                notes.Inlines.Add(new LineBreak());
            }
            notes.Inlines.Add(new Run(title) { FontWeight = FontWeights.SemiBold, Foreground = accent });
            notes.Inlines.Add(new LineBreak());
            notes.Inlines.Add(new Run(message));
        }

        private void UpdateMembership()
        {
            if (!metadataReady) return;
            dnsHostName.Text = Value(joinMode) == "Domain" ?
                (computerName + "." + detectedDomain).ToLowerInvariant() : computerName.ToLowerInvariant();
            UpdateNotes(); UpdateButtons();
        }

        private bool ConsoleActive()
        {
            return console != null && !console.HasExited;
        }

        private void UpdateButtons()
        {
            Dictionary<string, object> release;
            bool found = releases.TryGetValue(Value(version), out release);
            bool supported = found && Flag(release, "Supported");
            bool canOverrideOs = found && Flag(release, "CanOverrideOs");
            if (!hasState && unsupportedOs.IsChecked == true && !canOverrideOs) strictOs.IsChecked = true;
            bool osAllowed = supported || (unsupportedOs.IsChecked == true && canOverrideOs);
            bool membershipMatches = Value(joinMode) == "Domain" ? joinedDomain : !joinedDomain;
            start.IsEnabled = metadataReady && serverAllowed && membershipMatches && snapshotReady && !hasState && osAllowed &&
                license.IsChecked == true && !ConsoleActive();
            resume.IsEnabled = snapshotReady && canResume && !ConsoleActive();
            version.IsEnabled = components.IsEnabled = joinMode.IsEnabled = license.IsEnabled = !hasState && !ConsoleActive();
            domain.IsEnabled = !hasState && !ConsoleActive() && Value(joinMode) == "Domain";
            dnsHostName.IsEnabled = !hasState && !ConsoleActive() && Value(joinMode) == "Workgroup";
            strictOs.IsEnabled = !hasState && !ConsoleActive();
            unsupportedOs.IsEnabled = !hasState && !ConsoleActive() && canOverrideOs;
        }

        private async Task RefreshSnapshot()
        {
            if (refreshing) return;
            refreshing = true; refresh.IsEnabled = false;
            try
            {
                if (!metadataReady) await LoadMetadata();
                var data = await ReadBridge("Snapshot");
                snapshotReady = true; hasState = Flag(data, "HasState"); canResume = Flag(data, "CanResume");
                if (hasState && metadataReady)
                {
                    SelectChoice(version, Text(data, "Version"));
                    SelectChoice(components, Text(data, "Components"));
                    SelectChoice(joinMode, Text(data, "JoinMode"));
                    SelectChoice(patch, Text(data, "PatchSelection"));
                    SelectChoice(email, Text(data, "Email"));
                    domain.Text = Text(data, "DomainName");
                    dnsHostName.Text = Text(data, "DnsHostName");
                    if (Flag(data, "AllowUnsupportedOs")) unsupportedOs.IsChecked = true;
                    else strictOs.IsChecked = true;
                    UpdateNotes();
                }
                status.Text = Text(data, "Status") + "\n" + Text(data, "Summary");
                progress.Value = Convert.ToDouble(data["Progress"]);
                errors.Text = Text(data, "Error");
                if (metadataReady && !serverAllowed) errors.Text += "\nA supported Windows Server or Windows 10/11 lab VM (not a domain controller) is required.";
                else if (metadataReady && (Value(joinMode) == "Domain" ? !joinedDomain : joinedDomain))
                    errors.Text += "\nChoose the mode matching this VM's existing membership; the UI does not join/unjoin domains.";
                logs.Text = Text(data, "Logs");
                logs.ScrollToEnd();
                UpdateOptions();
                if (Text(data, "Status") == "Completed")
                {
                    timer.Stop();
                    refreshNote.Text = "Setup completed. Automatic refresh stopped. Use Refresh to check status again.";
                }
                else if (!windowClosed)
                {
                    timer.Start();
                    refreshNote.Text = AutoRefreshMessage;
                }
            }
            catch (Exception ex)
            {
                snapshotReady = false;
                errors.Text = "Monitoring failed (no success assumed): " + ex.Message;
            }
            finally { refreshing = false; refresh.IsEnabled = true; UpdateButtons(); }
        }

        private string BuildLauncherCommand(bool retry)
        {
            string script = Path.Combine(folder, @"GuestSetup\Setup-Server.ps1");
            string command = "& " + Quote(script);
            if (retry) return command + " -Resume -Confirm:$false";
            if ((Value(joinMode) == "Domain" && String.IsNullOrWhiteSpace(domain.Text)) ||
                String.IsNullOrWhiteSpace(instance.Text) || String.IsNullOrWhiteSpace(dnsHostName.Text))
                throw new InvalidOperationException("Enter the hostname, local SQL instance and (in Domain mode) existing domain.");
            return command + " -Version " + Quote(Value(version)) + " -Components " + Quote(Value(components)) +
                " -Patch " + Quote(Value(patch)) + " -Email " + Quote(Value(email)) +
                " -JoinMode " + Quote(Value(joinMode)) + " -DnsHostName " + Quote(dnsHostName.Text.Trim()) +
                (Value(joinMode) == "Domain" ? " -DomainName " + Quote(domain.Text.Trim()) : "") +
                " -SqlInstance " + Quote(instance.Text.Trim()) +
                (unsupportedOs.IsChecked == true ? " -AllowUnsupportedOs" : "") +
                " -AcceptLicenseTerms -Confirm:$false";
        }

        private void Launch(bool retry)
        {
            try
            {
                if (ConsoleActive()) throw new InvalidOperationException("The launcher console is still open. Follow its prompt/output first.");
                string command = BuildLauncherCommand(retry);
                string warning = retry ? "Retry the saved plan after repairing its failure? Required reboots are automatic." :
                    "Install the selected software on this VM? Reboots are automatic and no backups are created.\n\nEnter your Windows password in the PowerShell console that opens.";
                if (unsupportedOs.IsChecked == true) warning += "\n\nLAB OVERRIDE: You accept an unsupported OS version/build. Installation may fail or be unsupported. Other prerequisite checks and Microsoft installer checks remain active.";
                if (MessageBox.Show(warning,
                    "Approve setup", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
                command = "$ErrorActionPreference='Stop'; try { " + command +
                    "; Write-Host 'Launcher finished. Check the UI saved status for installation progress; you may now close this console.' } catch { Write-Error -ErrorRecord $_ -ErrorAction Continue }";
                var info = new ProcessStartInfo(powershell, "-NoProfile -NoExit -ExecutionPolicy Bypass -EncodedCommand " + Encode(command));
                info.UseShellExecute = true; info.WorkingDirectory = folder;
                if (console != null) console.Dispose();
                console = Process.Start(info);
                if (console == null) throw new InvalidOperationException("PowerShell console did not start.");
                status.Text = "Launcher console opened, NOT installation completion. Follow the console password prompt and any errors.";
                UpdateButtons();
            }
            catch (Exception ex) { MessageBox.Show(ex.Message, "Could not launch setup", MessageBoxButton.OK, MessageBoxImage.Error); }
        }

        private static void OpenPath(string path)
        {
            try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
            catch (Exception ex) { MessageBox.Show(ex.Message, "Could not open documentation", MessageBoxButton.OK, MessageBoxImage.Error); }
        }
    }
}
