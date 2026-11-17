package android.content;
import java.util.Set;
public interface SharedPreferences {
  int getInt(String key, int fallback);
  Set<String> getStringSet(String key, Set<String> fallback);
  Editor edit();
  interface Editor {
    Editor putStringSet(String key, Set<String> values);
    boolean commit();
  }
}
