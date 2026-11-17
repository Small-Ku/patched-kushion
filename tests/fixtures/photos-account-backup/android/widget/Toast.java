package android.widget;
import android.content.Context;
public final class Toast {
    public static final int LENGTH_LONG = 1;
    public static String lastMessage;
    public static Toast makeText(Context context, String message, int duration) {
        lastMessage = message;
        return new Toast();
    }
    public void show() {}
}
