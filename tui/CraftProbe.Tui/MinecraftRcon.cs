using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;

// Minecraft RCON is an optional dedicated-server transport. NEVER silently send commands
// to singleplayer: the Minecraft Java client does not provide an RCON/stdin console.
// RCON itself is unencrypted. Remote access therefore requires explicit opt-in.
internal static class MinecraftRcon
{
    public static async Task<string> ExecuteAsync(string address, string password, string command)
    {
        command = command.Trim().TrimStart('/');
        if (command.Length == 0 || command.Length > 512 || command.Contains('\r') || command.Contains('\n'))
            throw new ArgumentException("Befehl muss 1–512 Zeichen enthalten, ohne Zeilenumbruch.");
        if (string.IsNullOrEmpty(password)) throw new ArgumentException("RCON-Passwort fehlt.");

        if (!Uri.TryCreate("rcon://" + address.Trim(), UriKind.Absolute, out var endpoint) ||
            endpoint.Host.Length == 0 || endpoint.UserInfo.Length > 0 ||
            endpoint.AbsolutePath != "/" || endpoint.Query.Length > 0 || endpoint.Fragment.Length > 0)
            throw new ArgumentException("RCON-Adresse muss '127.0.0.1:25575' oder 'host:port' sein.");
        var port = endpoint.IsDefaultPort ? 25575 : endpoint.Port;
        if (port < 1 || port > 65535) throw new ArgumentException("Ungueltiger RCON-Port.");
        var host = endpoint.Host;
        var loopback = host.Equals("localhost", StringComparison.OrdinalIgnoreCase) || host == "127.0.0.1" || host == "::1";
        if (!loopback && Environment.GetEnvironmentVariable("CRAFTPROBE_RCON_ALLOW_REMOTE") != "1")
            throw new InvalidOperationException("RCON sendet Passwoerter unverschluesselt. Remote-RCON ist gesperrt. SSH-Tunnel verwenden oder CRAFTPROBE_RCON_ALLOW_REMOTE=1 bewusst setzen.");

        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        using var client = new TcpClient();
        await client.ConnectAsync(host, port, timeout.Token).ConfigureAwait(false);
        await using var stream = client.GetStream();
        const int authId = 17831, commandId = 17832;
        await WritePacket(stream, authId, 3, password, timeout.Token).ConfigureAwait(false);
        var authorized = false;
        for (var i = 0; i < 4; i++)
        {
            var response = await ReadPacket(stream, timeout.Token).ConfigureAwait(false);
            if (response.Id == -1) throw new UnauthorizedAccessException("RCON-Passwort abgelehnt.");
            if (response.Type == 2 && response.Id == authId) { authorized = true; break; }
        }
        if (!authorized) throw new IOException("Keine gueltige RCON-Authentifizierungsantwort.");
        await WritePacket(stream, commandId, 2, command, timeout.Token).ConfigureAwait(false);
        for (var i = 0; i < 4; i++)
        {
            var response = await ReadPacket(stream, timeout.Token).ConfigureAwait(false);
            if (response.Id != commandId) continue;
            return string.IsNullOrWhiteSpace(response.Body) ? "Befehl gesendet; Server hat keine Textantwort geliefert." : response.Body;
        }
        throw new IOException("Server hat nicht auf den RCON-Befehl geantwortet.");
    }

    private static async Task WritePacket(Stream stream, int id, int type, string payload, CancellationToken token)
    {
        var text = Encoding.UTF8.GetBytes(payload);
        var length = 10 + text.Length;
        if (length > 65536) throw new ArgumentException("RCON-Paket zu gross.");
        var buffer = new byte[length + 4];
        BinaryPrimitives.WriteInt32LittleEndian(buffer.AsSpan(0, 4), length);
        BinaryPrimitives.WriteInt32LittleEndian(buffer.AsSpan(4, 4), id);
        BinaryPrimitives.WriteInt32LittleEndian(buffer.AsSpan(8, 4), type);
        text.CopyTo(buffer, 12);
        await stream.WriteAsync(buffer, token).ConfigureAwait(false);
    }

    private static async Task<(int Id, int Type, string Body)> ReadPacket(Stream stream, CancellationToken token)
    {
        var lengthData = new byte[4];
        await stream.ReadExactlyAsync(lengthData, token).ConfigureAwait(false);
        var length = BinaryPrimitives.ReadInt32LittleEndian(lengthData);
        if (length < 10 || length > 1024 * 1024) throw new IOException("Ungueltige RCON-Paketlaenge.");
        var data = new byte[length];
        await stream.ReadExactlyAsync(data, token).ConfigureAwait(false);
        if (data[^1] != 0 || data[^2] != 0) throw new IOException("Ungueltiger RCON-Paketabschluss.");
        return (BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(0, 4)),
            BinaryPrimitives.ReadInt32LittleEndian(data.AsSpan(4, 4)),
            Encoding.UTF8.GetString(data, 8, length - 10));
    }
}
