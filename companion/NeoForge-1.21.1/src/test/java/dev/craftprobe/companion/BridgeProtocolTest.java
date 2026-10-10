package dev.craftprobe.companion;
public class BridgeProtocolTest {
    private static void check(boolean ok, String label) {
        if (!ok) throw new AssertionError(label);
        System.out.println("PASS " + label);
    }
    public static void main(String[] args) {
        check(BridgeProtocol.normalize("/tp Luporion 0 0 0").equals("tp Luporion 0 0 0"), "slash normalized");
        check(BridgeProtocol.normalize("say hi").equals("say hi"), "bare command");
        boolean rejected = false;
        try { BridgeProtocol.normalize("say hi\nstop"); } catch (IllegalArgumentException ex) { rejected = true; }
        check(rejected, "reject multiline");
        check(BridgeProtocol.isValidId(java.util.UUID.randomUUID().toString()), "uuid validated");
        check(!BridgeProtocol.isValidId("../../../x"), "path traversal id rejected");
        check(!BridgeProtocol.fresh(System.currentTimeMillis() - 50000, System.currentTimeMillis()), "request expiry");
        System.out.println("ALL Companion protocol tests passed");
    }
}
