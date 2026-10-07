package de.kwoo.shion.patches.knit

import app.morphe.patcher.patch.bytecodePatch
import app.morphe.patcher.patch.resourcePatch
import de.kwoo.shion.patches.identity.android
import de.kwoo.shion.patches.identity.setAndroid
import de.kwoo.shion.patches.knit.generated.KnitLauncherArtwork
import org.w3c.dom.Document
import org.w3c.dom.Element

internal data class KnitBrand(val launcherName: String, val artwork: String)

private val knitBrands = mapOf(
    "com.google.android.youtube" to KnitBrand("KnitTube", "tube"),
    "de.kwoo.shion.youtube" to KnitBrand("KnitTube", "tube"),
    "com.google.android.apps.youtube.music" to KnitBrand("KnitMusic", "music"),
    "de.kwoo.shion.music" to KnitBrand("KnitMusic", "music"),
    "com.google.android.apps.photos" to KnitBrand("KnitPhotos", "photos"),
    "app.revanced.android.photos" to KnitBrand("KnitPhotos", "photos"),
    "app.morphe.android.apps.photos" to KnitBrand("KnitPhotos", "photos"),
    "de.kwoo.shion.photos" to KnitBrand("KnitPhotos", "photos"),
    "com.instagram.android" to KnitBrand("Knitstagram", "instagram"),
    "de.kwoo.shion.instagram" to KnitBrand("Knitstagram", "instagram"),
    "com.facebook.orca" to KnitBrand("KnitMessenger", "messenger"),
    "de.kwoo.shion.messenger" to KnitBrand("KnitMessenger", "messenger"),
)

internal fun knitBrandFor(packageName: String): KnitBrand? = knitBrands[packageName]

private const val KNIT_ICON = "@mipmap/knit_launcher"

internal fun applyKnitManifestBranding(document: Document, brand: KnitBrand): Int {
    val application = document.getElementsByTagName("application").item(0) as? Element
        ?: error("Knit launcher branding could not find <application>")
    application.setAndroid("label", brand.launcherName)
    application.setAndroid("icon", KNIT_ICON)
    application.setAndroid("roundIcon", KNIT_ICON)

    var launchers = 0
    for (tag in listOf("activity", "activity-alias")) {
        val components = document.getElementsByTagName(tag)
        for (index in 0 until components.length) {
            val component = components.item(index) as Element
            val filters = component.getElementsByTagName("intent-filter")
            val hasLauncherFilter = (0 until filters.length).any { filterIndex ->
                val filter = filters.item(filterIndex) as Element
                val actions = filter.getElementsByTagName("action")
                val categories = filter.getElementsByTagName("category")
                val hasMainAction = (0 until actions.length).any { actionIndex ->
                    (actions.item(actionIndex) as Element).android("name") == "android.intent.action.MAIN"
                }
                val hasLauncherCategory = (0 until categories.length).any { categoryIndex ->
                    (categories.item(categoryIndex) as Element).android("name") == "android.intent.category.LAUNCHER"
                }
                hasMainAction && hasLauncherCategory
            }
            if (hasLauncherFilter) {
                component.setAndroid("label", brand.launcherName)
                component.setAndroid("icon", KNIT_ICON)
                launchers++
            }
        }
    }
    check(launchers > 0) { "Knit launcher branding found no MAIN/LAUNCHER component" }
    return launchers
}

private val knitLauncherResources = resourcePatch {
    execute {
        val packageName = packageMetadata.packageName
        val brand = knitBrandFor(packageName)
            ?: error("Knit launcher branding does not support package $packageName")

        val files = listOf(
            "drawable/knit_launcher_background.xml",
            "drawable/knit_launcher_foreground.xml",
            "drawable/knit_launcher_legacy_background.xml",
            "drawable/knit_launcher_monochrome.xml",
            "mipmap/knit_launcher.xml",
            "mipmap-anydpi-v26/knit_launcher.xml",
            "mipmap-anydpi-v33/knit_launcher.xml",
        )
        for (path in files) {
            val source = KnitLauncherArtwork.files["${brand.artwork}/res/$path"]
                ?: error("Knit launcher artwork is missing: ${brand.artwork}/res/$path")
            val destination = get("res/$path")
            check(destination.parentFile.mkdirs() || destination.parentFile.isDirectory) {
                "Could not create Knit launcher resource directory: ${destination.parentFile}"
            }
            destination.outputStream().use { it.write(source) }
        }

        document("AndroidManifest.xml").use { manifest ->
            applyKnitManifestBranding(manifest, brand)
        }
    }
}

val knitLauncherBrandingPatch = bytecodePatch(
    name = "Knit launcher branding",
    description = "Adds Knit launcher names and textile icon resources.",
    default = false,
) {
    compatibleWith(*knitBrands.keys.toTypedArray())
    dependsOn(knitLauncherResources)
    execute { }
}
