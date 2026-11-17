package de.kwoo.shion.extension.photos;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Log;
import android.widget.Toast;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.util.List;
import java.util.Set;

public final class BackupAccountFollower {
    private static final String TAG = "KouPhotosBackup";
    private static final String BACKUP_PREFS = "photos.backup.backup_prefs";
    private static final String ACCOUNT_KEY = "backup_prefs_account_id";
    private static final ThreadLocal<Boolean> IN_TRANSITION = new ThreadLocal<>();

    private BackupAccountFollower() {}

    // Called from the native AccountChangeHandler state-notification path.
    public static void onSelectedAccountChanged(Object state) {
        if (Boolean.TRUE.equals(IN_TRANSITION.get()) || state == null) return;
        final Context context;
        final int selected;
        final int previous;
        try {
            final Object callback = field(state, "e");
            if (callback == null) return;
            final Object accountHandler = field(callback, "a");
            if (accountHandler == null) return;
            if (isNativeBackupSelectionPending(accountHandler)) return;
            context = (Context) field(accountHandler, "d");
            selected = intField(state, "a");
            previous = intField(state, "d");
        } catch (ReflectiveOperationException | ClassCastException error) {
            Log.e(TAG, "Could not inspect Photos' selected account", error);
            return;
        }

        if (context == null || selected == previous) return;
        final SharedPreferences nativePrefs =
            context.getSharedPreferences(BACKUP_PREFS, Context.MODE_PRIVATE);
        final int backingUp = nativePrefs.getInt(ACCOUNT_KEY, -1);
        // Browsing accounts must never turn on a backup that was disabled.
        if (backingUp == -1 || backingUp == selected) return;

        IN_TRANSITION.set(Boolean.TRUE);
        try {
            if (selected != -1 && !isLoggedIn(context, selected)) {
                throw new IllegalStateException("Selected account not yet logged in");
            }
            final Set<String> expectedFolders =
                AccountScopedFolders.foldersForAccount(context, selected);
            if (!switchNativeBackupAccount(context, selected) ||
                    nativePrefs.getInt(ACCOUNT_KEY, -1) != selected) {
                throw new IllegalStateException("Native backup account switch was rejected");
            }
            final Set<String> committedFolders = nativePrefs.getStringSet(
                "photos.backup.backup_local_folders",
                java.util.Collections.<String>emptySet());
            if (!committedFolders.equals(expectedFolders)) {
                throw new IllegalStateException(
                    "Native backup destination changed without restoring its folders");
            }
            Log.i(TAG, "Backup account and folders committed; folder count=" +
                committedFolders.size());
        } catch (Exception exception) {
            Log.e(TAG, "Native backup account could not follow selected account", exception);
            boolean paused = false;
            try {
                paused = nativePrefs.getInt(ACCOUNT_KEY, -1) == -1 ||
                    (switchNativeBackupAccount(context, -1)
                        && nativePrefs.getInt(ACCOUNT_KEY, -1) == -1);
            } catch (Exception failure) {
                Log.e(TAG, "Could not pause backup after account mismatch", failure);
            }
            Toast.makeText(context,
                paused ? "KouPhotos: backup paused after an account switch error"
                       : "KouPhotos: backup account mismatch; check backup settings",
                Toast.LENGTH_LONG).show();
        } finally {
            IN_TRANSITION.remove();
        }
    }

    // The backup settings screen already has a native account-switch
    // transaction. Do not switch early while it is logging in its pending
    // account or that UI transaction would observe an "already enabled" state.
    private static boolean isNativeBackupSelectionPending(Object handler)
            throws ReflectiveOperationException {
        Object observers = field(handler, "a");
        if (!(observers instanceof List<?>)) return false;
        for (Object observer : (List<?>) observers) {
            if (observer != null && observer.getClass().getName().equals("uks")
                    && field(observer, "l") != null) {
                return true;
            }
        }
        return false;
    }
    private static boolean isLoggedIn(Context context, int accountId)
            throws ReflectiveOperationException {
        return (boolean) call(service(context, "caet"), "n",
                new Class<?>[]{int.class}, accountId);
    }

    private static boolean switchNativeBackupAccount(Context context, int accountId)
            throws ReflectiveOperationException {
        // Use native BackupSettingsEditor / BackupSettingsManager, not direct
        // SharedPreferences writes. Matches the backup settings UI's dispatch.
        final Class<?> reasonType = type("upd");
        final Object reason = construct(reasonType,
            new Class<?>[]{long.class, String.class, String.class},System.currentTimeMillis(),
                    "KouPhotos", "Follow selected Google Photos account");
        final Class<?> sourceType = type("tow");
        @SuppressWarnings({"unchecked", "rawtypes"})
        final Object source = Enum.valueOf((Class<? extends Enum>) sourceType,
                "SOURCE_PHOTOS");
        final Class<?> toggleType = type("tou");
        final Object toggle = construct(toggleType,
            new Class<?>[]{sourceType, String.class, int.class},source, null, 2);

        if ((boolean) call(service(context, "uat"), "h", new Class<?>[0])) {
            final Class<?> mutationType = type("unr");
            final Object mutation = construct(mutationType, new Class<?>[0]);
            if (accountId == -1) {
                call(mutation, "a", new Class<?>[]{toggleType}, toggle);
            } else {
                callStatic(mutationType, "e", new Class<?>[]{
                    mutationType, int.class, toggleType, type("tpg"),
                    type("uog"), int.class
                }, mutation, accountId, toggle, null, null, 8);
            }

            // BackupSettingsManager.j() retains the current folders unless
            // BackupSettingsMutation.l is explicitly set. Submit both account
            // and its saved buckets in the SAME native transaction, avoiding
            // an interval where the new destination sees the old selection.
            final Set<String> desiredFolders =
                AccountScopedFolders.foldersForAccount(context, accountId);
            call(mutation, "d", new Class<?>[]{Set.class}, desiredFolders);
            // Supply native audit context, like the backup settings screen.
            final Object uiContext = callStatic(type("shx"), "c",
                    new Class<?>[]{Context.class}, context);
            final Class<?> auditType = type("uoi");
            final Object audit = construct(auditType,
                new Class<?>[]{type("chxn"), type("chvt")},uiContext, null);
            final Object logging = construct(type("uol"),
                new Class<?>[]{reasonType, int.class, auditType},reason, 1, audit);
            final Object result = call(service(context, "unq"), "j",
                    new Class<?>[]{mutationType, type("uol")}, mutation, logging);
            return type("unu").isInstance(result);
        }

        final Object editor = call(service(context, "toi"), "i",
                new Class<?>[0]);
        if (accountId == -1) {
            call(editor, "k", new Class<?>[]{toggleType}, toggle);
        } else {
            call(editor, "l", new Class<?>[]{int.class, toggleType},
                    accountId, toggle);
        }
        return (boolean) call(editor, "a", new Class<?>[]{reasonType}, reason);
    }

    private static Object construct(Class<?> owner, Class<?>[] parameters,
                                    Object... args) throws ReflectiveOperationException {
        final Constructor<?> constructor = owner.getDeclaredConstructor(parameters);
        constructor.setAccessible(true);
        try {
            return constructor.newInstance(args);
        } catch (InvocationTargetException exception) {
            throw new ReflectiveOperationException("Photos native model constructor failed",
                    exception.getCause());
        }
    }
    private static Class<?> type(String name) throws ClassNotFoundException {
        return Class.forName(name);
    }

    private static Object service(Context context, String name)
            throws ReflectiveOperationException {
        return callStatic(type("cbyf"), "e",
                new Class<?>[]{Context.class, Class.class}, context, type(name));
    }

    private static Object call(Object receiver, String method, Class<?>[] types,
                               Object... args) throws ReflectiveOperationException {
        try {
            final Method target = receiver.getClass().getMethod(method, types);
            target.setAccessible(true);
            return target.invoke(receiver, args);
        } catch (InvocationTargetException exception) {
            throw new ReflectiveOperationException(
                "Photos native account operation failed", exception.getCause());
        }
    }

    private static Object callStatic(Class<?> owner, String method, Class<?>[] types,
                                     Object... args) throws ReflectiveOperationException {
        try {
            final Method target = owner.getMethod(method, types);
            target.setAccessible(true);
            return target.invoke(null, args);
        } catch (InvocationTargetException exception) {
            throw new ReflectiveOperationException(
                "Photos native account operation failed", exception.getCause());
        }
    }

    private static Object field(Object receiver, String name)
            throws ReflectiveOperationException {
        final Field field = receiver.getClass().getDeclaredField(name);
        field.setAccessible(true);
        return field.get(receiver);
    }

    private static int intField(Object receiver, String name)
            throws ReflectiveOperationException {
        final Field field = receiver.getClass().getDeclaredField(name);
        field.setAccessible(true);
        return field.getInt(receiver);
    }
}
