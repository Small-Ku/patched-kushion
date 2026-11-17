import android.util.Log;
import android.widget.Toast;
import de.kwoo.shion.extension.photos.BackupAccountFollower;

public final class BackupAccountFollowerTest {
    private static int passed;
    private static TestContext context;
    private static alfv handler;
    private static unq manager;
    private static toi legacy;
    private static void setup(int backingUp,boolean modern) {
        context = new TestContext();
        context.preferences.setBackupAccount(backingUp);
        handler = new alfv(context);
        manager = new unq(context);
        legacy = new toi(context);
        uat.modern=modern;
        cbyf.services.clear();
        cbyf.services.put(caet.class,new caet());
        cbyf.services.put(uat.class,new uat());
        cbyf.services.put(unq.class,manager);
        cbyf.services.put(toi.class,legacy);
        Toast.lastMessage=null;
        Log.errors=0;
    }
    private static int backedUp() {
        return context.preferences.getInt("backup_prefs_account_id",-1);
    }
    private static void switched(int before,int selected) {
        BackupAccountFollower.onSelectedAccountChanged(new alfy(before,selected,handler));
    }
    private static void check(boolean condition,String what) {
        if(!condition)throw new AssertionError(what);
    }
    private static void run(String description,Runnable test) {
        test.run(); passed++; System.out.println("PASS "+description);
    }
    public static void main(String[] args) {
        run("Modern manager follows selected account",()->{
            setup(10,true); switched(10,20);
            check(backedUp()==20,"modern destination");
            check(manager.commits==1,"modern transaction count");
            check(legacy.commits==0,"no legacy side effects");
            check(Toast.lastMessage==null,"no error toast");
        });
        run("Legacy editor follows selected account",()->{
            setup(10,false); switched(10,20);
            check(backedUp()==20,"legacy destination");
            check(manager.commits==0,"no modern side effects");
            check(legacy.commits==1,"legacy transaction count");
        });
        run("Disabled backup stays disabled during account browse",()->{
            setup(-1,true); switched(10,20);
            check(backedUp()==-1,"disabled destination");
            check(manager.commits==0,"must not enable");
        });
        run("Native backup settings transaction owns its switch",()->{
            setup(10,true);
            handler.a.add(new uks("test@example.com"));
            switched(10,20);
            check(backedUp()==10,"do not preempt native transaction");
            check(manager.commits==0,"native transaction guard");
        });
        run("Logged-out target pauses backup without leaking to old account",()->{
            setup(10,true); switched(10,99);
            check(backedUp()==-1,"invalid target must pause");
            check(manager.commits==1,"disable through manager");
            check(Toast.lastMessage!=null && Toast.lastMessage.contains("paused"),"warn");
        });
        run("Modern mutation rejected: warns and attempts backup disable",()->{
            setup(10,true); manager.reject=true; switched(10,20);
            check(backedUp()==10,"no false success");
            check(manager.commits==2,"attempt target and fail-safe disable");
            check(Toast.lastMessage!=null && Toast.lastMessage.contains("mismatch"),"warn");
        });
        run("Already matching account is a no-op",()->{
            setup(20,true); switched(10,20);
            check(backedUp()==20,"already selected account");
            check(manager.commits==0,"no transaction");
        });
        run("App did not change selected account: no-op",()->{
            setup(10,true); switched(10,10);
            check(backedUp()==10,"no change");
            check(manager.commits==0,"no transaction");
        });
        run("Sign out disables native backup",()->{
            setup(10,true); switched(10,-1);
            check(backedUp()==-1,"signed out destination");
            check(manager.commits==1,"native manager disable");
        });
        run("Native backup settings without pending request doesn't block",()->{
            setup(10,true); handler.a.add(new uks(null));
            switched(10,20);
            check(backedUp()==20,"ordinary account switch");
        });
        run("Account switch commits destination account and its saved folders atomically",()->{
            setup(10,true);
            context.preferences.values.put("photos.backup.backup_local_folders",
                java.util.Set.of("DCIM/Camera"));
            context.policies.values.put("kouphotos.backup.account-folders.v1.20",
                java.util.Set.of("DCIM/Screenshots"));
            switched(10,20);
            check(backedUp()==20,"target account");
            check(context.preferences.getStringSet(
                "photos.backup.backup_local_folders",java.util.Set.of()).equals(
                java.util.Set.of("DCIM/Screenshots")),"target folders");
            check(manager.commits==1,"single native atomic transaction");
        });
        run("New account gets no inherited backup folders",()->{
            setup(10,true);
            context.preferences.values.put("photos.backup.backup_local_folders",
                java.util.Set.of("DCIM/Camera"));
            switched(10,20);
            check(backedUp()==20,"target account");
            check(context.preferences.getStringSet(
                "photos.backup.backup_local_folders",java.util.Set.of()).isEmpty(),
                "new account must not inherit Camera");
        });
        run("B to A restores A without retaining B folders",()->{
            setup(20,true);
            context.preferences.values.put("photos.backup.backup_local_folders",
                java.util.Set.of("DCIM/Screenshots"));
            context.policies.values.put("kouphotos.backup.account-folders.v1.10",
                java.util.Set.of("DCIM/Camera"));
            switched(20,10);
            check(backedUp()==10,"restored account");
            check(context.preferences.getStringSet(
                "photos.backup.backup_local_folders",java.util.Set.of()).equals(
                java.util.Set.of("DCIM/Camera")),"restored source folders");
        });
        run("Backup disable also clears inherited local folders",()->{
            setup(10,true);
            context.preferences.values.put("photos.backup.backup_local_folders",
                java.util.Set.of("DCIM/Camera"));
            switched(10,-1);
            check(backedUp()==-1,"backup off");
            check(context.preferences.getStringSet(
                "photos.backup.backup_local_folders",java.util.Set.of()).isEmpty(),
                "disabling backup should not keep previous buckets active");
        });        run("Account-only native mutation fails closed instead of retaining old folders",()->{
            setup(10,true);
            manager.ignoreFolderWrites=true;
            context.preferences.values.put("photos.backup.backup_local_folders",
                java.util.Set.of("DCIM/Camera"));
            context.policies.values.put("kouphotos.backup.account-folders.v1.20",
                java.util.Set.of("DCIM/Screenshots"));
            switched(10,20);
            check(backedUp()==-1,"account-only mutation should disable backup");
            check(manager.commits==2,"native switch and safety disable");
            check(Toast.lastMessage!=null && Toast.lastMessage.contains("paused"),
                "user must see account/folder mismatch");
        });        System.out.println("PASS ALL "+passed+" native account-follow tests");
    }
}
