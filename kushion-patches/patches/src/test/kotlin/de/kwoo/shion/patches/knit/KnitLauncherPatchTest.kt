package de.kwoo.shion.patches.knit

import de.kwoo.shion.patches.identity.android
import java.io.ByteArrayInputStream
import javax.xml.parsers.DocumentBuilderFactory
import kotlin.test.*

class KnitLauncherPatchTest {
    private fun manifest() = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }
        .newDocumentBuilder().parse(ByteArrayInputStream("""
            <manifest xmlns:android="http://schemas.android.com/apk/res/android" package="de.kwoo.shion.music">
              <application android:label="Old name" android:icon="@mipmap/old" android:roundIcon="@mipmap/old">
                <activity android:name=".Home" android:label="Old name" android:icon="@mipmap/old">
                  <intent-filter>
                    <action android:name="android.intent.action.MAIN" />
                    <category android:name="android.intent.category.LAUNCHER" />
                  </intent-filter>
                </activity>
                <activity android:name=".Settings" android:label="Settings">
                  <intent-filter><action android:name="android.intent.action.MAIN" /></intent-filter>
                </activity>
                <activity android:name=".SeparatedFilters" android:label="Separated">
                  <intent-filter><action android:name="android.intent.action.MAIN" /></intent-filter>
                  <intent-filter><category android:name="android.intent.category.LAUNCHER" /></intent-filter>
                </activity>
              </application>
            </manifest>
        """.trimIndent().toByteArray()))

    @Test fun knownPackagesSelectTheExpectedKnitBrand() {
        assertEquals(KnitBrand("KnitTube", "tube"), knitBrandFor("com.google.android.youtube"))
        assertEquals(KnitBrand("KnitMusic", "music"), knitBrandFor("de.kwoo.shion.music"))
        assertEquals(KnitBrand("KnitPhotos", "photos"), knitBrandFor("de.kwoo.shion.photos"))
        assertEquals(KnitBrand("Knitstagram", "instagram"), knitBrandFor("com.instagram.android"))
        assertEquals(KnitBrand("KnitMessenger", "messenger"), knitBrandFor("de.kwoo.shion.messenger"))
        assertNull(knitBrandFor("org.example.external"))
    }

    @Test fun manifestUsesKnitNameAndIconForTheLauncher() {
        val document = manifest()
        assertEquals(1, applyKnitManifestBranding(document, KnitBrand("KnitMusic", "music")))
        val application = document.getElementsByTagName("application").item(0) as org.w3c.dom.Element
        val home = document.getElementsByTagName("activity").item(0) as org.w3c.dom.Element
        val settings = document.getElementsByTagName("activity").item(1) as org.w3c.dom.Element
        val separated = document.getElementsByTagName("activity").item(2) as org.w3c.dom.Element
        assertEquals("KnitMusic", application.android("label"))
        assertEquals("@mipmap/knit_launcher", application.android("icon"))
        assertEquals("@mipmap/knit_launcher", application.android("roundIcon"))
        assertEquals("KnitMusic", home.android("label"))
        assertEquals("@mipmap/knit_launcher", home.android("icon"))
        assertEquals("Settings", settings.android("label"))
        assertEquals("Separated", separated.android("label"))
        assertEquals("", separated.android("icon"))
    }

    @Test fun eachBrandIncludesLegacyAdaptiveAndMonochromeResources() {
        val required = listOf(
            "drawable/knit_launcher_background.xml",
            "drawable/knit_launcher_foreground.xml",
            "drawable/knit_launcher_legacy_background.xml",
            "drawable/knit_launcher_monochrome.xml",
            "mipmap/knit_launcher.xml",
            "mipmap-anydpi-v26/knit_launcher.xml",
            "mipmap-anydpi-v33/knit_launcher.xml",
        )
        for (art in listOf("tube", "music", "photos", "instagram", "messenger")) {
            for (path in required) {
                assertNotNull(javaClass.getResourceAsStream("/knit/$art/res/$path"), "$art/$path")
            }
        }
    }
}
