package dev.craftprobe.companion;

/** Pure Java protocol checks; kept dependency-free for unit tests. */
public final class BridgeProtocol {
    private BridgeProtocol() {}
    public static final int MAX_COMMAND_LENGTH = 512;
    public static final long REQUEST_TTL_MS = 30_000L;
    public static boolean isValidId(String id) {
        if (id == null) return false;
        try { return java.util.UUID.fromString(id).toString().equalsIgnoreCase(id); }
        catch (IllegalArgumentException e) { return false; }
    }
    public static String normalize(String command) {
        if (command == null) throw new IllegalArgumentException("empty command");
        String text = command.strip();
        if (text.startsWith("/")) text = text.substring(1);
        if (text.isEmpty() || text.length() > MAX_COMMAND_LENGTH || text.chars().anyMatch(Character::isISOControl))
            throw new IllegalArgumentException("bad command length / control character");
        return text;
    }
    public static boolean fresh(long createdAtMs, long nowMs) {
        long age = nowMs - createdAtMs;
        return age >= -5000 && age <= REQUEST_TTL_MS;
    }
}
