package de.kwoo.shion.patches.photos

import app.morphe.patcher.Fingerprint
import app.morphe.patcher.extensions.InstructionExtensions.addInstructions
import app.morphe.patcher.patch.bytecodePatch
import com.android.tools.smali.dexlib2.Opcode
import com.android.tools.smali.dexlib2.builder.MutableMethodImplementation
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction
import com.android.tools.smali.dexlib2.iface.instruction.OneRegisterInstruction
import com.android.tools.smali.dexlib2.iface.instruction.TwoRegisterInstruction
import com.android.tools.smali.dexlib2.iface.reference.MethodReference

private const val PREF_FILE = "photos.backup.backup_prefs"
private const val BRIDGE = "Lde/kwoo/shion/extension/photos/AccountScopedFolders;"

/**
 * Identify BackupPreferencesStore by its app-private preference filename, not
 * by a ProGuard class name. The update method must perform one native
 * SharedPreferences putStringSet call, shared by the 7.99 write paths.
 */
private object BackupPrefsStoreFingerprint : Fingerprint(
    returnType = "Landroid/content/SharedPreferences;",
    parameters = emptyList(),
    strings = listOf(PREF_FILE),
)

private object SelectedAccountStateFingerprint : Fingerprint(
    returnType = "V",
    parameters = listOf("Landroid/os/Bundle;"),
    strings = listOf("current_account_id", "previous_account_id", "current_account_handler_state"),
)

/**
 * Experimental feature patch. It does not alter distribution identity.
 * The existing Photos backup scheduler owns credential/account transactions.
 */
@Suppress("unused")
val accountScopedFoldersPatch = bytecodePatch(
    name = "KouPhotos account-scoped backup folders",
    description = "Follow selected Photos account for backup, retaining device folders per account.",
    default = false,
) {
    compatibleWith(TARGET_PACKAGE)
    extendWith("extensions/photos-account-backup.mpe")

    execute {
        val storeClass = classDefBy(BackupPrefsStoreFingerprint.method.definingClass)
        val store = mutableClassDefBy(storeClass)
        val candidates = store.methods.filter { method ->
            val types = method.parameterTypes.map(CharSequence::toString)
            val implementation = method.implementation ?: return@filter false
            method.returnType == "Z" &&
                types.size == 4 &&
                types[0] == types[1] &&
                types[3] == "I" &&
                implementation.instructions.count { instruction ->
                    ((instruction as? ReferenceInstruction)?.reference as? MethodReference)?.let {
                        it.definingClass == "Landroid/content/SharedPreferences\$Editor;" &&
                            it.name == "putStringSet"
                    } == true
                } == 1
        }
        require(candidates.size == 1) {
            "Unexpected Photos BackupPreferencesStore write contract: ${candidates.size} matches"
        }
        val write = candidates.single()
        val preferencesType = write.parameterTypes[1].toString()
        val prefsDef = classDefBy(preferencesType)
        require(prefsDef.fields.any { it.name == "b" && it.type == "I" }) {
            "Backup account ID field changed"
        }
        require(prefsDef.fields.any {
            it.name == "t" && it.type == "Lcom/google/common/collect/ImmutableSet;"
        }) { "Backup folder set field changed" }
        // The Android bridge uses reflection against this exact obfuscated
        // preference shape. Fail at patch time if even one member differs.
        val builderTypes = prefsDef.methods.filter {
            it.name == "<init>" && it.parameterTypes.size == 1 &&
                it.parameterTypes[0] != "Landroid/os/Parcel;"
        }.map { it.parameterTypes.single().toString() }.distinct()
        require(builderTypes.size == 1) { "Backup preferences builder changed: $builderTypes" }
        val builderType = builderTypes.single()
        val builder = classDefBy(builderType)
        require(builder.methods.any {
            it.name == "<init>" && it.parameterTypes.isEmpty()
        } && builder.methods.any {
            it.returnType == "V" && it.parameterTypes.map(CharSequence::toString) == listOf(preferencesType)
        } && builder.methods.any {
            it.returnType == "V" && it.parameterTypes.map(CharSequence::toString) == listOf("Ljava/util/Set;")
        } && builder.methods.any {
            it.returnType == preferencesType && it.parameterTypes.isEmpty()
        }) { "Backup preferences builder methods changed" }
        require(store.fields.count { it.type == "Landroid/content/Context;" } == 1) {
            "Backup preferences context ownership changed"
        }
        val monitorIndices = write.implementation!!.instructions.withIndex()
            .filter { it.value.opcode == Opcode.MONITOR_ENTER }.map { it.index }
        require(monitorIndices.size == 1) { "Backup store synchronization contract changed" }
        val implementation = write.implementation as MutableMethodImplementation
        // Photos 7.99 copies proposed BackupPreferences (p2) into a low-numbered
        // working register before monitor-enter. The original write uses that
        // working copy, not p2. Replacing p2 here would only update an unused
        // parameter register while persisting the previous account's buckets.
        val nativeInstructions = implementation.instructions.toList()
        val parameterStart = implementation.registerCount - write.parameterTypes.size - 1
        val proposedParameter = parameterStart + 2
        val proposedCopies = nativeInstructions.withIndex().filter { (index, instruction) ->
            index < monitorIndices.single() &&
                instruction.opcode == Opcode.MOVE_OBJECT_FROM16 &&
                (instruction as TwoRegisterInstruction).registerB == proposedParameter
        }
        require(proposedCopies.size == 1 &&
            proposedCopies.single().index == monitorIndices.single() - 1) {
            "Photos proposed preferences working-copy contract changed"
        }
        val proposedWorkingRegister =
            (proposedCopies.single().value as TwoRegisterInstruction).registerA
        require(proposedWorkingRegister < parameterStart &&
            nativeInstructions.getOrNull(monitorIndices.single() + 1)?.let {
                it.opcode == Opcode.IGET &&
                    (it as TwoRegisterInstruction).registerB == proposedWorkingRegister
            } == true) {
            "Photos backup store no longer reads its proposed working copy after the monitor"
        }

        // The original first try begins immediately after monitor-enter. Adding the
        // hook at that boundary would leave a throwing bridge outside its catchall
        // and permanently hold the store monitor. Retain the original release-and-
        // rethrow handler, and explicitly cover the injected instructions.
        val handlers = implementation.tryBlocks.flatMap { it.exceptionHandlers }
            .filter { it.exceptionType == null }.map { it.handlerCodeAddress }.distinct()
        require(handlers.size == 1) { "Unexpected Photos synchronized catchall: $handlers" }
        val monitorExitHandler = implementation.newLabelForAddress(handlers.single())
        write.addInstructions(
            monitorIndices.single() + 1,
            """
                invoke-static/range {p0 .. p2}, $BRIDGE->prepare(Ljava/lang/Object;Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;
                move-result-object v$proposedWorkingRegister
                check-cast v$proposedWorkingRegister, $preferencesType
            """.trimIndent()
        )
        val catchStart = implementation.newLabelForIndex(monitorIndices.single() + 1)
        val catchEnd = implementation.newLabelForIndex(monitorIndices.single() + 4)
        implementation.addCatch(catchStart, catchEnd, monitorExitHandler)
        // Persist the active account's folder selection from the committed
        // native preferences after every backup settings write. Previously the
        // bridge only snapshotted folders when the account ID changed.
        val storeReturnIndices = implementation.instructions.withIndex()
            .filter { it.value.opcode == Opcode.RETURN }.map { it.index }
        require(storeReturnIndices.size == 1) {
            "Backup preferences commit exit contract changed: " + storeReturnIndices
        }
        write.addInstructions(
            storeReturnIndices.single(),
            "invoke-static/range {p0 .. p0}, $BRIDGE->recordCurrent(Ljava/lang/Object;)V"
        )

        // Google Photos also adds device buckets directly through a second
        // method, bypassing BackupPreferencesStore.o(). Save that path too,
        // after its native SharedPreferences.Editor.apply().
        val directFolderWrites = store.methods.filter { method ->
            val types = method.parameterTypes.map(CharSequence::toString)
            val instructions = method.implementation?.instructions ?: return@filter false
            method.returnType == "V" &&
                types == listOf("Lcom/google/common/collect/ImmutableSet;") &&
                instructions.any { instruction ->
                    ((instruction as? ReferenceInstruction)?.reference as? MethodReference)?.let {
                        it.definingClass == "Landroid/content/SharedPreferences\$Editor;" &&
                            it.name == "putStringSet"
                    } == true
                } &&
                instructions.any { instruction ->
                    ((instruction as? ReferenceInstruction)?.reference as? MethodReference)?.let {
                        it.definingClass == "Landroid/content/SharedPreferences\$Editor;" &&
                            it.name == "apply"
                    } == true
                }
        }
        require(directFolderWrites.size == 1) {
            "Backup preferences direct-folder write contract changed: " + directFolderWrites.size
        }
        val directFolderWrite = directFolderWrites.single()
        // In the 7.99 method, p0 is held in v5 until the later asynchronous
        // k() call writes its result into v5. Hooking at RETURN_VOID would
        // therefore pass a cgdo instead of the store (and crash on Context).
        // SharedPreferences.apply() makes values visible in memory before it
        // returns, so capture the committed selection immediately afterwards.
        val directApplies = directFolderWrite.implementation!!.instructions.withIndex()
            .filter { instruction ->
                ((instruction.value as? ReferenceInstruction)?.reference as? MethodReference)?.let {
                    it.definingClass == "Landroid/content/SharedPreferences\$Editor;" &&
                        it.name == "apply"
                } == true
            }.map { it.index }
        require(directApplies.size == 1) {
            "Backup preferences direct-folder apply contract changed: " + directApplies
        }
        // Verify p0 still points to the synchronized store at the insertion
        // point. In 7.99 the method later overwrites that register with an
        // async future; this guard prevents accidentally moving the hook to
        // that later code path again.
        val directInstructions = directFolderWrite.implementation!!.instructions.toList()
        val receiverRegister = directFolderWrite.implementation!!.registerCount -
            directFolderWrite.parameterTypes.size - 1
        val directMonitors = directInstructions.withIndex()
            .filter { it.value.opcode == Opcode.MONITOR_ENTER }
        require(directMonitors.size == 1 &&
            (directMonitors.single().value as OneRegisterInstruction).registerA == receiverRegister &&
            directMonitors.single().index < directApplies.single()) {
            "Backup preferences direct write is no longer synchronized on its receiver"
        }
        require(directInstructions.withIndex().none { (index, instruction) ->
            index > directMonitors.single().index && index <= directApplies.single() &&
                instruction.opcode == Opcode.MOVE_RESULT_OBJECT &&
                (instruction as OneRegisterInstruction).registerA == receiverRegister
        }) {
            "Backup preferences receiver register overwritten before folder snapshot"
        }
        directFolderWrite.addInstructions(
            directApplies.single() + 1,
            "invoke-static/range {p0 .. p0}, $BRIDGE->recordCurrent(Ljava/lang/Object;)V"
        )
        // The viewed login account and the backup account use separate state.
        // Follow the Photos account-change notification using the native
        // BackupSettingsManager / BackupSettingsEditor implementation.
        val selectionState = mutableClassDefBy(
            SelectedAccountStateFingerprint.method.definingClass
        )
        require(selectionState.fields.any { it.name == "a" && it.type == "I" } &&
            selectionState.fields.any { it.name == "d" && it.type == "I" } &&
            selectionState.fields.any { it.name == "e" && it.type == "Lcchf;" }) {
            "Photos selected account state changed"
        }
        val notifyChange = selectionState.methods.singleOrNull { method ->
            method.name == "d" && method.parameterTypes.isEmpty() &&
                method.returnType == "V" &&
                method.implementation?.instructions?.any { instruction ->
                    ((instruction as? ReferenceInstruction)?.reference as? MethodReference)?.let {
                        it.definingClass == "Lcael;" && it.name == "b"
                    } == true
                } == true
        } ?: error("Photos selected account notification changed")
        // The Java bridge must resolve the native DEX classes by exact
        // descriptors. JADX uses a synthetic "defpackage" label for these
        // default-package classes, which is not part of their runtime names.
        fun hasMethod(owner: String, name: String, parameters: List<String>, returnType: String): Boolean {
            return classDefBy(owner).methods.any { method ->
                method.name == name && method.returnType == returnType &&
                    method.parameterTypes.map(CharSequence::toString) == parameters
            }
        }
        require(classDefBy("Lalfv;").fields.any {
            it.name == "d" && it.type == "Landroid/content/Context;"
        } && classDefBy("Lalfv;").fields.any {
            it.name == "a" && it.type == "Ljava/util/List;"
        }) { "Photos account handler contract changed" }
        require(classDefBy("Luks;").fields.any {
            it.name == "l" && it.type == "Ljava/lang/String;"
        }) { "Photos native backup selection pending state changed" }
        require(classDefBy("Lcchf;").fields.any { it.name == "a" }) {
            "Photos account notification owner moved"
        }
        require(hasMethod("Lcaet;", "n", listOf("I"), "Z") &&
            hasMethod("Luat;", "h", emptyList(), "Z") &&
            hasMethod("Lcbyf;", "e",
                listOf("Landroid/content/Context;", "Ljava/lang/Class;"),
                "Ljava/lang/Object;") &&
            hasMethod("Lunr;", "d", listOf("Ljava/util/Set;"), "V") &&
            hasMethod("Lunq;", "j", listOf("Lunr;", "Luol;"), "Lunv;") &&
            hasMethod("Ltoi;", "i", emptyList(), "Ltoh;") &&
            hasMethod("Lshx;", "c", listOf("Landroid/content/Context;"), "Lchxn;")) {
            "Photos native account backup editor contract changed"
        }
        for (type in listOf("Ltou;", "Ltow;", "Lupd;", "Luoi;", "Luol;",
                "Lunr;", "Lunu;", "Ltpg;", "Luog;", "Lchvt;", "Lchxn;")) {
            require(classDefBy(type).type == type) {
                "Photos native backup editor type missing: $type"
            }
        }
        val accountBridge = "Lde/kwoo/shion/extension/photos/BackupAccountFollower;"
        notifyChange.addInstructions(
            0,
            "invoke-static {p0}, $accountBridge->onSelectedAccountChanged(Ljava/lang/Object;)V"
        )
    }
}
