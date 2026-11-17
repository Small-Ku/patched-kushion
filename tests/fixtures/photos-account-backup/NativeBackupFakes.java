import android.content.Context;
import android.content.SharedPreferences;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
/**
 * Native contracts from KouPhotos 7.99 (actual default-package class names).
 * Fake native models are used only in tests; never included in the MPP.
 */
class alfy {
    public int a;
    private int d;
    private cchf e;
    alfy(int previous, int current, alfv handler) {
        d = previous; a = current; e = new cchf(handler);
    }
}
class cchf {
    public Object a;
    cchf(Object owner) { a = owner; }
}
class alfv {
    private Context d;
    public final List<Object> a = new ArrayList<>();
    alfv(Context context) { d = context; }
}
class uks {
    private String l;
    uks(String pendingAccount) { l=pendingAccount; }
}
class TestContext extends Context {
    final TestPreferences preferences = new TestPreferences();
    final TestPreferences policies = new TestPreferences();
    @Override public SharedPreferences getSharedPreferences(String file, int mode) {
        if(mode != Context.MODE_PRIVATE) throw new AssertionError("mode");
        if(file.equals("photos.backup.backup_prefs")) return preferences;
        if(file.equals("kouphotos.backup.account_folder_policies")) return policies;
        throw new AssertionError(file);
    }
}
class TestPreferences implements SharedPreferences {
    final Map<String,Object> values = new HashMap<>();
    void setBackupAccount(int account) { values.put("backup_prefs_account_id", account); }
    @Override public int getInt(String key, int fallback) {
        Object value = values.get(key);
        return value == null ? fallback : (Integer)value;
    }
    @Override @SuppressWarnings("unchecked")
    public Set<String> getStringSet(String key, Set<String> fallback) {
        Object value=values.get(key);
        return value == null ? fallback : (Set<String>)value;
    }
    @Override public Editor edit() {
        return new Editor() {
            @Override public Editor putStringSet(String key, Set<String> folders) {
                values.put(key,folders); return this;
            }
            @Override public boolean commit() { return true; }
        };
    }
}
class cbyf {
    static final Map<Class<?>,Object> services = new HashMap<>();
    public static Object e(Context context, Class<?> klass) {
        Object service = services.get(klass);
        if(service == null) throw new IllegalStateException("Not registered: "+klass);
        return service;
    }
}
class caet {
    public boolean n(int id) {return id == 10 || id == 20;}
}
class uat {
    static boolean modern = true;
    public boolean h() {return modern;}
}
enum tow {SOURCE_PHOTOS}
class tou {
    final tow source;
    final int entryPoint;
    public tou(tow source,String packageName,int entryPoint) {
        this.source=source; this.entryPoint=entryPoint;
    }
}
class upd {
    public upd(long time,String source,String message){}
}
class tpg {}
class uog {}
class chxn {}
class chvt {}
class uoi { public uoi(chxn ui, chvt token) {} }
class shx { public static chxn c(Context ctx) {return new chxn();} }
class uol { public uol(upd reason,int mode,uoi audit) {} }
class unr {
    Integer b;
    Set<String> l;
    public unr(){}
    public void d(Set<String> buckets) { l = new java.util.HashSet<>(buckets); }
    public static void e(unr mutation,int target,tou toggle,tpg policy,uog settings,int mask) {
        mutation.b=target;
    }
    public void a(tou toggle){b=-1;}
}
class unv {}
class unu extends unv {}
class unt extends unv {}
class unq {
    final TestContext context;
    boolean reject = false;
    boolean ignoreFolderWrites = false;
    int commits = 0;
    unq(TestContext context){this.context=context;}
    public unv j(unr mutation,uol logging) {
        commits++;
        if(reject)return new unt();
        context.preferences.setBackupAccount(mutation.b);
        if(mutation.l != null && !ignoreFolderWrites)
            context.preferences.values.put("photos.backup.backup_local_folders",
                    new java.util.HashSet<>(mutation.l));
        return new unu();
    }
}
class toi {
    final TestContext context;
    int commits = 0;
    boolean reject = false;
    toi(TestContext context) { this.context=context; }
    public tvy i() {return new tvy(this);}
}
class tvy {
    final toi owner;
    int target;
    tvy(toi owner){this.owner=owner;}
    public void l(int target,tou toggle){this.target=target;}
    public void k(tou toggle){this.target=-1;}
    public boolean a(upd reason) {
        owner.commits++;
        if(owner.reject)return false;
        owner.context.preferences.setBackupAccount(target);
        return true;
    }
}
