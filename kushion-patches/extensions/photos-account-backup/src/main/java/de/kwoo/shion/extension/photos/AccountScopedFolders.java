package de.kwoo.shion.extension.photos;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Log;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;

/**
 * Narrowly scoped to the Google Photos BackupPreferencesStore write transaction.
 *
 * Called only while the store's monitor is held, immediately after monitor-enter,
 * and before its native SharedPreferences.Editor.commit().
 *
 * The original Photos backup scheduler and account selection are preserved.
 * A previous account's effective folder set is durably snapshotted before the
 * native account switch, and the incoming BackupPreferences gets the target's
 * stored folder set (or none on first use).
 *
 * Reflection here is intentional: target classes are obfuscated, discovered
 * and checked by the accompanying Morphe fingerprint before injection.
 * Never silently fail open: if a contract changes, abort the switch rather
 * than allow a previous account's folder choice into a different account.
 */
public final class AccountScopedFolders {
    private static final String TAG = "KouPhotosBackup";
    private static final String PREF_FILE = "photos.backup.backup_prefs";
    private static final String POLICY_PREF_FILE = "kouphotos.backup.account_folder_policies";
    private static final String ACCOUNT_KEY = "backup_prefs_account_id";
    private static final String FOLDERS_KEY = "photos.backup.backup_local_folders";
    private static final String ACCOUNT_POLICY_PREFIX = "kouphotos.backup.account-folders.v1.";
    private static final int DISABLED_ACCOUNT = -1;

    private AccountScopedFolders() {}

    public static Object prepare(Object store, Object previous, Object proposed) {
        if (store == null || previous == null || proposed == null
                || previous.getClass() != proposed.getClass()) {
            throw new IllegalStateException("Unexpected backup preferences transition");
        }
        try {
            final int fromId = accountId(previous);
            final int toId = accountId(proposed);
            if (fromId == toId) return proposed;

            final Context context = contextOf(store);
            final SharedPreferences prefs = context.getSharedPreferences(PREF_FILE, Context.MODE_PRIVATE);
            final SharedPreferences policyPrefs = context.getSharedPreferences(
                POLICY_PREF_FILE, Context.MODE_PRIVATE);
            final int durableAccountId = prefs.getInt(ACCOUNT_KEY, DISABLED_ACCOUNT);
            if (durableAccountId != fromId) {
                throw new IllegalStateException("Backup account changed outside the expected store");
            }

            final Set<String> activeFolders = new HashSet<>(
                prefs.getStringSet(FOLDERS_KEY, Collections.<String>emptySet()));
            final Set<String> previousFolders = bucketsOf(previous);
            if (!activeFolders.equals(previousFolders)) {
                throw new IllegalStateException("Backup folders changed outside the expected store");
            }
            if (fromId != DISABLED_ACCOUNT) {
                final boolean saved = policyPrefs.edit()
                    .putStringSet(accountPolicyKey(fromId), activeFolders).commit();
                if (!saved) {
                    throw new IllegalStateException("Could not persist old account's folders");
                }
            }

            final Set<String> destinationFolders = toId == DISABLED_ACCOUNT
                ? Collections.<String>emptySet()
                : new HashSet<>(policyPrefs.getStringSet(
                    accountPolicyKey(toId), Collections.<String>emptySet()));

            Log.i(TAG, "Restoring account folder policy: currentCount=" +
                activeFolders.size() + " targetCount=" + destinationFolders.size());
            return withBuckets(proposed, destinationFolders);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("Backup preferences contract changed", e);
        }
    }

    /**
     * Capture the current native backup folder selection after Photos commits
     * its normal settings transaction (or applies its direct bucket update).
     * Account switches already save the departing account in prepare(); this
     * completes the other side of the contract: each in-account folder edit
     * updates that account's own snapshot immediately.
     *
     * Read the native preference file instead of trusting a proposed builder:
     * rejected commits must not update a policy.
     */
    public static void recordCurrent(Object store) {
        // This is a post-write snapshot, not an atomic part of the native
        // transaction. Throwing from here would kill Photos after it has
        // already applied the requested folder edit. Retry the snapshot via
        // prepare() before the next account change, which remains fail-closed.
        try {
            if (store == null) {
                throw new IllegalStateException("BackupPreferencesStore is null");
            }
            synchronized (store) {
                final Context context = contextOf(store);
                final SharedPreferences nativePrefs = context.getSharedPreferences(
                    PREF_FILE, Context.MODE_PRIVATE);
                final int account = nativePrefs.getInt(ACCOUNT_KEY, DISABLED_ACCOUNT);
                if (account == DISABLED_ACCOUNT) return;

                final Set<String> folders = new HashSet<>(
                    nativePrefs.getStringSet(FOLDERS_KEY, Collections.<String>emptySet()));
                final SharedPreferences policyPrefs = context.getSharedPreferences(
                    POLICY_PREF_FILE, Context.MODE_PRIVATE);
                final String key = accountPolicyKey(account);
                final Set<String> saved = policyPrefs.getStringSet(key, null);
                if (saved != null && saved.equals(folders)) return;

                if (!policyPrefs.edit().putStringSet(key, folders).commit()) {
                    throw new IllegalStateException(
                        "Could not preserve selected backup folders for current account");
                }
                Log.i(TAG, "Saved active account folder policy; folderCount=" + folders.size());
            }
        } catch (ReflectiveOperationException | RuntimeException exception) {
            Log.e(TAG, "Cannot persist folder snapshot; account switch must retry", exception);
        }
    }
    /**
     * Read a saved target account's chosen local folders. The native backup
     * settings transaction must receive this set when changing accounts:
     * leaving BackupSettingsMutation.l unset retains the previous account's
     * buckets in 7.99.
     *
     * A target without saved policy deliberately gets no local folders.
     */
    public static Set<String> foldersForAccount(Context context, int account) {
        if (account == DISABLED_ACCOUNT) return Collections.emptySet();
        if (account < 0 || context == null) {
            throw new IllegalArgumentException("Invalid target backup account");
        }
        final SharedPreferences policyPrefs = context.getSharedPreferences(
            POLICY_PREF_FILE, Context.MODE_PRIVATE);
        return new HashSet<>(policyPrefs.getStringSet(
            accountPolicyKey(account), Collections.<String>emptySet()));
    }
    private static String accountPolicyKey(int id) {
        if (id < 0) throw new IllegalArgumentException("Invalid active backup account");
        return ACCOUNT_POLICY_PREFIX + id;
    }

    private static int accountId(Object value) throws ReflectiveOperationException {
        final Field field = value.getClass().getDeclaredField("b");
        if (field.getType() != int.class) {
            throw new IllegalStateException("Unexpected account field type");
        }
        field.setAccessible(true);
        return field.getInt(value);
    }

    @SuppressWarnings("unchecked")
    private static Set<String> bucketsOf(Object value) throws ReflectiveOperationException {
        final Field field = value.getClass().getDeclaredField("t");
        field.setAccessible(true);
        final Object buckets = field.get(value);
        if (!(buckets instanceof Set)) {
            throw new IllegalStateException("Unexpected bucket field type");
        }
        return new HashSet<>((Set<String>) buckets);
    }

    private static Context contextOf(Object store) throws ReflectiveOperationException {
        Context context = null;
        for (Field field : store.getClass().getDeclaredFields()) {
            if (!Context.class.isAssignableFrom(field.getType())) continue;
            if (context != null) throw new IllegalStateException("Ambiguous Photos context");
            field.setAccessible(true);
            context = (Context) field.get(store);
        }
        if (context == null) throw new IllegalStateException("Missing Photos context");
        return context;
    }

    private static Object withBuckets(Object proposed, Set<String> desired)
            throws ReflectiveOperationException {
        final Class<?> preferencesClass = proposed.getClass();
        Class<?> builderClass = null;
        for (Constructor<?> ctor : preferencesClass.getDeclaredConstructors()) {
            if (ctor.getParameterTypes().length != 1) continue;
            final Class<?> candidate = ctor.getParameterTypes()[0];
            if (candidate.getName().equals("android.os.Parcel")) continue;
            if (builderClass != null) throw new IllegalStateException("Ambiguous preferences builder");
            builderClass = candidate;
        }
        if (builderClass == null) throw new IllegalStateException("Missing preferences builder");

        final Constructor<?> constructor = builderClass.getDeclaredConstructor();
        constructor.setAccessible(true);
        final Object builder = constructor.newInstance();

        Method copy = null, setBuckets = null, build = null;
        for (Method method : builderClass.getDeclaredMethods()) {
            final Class<?>[] params = method.getParameterTypes();
            if (params.length == 1 && params[0] == preferencesClass && method.getReturnType() == void.class)
                copy = method;
            if (params.length == 1 && params[0] == Set.class && method.getReturnType() == void.class)
                setBuckets = method;
            if (params.length == 0 && method.getReturnType() == preferencesClass)
                build = method;
        }
        if (copy == null || setBuckets == null || build == null) {
            throw new IllegalStateException("Missing preferences builder methods");
        }
        copy.setAccessible(true);
        setBuckets.setAccessible(true);
        build.setAccessible(true);
        copy.invoke(builder, proposed);
        setBuckets.invoke(builder, desired);
        final Object adjusted = build.invoke(builder);
        if (adjusted == null || accountId(adjusted) != accountId(proposed)
                || !bucketsOf(adjusted).equals(desired)) {
            throw new IllegalStateException("Backup preferences reconstruction failed");
        }
        return adjusted;
    }
}
