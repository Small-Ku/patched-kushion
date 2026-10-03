package de.kwoo.shion.patches.photos

import de.kwoo.shion.patches.identity.*
import org.w3c.dom.Document

const val UPSTREAM_PACKAGE = "com.google.android.apps.photos"
const val TARGET_PACKAGE = "de.kwoo.shion.photos"
const val MARS_AUTHORITY = "$TARGET_PACKAGE.api.mars"
val PHOTOS_PACKAGES = setOf(UPSTREAM_PACKAGE, "app.revanced.android.photos", "app.morphe.android.apps.photos", TARGET_PACKAGE)
val MARS_ALIASES = setOf(
    "com.google.android.libraries.photos.api.mars",
    "app.revanced.android.apps.photos.api.mars",
    "app.morphe.android.apps.photos.api.mars",
    "$UPSTREAM_PACKAGE.api.mars",
    "app.revanced.android.photos.api.mars",
    MARS_AUTHORITY,
)

internal fun normalizePhotos(document: Document, targetPackage: String = TARGET_PACKAGE, upstreamPackage: String = UPSTREAM_PACKAGE): ManifestIdentity {
    require(targetPackage == TARGET_PACKAGE && upstreamPackage == UPSTREAM_PACKAGE)
    val identity = ManifestIdentity(targetPackage, upstreamPackage, PHOTOS_PACKAGES)
    identity.normalize(document)
    MARS_ALIASES.forEach { identity.record(it, MARS_AUTHORITY) }
    var providers = 0
    document.elements("provider").filter { it.parentNode.nodeName == "application" }.forEach { provider ->
        val authorities = provider.android("authorities").split(';')
        if (authorities.any { it in MARS_ALIASES }) {
            require(provider.android("name").endsWith(".MarsStoreProvider")) { "Mars authority belongs to an unexpected provider" }
            require(authorities.size == 1) { "Unexpected additional Mars provider authority" }
            provider.setAndroid("authorities", MARS_AUTHORITY)
            providers++
        }
    }
    var hosts = 0
    document.elements("data").filter { it.parentNode.nodeName == "intent-filter" }.forEach { data ->
        if (data.android("host") in MARS_ALIASES) {
            data.setAndroid("host", MARS_AUTHORITY)
            hosts++
        }
    }
    require(providers == 1 && hosts > 0) { "Photos Mars contract missing: providers=$providers hosts=$hosts" }
    return identity
}
