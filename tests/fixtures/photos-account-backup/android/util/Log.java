package android.util;
public final class Log {
    public static int errors = 0;
    public static int infos = 0;
    public static int i(String tag, String message) { infos++; return 0; }
    public static int e(String tag, String message, Throwable error) {
        errors++;
        System.err.println(tag + ": " + message + ": " + error.getClass().getName());
        return 0;
    }
}
