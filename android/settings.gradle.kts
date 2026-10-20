pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // The Maps SDK downloads without a secret token since v11.
        maven("https://api.mapbox.com/downloads/v2/releases/maven")
    }
}

rootProject.name = "Walkies"
include(":app")
