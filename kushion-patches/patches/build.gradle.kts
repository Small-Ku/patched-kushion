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
