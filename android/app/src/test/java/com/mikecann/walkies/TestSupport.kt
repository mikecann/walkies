package com.mikecann.walkies

import com.mikecann.walkies.store.Store
import java.io.File
import java.nio.file.Files

class FakeSettings(
    override var alwaysOn: Boolean = false,
    override var autoWalkGap: Double = 0.0,
    override var selectedCity: String? = null,
    override var setupDone: Boolean = true,
    override var mistDays: Double = 0.0,
) : Settings

class FakeLocation(override var authorization: LocationAccess.Authorization = LocationAccess.Authorization.Allowed) : LocationAccess {
    var requests = 0
    override fun requestPermission() {
        requests++
    }
}

/** A fresh folder for a store, deleted when the JVM exits. */
fun tempStore(): Pair<Store, File> {
    val root = File(Files.createTempDirectory("walkies").toFile(), "Walkies")
    root.parentFile.deleteOnExit()
    return Store(root) to root
}

/** The repo's top folder, from the fixtures path Gradle passes in. */
fun repoRoot(): File {
    val fixtures = System.getProperty("walkies.fixtures") ?: "../../shared/fixtures"
    return File(fixtures).absoluteFile.parentFile.parentFile
}
