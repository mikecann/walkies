#!/bin/bash
# Real Kotlin models, storage, tracking policy and sync, without an Android SDK.
# Run the full suite on Tinker Desk through heavy; --tests selects a narrow test.
set -euo pipefail
cd "$(dirname "$0")/.."
# Tinker Desk has no system JDK; its JDK 21 and Gradle cache live on the external SSD.
tinker_jdk=/Volumes/TinkerSSD/fdroid-jdk21
if [ -z "${JAVA_HOME:-}" ] && ! /usr/libexec/java_home >/dev/null 2>&1 && [ -x "$tinker_jdk/jdk/Contents/Home/bin/java" ]; then
    export JAVA_HOME="$tinker_jdk/jdk/Contents/Home"
    export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$tinker_jdk/gradle}"
fi
python3 - <<'PY'
from pathlib import Path
root = Path('build/android-model-tests')
support = root / 'support/com/mikecann/walkies/ui'
support.mkdir(parents=True, exist_ok=True)
# The formatting object lives beside Compose controls. Compile that exact object,
# rather than a stub that could silently diverge from the app.
controls = Path('android/app/src/main/java/com/mikecann/walkies/ui/WalkControls.kt').read_text()
formatting = controls[controls.index('object Format {'):controls.index('/**\n * What sits at the bottom')]
(support / 'Format.kt').write_text('package com.mikecann.walkies.ui\nimport java.util.Locale\n' + formatting)
(root / 'settings.gradle.kts').write_text('rootProject.name = "walkies-model-tests"\n')
(root / 'gradle.properties').write_text('org.gradle.workers.max=2\norg.gradle.jvmargs=-Xmx2g\nkotlin.compiler.execution.strategy=in-process\n')
(root / 'build.gradle.kts').write_text('''plugins { kotlin("jvm") version "2.2.0" }
repositories { mavenCentral() }
dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
    testImplementation("junit:junit:4.13.2")
}
kotlin { jvmToolchain(21) }
sourceSets {
    main {
        kotlin.srcDir("../../android/app/src/main/java")
        kotlin.srcDir("support")
        kotlin.include("com/mikecann/walkies/AppModel.kt", "com/mikecann/walkies/ui/Format.kt", "com/mikecann/walkies/grid/**", "com/mikecann/walkies/map/CloudField.kt", "com/mikecann/walkies/map/MapPoint.kt", "com/mikecann/walkies/model/**", "com/mikecann/walkies/place/**", "com/mikecann/walkies/store/**", "com/mikecann/walkies/convex/**", "com/mikecann/walkies/sync/**", "com/mikecann/walkies/lore/**", "com/mikecann/walkies/location/AlwaysOnTracking.kt", "com/mikecann/walkies/location/StationaryFence.kt", "com/mikecann/walkies/location/ActivityMotion.kt")
        kotlin.exclude("**/SecretNotifier.kt")
    }
    test {
        kotlin.srcDir("../../android/app/src/test/java")
        kotlin.include("com/mikecann/walkies/TestSupport.kt", "com/mikecann/walkies/AppModelTest.kt", "com/mikecann/walkies/StepTest.kt", "com/mikecann/walkies/ProgressionModelTest.kt", "com/mikecann/walkies/*RelaunchTest.kt", "com/mikecann/walkies/*LifecycleTest.kt", "com/mikecann/walkies/location/**", "com/mikecann/walkies/sync/**", "com/mikecann/walkies/store/**", "com/mikecann/walkies/model/CoverageTest.kt")
    }
}
tasks.test {
    maxParallelForks = 1
    systemProperty("walkies.fixtures", file("../../shared/fixtures").absolutePath)
    systemProperty("walkies.lore", file("../../Walkies/Lore").absolutePath)
    testLogging { events("passed", "skipped", "failed"); showStandardStreams = false }
    afterSuite(KotlinClosure2<TestDescriptor, TestResult, Unit>({ suite, result ->
        if (suite.parent == null) {
            println("Discovered: ${result.testCount}; passed: ${result.successfulTestCount}; failed: ${result.failedTestCount}; skipped: ${result.skippedTestCount}")
            check(result.testCount > 0) { "No model tests matched" }
        }
    }))
}
''')
PY
exec bash android/gradlew --no-daemon -p build/android-model-tests test "$@"
