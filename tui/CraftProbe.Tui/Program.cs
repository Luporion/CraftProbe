using System.Collections.Concurrent;
using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Terminal.Gui.App;
using Terminal.Gui.ViewBase;
using Terminal.Gui.Views;

// CraftProbe v0.6.3 — shared Terminal.Gui 2.5.0 UI: PowerShell on Windows, Linux agent on Linux.
// UI changes never discard a running recording. All UI interactions stay on the UI thread.
var root = FindRoot(AppContext.BaseDirectory);
if (root is null)
{
    Console.Error.WriteLine("Recorder not found. Launch from CraftProbe.cmd (Windows) or ./craftprobe (Linux).");
    return 3;
}
var linuxPlatform = OperatingSystem.IsLinux();
var recorderPath = Path.Combine(root, "src", "Minecraft-Diagnose-Recorder.ps1");
var linuxAgentPath = Path.Combine(root, "linux", "craftprobe_agent.py");
var prefs = PathSettings.Load();

using IApplication app = Application.Create();
app.Init();
using var window = new Window { Title = "CraftProbe v0.6.3 | Minecraft Diagnosis" };
var recordNav = new Button { X = 1, Y = 1, Text = "_Aufnahme" };
var historyNav = new Button { X = 15, Y = 1, Text = "_Aufnahmen" };
var consoleNav = new Button { X = 31, Y = 1, Text = "_Konsole" };
var settingsNav = new Button { X = 45, Y = 1, Text = "_Einstellungen" };
var exitNav = new Button { X = 66, Y = 1, Text = "_Beenden" };
var screenCapture = new View { X = 0, Y = 3, Width = Dim.Fill(), Height = Dim.Fill() };
var screenHistory = new View { X = 0, Y = 3, Width = Dim.Fill(), Height = Dim.Fill(), Visible = false };
var screenConsole = new View { X = 0, Y = 3, Width = Dim.Fill(), Height = Dim.Fill(), Visible = false };
var screenSettings = new View { X = 0, Y = 3, Width = Dim.Fill(), Height = Dim.Fill(), Visible = false };
window.Add(recordNav, historyNav, consoleNav, settingsNav, exitNav, screenCapture, screenHistory, screenConsole, screenSettings);

var profileLabel = new Label { X = 1, Y = 0, Text = "Minecraft-Profil:" };
var profileChoices = new DropDownList
{
    X = 20, Y = 0, Width = Dim.Fill(2), ReadOnly = false,
    Source = Choices(prefs.Profiles), Text = prefs.InitialProfile
};
var exportLabel = new Label { X = 1, Y = 2, Text = "Exportziel:" };
var exportChoices = new DropDownList
{
    X = 20, Y = 2, Width = Dim.Fill(2), ReadOnly = false,
    Source = Choices(prefs.ExportPaths), Text = prefs.InitialOutput
};
var exportHint = new Label { X = 1, Y = 4, Width = Dim.Fill(2), Text = "Bei Profilordner: ZIPs automatisch in _CraftProbe-Exports/" };
var contextLabel = new Label { X = 1, Y = 5, Text = "Session-Kontext / eigene Notizen (optional):" };
var contextEditor = new TextView { X = 1, Y = 6, Width = Dim.Fill(2), Height = 3, ReadOnly = false, Text = "" };
var startButton = new Button { X = 1, Y = 10, Text = "_Aufnahme starten" };
var incidentButton = new Button { X = 26, Y = 10, Text = "_Ereignis (Alt+E)", Enabled = false };
var saveContext = new Button { X = 51, Y = 10, Text = "_Notiz speichern" };
var status = new Label { X = 1, Y = 12, Width = Dim.Fill(2), Text = "Bereit. Minecraft kann bereits laufen oder spaeter gestartet werden." };
var jfr = new Label { X = 1, Y = 13, Width = Dim.Fill(2), Text = "JFR: noch nicht gestartet" };
var runtime = new Label { X = 1, Y = 14, Width = Dim.Fill(2), Text = "Aufnahme: --:--:--     Stalls: 0     Incidents: 0" };
var exportProgress = new Label { X = 1, Y = 15, Width = Dim.Fill(2), Text = "" };
var eventsLabel = new Label { X = 1, Y = 16, Width = Dim.Fill(2), Text = "Live-Ereignisse" };
var outputView = new TextView { X = 1, Y = 17, Width = Dim.Fill(2), Height = Dim.Fill(1), ReadOnly = true, Text = "Noch keine Aufnahme." };
screenCapture.Add(profileLabel, profileChoices, exportLabel, exportChoices, exportHint,
    contextLabel, contextEditor, startButton, incidentButton, saveContext, status, jfr, runtime, exportProgress, eventsLabel, outputView);

var historyHeader = new Label { X = 1, Y = 0, Width = Dim.Fill(2), Text = "Vorhandene Aufnahmen (auch ZIPs aelterer CraftProbe-Versionen)" };
var historyList = new ListView { X = 1, Y = 2, Width = Dim.Fill(2), Height = 9 };
var historyRefresh = new Button { X = 1, Y = 12, Text = "_Aktualisieren" };
var historyOpen = new Button { X = 23, Y = 12, Text = "Ordner _oeffnen" };
var historyDetail = new TextView { X = 1, Y = 15, Width = Dim.Fill(2), Height = Dim.Fill(1), ReadOnly = true, Text = "Noch keine Aufnahme ausgewaehlt." };
screenHistory.Add(historyHeader, historyList, historyRefresh, historyOpen, historyDetail);

// Read-only live client logs require no Minecraft mod and work independently of the recorder.
// Remote commands use RCON only when the operator explicitly configured the server and a password.
var consoleHeader = new Label { X = 1, Y = 0, Width = Dim.Fill(2), Text = "Game-Konsole: Live-Logs / Singleplayer-Companion / Server-RCON" };
var consoleState = new Label { X = 1, Y = 1, Width = Dim.Fill(2), Text = "Logquelle: logs/latest.log" };
var consoleSearchLabel = new Label { X = 1, Y = 2, Text = "Suchen:" };
var consoleSearch = new TextField { X = 10, Y = 2, Width = 30, Text = "" };
var consoleLevelLabel = new Label { X = 43, Y = 2, Text = "Filter:" };
var consoleLevel = new DropDownList { X = 52, Y = 2, Width = 21, ReadOnly = true,
    Source = Choices(new[] { "Alle", "Warnungen + Fehler", "Nur Fehler" }), Text = "Alle" };
// TextView's native v2.5 scrollbars track the actual content, without wrapping long log lines.
// The scroll controller below preserves user position across incremental log refreshes.
var consoleLog = new TextView { X = 1, Y = 4, Width = Dim.Fill(2), Height = Dim.Fill(10),
    ReadOnly = true, CanFocus = true, WordWrap = false, ScrollBars = true,
    Text = "Noch keine Minecraft-Logs vorhanden." };
// Preserve TextView's default viewport flags (it uses them internally for cursor movement).
consoleLog.ViewportSettings |= ViewportSettingsFlags.HasScrollBars;
var consolePause = new Button { X = 1, Y = Pos.AnchorEnd(9), Text = "_Pause" };
var consoleRefresh = new Button { X = 15, Y = Pos.AnchorEnd(9), Text = "_Aktualisieren" };
var consoleSave = new Button { X = 37, Y = Pos.AnchorEnd(9), Text = "_Auszug speichern" };
var consoleIncident = new Button { X = 61, Y = Pos.AnchorEnd(9), Text = "_Incident", Enabled = false };
var consoleBottom = new Button { X = 1, Y = Pos.AnchorEnd(8), Text = "_Ganz nach unten" };
var consoleScrollStatus = new Label { X = 23, Y = Pos.AnchorEnd(8), Width = Dim.Fill(2),
    Text = "Auto-Follow: AN  |  Strg+End: zum Log-Ende" };
var consoleHelp = new Label { X = 1, Y = Pos.AnchorEnd(7), Width = Dim.Fill(2),
    Text = "Client: /craftprobe enable im Spiel. Server: RCON. Befehle nutzen vorhandene Rechte." };
var commandModeLabel = new Label { X = 1, Y = Pos.AnchorEnd(6), Text = "Befehle ueber:" };
var commandMode = new DropDownList { X = 17, Y = Pos.AnchorEnd(6), Width = 28, ReadOnly = true,
    Source = Choices(new[] { "Singleplayer Companion", "Server RCON" }), Text = "Singleplayer Companion" };
var companionStatusLabel = new Label { X = 47, Y = Pos.AnchorEnd(6), Width = Dim.Fill(2), Text = "Companion: pruefen..." };
var rconAddressLabel = new Label { X = 1, Y = Pos.AnchorEnd(5), Text = "RCON-Host:" };
var rconAddress = new TextField { X = 15, Y = Pos.AnchorEnd(5), Width = 25,
    Text = Environment.GetEnvironmentVariable("CRAFTPROBE_RCON_ADDRESS") ?? "127.0.0.1:25575" };
var rconSecurity = new Label { X = 43, Y = Pos.AnchorEnd(5), Width = Dim.Fill(2),
    Text = "Passwort: Umgebungsvariable" };
var consoleCommandLabel = new Label { X = 1, Y = Pos.AnchorEnd(3), Text = "Minecraft-Befehl:" };
var consoleCommand = new TextField { X = 17, Y = Pos.AnchorEnd(3), Width = Dim.Fill(19), Text = "" };
var consoleSend = new Button { X = Pos.AnchorEnd(16), Y = Pos.AnchorEnd(3), Text = "_Senden" };
var consoleFooter = new Label { X = 1, Y = Pos.AnchorEnd(1), Width = Dim.Fill(2),
    Text = "RCON benoetigt enable-rcon=true und CRAFTPROBE_RCON_PASSWORD (siehe Doku)." };
screenConsole.Add(consoleHeader, consoleState, consoleSearchLabel, consoleSearch, consoleLevelLabel,
    consoleLevel, consoleLog, consolePause, consoleRefresh, consoleSave, consoleIncident,
    consoleBottom, consoleScrollStatus, consoleHelp, commandModeLabel, commandMode, companionStatusLabel, rconAddressLabel, rconAddress, rconSecurity, consoleCommandLabel,
    consoleCommand, consoleSend, consoleFooter);

var settingsInfo = new Label { X = 1, Y = 0, Width = Dim.Fill(2), Text = "Verzeichnisse direkt in den Dropdowns eingeben oder gespeicherte auswaehlen." };
var settingsInfo2 = new Label { X = 1, Y = 2, Width = Dim.Fill(2), Text = "Profil- und Exportauswahl werden beim Start automatisch gespeichert." };
var settingsInfo3 = new Label { X = 1, Y = 4, Width = Dim.Fill(2), Text = "Der bisherige CLI-Modus bleibt mit craftprobe --cli verfuegbar." };
var settingsReload = new Button { X = 1, Y = 6, Text = "_Pfade neu laden" };
var settingsDetail = new Label { X = 1, Y = 9, Width = Dim.Fill(2), Text = "Settings: " + PathSettings.SettingsFile };
screenSettings.Add(settingsInfo, settingsInfo2, settingsInfo3, settingsReload, settingsDetail);

Process? recorder = null;
string? eventsPath = null;
string? commandsPath = null;
string? contextPath = null;
string? childLogPath = null;
DateTimeOffset? startedAt = null;
DateTimeOffset? recordingStoppedAt = null;
RecorderPhase phase = RecorderPhase.Idle;
int lastExportStep = 0;
string[] exportStepNames = { "JFR sichern", "Recorder abschliessen", "Session-Daten sammeln", "ZIPs erstellen" };
var recent = new Queue<string>();
var incomingConsole = new ConcurrentQueue<string>();
var rconResults = new ConcurrentQueue<string>();
var consoleRconHistory = new Queue<string>();
var consoleTail = new MinecraftLogTail();
var consoleScroll = new ConsoleLogScrollState();
int consoleDisplayedRows = 1;
int consoleMatchedEvictions = 0;
var consoleBuffer = new Queue<string>();
var consolePaused = false;
var consoleDirty = true;
var lastConsoleQuery = "";
var lastConsoleLevel = "Alle";
var lastConsoleProfile = "";
var consoleWarns = 0;
var consoleErrors = 0;
var rconBusy = 0;
var companionLastStatus = "";
var pendingCompanion = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
string previousProfile = prefs.InitialProfile;
var recordings = new List<Recording>();
int consumedEvents = 0, stalls = 0, incidents = 0;
int oldSelected = -1;

void AddLine(string message)
{
    recent.Enqueue(message);
    while (recent.Count > 80) recent.Dequeue();
    outputView.Text = string.Join(Environment.NewLine, recent);
}

void Show(View screen)
{
    screenCapture.Visible = screen == screenCapture;
    screenHistory.Visible = screen == screenHistory;
    screenConsole.Visible = screen == screenConsole;
    screenSettings.Visible = screen == screenSettings;
}

string CurrentProfile() => (profileChoices.Text?.ToString() ?? "").Trim().Trim('"');
string CurrentOutput() => (exportChoices.Text?.ToString() ?? "").Trim().Trim('"');

string EffectiveOutput()
{
    var profile = CurrentProfile();
    var desired = CurrentOutput();
    if (string.IsNullOrWhiteSpace(desired) || desired == PathSettings.ProfileToken || SameDirectory(profile, desired))
        return Path.Combine(profile, "_CraftProbe-Exports");
    return desired;
}

// Keep the profile-root export default aligned with the selected Minecraft instance.
profileChoices.ValueChanged += (_, _) =>
{
    var current = profileChoices.Text?.ToString()?.Trim().Trim('"') ?? "";
    var export = exportChoices.Text?.ToString()?.Trim().Trim('"') ?? "";
    if (export == PathSettings.ProfileToken || (previousProfile.Length > 0 && SameDirectory(previousProfile, export)))
        exportChoices.Text = current;
    previousProfile = current;
};

void WriteContext()
{
    if (contextPath is null) return;
    var contents = new
    {
        schema = 1,
        source = "user",
        updatedAt = DateTimeOffset.Now.ToString("O"),
        notes = contextEditor.Text?.ToString() ?? ""
    };
    // Atomic replace so the recorder never sees a partially-written JSON document.
    var tmp = contextPath + ".new";
    File.WriteAllText(tmp, JsonSerializer.Serialize(contents, new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
    File.Move(tmp, contextPath, true);
}

static DateTimeOffset ReadEventTime(string raw)
{
    return DateTimeOffset.TryParse(raw, System.Globalization.CultureInfo.InvariantCulture,
        System.Globalization.DateTimeStyles.RoundtripKind, out var time) ? time : DateTimeOffset.Now;
}

void FreezeRecording(DateTimeOffset at)
{
    // The lifetime of the Minecraft process, not the later ZIP export, ends the timer.
    if (startedAt.HasValue && !recordingStoppedAt.HasValue)
        recordingStoppedAt = at < startedAt.Value ? startedAt.Value : at;
}

void SetPhase(RecorderPhase next)
{
    // A late/queued event must never move a finished or failed recording backwards.
    if ((phase == RecorderPhase.Completed || phase == RecorderPhase.Failed) &&
        next != RecorderPhase.Waiting && next != RecorderPhase.Idle) return;
    phase = next;
    incidentButton.Enabled = phase == RecorderPhase.Recording;
    consoleIncident.Enabled = phase == RecorderPhase.Recording;
}

void SetExportStep(int step, string description)
{
    if (step < 1 || step > exportStepNames.Length) return;
    if (step <= lastExportStep) return;
    lastExportStep = step;
    SetPhase(RecorderPhase.Exporting);
    exportProgress.Text = $"Export: Schritt {step}/4 – {exportStepNames[step - 1]}";
    status.Text = "Export laeuft: " + description;
}

void StartRecording()
{
    if (recorder is { HasExited: false })
    {
        AddLine("Eine Aufnahme laeuft bereits. Minecraft normal beenden, damit die ZIPs erzeugt werden.");
        return;
    }
    if (recorder is { HasExited: true }) { recorder.Dispose(); recorder = null; }
    var profile = CurrentProfile();
    if (!Directory.Exists(profile) || !LooksLikeMinecraft(profile))
    {
        status.Text = "Ungueltiger Profilordner (mods/config/logs/saves erforderlich).";
        return;
    }
    profile = Path.GetFullPath(profile);
    var requestedOutput = CurrentOutput();
    if (requestedOutput == PathSettings.ProfileToken || string.IsNullOrWhiteSpace(requestedOutput)) requestedOutput = profile;
    string actualOutput = EffectiveOutput();
    try { Directory.CreateDirectory(actualOutput); }
    catch (Exception ex) { status.Text = "Exportziel nicht beschreibbar: " + ex.Message; return; }

    try
    {
        var runId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssfff") + "_" + Guid.NewGuid().ToString("N")[..8];
        var ipcDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CraftProbe", "tui-sessions", runId);
        Directory.CreateDirectory(ipcDir);
        eventsPath = Path.Combine(ipcDir, "events.jsonl");
        commandsPath = Path.Combine(ipcDir, "commands.txt");
        contextPath = Path.Combine(ipcDir, "session-context.json");
        childLogPath = Path.Combine(ipcDir, "recorder-output.txt");
        File.WriteAllText(commandsPath, "", new UTF8Encoding(false));
        WriteContext();
        consumedEvents = stalls = incidents = 0;
        startedAt = DateTimeOffset.Now;
        recordingStoppedAt = null;
        lastExportStep = 0;
        SetPhase(RecorderPhase.Waiting);
        exportProgress.Text = "";
        recent.Clear();
        prefs.Remember(profile, requestedOutput);
        // Update both menus after persistence, retaining the selected values.
        profileChoices.Source = Choices(prefs.Profiles);
        exportChoices.Source = Choices(prefs.ExportPaths);
        profileChoices.Text = profile;
        exportChoices.Text = requestedOutput;

        var psi = new ProcessStartInfo(linuxPlatform ? "python3" : "powershell.exe")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = root
        };
        var args = linuxPlatform
            ? new[] { "-u", linuxAgentPath, "--profile", profile, "--output", requestedOutput,
                      "--ui-events", eventsPath, "--ui-commands", commandsPath,
                      "--session-context", contextPath }
            : new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", recorderPath,
                      "-ProfilePath", profile, "-OutputPath", requestedOutput,
                      "-InvocationDirectory", Environment.CurrentDirectory,
                      "-UiEventsPath", eventsPath, "-UiCommandsPath", commandsPath,
                      "-SessionContextPath", contextPath };
        foreach (var arg in args)
            psi.ArgumentList.Add(arg);
        recorder = new Process { StartInfo = psi, EnableRaisingEvents = true };
        recorder.OutputDataReceived += (_, ev) => { if (ev.Data is not null) incomingConsole.Enqueue(ev.Data); };
        recorder.ErrorDataReceived += (_, ev) => { if (ev.Data is not null) incomingConsole.Enqueue("ERROR: " + ev.Data); };
        if (!recorder.Start()) throw new InvalidOperationException("PowerShell Recorder konnte nicht gestartet werden.");
        recorder.BeginOutputReadLine();
        recorder.BeginErrorReadLine();
        status.Text = "Recorder gestartet; warte auf Minecraft oder verbinde mit laufendem Spiel ...";
        jfr.Text = "JFR: wird geprueft";
        AddLine("Session aufgenommen: " + profile);
        AddLine("Exportziel: " + actualOutput);
    }
    catch (Exception ex)
    {
        status.Text = "Fehler beim Recorder-Start: " + ex.Message;
        AddLine(ex.ToString());
        FreezeRecording(DateTimeOffset.Now);
        SetPhase(RecorderPhase.Failed);
        recorder?.Dispose(); recorder = null;
    }
}

void MarkIncident()
{
    if (phase != RecorderPhase.Recording || recorder is null || recorder.HasExited || commandsPath is null)
    {
        status.Text = "Keine laufende Aufnahme. Zuerst Recorder starten.";
        return;
    }
    try
    {
        WriteContext();
        File.AppendAllText(commandsPath, "incident" + Environment.NewLine, new UTF8Encoding(false));
        AddLine(DateTime.Now.ToString("HH:mm:ss") + "  Incident angefordert (Alt+E)");
    }
    catch (Exception ex) { status.Text = "Incident fehlgeschlagen: " + ex.Message; }
}

void PollGameConsole(bool forceRefresh = false)
{
    var profile = CurrentProfile();
    if (profile != lastConsoleProfile)
    {
        lastConsoleProfile = profile;
        consoleTail.Reset();
        consoleBuffer.Clear();
        consoleRconHistory.Clear();
        pendingCompanion.Clear();
        companionLastStatus = "";
        consoleScroll.Reset();
        consoleDisplayedRows = 1;
        consoleMatchedEvictions = 0;
        consoleWarns = consoleErrors = 0;
        consoleDirty = true;
    }
    if (Directory.Exists(profile) && (!consolePaused || forceRefresh))
    {
        var logFile = Path.Combine(profile, "logs", "latest.log");
        foreach (var line in consoleTail.Poll(logFile))
        {
            consoleBuffer.Enqueue(ConsoleLogTools.Clean(line));
            while (consoleBuffer.Count > 1200)
            {
                var removed = consoleBuffer.Dequeue();
                if (ConsoleLogTools.Filter(new[] { removed }, lastConsoleQuery, lastConsoleLevel).Any())
                    consoleMatchedEvictions++;
            }
            if (ConsoleLogTools.Level(line) >= 2) consoleErrors++;
            else if (ConsoleLogTools.Level(line) >= 1) consoleWarns++;
            consoleDirty = true;
        }
        consoleState.Text = $"Log: {logFile}  |  Warnungen: {consoleWarns}  Fehler: {consoleErrors}";
        if (!File.Exists(logFile))
            consoleState.Text = "Keine logs/latest.log im gewaehlten Profil. Logs erscheinen nach dem Spielstart.";
    }
    var query = consoleSearch.Text?.ToString() ?? "";
    var level = consoleLevel.Text?.ToString() ?? "Alle";
    if (query != lastConsoleQuery || level != lastConsoleLevel)
    {
        lastConsoleQuery = query;
        lastConsoleLevel = level;
        consoleDirty = true;
        consoleMatchedEvictions = 0; // A new filter changes the visible row mapping.
    }
    if (!screenConsole.Visible || consoleLog.Viewport.Height <= 0) return;

    // Detect manual scrollbar/mouse/keyboard movement even when no new log lines arrived.
    var viewportBefore = consoleLog.Viewport;
    consoleScroll.ObserveViewport(viewportBefore.Y, viewportBefore.Height, consoleDisplayedRows);
    if (!consoleDirty)
    {
        UpdateConsoleScrollStatus();
        return;
    }

    // Retain the full bounded history (1200 lines), not merely the final 180 rows.
    var matched = ConsoleLogTools.Filter(consoleBuffer, query, level).ToArray();
    // RCON replies can contain embedded newlines; split them so the scrollbar's
    // content height matches the actual visual row count.
    var rconLines = consoleRconHistory.SelectMany(msg => msg.Replace("\r", "").Split('\n'))
        .Select(ConsoleLogTools.Clean);
    var rendered = matched.Concat(rconLines).ToArray();
    if (rendered.Length == 0) rendered = new[] { "Keine passenden Logzeilen." };
    var oldX = viewportBefore.X;
    consoleLog.Text = string.Join("\n", rendered);
    // TextView.Text resets its cursor/viewport. Let scrollbar visibility/padding settle
    // before calculating the target bottom row (horizontal scrollbar uses one row).
    consoleLog.SetContentSize(new System.Drawing.Size(
        Math.Max(1, rendered.Max(line => line.Length) + 1), Math.Max(1, rendered.Length)));
    var targetY = consoleScroll.AfterRefresh(viewportBefore.Y, consoleLog.Viewport.Height,
        rendered.Length, consoleMatchedEvictions);
    consoleLog.Viewport = consoleLog.Viewport with { X = oldX, Y = targetY };
    consoleScroll.RecordApplied(consoleLog.Viewport.Y, consoleLog.Viewport.Height);
    consoleDisplayedRows = rendered.Length;
    consoleMatchedEvictions = 0;
    consoleDirty = false;
    UpdateConsoleScrollStatus();
}

void UpdateConsoleScrollStatus()
{
    consoleScrollStatus.Text = $"Logzeilen: {consoleDisplayedRows}  |  Auto-Follow: " +
        (consoleScroll.AutoFollow ? "AN" : "AUS (manuell scrollen)") + "  |  Strg+End: zum Ende";
}

void JumpConsoleToBottom()
{
    // Only the vertical offset changes: users can keep their horizontal reading position.
    var viewport = consoleLog.Viewport;
    var y = consoleScroll.JumpToBottom(consoleDisplayedRows, viewport.Height);
    consoleLog.Viewport = viewport with { Y = y };
    consoleScroll.RecordApplied(consoleLog.Viewport.Y, consoleLog.Viewport.Height);
    UpdateConsoleScrollStatus();
    consoleLog.SetFocus();
}

void SaveConsoleExcerpt()
{
    var profile = CurrentProfile();
    if (!Directory.Exists(profile)) { consoleFooter.Text = "Ungueltiger Profilordner."; return; }
    try
    {
        var dir = Path.Combine(profile, "_CraftProbe-Exports", "log-snippets");
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, "CraftProbe-Console_" + DateTime.Now.ToString("yyyy-MM-dd_HH-mm-ss") + ".txt");
        var entries = ConsoleLogTools.Filter(consoleBuffer, consoleSearch.Text?.ToString() ?? "",
            consoleLevel.Text?.ToString() ?? "Alle");
        File.WriteAllLines(path, entries, new UTF8Encoding(false));
        consoleFooter.Text = "Gespeichert: " + path;
    }
    catch (Exception ex) { consoleFooter.Text = "Speichern fehlgeschlagen: " + ex.Message; }
}

void SendMinecraftCommand()
{
    var command = (consoleCommand.Text?.ToString() ?? "").Trim();
    if (string.IsNullOrWhiteSpace(command)) return;
    if ((commandMode.Text?.ToString() ?? "").Contains("Companion", StringComparison.OrdinalIgnoreCase))
    {
        try
        {
            var normalized = MinecraftCompanionBridge.NormalizeCommand(command);
            var id = MinecraftCompanionBridge.Send(CurrentProfile(), normalized);
            pendingCompanion[id] = normalized;
            consoleRconHistory.Enqueue("Companion: > /" + normalized + " (an Minecraft uebergeben...)");
            while (consoleRconHistory.Count > 50) consoleRconHistory.Dequeue();
            consoleDirty = true;
            consoleCommand.Text = "";
            consoleFooter.Text = "Companion-Befehl zugestellt; warte auf Bestaetigung. Spielerrechte bleiben erhalten.";
        }
        catch (Exception ex) { consoleFooter.Text = "Companion: " + ex.Message; }
        return;
    }
    SendRconCommand();
}

void SendRconCommand()
{
    if (System.Threading.Interlocked.CompareExchange(ref rconBusy, 1, 0) != 0)
    {
        consoleFooter.Text = "Ein RCON-Befehl wird bereits ausgefuehrt.";
        return;
    }
    var command = (consoleCommand.Text?.ToString() ?? "").Trim();
    if (command.Length == 0) { System.Threading.Interlocked.Exchange(ref rconBusy, 0); return; }
    var password = Environment.GetEnvironmentVariable("CRAFTPROBE_RCON_PASSWORD");
    if (string.IsNullOrEmpty(password))
    {
        consoleFooter.Text = "RCON nicht konfiguriert: CRAFTPROBE_RCON_PASSWORD fehlt (siehe docs/GAME-CONSOLE.md).";
        System.Threading.Interlocked.Exchange(ref rconBusy, 0);
        return;
    }
    var address = rconAddress.Text?.ToString() ?? "";
    consoleCommand.Text = "";
    consoleFooter.Text = "RCON-Befehl wird ausgefuehrt ...";
    _ = Task.Run(async () =>
    {
        try
        {
            var result = await MinecraftRcon.ExecuteAsync(address, password, command).ConfigureAwait(false);
            rconResults.Enqueue("RCON: > " + command + "\n" +
                (result.Length > 4000 ? result[..4000] + "\n[Antwort in TUI auf 4000 Zeichen begrenzt]" : result));
        }
        catch (Exception ex) { rconResults.Enqueue("RCON-Fehler: " + ex.Message); }
        finally { System.Threading.Interlocked.Exchange(ref rconBusy, 0); }
    });
}

void RefreshHistory()
{
    var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    var profile = CurrentProfile();
    if (Directory.Exists(profile))
    {
        paths.Add(profile); // Backward compatibility: older ZIPs were saved directly in the profile root.
        paths.Add(Path.Combine(profile, "_CraftProbe-Exports"));
    }
    foreach (var storedProfile in prefs.Profiles.Where(Directory.Exists))
    {
        paths.Add(storedProfile);
        paths.Add(Path.Combine(storedProfile, "_CraftProbe-Exports"));
    }
    var output = EffectiveOutput();
    if (Directory.Exists(output)) paths.Add(output);
    foreach (var stored in prefs.ExportPaths)
        if (Directory.Exists(stored)) paths.Add(stored);
    recordings = Recording.Discover(paths);
    historyList.SetSource(new ObservableCollection<string>(recordings.Select(x => x.Title)));
    oldSelected = -1;
    historyHeader.Text = $"Vorhandene Aufnahmen: {recordings.Count} (neuste zuerst)";
    if (recordings.Count == 0) historyDetail.Text = "Keine ZIP-Aufnahmen gefunden. Gesucht in: " + string.Join(", ", paths);
    else { historyList.SelectedItem = 0; ShowHistoryDetail(); }
}

void ShowHistoryDetail()
{
    var selected = historyList.SelectedItem;
    if (!selected.HasValue || selected.Value < 0 || selected.Value >= recordings.Count) return;
    var recording = recordings[selected.Value];
    historyDetail.Text = $"Profil: {recording.Profile}\nZeitpunkt: {recording.At:yyyy-MM-dd HH:mm:ss}\n" +
        $"Analyse: {recording.AnalysisZip ?? "nicht vorhanden"}\nPerformance: {recording.PerformanceZip ?? "nicht vorhanden"}\n" +
        $"Notiz: {(string.IsNullOrWhiteSpace(recording.Notes) ? "keine" : recording.Notes)}";
}

recordNav.Accepted += (_, _) => Show(screenCapture);
consoleNav.Accepted += (_, _) => { consoleDirty = true; Show(screenConsole); PollGameConsole(); };
commandMode.ValueChanged += (_, _) =>
{
    bool client = (commandMode.Text?.ToString() ?? "").Contains("Companion", StringComparison.OrdinalIgnoreCase);
    consoleFooter.Text = client
        ? "Singleplayer: Client-Companion-Mod installieren, im Spiel /craftprobe enable eingeben."
        : "Server: enable-rcon=true und CRAFTPROBE_RCON_PASSWORD erforderlich.";
};
historyNav.Accepted += (_, _) => { RefreshHistory(); Show(screenHistory); };
settingsNav.Accepted += (_, _) => Show(screenSettings);
exitNav.Accepted += (_, _) =>
{
    if (recorder is { HasExited: false })
    {
        status.Text = "Aufnahme laeuft. Bitte Minecraft zuerst normal beenden, damit der Export abgeschlossen wird.";
        Show(screenCapture);
        return;
    }
    app.RequestStop();
};
startButton.Accepted += (_, _) => StartRecording();
incidentButton.Accepted += (_, _) => MarkIncident();
saveContext.Accepted += (_, _) =>
{
    try { WriteContext(); status.Text = contextPath is null ? "Kontext wird beim Start uebernommen." : "Session-Notiz gespeichert."; }
    catch (Exception ex) { status.Text = "Notiz speichern fehlgeschlagen: " + ex.Message; }
};
historyRefresh.Accepted += (_, _) => RefreshHistory();
consolePause.Accepted += (_, _) =>
{
    consolePaused = !consolePaused;
    consolePause.Text = consolePaused ? "_Weiter" : "_Pause";
    consoleFooter.Text = consolePaused ? "Live-Anzeige pausiert. Minecraft laeuft weiter." : "Live-Anzeige fortgesetzt.";
    if (!consolePaused) PollGameConsole(true);
};
consoleRefresh.Accepted += (_, _) => { consoleDirty = true; PollGameConsole(true); };
consoleBottom.Accepted += (_, _) => JumpConsoleToBottom();
consoleSave.Accepted += (_, _) => SaveConsoleExcerpt();
consoleIncident.Accepted += (_, _) => MarkIncident();
consoleSend.Accepted += (_, _) => SendMinecraftCommand();
historyOpen.Accepted += (_, _) =>
{
    var index = historyList.SelectedItem;
    if (index is null || index < 0 || index >= recordings.Count) return;
    var item = recordings[index.Value];
    var file = item.AnalysisZip ?? item.PerformanceZip;
    if (file is null) return;
    try
    {
        if (OperatingSystem.IsWindows())
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{file}\"") { UseShellExecute = true });
        else
            Process.Start(new ProcessStartInfo("xdg-open") { UseShellExecute = false, ArgumentList = { Path.GetDirectoryName(file)! } });
    }
    catch (Exception ex) { historyDetail.Text = "Explorer konnte nicht geoeffnet werden: " + ex.Message; }
};
settingsReload.Accepted += (_, _) =>
{
    prefs = PathSettings.Load();
    profileChoices.Source = Choices(prefs.Profiles);
    exportChoices.Source = Choices(prefs.ExportPaths);
    if (!string.IsNullOrEmpty(prefs.InitialProfile)) profileChoices.Text = prefs.InitialProfile;
    exportChoices.Text = prefs.InitialOutput;
    settingsDetail.Text = "Gespeicherte Pfade neu geladen. " + PathSettings.SettingsFile;
};

bool Tick()
{
    if (eventsPath is not null && File.Exists(eventsPath))
    {
        try
        {
            string[] lines;
            using (var stream = new FileStream(eventsPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (var reader = new StreamReader(stream, Encoding.UTF8))
                lines = reader.ReadToEnd().Split('\n');
            if (lines.Length - 1 < consumedEvents) consumedEvents = 0;
            for (var eventNo = consumedEvents; eventNo < lines.Length - 1; eventNo++)
            {
                var line = lines[eventNo].TrimEnd('\r');
                try
                {
                    using var parsed = JsonDocument.Parse(line);
                    var item = parsed.RootElement;
                    var type = Val(item, "type");
                    var message = Val(item, "message");
                    var detail = Val(item, "detail");
                    var at = Val(item, "timestamp");
                    var clock = at.Length >= 19 ? at.Substring(11, 8) : DateTime.Now.ToString("HH:mm:ss");
                    AddLine(clock + "  " + message + (string.IsNullOrWhiteSpace(detail) ? "" : " · " + detail));
                    switch (type)
                    {
                        case "minecraft":
                            startedAt = ReadEventTime(at); // Recording begins when the JVM is attached, not while waiting.
                            recordingStoppedAt = null;
                            SetPhase(RecorderPhase.Recording);
                            status.Text = "Minecraft verbunden. Aufnahme laeuft.";
                            break;
                        case "waiting":
                            SetPhase(RecorderPhase.Waiting);
                            status.Text = "Warte auf Minecraft-Start ...";
                            break;
                        case "stopped":
                            FreezeRecording(ReadEventTime(at));
                            SetPhase(RecorderPhase.Exporting);
                            status.Text = "Minecraft beendet. Diagnoseexport wird vorbereitet ...";
                            break;
                        case "export":
                            FreezeRecording(ReadEventTime(at)); // fallback if a stopped event was missed
                            if (int.TryParse(Val(item, "step"), out var step))
                                SetExportStep(step, message);
                            else
                            {
                                var match = System.Text.RegularExpressions.Regex.Match(detail, @"Schritt\s+(\d+)\s+von\s+4");
                                if (match.Success && int.TryParse(match.Groups[1].Value, out step))
                                    SetExportStep(step, message);
                                else { SetPhase(RecorderPhase.Exporting); status.Text = "Export: " + message; }
                            }
                            break;
                        case "completed":
                            FreezeRecording(ReadEventTime(at));
                            SetPhase(RecorderPhase.Completed);
                            exportProgress.Text = "Export: Schritt 4/4 abgeschlossen";
                            status.Text = "FERTIG: " + detail;
                            break;
                        case "error":
                            FreezeRecording(ReadEventTime(at));
                            SetPhase(RecorderPhase.Failed);
                            status.Text = "FEHLER: " + message + (detail.Length > 0 ? " – " + detail : "");
                            break;
                        case "jfr": jfr.Text = "JFR: Aufnahme aktiv (Snapshot-Erfolg getrennt geprueft)"; break;
                        case "jfr_snapshot": jfr.Text = "JFR: letzter Snapshot erfolgreich geprueft"; break;
                        case "stall": stalls++; break;
                        case "incident": incidents++; break;
                    }
                    if (type == "warning" && message.Contains("JFR", StringComparison.OrdinalIgnoreCase))
                        jfr.Text = "JFR: Warnung! " + message;
                }
                catch (JsonException) { break; }
                consumedEvents = eventNo + 1;
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
    PollGameConsole();
    // The on-disk heartbeat is authoritative: old JVM sessions must not appear connected.
    if (screenConsole.Visible)
    {
        var cStatus = MinecraftCompanionBridge.ReadStatus(CurrentProfile());
        if (companionLastStatus != cStatus.State)
        {
            companionLastStatus = cStatus.State;
            companionStatusLabel.Text = "Companion: " + (cStatus.Ready ? "BEREIT" : cStatus.State);
            if ((commandMode.Text?.ToString() ?? "").Contains("Companion", StringComparison.OrdinalIgnoreCase))
                consoleFooter.Text = cStatus.Detail;
        }
        foreach (var reply in MinecraftCompanionBridge.TakeReplies(CurrentProfile()))
        {
            // Only show responses for commands initiated in this TUI session.
            if (!pendingCompanion.Remove(reply.Id, out var sentCommand)) continue;
            consoleRconHistory.Enqueue("Companion: /" + sentCommand + " – " + reply.State + ": " + reply.Message);
            while (consoleRconHistory.Count > 50) consoleRconHistory.Dequeue();
            consoleFooter.Text = "Companion: " + reply.State + " – " + reply.Message;
            consoleDirty = true;
        }
    }
    while (rconResults.TryDequeue(out var message))
    {
        consoleFooter.Text = message.Replace('\n', ' ');
        // RCON responses are separate from Minecraft's log file and survive view refreshes.
        consoleRconHistory.Enqueue(message);
        while (consoleRconHistory.Count > 20) consoleRconHistory.Dequeue();
        consoleDirty = true;
    }
    while (incomingConsole.TryDequeue(out var line))
    {
        if (childLogPath is not null)
        {
            try { File.AppendAllText(childLogPath, line + Environment.NewLine); } catch { }
        }
        if (line.Contains("EXPORT FEHLGESCHLAGEN", StringComparison.OrdinalIgnoreCase) ||
            line.Contains("Exception", StringComparison.OrdinalIgnoreCase)) AddLine("Recorder: " + line);
    }
    if (recorder is { HasExited: true } && phase != RecorderPhase.Completed && phase != RecorderPhase.Failed)
    {
        FreezeRecording(DateTimeOffset.Now); // unexpected recorder exit: stop the timer regardless
        if (recorder.ExitCode != 0)
        {
            SetPhase(RecorderPhase.Failed);
            status.Text = "Recorder beendet mit Fehlercode " + recorder.ExitCode + ". Protokoll: " + childLogPath;
        }
        else
        {
            // A zero exit code without a confirmed export is not proof of success.
            SetPhase(RecorderPhase.Failed);
            status.Text = "Recorder beendet, aber kein abgeschlossener Export bestaetigt. Protokoll: " + childLogPath;
        }
    }
    if (screenHistory.Visible && historyList.SelectedItem is { } chosen && chosen != oldSelected)
    {
        oldSelected = chosen;
        ShowHistoryDetail();
    }
    var elapsed = startedAt.HasValue
        ? ((recordingStoppedAt ?? DateTimeOffset.Now) - startedAt.Value)
        : (TimeSpan?)null;
    if (elapsed.HasValue && elapsed.Value < TimeSpan.Zero) elapsed = TimeSpan.Zero;
    var elapsedText = elapsed.HasValue
        ? $"{(int)elapsed.Value.TotalHours:00}:{elapsed.Value.Minutes:00}:{elapsed.Value.Seconds:00}"
        : "--:--:--";
    var phaseText = phase switch
    {
        RecorderPhase.Waiting => "Warten auf Minecraft",
        RecorderPhase.Recording => "Aufnahme laeuft",
        RecorderPhase.Exporting => "Export laeuft",
        RecorderPhase.Completed => "Fertig",
        RecorderPhase.Failed => "Fehler",
        _ => "Bereit"
    };
    runtime.Text = $"Aufnahme: {elapsedText}  |  {phaseText}  |  Stalls: {stalls}  Incidents: {incidents}";
    return true;
}

app.AddTimeout(TimeSpan.FromMilliseconds(450), Tick);
app.Run(window);
if (recorder is { HasExited: true }) recorder.Dispose();
return 0;

static string? FindRoot(string folder)
{
    var cursor = new DirectoryInfo(folder);
    for (var i = 0; i < 8 && cursor is not null; i++, cursor = cursor.Parent)
        if (File.Exists(Path.Combine(cursor.FullName, "src", "Minecraft-Diagnose-Recorder.ps1")) &&
            File.Exists(Path.Combine(cursor.FullName, "linux", "craftprobe_agent.py"))) return cursor.FullName;
    return null;
}
static bool LooksLikeMinecraft(string folder) => new[] { "mods", "config", "logs", "saves", "world", "server.properties", "eula.txt", "options.txt", "minecraftinstance.json" }
    .Count(name => File.Exists(Path.Combine(folder, name)) || Directory.Exists(Path.Combine(folder, name))) >= 2;
static bool SameDirectory(string x, string y)
{
    try { return string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(x)),
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(y)),
        OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal); }
    catch { return false; }
}
static string Val(JsonElement item, string name) => item.TryGetProperty(name, out var value) ? value.ToString() : "";
static ListWrapper<string> Choices(IEnumerable<string> paths) => new(new ObservableCollection<string>(paths.Distinct(StringComparer.OrdinalIgnoreCase).ToList()));

sealed class PathSettings
{
    public const string ProfileToken = "__PROFILE__";
    public static readonly string SettingsFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CraftProbe", "settings.json");
    public List<string> Profiles { get; } = new();
    public List<string> ExportPaths { get; } = new();
    public string InitialProfile { get; set; } = "";
    public string InitialOutput { get; set; } = ProfileToken;

    public static PathSettings Load()
    {
        var s = new PathSettings();
        if (!File.Exists(SettingsFile)) return s;
        try
        {
            var node = JsonNode.Parse(File.ReadAllText(SettingsFile))?.AsObject();
            if (node is null) return s;
            foreach (var path in ReadPaths(node["profiles"]))
                if (Directory.Exists(path)) s.Profiles.Add(path);
            foreach (var path in ReadPaths(node["exports"]))
                if (Directory.Exists(path)) s.ExportPaths.Add(path);
            var preferred = node["defaultProfile"]?.ToString() ?? "";
            s.InitialProfile = Directory.Exists(preferred) ? preferred : s.Profiles.FirstOrDefault() ?? "";
            var output = node["defaultExport"]?.ToString() ?? ProfileToken;
            s.InitialOutput = output == ProfileToken ? (s.InitialProfile.Length > 0 ? s.InitialProfile : ProfileToken) : output;
            if (s.InitialProfile.Length > 0 && !s.Profiles.Contains(s.InitialProfile, StringComparer.OrdinalIgnoreCase)) s.Profiles.Add(s.InitialProfile);
            if (s.InitialOutput.Length > 0 && s.InitialOutput != ProfileToken && !s.ExportPaths.Contains(s.InitialOutput, StringComparer.OrdinalIgnoreCase)) s.ExportPaths.Add(s.InitialOutput);
        }
        catch { /* Corrupt optional settings must not prevent starting the UI. */ }
        return s;
    }
    private static IEnumerable<string> ReadPaths(JsonNode? value)
    {
        if (value is not JsonArray arr) yield break;
        foreach (var node in arr)
        {
            var path = node is JsonValue ? node.ToString() : node?["path"]?.ToString();
            if (!string.IsNullOrWhiteSpace(path)) yield return path;
        }
    }
    public void Remember(string profile, string output)
    {
        if (!Profiles.Contains(profile, StringComparer.OrdinalIgnoreCase)) Profiles.Add(profile);
        if (output != ProfileToken && !ExportPaths.Contains(output, StringComparer.OrdinalIgnoreCase)) ExportPaths.Add(output);
        InitialProfile = profile; InitialOutput = output;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(SettingsFile)!);
            JsonObject node;
            try { node = JsonNode.Parse(File.ReadAllText(SettingsFile))?.AsObject() ?? new JsonObject(); }
            catch { node = new JsonObject(); }
            node["schemaVersion"] = 2;
            node["profiles"] = new JsonArray(Profiles.Distinct(StringComparer.OrdinalIgnoreCase).Select(x => (JsonNode?)JsonValue.Create(x)).ToArray());
            node["defaultProfile"] = profile;
            node["exports"] = new JsonArray(ExportPaths.Distinct(StringComparer.OrdinalIgnoreCase).Select(x => (JsonNode?)JsonValue.Create(x)).ToArray());
            node["defaultExport"] = string.Equals(profile, output, StringComparison.OrdinalIgnoreCase) ? ProfileToken : output;
            var tmp = SettingsFile + ".new";
            File.WriteAllText(tmp, node.ToJsonString(new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            File.Move(tmp, SettingsFile, true);
        }
        catch { /* A settings write must never block diagnostics. */ }
    }
}

sealed class Recording
{
    public required string Profile { get; init; }
    public required DateTime At { get; init; }
    public string? AnalysisZip { get; set; }
    public string? PerformanceZip { get; set; }
    public string? Notes { get; set; }
    public string Title => $"{At:yyyy-MM-dd HH:mm:ss} | {Profile} | " +
        (AnalysisZip is null ? "--" : "Analyse") + " / " + (PerformanceZip is null ? "--" : "Performance");

    public static List<Recording> Discover(IEnumerable<string> roots)
    {
        var entries = new Dictionary<string, Recording>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in roots.Where(Directory.Exists))
        {
            IEnumerable<string> files;
            try { files = Directory.EnumerateFiles(path, "*.zip", SearchOption.TopDirectoryOnly).Take(300).ToArray(); }
            catch { continue; }
            foreach (var file in files)
            {
                var name = Path.GetFileNameWithoutExtension(file);
                var type = name.Contains("_Session-Analyse_", StringComparison.OrdinalIgnoreCase) ? "_Session-Analyse_" :
                           name.Contains("_Performance-Diagnose_", StringComparison.OrdinalIgnoreCase) ? "_Performance-Diagnose_" : null;
                if (type is null) continue;
                var pos = name.LastIndexOf(type, StringComparison.OrdinalIgnoreCase);
                var profile = name[..pos];
                var stamp = name[(pos + type.Length)..];
                var key = path + "|" + profile + "|" + stamp;
                var when = DateTime.TryParseExact(stamp, "yyyy-MM-dd_HH-mm-ss", System.Globalization.CultureInfo.InvariantCulture,
                    System.Globalization.DateTimeStyles.None, out var date) ? date : File.GetLastWriteTime(file);
                if (!entries.TryGetValue(key, out var item))
                    entries[key] = item = new Recording { Profile = profile, At = when };
                if (type == "_Session-Analyse_")
                {
                    item.AnalysisZip = file;
                    var sidecar = Path.ChangeExtension(file, ".session.json");
                    if (File.Exists(sidecar))
                    {
                        try { item.Notes = JsonNode.Parse(File.ReadAllText(sidecar))?["notes"]?.ToString(); }
                        catch { /* sidecars are optional */ }
                    }
                }
                else item.PerformanceZip = file;
            }
        }
        return entries.Values.OrderByDescending(x => x.At).Take(250).ToList();
    }
}

// State changes are driven by recorder events rather than the TUI redraw timer.
enum RecorderPhase { Idle, Waiting, Recording, Exporting, Completed, Failed }
