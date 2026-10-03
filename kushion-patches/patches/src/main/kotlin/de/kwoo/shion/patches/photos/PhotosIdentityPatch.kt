package de.kwoo.shion.patches.photos

import app.morphe.patcher.extensions.InstructionExtensions.replaceInstruction
import app.morphe.patcher.patch.bytecodePatch
import app.morphe.patcher.patch.resourcePatch
import app.morphe.patcher.patch.stringOption
import com.android.tools.smali.dexlib2.Opcode
import com.android.tools.smali.dexlib2.builder.instruction.BuilderInstruction31c
import com.android.tools.smali.dexlib2.iface.instruction.OneRegisterInstruction
import com.android.tools.smali.dexlib2.iface.instruction.ReferenceInstruction
import com.android.tools.smali.dexlib2.iface.reference.StringReference
import com.android.tools.smali.dexlib2.immutable.reference.ImmutableStringReference
import de.kwoo.shion.patches.identity.ManifestIdentity

private lateinit var manifestIdentity: ManifestIdentity
private var targetPackageValue = TARGET_PACKAGE
private var upstreamPackageValue = UPSTREAM_PACKAGE

private val photosManifestIdentity = resourcePatch {
    execute {
        document("AndroidManifest.xml").use { document ->
            manifestIdentity = normalizePhotos(document, targetPackageValue, upstreamPackageValue)
        }
    }
}

val photosIdentityPatch = bytecodePatch(
    name = "KouPhotos distribution identity",
    description = "Owns KouPhotos package, declared manifest identities and linked Mars runtime identities.",
    default = false,
) {
    // Include known functional-patch outputs: this is a separate invocation over an already patched APK.
    compatibleWith(*PHOTOS_PACKAGES.toTypedArray())
    dependsOn(photosManifestIdentity)

    val targetPackage by stringOption(
        key = "targetPackage", default = TARGET_PACKAGE, title = "Distribution package",
        description = "Stable KouPhotos install package", required = true,
    ) { it == TARGET_PACKAGE }
    val upstreamPackage by stringOption(
        key = "upstreamPackage", default = UPSTREAM_PACKAGE, title = "Upstream package",
        description = "Original Photos package before functional patching", required = true,
    ) { it == UPSTREAM_PACKAGE }

    // Dependency execution comes before this patch. Options are fixed to this single Kushion app,
    // so the manifest dependency can use the same explicit contract even with no options supplied.
    execute {
        check(targetPackage == targetPackageValue && upstreamPackage == upstreamPackageValue)
        getAllClassesWithStrings().forEach { classDef ->
            val matches = classDef.methods.any { method ->
                method.implementation?.instructions?.any { instruction ->
                    instruction.opcode in setOf(Opcode.CONST_STRING, Opcode.CONST_STRING_JUMBO) &&
                        ((instruction as? ReferenceInstruction)?.reference as? StringReference)?.string
                            ?.let { manifestIdentity.runtimeReplacement(it) != null } == true
                } == true
            }
            if (!matches) return@forEach
            val mutableClass = mutableClassDefBy(classDef)
            for (method in mutableClass.methods) {
                val replacements = method.implementation?.instructions?.mapIndexedNotNull { index, instruction ->
                    if (instruction.opcode !in setOf(Opcode.CONST_STRING, Opcode.CONST_STRING_JUMBO)) return@mapIndexedNotNull null
                    val value = ((instruction as ReferenceInstruction).reference as StringReference).string
                    val replacement = manifestIdentity.runtimeReplacement(value) ?: return@mapIndexedNotNull null
                    index to BuilderInstruction31c(
                        Opcode.CONST_STRING_JUMBO, (instruction as OneRegisterInstruction).registerA,
                        ImmutableStringReference(replacement),
                    )
                }.orEmpty()
                replacements.forEach { (index, instruction) -> method.replaceInstruction(index, instruction) }
            }
        }
    }
}
