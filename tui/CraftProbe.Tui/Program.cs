using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using Terminal.Gui.App;
using Terminal.Gui.ViewBase;
using Terminal.Gui.Views;

// CraftProbe TUI v0.5.0
// Presentation only. The PowerShell diagnostic core remains the source of truth.
// No console output is written while Terminal.Gui owns the screen.

if (!OperatingSystem.IsWindows())
{
    Console.Error.WriteLine("CraftProbe's current recorder requires Windows.");
    return 2;
}

var repoRoot = FindRoot(AppContext.BaseDirectory);
if (repoRoot is null)
{
    Console.Error.WriteLine("Could not find src/Minecraft-Diagnose-Recorder.ps1 beside the TUI. Use CraftProbe.cmd --cli.");
    return 3;
}
var recorderPath = Path.Combine(repoRoot, "src", "Minecraft-Diagnose-Recorder.ps1");
var settings = LoadSettings();

using IApplication app = Application.Create();
app.Init();
using var window = new Window { Title = "CraftProbe v0.5.0 | Minecraft Diagnosis" };

var profileLabel = new Label { X = 1, Y = 1, Text = "Profil:" };
var profileField = new TextField { X = 16, Y = 1, Width = Dim.Fill(2), Text = settings.InitialProfile };
var nextProfile = new Button { X = 1, Y = 3, Text = "_Naechstes Profil" };
var outputLabel = new Label { X = 1, Y = 5, Text = "Exportziel:" };
var outputField = new TextField { X = 16, Y = 5, Width = Dim.Fill(2), Text = settings.InitialOutput };
var startButton = new Button { X = 1, Y = 7, Text = "_Aufnahme starten" };
var incidentButton = new Button { X = 26, Y = 7, Text = "_Ereignis markieren (Alt+E)" };
var leaveButton = new Button { X = 61, Y = 7, Text = "_Beenden" };
var status = new Label { X = 1, Y = 9, Width = Dim.Fill(2), Height = 1, Text = "Bereit. Minecraft kann bereits laufen oder spaeter gestartet werden." };
var jfr = new Label { X = 1, Y = 10, Width = Dim.Fill(2), Height = 1, Text = "JFR: noch nicht gestartet" };
var runtime = new Label { X = 1, Y = 11, Width = Dim.Fill(2), Height = 1, Text = "Sitzung: --:--:--     Stalls: 0     Incidents: 0" };
var separator = new Label { X = 1, Y = 13, Width = Dim.Fill(2), Text = "Live-Ereignisse / Status" };
var outputView = new TextView { X = 1, Y = 14, Width = Dim.Fill(2), Height = Dim.Fill(2), ReadOnly = true, Text = "Noch keine Aufnahme." };
window.Add(profileLabel, profileField, nextProfile, outputLabel, outputField,
    startButton, incidentButton, leaveButton, status, jfr, runtime, separator, outputView);

Process? child = null;
string? eventsPath = null;
string? commandsPath = null;
string? childLogPath = null;
DateTime? startedAt = null;
int consumedEvents = 0;
int stallCount = 0;
int incidentCount = 0;
var recent = new Queue<string>();
var incomingConsole = new ConcurrentQueue<string>();
int profileIndex = -1;

void AddLine(string line)
{
    recent.Enqueue(line);
    while (recent.Count > 20) recent.Dequeue();
    outputView.Text = string.Join(Environment.NewLine, recent);
}

void StartRecording()
{
    if (child is { HasExited: false })
    {
        AddLine("Aufnahme laeuft bereits. Minecraft normal beenden, um ZIPs zu erzeugen.");
        return;
    }
    var profile = profileField.Text?.ToString()?.Trim().Trim('"') ?? "";
    if (!Directory.Exists(profile) || !LooksLikeMinecraft(profile))
    {
        status.Text = "Ungueltiges Profil: Bitte Minecraft-Spielordner mit mods/config/logs/saves eingeben.";
        return;
    }
    profile = Path.GetFullPath(profile);
    var export = outputField.Text?.ToString()?.Trim().Trim('"') ?? "";
    if (string.IsNullOrWhiteSpace(export)) export = profile;
    try { Directory.CreateDirectory(export); }
    catch (Exception e) { status.Text = "Exportziel ungueltig: " + e.Message; return; }

    try
    {
        var runId = DateTime.UtcNow.ToString("yyyyMMddTHHmmssfff") + "_" + Guid.NewGuid().ToString("N")[..8];
        var ipcDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "CraftProbe", "tui-sessions", runId);
        Directory.CreateDirectory(ipcDir);
        eventsPath = Path.Combine(ipcDir, "events.jsonl");
        commandsPath = Path.Combine(ipcDir, "commands.txt");
        childLogPath = Path.Combine(ipcDir, "recorder-output.txt");
        File.WriteAllText(commandsPath, "", new UTF8Encoding(false));
        consumedEvents = 0;
        stallCount = 0;
        incidentCount = 0;
        startedAt = DateTime.Now;
        while (recent.Count > 0) recent.Dequeue();

        var psi = new ProcessStartInfo("powershell.exe")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = repoRoot
        };
        foreach (var arg in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", recorderPath,
                     "-ProfilePath", profile, "-OutputPath", export,
                     "-InvocationDirectory", Environment.CurrentDirectory,
                     "-UiEventsPath", eventsPath, "-UiCommandsPath", commandsPath })
            psi.ArgumentList.Add(arg);
        child = new Process { StartInfo = psi, EnableRaisingEvents = true };
        child.OutputDataReceived += (_, e) => { if (e.Data is not null) incomingConsole.Enqueue(e.Data); };
        child.ErrorDataReceived += (_, e) => { if (e.Data is not null) incomingConsole.Enqueue("ERROR: " + e.Data); };
        if (!child.Start()) throw new InvalidOperationException("PowerShell recorder could not be started.");
        child.BeginOutputReadLine();
        child.BeginErrorReadLine();
        status.Text = "Recorder gestartet, suche bereits laufendes Minecraft oder warte auf Spielstart ...";
        jfr.Text = "JFR: wird geprueft";
        AddLine("Aufnahme gestartet fuer " + profile);
        AddLine("Minecraft darf jetzt gestartet werden oder bereits laufen.");
    }
    catch (Exception ex)
    {
        status.Text = "Recorder konnte nicht gestartet werden: " + ex.Message;
        AddLine(ex.ToString());
        startedAt = null;
        child?.Dispose(); child = null;
    }
}

void MarkIncident()
{
    if (child is null || child.HasExited || commandsPath is null)
    {
        status.Text = "Keine laufende Aufnahme. Zuerst Recorder starten.";
        return;
    }
    try
    {
        // Append-only commands: the recorder reads each line once.
        File.AppendAllText(commandsPath, "incident" + Environment.NewLine, new UTF8Encoding(false));
        AddLine(DateTime.Now.ToString("HH:mm:ss") + "  Incident angefordert (E)");
    }
    catch (Exception ex) { status.Text = "Incident konnte nicht gesendet werden: " + ex.Message; }
}

bool Tick()
{
    if (eventsPath is not null && File.Exists(eventsPath))
    {
        try
        {
            // Event stream is intentionally low volume. Discard a partial last line.
            // Low-volume JSONL events; use line offsets to avoid StreamReader buffering
            // causing missed events. Malformed trailing lines are retried next tick.
            string[] lines;
            using (var stream = new FileStream(eventsPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (var reader = new StreamReader(stream, Encoding.UTF8))
                lines = reader.ReadToEnd().Split('\n');
            if (lines.Length - 1 < consumedEvents) consumedEvents = 0;
            for (int eventNo = consumedEvents; eventNo < lines.Length - 1; eventNo++)
            {
                var line = lines[eventNo].TrimEnd('\r');
                try
                {
                    using var parsed = JsonDocument.Parse(line);
                    var root = parsed.RootElement;
                    var type = Val(root, "type");
                    var message = Val(root, "message");
                    var details = Val(root, "detail");
                    var at = Val(root, "timestamp");
                    var hhmmss = at.Length >= 19 ? at.Substring(11, 8) : DateTime.Now.ToString("HH:mm:ss");
                    AddLine(hhmmss + "  " + message + (string.IsNullOrWhiteSpace(details) ? "" : " · " + details));
                    if (type == "minecraft") status.Text = "Minecraft verbunden. Aufnahme laeuft.";
                    if (type == "waiting") status.Text = "Warte auf Minecraft-Start ...";
                    if (type == "jfr") jfr.Text = "JFR: aktiv (Rolling und Meilensteine)";
                    if (type == "warning" && message.Contains("JFR", StringComparison.OrdinalIgnoreCase)) jfr.Text = "JFR: nicht verfuegbar (Basisdiagnose aktiv)";
                    if (type == "stall") stallCount++;
                    if (type == "incident") incidentCount++;
                    if (type == "export") status.Text = "Export laeuft: " + message;
                    if (type == "completed") status.Text = "FERTIG: ZIP-Export erfolgreich. " + details;
                    if (type == "error") status.Text = "FEHLER: " + message;
                }
                catch (JsonException)
                {
                    // Incomplete event due to concurrent append. Retry next tick.
                    break;
                }
                consumedEvents = eventNo + 1;
            }
        }
        catch (IOException) { /* recorder may be writing */ }
        catch (UnauthorizedAccessException) { }
    }
    // Show a few output lines from the legacy core as a fallback for errors.
    while (incomingConsole.TryDequeue(out var line))
    {
        if (childLogPath is not null)
        {
            try { File.AppendAllText(childLogPath, line + Environment.NewLine); } catch { }
        }
        if (line.Contains("EXPORT FEHLGESCHLAGEN", StringComparison.OrdinalIgnoreCase) ||
            line.Contains("Exception", StringComparison.OrdinalIgnoreCase))
            AddLine("Recorder: " + line);
    }
    if (child is { HasExited: true })
    {
        if (child.ExitCode != 0) status.Text = "Recorder beendet mit Fehlercode " + child.ExitCode + ". Details: " + childLogPath;
        else if (!status.Text.ToString()!.Contains("FERTIG", StringComparison.OrdinalIgnoreCase))
            status.Text = "Recorder erfolgreich beendet. Exportordner pruefen.";
    }
    runtime.Text = "Sitzung: " + (startedAt.HasValue ? (DateTime.Now - startedAt.Value).ToString(@"hh\:mm\:ss") : "--:--:--") +
                   $"    Stalls: {stallCount}    Incidents: {incidentCount}";
    return true;
}

nextProfile.Accepted += (_, _) =>
{
    if (settings.Profiles.Count == 0) { status.Text = "Keine gespeicherten Profile. Pfad direkt eingeben."; return; }
    profileIndex = (profileIndex + 1) % settings.Profiles.Count;
    profileField.Text = settings.Profiles[profileIndex];
    if (settings.ExportAsProfile) outputField.Text = settings.Profiles[profileIndex];
};
startButton.Accepted += (_, _) => StartRecording();
incidentButton.Accepted += (_, _) => MarkIncident();
leaveButton.Accepted += (_, _) =>
{
    if (child is { HasExited: false })
    {
        status.Text = "Recorder laeuft. Minecraft zuerst normal beenden (TUI bleibt offen).";
        return;
    }
    app.RequestStop();
};
// Use a UI timer to update the dashboard only on the main UI thread.
app.AddTimeout(TimeSpan.FromMilliseconds(450), Tick);
app.Run(window);
if (child is { HasExited: true }) child.Dispose();
return 0;

static string? FindRoot(string start)
{
    var cursor = new DirectoryInfo(start);
    for (var i = 0; i < 8 && cursor is not null; i++, cursor = cursor.Parent)
        if (File.Exists(Path.Combine(cursor.FullName, "src", "Minecraft-Diagnose-Recorder.ps1")))
            return cursor.FullName;
    return null;
}
static bool LooksLikeMinecraft(string path)
{
    return new[] { "mods", "config", "logs", "saves", "options.txt", "minecraftinstance.json" }
        .Count(marker => File.Exists(Path.Combine(path, marker)) || Directory.Exists(Path.Combine(path, marker))) >= 2;
}
static string Val(JsonElement element, string name) =>
    element.TryGetProperty(name, out var value) ? value.ToString() : "";
static StartupSettings LoadSettings()
{
    var output = new StartupSettings();
    var home = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
    var file = Path.Combine(home, "CraftProbe", "settings.json");
    if (!File.Exists(file)) return output;
    try
    {
        using var json = JsonDocument.Parse(File.ReadAllText(file));
        var root = json.RootElement;
        if (root.TryGetProperty("profiles", out var profiles) && profiles.ValueKind == JsonValueKind.Array)
        {
            foreach (var item in profiles.EnumerateArray())
            {
                var path = item.ValueKind == JsonValueKind.String ? item.GetString() :
                    (item.TryGetProperty("path", out var property) ? property.GetString() : null);
                if (path is not null && Directory.Exists(path) && !output.Profiles.Contains(path)) output.Profiles.Add(path);
            }
        }
        var preferred = root.TryGetProperty("defaultProfile", out var d) ? d.ToString() : "";
        if (Directory.Exists(preferred)) output.InitialProfile = preferred;
        else if (output.Profiles.Count > 0) output.InitialProfile = output.Profiles[0];
        var export = root.TryGetProperty("defaultExport", out var e) ? e.ToString() : "";
        if (!string.IsNullOrWhiteSpace(export) && export != "__PROFILE__") output.InitialOutput = export;
        else { output.ExportAsProfile = true; output.InitialOutput = output.InitialProfile; }
    }
    catch { /* Never prevent startup due to corrupt optional settings. */ }
    return output;
}
sealed class StartupSettings
{
    public List<string> Profiles { get; } = new();
    public string InitialProfile { get; set; } = "";
    public string InitialOutput { get; set; } = "";
    public bool ExportAsProfile { get; set; }
}
