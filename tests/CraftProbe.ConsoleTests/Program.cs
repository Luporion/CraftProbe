using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;

static void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
    Console.WriteLine("PASS " + message);
}

var dir = Path.Combine(Path.GetTempPath(), "CraftProbe Test " + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(dir);
try
{
    var path = Path.Combine(dir, "latest.log");
    var tail = new MinecraftLogTail();
    File.WriteAllText(path, "[00:01:01] [Server thread/INFO] Start\n", Encoding.UTF8);
    Check(tail.Poll(path).Count == 1, "initial log line");
    File.AppendAllText(path, "[00:01:02] [Server thread/WARN] Slow tick\n");
    var appended = tail.Poll(path);
    Check(appended.Count == 1 && ConsoleLogTools.Level(appended[0]) == 1, "incremental warning tail");
    File.AppendAllText(path, "[00:01:03] [Server thread/ERROR] Something");
    Check(tail.Poll(path).Count == 0, "partial lines are not published");
    File.AppendAllText(path, " broke\n");
    var completed = tail.Poll(path);
    Check(completed.Count == 1 && completed[0].EndsWith("Something broke"), "partial line assembly");
    Check(ConsoleLogTools.Filter(appended.Concat(completed), "slow", "Warnungen + Fehler").Count() == 1,
        "combined search and severity filter");
    Check(ConsoleLogTools.Filter(appended.Concat(completed), "", "Nur Fehler").Count() == 1,
        "error severity filter");
    File.WriteAllText(path, "[00:02:00] [main/INFO] Restart\n");
    Check(tail.Poll(path).Count == 1, "log truncation / restart");
    Check(!ConsoleLogTools.Clean("abc\u001b[31m").Contains('\u001b'), "terminal control characters stripped");
    Check(ConsoleLogTools.Clean(new string('X', 600)).Length == 600,
        "long log lines retained for horizontal scrolling");

    var scroll = new ConsoleLogScrollState();
    Check(scroll.AfterRefresh(0, 10, 200, 0) == 190, "auto-follow initial log tail");
    scroll.RecordApplied(190, 10);
    scroll.ObserveViewport(120, 10, 200); // user scrolled up via wheel or scrollbar
    Check(!scroll.AutoFollow, "scrolling up disables auto-follow");
    Check(scroll.AfterRefresh(120, 10, 210, 0) == 120, "manual scroll anchor survives log append");
    scroll.RecordApplied(120, 10);
    Check(scroll.AfterRefresh(120, 10, 210, 8) == 112, "buffer eviction preserves visible line");
    scroll.RecordApplied(112, 10);
    Check(scroll.JumpToBottom(210, 10) == 200 && scroll.AutoFollow, "jump-to-bottom resumes auto-follow");
    scroll.RecordApplied(200, 10);
    Check(scroll.AfterRefresh(200, 10, 220, 0) == 210, "auto-follow advances to latest lines");
    scroll.RecordApplied(210, 10);
    scroll.ObserveViewport(210, 15, 220);
    Check(scroll.AutoFollow, "terminal resize does not disable auto-follow");
    scroll.RecordApplied(205, 15);
    scroll.ObserveViewport(205, 15, 220);
    Check(scroll.AutoFollow, "unchanged viewport retains follow state");
    scroll.Reset();
    Check(scroll.AutoFollow, "profile switch resets follow state");

    // Companion IPC: cannot send commands until explicit in-game permission.
    Check(!MinecraftCompanionBridge.ReadStatus(dir).Ready, "companion absent defaults to disabled");
    var bridgeDir = Path.Combine(dir, ".craftprobe-bridge");
    Directory.CreateDirectory(bridgeDir);
    string sid = Guid.NewGuid().ToString();
    string token = Guid.NewGuid().ToString();
    File.WriteAllText(Path.Combine(bridgeDir,"status.json"),
        System.Text.Json.JsonSerializer.Serialize(new { session = sid, token, mode="singleplayer", enabled=false,
            updatedAtMs=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() }));
    Check(!MinecraftCompanionBridge.ReadStatus(dir).Ready, "in-game opt-in required");
    File.WriteAllText(Path.Combine(bridgeDir,"status.json"),
        System.Text.Json.JsonSerializer.Serialize(new { session = sid, token, mode="singleplayer", enabled=true,
            updatedAtMs=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() }));
    Check(MinecraftCompanionBridge.ReadStatus(dir).Ready, "opt-in companion handshake ready");
    var id = MinecraftCompanionBridge.Send(dir, "/tp Luporion 0 0 0");
    var request = System.Text.Json.JsonDocument.Parse(File.ReadAllText(Path.Combine(bridgeDir,"requests",id+".json"))).RootElement;
    Check(request.GetProperty("command").GetString() == "tp Luporion 0 0 0", "companion teleport dispatched without leading slash");
    Check(request.GetProperty("token").GetString() == token, "companion token attached to request");
    Check(!Directory.EnumerateFiles(Path.Combine(bridgeDir,"requests"), "*.writing").Any(), "companion request written atomically");
    var rejected = false;
    try { MinecraftCompanionBridge.NormalizeCommand("/say X\nstop"); }
    catch (ArgumentException) { rejected = true; }
    Check(rejected, "companion rejects multi-line commands");
    Directory.CreateDirectory(Path.Combine(bridgeDir,"responses"));
    File.WriteAllText(Path.Combine(bridgeDir,"responses",id+".json"),
        System.Text.Json.JsonSerializer.Serialize(new { id, command="tp Luporion 0 0 0",state="SENT",message="sent" }));
    Check(MinecraftCompanionBridge.TakeReplies(dir).Count == 1, "companion reply read exactly once");
    Check(MinecraftCompanionBridge.TakeReplies(dir).Count == 0, "companion reply consumed");
    File.WriteAllText(Path.Combine(bridgeDir,"status.json"),
        System.Text.Json.JsonSerializer.Serialize(new { session = sid, token, mode="singleplayer", enabled=true,
            updatedAtMs=DateTimeOffset.UtcNow.AddSeconds(-40).ToUnixTimeMilliseconds() }));
    Check(!MinecraftCompanionBridge.ReadStatus(dir).Ready, "stale companion heartbeat rejected");

    using var listener = new TcpListener(IPAddress.Loopback, 0);
    listener.Start();
    var port = ((IPEndPoint)listener.LocalEndpoint).Port;
    var server = Task.Run(async () =>
    {
        using var peer = await listener.AcceptTcpClientAsync();
        await using var s = peer.GetStream();
        var auth = await ReadPacket(s);
        Check(auth.Type == 3 && auth.Body == "secret", "RCON authentication request");
        await WritePacket(s, auth.Id, 0, "");
        await WritePacket(s, auth.Id, 2, "");
        var command = await ReadPacket(s);
        Check(command.Type == 2 && command.Body == "list", "RCON slash removal and command");
        await WritePacket(s, command.Id, 0, "There are 2 players online");
    });
    var result = await MinecraftRcon.ExecuteAsync("127.0.0.1:" + port, "secret", "/list");
    Check(result.Contains("2 players"), "RCON real TCP response");
    await server;
    listener.Stop();
    var blocked = false;
    try { await MinecraftRcon.ExecuteAsync("8.8.8.8:25575", "secret", "list"); }
    catch (InvalidOperationException) { blocked = true; }
    Check(blocked, "remote unencrypted RCON blocked by default");
    Console.WriteLine("ALL CraftProbe console tests passed.");
}
finally
{
    try { Directory.Delete(dir, recursive: true); } catch { }
}

static async Task<(int Id, int Type, string Body)> ReadPacket(Stream s)
{
    var length = new byte[4];
    await s.ReadExactlyAsync(length);
    var size = BinaryPrimitives.ReadInt32LittleEndian(length);
    var data = new byte[size];
    await s.ReadExactlyAsync(data);
    return (BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(0, 4)),
        BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(4, 4)),
        Encoding.UTF8.GetString(data, 8, size - 10));
}
static async Task WritePacket(Stream s, int id, int type, string body)
{
    var bytes = Encoding.UTF8.GetBytes(body);
    var data = new byte[14 + bytes.Length];
    BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(0, 4), data.Length - 4);
    BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(4, 4), id);
    BinaryPrimitives.WriteInt32LittleEndian(data.AsSpan(8, 4), type);
    bytes.CopyTo(data, 12);
    await s.WriteAsync(data);
}
