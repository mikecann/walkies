import java.net.URI
import java.util.Properties
import java.util.UUID
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
}

val localProperties = Properties().apply {
    rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}
val mapboxToken = localProperties.getProperty("MAPBOX_ACCESS_TOKEN").orEmpty().trim()

/**
 * The release signing key, from android/keystore.properties (never committed):
 *     storeFile=/path/to/walkies.jks
 *     storePassword=…
 *     keyAlias=walkies
 *     keyPassword=…
 * Without it, release builds come out unsigned, so CI and tests still build.
 */
val keystoreProperties = Properties().apply {
    rootProject.file("keystore.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}
val hasReleaseKey = listOf("storeFile", "storePassword", "keyAlias", "keyPassword").all { !keystoreProperties.getProperty(it).isNullOrBlank() }

/**
 * Ties a release build to its R8 mapping in Sentry, so crash reports show real class and method
 * names. Each Gradle run gets a new id: the release manifest carries it (src/release, read when
 * CrashReporting starts Sentry) and uploadProguardMapping sends the mapping under it.
 */
val sentryProguardUuid = UUID.randomUUID().toString()

/** The iPhone app and the shared fixtures, so iOS stays the single source of truth. */
val repoRoot = rootProject.projectDir.parentFile

android {
    namespace = "com.mikecann.walkies"
    compileSdk = 36

    defaultConfig {
        // Every current Android phone (Dad's Pixel included) and the Apple-silicon emulator are 64-bit ARM.
        // Older 32-bit devices, like the Galaxy Tab A test tablet: -Pabis=armeabi-v7a,arm64-v8a
        ndk { abiFilters += (findProperty("abis") as String?)?.split(",") ?: listOf("arm64-v8a") }
        applicationId = "com.mikecann.walkies"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
        buildConfigField("String", "MAPBOX_ACCESS_TOKEN", "\"${mapboxToken.replace("\"", "")}\"")
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    // The Convex deployments, both in Sydney (Backend in Convex.swift). Debug builds talk
    // to dev, which also allows test sign-in; release builds to the real walks on prod,
    // with no test sign-in (src/release has a stand-in that does nothing).
    buildTypes {
        debug {
            // -PfastDebug: still dev and test sign-in, but not debuggable, so ART compiles it
            // and it runs at real speed. For judging performance on old test devices.
            if (findProperty("fastDebug") != null) isDebuggable = false
            buildConfigField("String", "CONVEX_CLOUD_URL", "\"https://resolute-pig-177.ap-southeast-2.convex.cloud\"")
            buildConfigField("String", "CONVEX_SITE_URL", "\"https://resolute-pig-177.ap-southeast-2.convex.site\"")
        }
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (hasReleaseKey) signingConfig = signingConfigs.getByName("release")
            manifestPlaceholders["sentryProguardUuid"] = sentryProguardUuid
            buildConfigField("String", "CONVEX_CLOUD_URL", "\"https://savory-bee-296.ap-southeast-2.convex.cloud\"")
            buildConfigField("String", "CONVEX_SITE_URL", "\"https://savory-bee-296.ap-southeast-2.convex.site\"")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    testOptions {
        unitTests.all {
            it.systemProperty("walkies.fixtures", File(repoRoot, "shared/fixtures").absolutePath)
            // The lore JSON, read straight from the iPhone app's sources (LoreLibrary.reader).
            it.systemProperty("walkies.lore", File(repoRoot, "Walkies/Lore").absolutePath)
            // ./gradlew testDebugUnitTest -PwriteFixtures writes shared/fixtures/android for the iPhone's tests.
            it.systemProperty("walkies.writeFixtures", providers.gradleProperty("writeFixtures").map { "true" }.getOrElse(""))
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)
    implementation(libs.mapbox.maps)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.play.services.location)
    implementation(libs.play.services.fitness)
    implementation(libs.kotlinx.coroutines.android)
    // Google sign-in runs in a Custom Tab.
    implementation(libs.androidx.browser)
    // Crash and error reports, started by CrashReporting on release builds only.
    implementation(libs.sentry.android)
    testImplementation(libs.junit)
}

/**
 * Copies the lore and the iPhone app's imagesets into the app's assets at build time.
 * Each `name.imageset/whatever.png` lands as `images/name.png`; lore JSON into `lore/`.
 * (No slash-star in here: Kotlin nests block comments.)
 */
abstract class CopyIosAssets : DefaultTask() {
    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val lore: DirectoryProperty

    @get:InputDirectory
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val xcassets: DirectoryProperty

    /** Which folders of the asset catalogue to bring across. */
    @get:Input
    abstract val groups: ListProperty<String>

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun copy() {
        val out = outputDir.get().asFile
        out.deleteRecursively()
        val lore = File(out, "lore").apply { mkdirs() }
        this.lore.get().asFile.listFiles { f -> f.extension == "json" }?.forEach { it.copyTo(File(lore, it.name)) }
        val images = File(out, "images").apply { mkdirs() }
        for (group in groups.get()) {
            val folder = File(xcassets.get().asFile, group)
            folder.listFiles { f -> f.isDirectory && f.name.endsWith(".imageset") }?.forEach { set ->
                val image = set.listFiles { f -> f.extension.lowercase() in setOf("png", "jpg", "jpeg") }
                    ?.minByOrNull { it.name } ?: return@forEach
                image.copyTo(File(images, set.name.removeSuffix(".imageset") + "." + image.extension.lowercase()))
            }
        }
    }
}

val iosAssetsDir = layout.buildDirectory.dir("generated/iosAssets")

val copyIosAssets = tasks.register<CopyIosAssets>("copyIosAssets") {
    outputDir.set(iosAssetsDir)
    lore.set(File(repoRoot, "Walkies/Lore"))
    xcassets.set(File(repoRoot, "Walkies/Assets.xcassets"))
    // Photos are the secrets' Wikimedia Commons pictures, shown under each story.
    // Progression is the shop's art: shells, markers, book covers, the spyglass.
    groups.set(listOf("Icons", "Stickers", "Photos", "Progression"))
}

// Plain source dir plus preBuild, so the copy always runs before resources and assets merge.
android.sourceSets.getByName("main").assets.srcDir(iosAssetsDir)
tasks.named("preBuild") { dependsOn(copyIosAssets) }

/**
 * Nunito, the rounded heading font, is bundled in src/main/assets/fonts (OFL).
 * Fetches it once if it's missing; the app falls back to the system font without it.
 */
val fetchFonts = tasks.register("fetchFonts") {
    val target = file("src/main/assets/fonts/Nunito.ttf")
    outputs.file(target)
    onlyIf { !target.exists() }
    doLast {
        try {
            target.parentFile.mkdirs()
            URI("https://github.com/google/fonts/raw/main/ofl/nunito/Nunito%5Bwght%5D.ttf").toURL().openStream().use { input ->
                target.outputStream().use { input.copyTo(it) }
            }
        } catch (e: Exception) {
            target.delete()
            logger.warn("Couldn't download Nunito (${e.message}). Headings will use the system font.")
        }
    }
}
tasks.named("preBuild") { dependsOn(fetchFonts) }

/**
 * Uploads R8's mapping to Sentry (project `walkies`) after a signed `assembleRelease`, the build
 * that goes on phones; unsigned ones (CI, tests) don't. Never fails the build: no sentry-cli
 * (PATH or ~/.local/bin) or token (SENTRY_AUTH_TOKEN, else ~/.config/sentry/token) says so in one
 * line, and a failed upload only warns.
 */
fun uploadProguardMapping(mapping: File) {
    val home = System.getProperty("user.home")
    val cli = (System.getenv("PATH").orEmpty().split(File.pathSeparator) + "$home/.local/bin")
        .map { File(it, "sentry-cli") }.firstOrNull { it.canExecute() }
    val token = System.getenv("SENTRY_AUTH_TOKEN")?.takeIf { it.isNotBlank() }
        ?: File("$home/.config/sentry/token").takeIf { it.canRead() }?.readText()?.trim()?.takeIf { it.isNotEmpty() }
    if (cli == null || token == null) {
        logger.lifecycle("R8 mapping not uploaded to Sentry (no sentry-cli or no token).")
        return
    }
    // Its output comes back through Gradle's log: the daemon's own stdout isn't the console.
    val (code, output) = runCatching {
        val process = ProcessBuilder(cli.path, "upload-proguard", "--org", "mikec", "--project", "walkies",
            "--uuid", sentryProguardUuid, mapping.path)
            .apply { environment()["SENTRY_AUTH_TOKEN"] = token }
            .redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().readText()
        process.waitFor() to output
    }.getOrElse { 1 to it.toString() }
    logger.lifecycle(output.trim())
    if (code != 0) logger.warn("WARNING: the R8 mapping wasn't uploaded to Sentry; crash reports from this build will show shrunk names.")
}

val releaseMapping = layout.buildDirectory.file("outputs/mapping/release/mapping.txt")
tasks.matching { it.name == "assembleRelease" }.configureEach {
    if (hasReleaseKey) doLast { uploadProguardMapping(releaseMapping.get().asFile) }
}
