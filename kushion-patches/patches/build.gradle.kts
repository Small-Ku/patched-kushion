import java.util.Base64
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

group = "de.kwoo.shion"

patches {
    about {
        name = "Kushion Patches"
        description = "KouPhotos distribution identity patches for patched-kushion; compatible with Morphe"
        source = "https://github.com/Small-Ku/patched-kushion"
        author = "Small-Ku"
        contact = "https://github.com/Small-Ku/patched-kushion/issues"
        website = "https://github.com/Small-Ku/patched-kushion"
        license = "GPLv3"
    }
}

dependencies {
    testImplementation(kotlin("test-junit5"))
    testRuntimeOnly("org.junit.platform:junit-platform-launcher:1.14.1")
    testRuntimeOnly("org.junit.jupiter:junit-jupiter-engine:5.14.1")
}

tasks.test { useJUnitPlatform() }

val knitArtworkDirectory = layout.projectDirectory.dir("src/main/resources/knit")
val knitArtworkGeneratedDirectory = layout.buildDirectory.dir("generated/sources/knit-artwork")
val embedKnitArtwork = tasks.register("embedKnitArtwork") {
    inputs.dir(knitArtworkDirectory)
    outputs.dir(knitArtworkGeneratedDirectory)
    doLast {
        val output = knitArtworkGeneratedDirectory.get().file(
            "de/kwoo/shion/patches/knit/generated/KnitLauncherArtwork.kt",
        ).asFile
        output.parentFile.mkdirs()
        val files = knitArtworkDirectory.asFile.walkTopDown()
            .filter { it.isFile }
            .sortedBy { it.relativeTo(knitArtworkDirectory.asFile).invariantSeparatorsPath }
        val archive = ByteArrayOutputStream().also { bytes ->
            ZipOutputStream(bytes).use { zip ->
                for (file in files) {
                    val entry = ZipEntry(file.relativeTo(knitArtworkDirectory.asFile).invariantSeparatorsPath)
                    entry.time = 0L
                    zip.putNextEntry(entry)
                    zip.write(file.readBytes())
                    zip.closeEntry()
                }
            }
        }.toByteArray()
        output.writeText(buildString {
            appendLine("package de.kwoo.shion.patches.knit.generated")
            appendLine()
            appendLine("internal object KnitLauncherArtwork {")
            appendLine("    private const val archive = \"${Base64.getEncoder().encodeToString(archive)}\"")
            appendLine("    val files: Map<String, ByteArray> by lazy {")
            appendLine("        java.util.zip.ZipInputStream(java.io.ByteArrayInputStream(java.util.Base64.getDecoder().decode(archive))).use { zip ->")
            appendLine("            buildMap { while (true) { val entry = zip.nextEntry ?: break; put(entry.name, zip.readBytes()) } }")
            appendLine("        }")
            appendLine("    }")
            appendLine("}")
        })
    }
}

kotlin.sourceSets.named("main") {
    kotlin.srcDir(knitArtworkGeneratedDirectory)
}
tasks.named("compileKotlin") { dependsOn(embedKnitArtwork) }

// The plugin otherwise inserts wall-clock time into the bundle manifest, which
// invalidates every patch cache even when the source and toolchain are unchanged.
tasks.withType<org.gradle.jvm.tasks.Jar>().configureEach {
    manifest.attributes["Timestamp"] = "0"
    isPreserveFileTimestamps = false
    isReproducibleFileOrder = true
}

// Preserve the template's required notices in the distributed patch bundle.
tasks.processResources {
    from(rootProject.file("NOTICE")) { into("META-INF/patched-kushion") }
    from(rootProject.file("../LICENSE")) { into("META-INF/patched-kushion") }
}
