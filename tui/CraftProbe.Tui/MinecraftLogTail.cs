using System.Text;

// Incremental file tailer: never reads an entire multi-GB modded Minecraft latest.log.
// No Minecraft stdin is touched; this viewer is safe with the game running or already crashed.
internal sealed class MinecraftLogTail
{
    private const int InitialTailBytes = 512 * 1024;
    private const int MaxBytesPerPoll = 256 * 1024;
    private const int MaxPendingLineBytes = 64 * 1024;
    private string? _path;
    private DateTime _created;
    private long _position;
    private bool _initialized;
    private bool _skipPartialFirstLine;
    private readonly List<byte> _pending = new();

    public void Reset()
    {
        _path = null;
        _created = default;
        _position = 0;
        _initialized = false;
        _skipPartialFirstLine = false;
        _pending.Clear();
    }

    public IReadOnlyList<string> Poll(string path)
    {
        var lines = new List<string>();
        if (!File.Exists(path))
        {
            Reset();
            return lines;
        }

        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            var info = new FileInfo(path);
            if (!_initialized || !string.Equals(_path, path, StringComparison.OrdinalIgnoreCase) ||
                info.CreationTimeUtc != _created || stream.Length < _position)
            {
                _path = path;
                _created = info.CreationTimeUtc;
                _position = Math.Max(0, stream.Length - InitialTailBytes);
                _skipPartialFirstLine = _position > 0;
                _pending.Clear();
                _initialized = true;
            }

            stream.Position = _position;
            var left = (int)Math.Min(MaxBytesPerPoll, stream.Length - _position);
            var buffer = new byte[Math.Min(8192, Math.Max(1, left))];
            while (left > 0)
            {
                var count = stream.Read(buffer, 0, Math.Min(buffer.Length, left));
                if (count <= 0) break;
                _position += count;
                left -= count;
                for (var i = 0; i < count; i++)
                {
                    var b = buffer[i];
                    if (b == (byte)'\n')
                    {
                        if (!_skipPartialFirstLine)
                        {
                            var data = _pending.ToArray();
                            if (data.Length > 0 && data[^1] == '\r') Array.Resize(ref data, data.Length - 1);
                            var line = Encoding.UTF8.GetString(data).TrimStart('\uFEFF');
                            if (line.Length > 0) lines.Add(line);
                        }
                        _skipPartialFirstLine = false;
                        _pending.Clear();
                    }
                    else if (!_skipPartialFirstLine)
                    {
                        if (_pending.Count < MaxPendingLineBytes) _pending.Add(b);
                        // Keep memory bounded even if a malformed mod writes a huge non-terminated line.
                    }
                }
            }
        }
        catch (IOException) { /* log temporarily locked or rotated; retry next UI tick */ }
        catch (UnauthorizedAccessException) { /* UI must not crash on log permission problems */ }
        return lines;
    }
}

internal static class ConsoleLogTools
{
    public static int Level(string line)
    {
        if (line.Contains("/ERROR]", StringComparison.OrdinalIgnoreCase) ||
            line.Contains("[ERROR]", StringComparison.OrdinalIgnoreCase) ||
            line.Contains("[FATAL]", StringComparison.OrdinalIgnoreCase)) return 2;
        if (line.Contains("/WARN]", StringComparison.OrdinalIgnoreCase) ||
            line.Contains("[WARN]", StringComparison.OrdinalIgnoreCase)) return 1;
        return 0;
    }

    public static IEnumerable<string> Filter(IEnumerable<string> lines, string search, string severity)
    {
        var minimum = severity == "Nur Fehler" ? 2 : severity == "Warnungen + Fehler" ? 1 : 0;
        foreach (var line in lines)
        {
            if (Level(line) < minimum) continue;
            if (search.Length > 0 && !line.Contains(search, StringComparison.OrdinalIgnoreCase)) continue;
            yield return line;
        }
    }

    public static string Clean(string line)
    {
        // Preserve long mod/stacktrace lines for horizontal scrolling, while bounding UI memory.
        var builder = new StringBuilder(Math.Min(4096, line.Length));
        foreach (var ch in line)
        {
            if (builder.Length == 4096) break;
            if (ch >= 32 && ch != 127 && ch != '\u001b') builder.Append(ch);
            else if (ch == '\t') builder.Append(' ');
        }
        return builder.ToString();
    }
}
