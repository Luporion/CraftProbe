using System.Text;
using System.Text.Json;

// CraftProbe's opt-in, singleplayer-only, filesystem IPC transport. The Java companion
// is the ONLY component that actually sends the command to Minecraft. No UI injection.
internal static class MinecraftCompanionBridge
{
    internal sealed record Status(bool Installed, bool Ready, string Session, string Token, string State, string Detail);
    internal sealed record Reply(string Id, string Command, string State, string Message);

    private static string BridgeDir(string profile) => Path.Combine(profile, ".craftprobe-bridge");
    private static string GetText(JsonElement obj, string name)
        => obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? (v.GetString() ?? "") : "";

    internal static Status ReadStatus(string profile)
    {
        var path = Path.Combine(BridgeDir(profile), "status.json");
        if (!File.Exists(path)) return new(false, false, "", "", "NOT_INSTALLED", "Companion-Mod nicht erkannt. In Minecraft installieren und /craftprobe enable verwenden.");
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path, Encoding.UTF8));
            var obj = doc.RootElement;
            var session = GetText(obj, "session");
            var token = GetText(obj, "token");
            var mode = GetText(obj, "mode");
            bool enabled = obj.TryGetProperty("enabled", out var e) && e.ValueKind == JsonValueKind.True;
            long timestamp = obj.GetProperty("updatedAtMs").GetInt64();
            var age = DateTimeOffset.UtcNow - DateTimeOffset.FromUnixTimeMilliseconds(timestamp);
            if (age < TimeSpan.FromSeconds(-5) || age > TimeSpan.FromSeconds(10))
                return new(true, false, "", "", "STALE", "Companion ist nicht mehr aktiv (Status veraltet).");
            if (mode != "singleplayer")
                return new(true, false, "", "", "NO_WORLD", "Nur in einer lokalen Singleplayer-Welt verfuegbar.");
            if (!enabled || !Guid.TryParse(session, out _) || !Guid.TryParse(token, out _))
                return new(true, false, "", "", "DISABLED", "Im Minecraft-Chat /craftprobe enable eingeben.");
            return new(true, true, session, token, "READY", "Companion verbunden (Singleplayer; Spielerrechte gelten).");
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or FormatException or KeyNotFoundException or ArgumentOutOfRangeException)
        {
            return new(true, false, "", "", "INVALID", "Companion-Status ist unlesbar oder unvollstaendig.");
        }
    }

    internal static string NormalizeCommand(string command)
    {
        var text = command.Trim();
        if (text.StartsWith('/')) text = text[1..];
        if (text.Length == 0 || text.Length > 512 || text.Contains('\n') || text.Contains('\r') || text.Any(char.IsControl))
            throw new ArgumentException("Befehl muss 1-512 Zeichen haben und darf keine Zeilenumbrueche/Steuerzeichen enthalten.");
        return text;
    }

    internal static string Send(string profile, string command)
    {
        var status = ReadStatus(profile);
        if (!status.Ready) throw new InvalidOperationException(status.Detail);
        var normalized = NormalizeCommand(command);
        var id = Guid.NewGuid().ToString();
        var directory = Path.Combine(BridgeDir(profile), "requests");
        Directory.CreateDirectory(directory);
        var json = JsonSerializer.Serialize(new {
            id, session = status.Session, token = status.Token,
            command = normalized, createdAtMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
        });
        var temp = Path.Combine(directory, id + ".writing");
        var final = Path.Combine(directory, id + ".json");
        try
        {
            File.WriteAllText(temp, json, new UTF8Encoding(false));
            // A rename on the same volume prevents the game from reading a partial request.
            File.Move(temp, final);
        }
        finally { try { File.Delete(temp); } catch { } }
        return id;
    }

    internal static IReadOnlyList<Reply> TakeReplies(string profile)
    {
        var output = new List<Reply>();
        var dir = Path.Combine(BridgeDir(profile), "responses");
        if (!Directory.Exists(dir)) return output;
        foreach (var path in Directory.EnumerateFiles(dir, "*.json").Take(32))
        {
            try
            {
                if (new FileInfo(path).Length > 8192) continue;
                using var document = JsonDocument.Parse(File.ReadAllText(path, Encoding.UTF8));
                var obj = document.RootElement;
                var id = GetText(obj, "id");
                if (!Guid.TryParse(id, out _)) continue;
                output.Add(new(id, GetText(obj,"command"), GetText(obj,"state"), GetText(obj,"message")));
                File.Delete(path);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { }
        }
        return output;
    }
}
