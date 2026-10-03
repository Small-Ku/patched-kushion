package de.kwoo.shion.patches.photos

import de.kwoo.shion.patches.identity.*
import java.io.ByteArrayInputStream
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.*

class PhotosIdentityTest {
    private fun fixture(mars: String, incoming: String = UPSTREAM_PACKAGE, aware: Boolean = true) = DocumentBuilderFactory.newInstance()
        .apply { isNamespaceAware = aware }.newDocumentBuilder().parse(ByteArrayInputStream("""
        <manifest xmlns:android="http://schemas.android.com/apk/res/android" package="$incoming">
          <permission android:name="$UPSTREAM_PACKAGE.permission.LOCAL"/>
          <uses-permission android:name="$UPSTREAM_PACKAGE.permission.LOCAL"/>
          <uses-permission android:name="app.revanced.android.gms.permission.EXTERNAL"/>
          <queries><package android:name="app.revanced.android.gms"/><provider android:authorities="$UPSTREAM_PACKAGE.external.query"/></queries>
          <application android:name=".PhotosApplication" android:permission="$UPSTREAM_PACKAGE.permission.LOCAL">
            <meta-data android:name="app.revanced.android.gms.SPOOFED_PACKAGE_NAME" android:value="$UPSTREAM_PACKAGE"/>
            <provider android:name="com.google.android.libraries.photos.api.mars.MarsStoreProvider" android:authorities="$mars"/>
            <provider android:name=".LocalProvider" android:authorities="$UPSTREAM_PACKAGE.fileprovider;external.authority"/>
            <activity android:name="HomeActivity"><intent-filter><data android:scheme="content" android:host="$mars"/></intent-filter></activity>
          </application>
        </manifest>
        """.trimIndent().toByteArray()))

    @Test fun stockAndLegacyMarsAreNormalized() {
        for (aware in listOf(false, true)) for (mars in MARS_ALIASES) for (incoming in PHOTOS_PACKAGES) {
            val document = fixture(mars, incoming, aware)
            val identity = normalizePhotos(document)
            assertEquals(TARGET_PACKAGE, document.documentElement.getAttribute("package"))
            assertEquals("$UPSTREAM_PACKAGE.external.query", document.elements("provider")[0].android("authorities"))
            assertEquals(MARS_AUTHORITY, document.elements("provider")[1].android("authorities"))
            assertEquals(MARS_AUTHORITY, document.elements("data")[0].android("host"))
            assertEquals("$incoming.PhotosApplication", document.elements("application")[0].android("name"))
            assertEquals("$TARGET_PACKAGE.fileprovider;external.authority", document.elements("provider")[2].android("authorities"))
            assertEquals("$TARGET_PACKAGE.permission.LOCAL", document.elements("uses-permission")[0].android("name"))
            assertEquals("app.revanced.android.gms.permission.EXTERNAL", document.elements("uses-permission")[1].android("name"))
            assertEquals(UPSTREAM_PACKAGE, document.elements("meta-data")[0].android("value"))
            assertEquals(MARS_AUTHORITY.takeIf { mars != MARS_AUTHORITY }, identity.runtimeReplacement(mars))
            assertEquals(("content://$MARS_AUTHORITY/path?q=1#x").takeIf { mars != MARS_AUTHORITY }, identity.runtimeReplacement("content://$mars/path?q=1#x"))
            assertNull(identity.runtimeReplacement("content://$mars.external/path"))
            assertNull(identity.runtimeReplacement("app.revanced.android.gms"))
            assertNull(identity.runtimeReplacement(UPSTREAM_PACKAGE))
            normalizePhotos(document) // idempotent second application
        }
    }

    @Test fun failClosedOnUnknownInputOrMissingMars() {
        assertFailsWith<IllegalArgumentException> { normalizePhotos(fixture(MARS_AUTHORITY, "other.app")) }
        assertFailsWith<IllegalArgumentException> { normalizePhotos(fixture("unknown.api.mars")) }
        assertFailsWith<IllegalArgumentException> { normalizePhotos(fixture(MARS_AUTHORITY), "other.app") }
        val missingHost = fixture(MARS_AUTHORITY)
        missingHost.elements("data")[0].setAndroid("host", "external.host")
        assertFailsWith<IllegalArgumentException> { normalizePhotos(missingHost) }
    }
}
