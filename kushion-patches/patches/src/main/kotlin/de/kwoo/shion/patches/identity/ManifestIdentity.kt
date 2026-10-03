package de.kwoo.shion.patches.identity

import org.w3c.dom.Document
import org.w3c.dom.Element

internal const val ANDROID_NS = "http://schemas.android.com/apk/res/android"

internal fun Document.elements(tag: String): List<Element> =
    getElementsByTagName(tag).let { nodes -> (0 until nodes.length).map { nodes.item(it) as Element } }

// Patcher Document currently uses a namespace-unaware DOM; fixtures also exercise aware DOMs.
internal fun Element.android(name: String): String = getAttributeNS(ANDROID_NS, name).ifEmpty { getAttribute("android:$name") }
internal fun Element.setAndroid(name: String, value: String) {
    if (getAttributeNode("android:$name")?.namespaceURI == null) setAttribute("android:$name", value)
    else setAttributeNS(ANDROID_NS, "android:$name", value)
}

/** Only manifest declarations establish ownership; external dependencies never do. */
internal class ManifestIdentity(
    val targetPackage: String,
    val upstreamPackage: String,
    val incomingPackages: Set<String>,
) {
    val replacements = linkedMapOf<String, String>()

    fun ownedName(value: String): String = incomingPackages.firstOrNull { value.startsWith("$it.") }
        ?.let { targetPackage + value.removePrefix(it) } ?: value

    fun record(old: String, new: String): String {
        if (old != new) replacements[old] = new
        return new
    }

    fun normalize(document: Document) {
        val manifest = document.documentElement
        val incoming = manifest.getAttribute("package")
        require(incoming in incomingPackages) { "Unexpected Photos input package: $incoming" }

        // Relative component names belong to the input's code namespace, not the new install package.
        for (tag in listOf("application", "activity", "activity-alias", "service", "receiver", "provider", "instrumentation")) {
            for (element in document.elements(tag)) {
                for (attribute in listOf("name", "targetActivity", "backupAgent", "appComponentFactory", "manageSpaceActivity", "parentActivityName")) {
                    val value = element.android(attribute)
                    if (value.isNotEmpty() && (value.startsWith(".") || !value.contains('.'))) {
                        element.setAndroid(attribute, if (value.startsWith(".")) incoming + value else "$incoming.$value")
                    }
                }
            }
        }

        val permissions = document.elements("permission").associate { permission ->
            val old = permission.android("name")
            val new = record(old, ownedName(old))
            permission.setAndroid("name", new)
            old to new
        }
        for (element in document.elements("*")) {
            for (attribute in listOf("permission", "readPermission", "writePermission")) {
                permissions[element.android(attribute)]?.let { element.setAndroid(attribute, it) }
            }
            if (element.tagName in setOf("uses-permission", "uses-permission-sdk-23")) {
                permissions[element.android("name")]?.let { element.setAndroid("name", it) }
            }
        }
        for (provider in document.elements("provider").filter { it.parentNode.nodeName == "application" }) {
            val authorities = provider.android("authorities").split(';').joinToString(";") { record(it, ownedName(it)) }
            provider.setAndroid("authorities", authorities)
        }
        manifest.setAttribute("package", targetPackage)
        // Only an already changed package is runtime coupled here. Upstream functional patches
        // own original Google package literals (including GmsCore's spoof metadata).
        if (incoming != upstreamPackage) record(incoming, targetPackage)
    }

    fun runtimeReplacement(value: String): String? {
        replacements[value]?.let { return it }
        if (!value.startsWith("content://")) return null
        val authority = value.removePrefix("content://").takeWhile { it !in "/?#" }
        return replacements[authority]?.let { "content://$it" + value.removePrefix("content://$authority") }
    }
}
