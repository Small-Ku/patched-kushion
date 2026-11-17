import android.content.Context;
import android.content.SharedPreferences;
import android.util.Log;
import de.kwoo.shion.extension.photos.AccountScopedFolders;
import java.util.*;

public class PhotosAccountBackupBridgeTest {
    private static final String ACCOUNT = "backup_prefs_account_id";
    private static final String FOLDERS = "photos.backup.backup_local_folders";
    private static final String PREFIX = "kouphotos.backup.account-folders.v1.";
    private static int tests = 0;

    // Shape of the verified Google Photos 7.99 obfuscated preference object.
    public static final class FakePrefs {
        public final int b;
        public final Set<String> t;
        public FakePrefs(FakeBuilder builder) {
            this.b = builder.account;
            this.t = Collections.unmodifiableSet(new HashSet<>(builder.buckets));
        }
    }
    public static final class FakeBuilder {
        int account = -1;
        Set<String> buckets = new HashSet<>();
        public FakeBuilder() {}
        public void b(FakePrefs oldPrefs) {
            account = oldPrefs.b;
            buckets = new HashSet<>(oldPrefs.t);
        }
        public void c(Set<String> desired) { buckets = new HashSet<>(desired); }
        public FakePrefs a() { return new FakePrefs(this); }
    }
    static FakePrefs prefs(int account, String... folders) {
        FakeBuilder b = new FakeBuilder();
        b.account = account;
        b.buckets.addAll(Arrays.asList(folders));
        return b.a();
    }
    static class InMemoryPrefs implements SharedPreferences {
        final Map<String, Object> fields = new HashMap<>();
        boolean failCommit = false;
        @Override public int getInt(String key, int def) {
            Object value = fields.get(key);
            return value == null ? def : (Integer)value;
        }
        @Override @SuppressWarnings("unchecked") public Set<String> getStringSet(String key, Set<String> def) {
            Object value = fields.get(key);
            return value == null ? def : new HashSet<>((Set<String>)value);
        }
        @Override public Editor edit() {
            return new Editor() {
                Map<String, Object> updates = new HashMap<>();
                @Override public Editor putStringSet(String key, Set<String> value) {
                    updates.put(key, new HashSet<>(value)); return this;
                }
                @Override public boolean commit() {
                    if(failCommit) return false;
                    fields.putAll(updates);
                    return true;
                }
            };
        }
        void setCurrent(FakePrefs prefs) {
            fields.put(ACCOUNT, prefs.b);
            fields.put(FOLDERS, new HashSet<>(prefs.t));
        }
    }
    static final class FakeContext extends Context {
        final InMemoryPrefs prefs = new InMemoryPrefs();
        final InMemoryPrefs policyPrefs = new InMemoryPrefs();
        @Override public SharedPreferences getSharedPreferences(String name, int mode) {
            if(mode != 0) throw new AssertionError("mode");
            if(name.equals("photos.backup.backup_prefs")) return prefs;
            if(name.equals("kouphotos.backup.account_folder_policies")) return policyPrefs;
            throw new AssertionError(name);
        }
    }
    public static final class FakeStore {
        public final Context b;
        public FakeStore(Context context) {b=context;}
    }

    static void ok(String title, Runnable test) { test.run(); tests++; System.out.println("PASS "+title); }
    static void assertSet(Set<String> set, String... values) {
        if(!set.equals(new HashSet<>(Arrays.asList(values)))) throw new AssertionError("expected "+Arrays.toString(values)+" got "+set);
    }
    static void throwsFailClosed(Runnable call) {
        try { call.run(); throw new AssertionError("must fail closed"); }
        catch(IllegalStateException expected) {}
    }

    public static void main(String[] args) {
        final FakeContext context = new FakeContext();
        final FakeStore store = new FakeStore(context);
        final FakePrefs a = prefs(11,"DCIM/Camera");
        final FakePrefs b = prefs(22,"DCIM/Screenshots");

        ok("new backup account starts with zero selected folders", () -> {
            context.prefs.setCurrent(a);
            FakePrefs switched = (FakePrefs) AccountScopedFolders.prepare(store,a,b);
            assertSet(switched.t);
            assertSet(context.policyPrefs.getStringSet(PREFIX+"11", Set.of()),"DCIM/Camera");
            if(switched.b != 22) throw new AssertionError("wrong backup account");
            if(context.prefs.fields.keySet().stream().anyMatch(key -> key.startsWith(PREFIX)))
                throw new AssertionError("injected keys into the native preferences file");
        });
        ok("account A and B folders survive repeated switches", () -> {
            FakePrefs bActive = prefs(22, "DCIM/Screenshots");
            context.prefs.setCurrent(bActive);
            FakePrefs aRestored = (FakePrefs) AccountScopedFolders.prepare(store, bActive, prefs(11,"garbage"));
            assertSet(aRestored.t, "DCIM/Camera");
            assertSet(context.policyPrefs.getStringSet(PREFIX+"22", Set.of()),"DCIM/Screenshots");
            context.prefs.setCurrent(aRestored);
            FakePrefs bRestored = (FakePrefs) AccountScopedFolders.prepare(store, aRestored, prefs(22,"garbage"));
            assertSet(bRestored.t,"DCIM/Screenshots");
        });
        ok("folder edits without backup-account switch pass through", () -> {
            FakePrefs before = prefs(11,"DCIM/Camera");
            context.prefs.setCurrent(before);
            FakePrefs edited = prefs(11,"DCIM/Camera","Pictures/Other");
            if(AccountScopedFolders.prepare(store,before,edited) != edited)
                throw new AssertionError("same account must not clone or reset");
            assertSet(context.prefs.getStringSet(FOLDERS,Set.of()),"DCIM/Camera");
        });
        ok("backup disable never inherits previous folders", () -> {
            FakePrefs before = prefs(11,"DCIM/Camera");
            context.prefs.setCurrent(before);
            FakePrefs result=(FakePrefs) AccountScopedFolders.prepare(store,before,prefs(-1,"DCIM/Screenshots"));
            assertSet(result.t);
        });
        ok("unexpected account mutation fails without changing global prefs", () -> {
            context.prefs.setCurrent(prefs(99, "DCIM/Camera"));
            throwsFailClosed(() -> AccountScopedFolders.prepare(store,a,b));
            if(context.prefs.getInt(ACCOUNT,-1)!=99)throw new AssertionError("mutated account");
        });
        ok("unexpected previous folder mutation fails closed", () -> {
            context.prefs.setCurrent(prefs(11, "DCIM/Screenshots"));
            throwsFailClosed(() -> AccountScopedFolders.prepare(store,a,b));
            assertSet(context.prefs.getStringSet(FOLDERS,Set.of()),"DCIM/Screenshots");
        });
        ok("old account policy persistence failure blocks switch", () -> {
            context.prefs.setCurrent(a);
            context.policyPrefs.failCommit=true;
            throwsFailClosed(() -> AccountScopedFolders.prepare(store,a,b));
            context.policyPrefs.failCommit=false;
            if(context.prefs.getInt(ACCOUNT,-1)!=11)throw new AssertionError("switched on failure");
        });
        ok("initial backup enable is isolated from disabled account", () -> {
            FakePrefs disabled=prefs(-1);
            context.prefs.setCurrent(disabled);
            FakePrefs initial=(FakePrefs) AccountScopedFolders.prepare(store,disabled,prefs(123,"DCIM/Camera"));
            assertSet(initial.t);
        });
        ok("no false success on unknown preference class contract", () -> {
            context.prefs.setCurrent(a);
            throwsFailClosed(() -> AccountScopedFolders.prepare(store,a,new Object()));
        });
        // True end-to-end folder-policy roundtrip: the proposed value alone
        // must never persist a failed edit; native prefs commit first, then
        // recordCurrent snapshots that account. This was missing from the
        // original nine POC tests.
        final FakeContext strict = new FakeContext();
        final FakeStore strictStore = new FakeStore(strict);
        ok("current account folders are saved immediately after native commit", () -> {
            strict.prefs.setCurrent(prefs(11, "DCIM/Camera"));
            AccountScopedFolders.recordCurrent(strictStore);
            assertSet(strict.policyPrefs.getStringSet(PREFIX+"11", Set.of()), "DCIM/Camera");
        });
        ok("same-account edit changes only its own saved folder selection", () -> {
            FakePrefs before = prefs(11, "DCIM/Camera");
            FakePrefs changed = prefs(11, "Pictures/Other");
            if (AccountScopedFolders.prepare(strictStore, before, changed) != changed) {
                throw new AssertionError("native folder editor was changed");
            }
            // Native BackupPreferencesStore.o() commits the effective value.
            strict.prefs.setCurrent(changed);
            AccountScopedFolders.recordCurrent(strictStore);
            assertSet(strict.policyPrefs.getStringSet(PREFIX+"11", Set.of()), "Pictures/Other");
        });
        ok("account B starts empty, A selection remains untouched", () -> {
            FakePrefs before = prefs(11, "Pictures/Other");
            FakePrefs target = (FakePrefs) AccountScopedFolders.prepare(
                strictStore, before, prefs(22, "Pictures/Other"));
            assertSet(target.t);
            strict.prefs.setCurrent(target);
            AccountScopedFolders.recordCurrent(strictStore);
            assertSet(strict.policyPrefs.getStringSet(PREFIX+"11", Set.of()), "Pictures/Other");
            assertSet(strict.policyPrefs.getStringSet(PREFIX+"22", Set.of()));
        });
        ok("direct bucket write is stored under the active backup account", () -> {
            strict.prefs.setCurrent(prefs(22, "DCIM/Screenshots"));
            AccountScopedFolders.recordCurrent(strictStore);
            assertSet(strict.policyPrefs.getStringSet(PREFIX+"22", Set.of()), "DCIM/Screenshots");
            assertSet(strict.policyPrefs.getStringSet(PREFIX+"11", Set.of()), "Pictures/Other");
        });
        ok("A and B retain distinct folders over two round trips", () -> {
            FakePrefs fromB = prefs(22, "DCIM/Screenshots");
            FakePrefs aAgain = (FakePrefs) AccountScopedFolders.prepare(
                strictStore, fromB, prefs(11, "DCIM/Screenshots"));
            assertSet(aAgain.t, "Pictures/Other");
            strict.prefs.setCurrent(aAgain);
            AccountScopedFolders.recordCurrent(strictStore);
            FakePrefs bAgain = (FakePrefs) AccountScopedFolders.prepare(
                strictStore, aAgain, prefs(22, "Pictures/Other"));
            assertSet(bAgain.t, "DCIM/Screenshots");
            strict.prefs.setCurrent(bAgain);
            AccountScopedFolders.recordCurrent(strictStore);
            assertSet(strict.policyPrefs.getStringSet(PREFIX+"11", Set.of()), "Pictures/Other");
            assertSet(strict.policyPrefs.getStringSet(PREFIX+"22", Set.of()), "DCIM/Screenshots");
        });
        ok("uncommitted settings changes do not overwrite saved policy", () -> {
            FakePrefs before = prefs(22, "DCIM/Screenshots");
            FakePrefs proposed = prefs(22, "DCIM/Camera");
            if (AccountScopedFolders.prepare(strictStore, before, proposed) != proposed)
                throw new AssertionError("native edit unexpectedly transformed");
            // No native commit => no recordCurrent. Policy remains unchanged.
            assertSet(strict.policyPrefs.getStringSet(PREFIX+"22", Set.of()), "DCIM/Screenshots");
        });
        ok("disabled backup must not overwrite a saved account policy", () -> {
            strict.prefs.setCurrent(prefs(-1));
            AccountScopedFolders.recordCurrent(strictStore);
            assertSet(strict.policyPrefs.getStringSet(PREFIX+"22", Set.of()), "DCIM/Screenshots");
        });
        ok("policy write failure is detectable after a native folder edit", () -> {
            strict.prefs.setCurrent(prefs(22, "DCIM/Camera"));
            strict.policyPrefs.failCommit = true;
            int errorsBefore = Log.errors;
            AccountScopedFolders.recordCurrent(strictStore);
            if (Log.errors != errorsBefore + 1)
                throw new AssertionError("snapshot failure must be logged");
            strict.policyPrefs.failCommit = false;
            assertSet(strict.policyPrefs.getStringSet(PREFIX+"22", Set.of()), "DCIM/Screenshots");
        });
        ok("unexpected direct-write receiver does not crash UI", () -> {
            int errorsBefore = Log.errors;
            AccountScopedFolders.recordCurrent(new Object());
            if (Log.errors != errorsBefore + 1)
                throw new AssertionError("unexpected receiver must be diagnosed");
        });
        System.out.println("PASS ALL "+tests+" bridge cases");
    }
}
