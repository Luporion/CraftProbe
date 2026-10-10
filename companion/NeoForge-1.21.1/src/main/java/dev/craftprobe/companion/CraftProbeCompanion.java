package dev.craftprobe.companion;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.mojang.brigadier.Command;
import net.minecraft.client.Minecraft;
import net.minecraft.commands.Commands;
import net.minecraft.network.chat.Component;
import net.neoforged.api.distmarker.Dist;
import net.neoforged.fml.common.Mod;
import net.neoforged.neoforge.common.NeoForge;
import net.neoforged.neoforge.client.event.ClientTickEvent;
import net.neoforged.neoforge.client.event.RegisterClientCommandsEvent;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.Comparator;
import java.util.List;
import java.util.UUID;

/** Optional, physical-client-only IPC connector. Never opens a network port. */
@Mod(value = "craftprobe_companion", dist = Dist.CLIENT)
public class CraftProbeCompanion {
    // Do not access Minecraft in static class initializers: the mod can load
    // before the Minecraft singleton and game directory are initialized.
    private static Minecraft mc() { return Minecraft.getInstance(); }
    private static Path root() { return mc().gameDirectory.toPath().resolve(".craftprobe-bridge"); }
    private static boolean enabled = false;
    private static String session = "";
    private static String token = "";
    private static int ticks = 0;

    public CraftProbeCompanion() {
        NeoForge.EVENT_BUS.addListener(CraftProbeCompanion::onTick);
        NeoForge.EVENT_BUS.addListener(CraftProbeCompanion::registerCommands);
    }

    private static boolean localWorld() {
        return mc().player != null && mc().player.connection != null && mc().getSingleplayerServer() != null;
    }

    private static void chat(String message) {
        if (mc().gui != null) mc().gui.getChat().addMessage(Component.literal("[CraftProbe] " + message));
    }

    private static void registerCommands(RegisterClientCommandsEvent event) {
        event.getDispatcher().register(
            Commands.literal("craftprobe")
                .then(Commands.literal("enable").executes(ctx -> {
                    if (!localWorld()) { chat("Nur in einer Singleplayer-Welt verfuegbar."); return 0; }
                    // Opt-in is always a direct in-game action; never enabled by disk input.
                    enabled = true;
                    session = UUID.randomUUID().toString();
                    token = UUID.randomUUID().toString();
                    clearOldRequests();
                    writeStatus();
                    chat("Befehle von CraftProbe fuer diese Spielwelt aktiviert. /craftprobe disable zum Beenden.");
                    return Command.SINGLE_SUCCESS;
                }))
                .then(Commands.literal("disable").executes(ctx -> {
                    disabled(); writeStatus(); chat("Befehlsverbindung deaktiviert.");
                    return Command.SINGLE_SUCCESS;
                }))
                .then(Commands.literal("status").executes(ctx -> {
                    chat(enabled && localWorld() ? "Verbunden: Singleplayer (Spielerrechte gelten)." : "Nicht aktiviert. /craftprobe enable");
                    return Command.SINGLE_SUCCESS;
                }))
        );
    }

    private static void disabled() {
        enabled = false;
        token = "";
        session = "";
    }

    private static void onTick(ClientTickEvent.Post ignored) {
        if (!localWorld() && enabled) disabled(); // Never carry permission into a new world/server.
        ticks++;
        if (ticks % 20 == 0) writeStatus();
        if (enabled && localWorld() && ticks % 5 == 0) pollRequests();
    }

    private static void clearOldRequests() {
        try {
            Path dir = root().resolve("requests");
            if (!Files.isDirectory(dir)) return;
            try (var paths = Files.list(dir)) {
                paths.filter(f -> f.getFileName().toString().endsWith(".json"))
                     .forEach(f -> { try { Files.deleteIfExists(f); } catch (IOException ignored) {} });
            }
        } catch (IOException ignored) { }
    }

    private static void writeStatus() {
        JsonObject obj = new JsonObject();
        obj.addProperty("protocol", 1);
        obj.addProperty("session", session);
        obj.addProperty("token", enabled ? token : "");
        obj.addProperty("mode", localWorld() ? "singleplayer" : "none");
        obj.addProperty("enabled", enabled && localWorld());
        obj.addProperty("updatedAtMs", System.currentTimeMillis());
        writeAtomic(root().resolve("status.json"), obj.toString());
    }

    private static void pollRequests() {
        Path dir = root().resolve("requests");
        if (!Files.isDirectory(dir)) return;
        try (var stream = Files.list(dir)) {
            List<Path> requests = stream
                .filter(f -> f.getFileName().toString().endsWith(".json") && Files.isRegularFile(f))
                .sorted(Comparator.comparing(Path::toString)).limit(8).toList();
            for (Path request : requests) consumeRequest(request);
        } catch (IOException ignored) { }
    }

    private static void consumeRequest(Path path) {
        String id = path.getFileName().toString().replaceFirst("\\.json$", "");
        if (!BridgeProtocol.isValidId(id)) return;
        String command = "";
        String state = "REJECTED";
        String detail = "invalid request";
        try {
            if (Files.size(path) > 4096) throw new IllegalArgumentException("request too large");
            JsonObject request = JsonParser.parseString(Files.readString(path, StandardCharsets.UTF_8)).getAsJsonObject();
            if (!id.equals(request.get("id").getAsString()) ||
                !session.equals(request.get("session").getAsString()) ||
                !token.equals(request.get("token").getAsString()))
                throw new IllegalArgumentException("wrong session/token");
            if (!BridgeProtocol.fresh(request.get("createdAtMs").getAsLong(), System.currentTimeMillis()))
                throw new IllegalArgumentException("request expired");
            command = BridgeProtocol.normalize(request.get("command").getAsString());
            if (!enabled || !localWorld()) throw new IllegalArgumentException("not enabled in singleplayer");
            // Client's actual player connection, not an elevated server console.
            // Runs on Minecraft's client tick thread; permissions are checked by the game server.
            mc().player.connection.sendCommand(command);
            state = "SENT";
            detail = "An Minecraft gesendet. Befehlsausgabe im Spiel pruefen; keine Erfolgsgarantie.";
        } catch (Exception e) {
            detail = e.getMessage() == null ? "request invalid" : e.getMessage();
            if (detail.length() > 180) detail = detail.substring(0, 180);
        } finally {
            try { Files.deleteIfExists(path); } catch (IOException ignored) { }
            JsonObject response = new JsonObject();
            response.addProperty("id", id);
            response.addProperty("command", command);
            response.addProperty("state", state);
            response.addProperty("message", detail);
            response.addProperty("atMs", System.currentTimeMillis());
            writeAtomic(root().resolve("responses").resolve(id + ".json"), response.toString());
        }
    }

    private static void writeAtomic(Path target, String text) {
        Path temp = target.resolveSibling(target.getFileName() + ".writing");
        try {
            Files.createDirectories(target.getParent());
            Files.writeString(temp, text, StandardCharsets.UTF_8);
            try { Files.move(temp, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING); }
            catch (AtomicMoveNotSupportedException e) {
                Files.move(temp, target, StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (IOException ignored) { }
        finally { try { Files.deleteIfExists(temp); } catch (IOException ignored) {} }
    }
}
