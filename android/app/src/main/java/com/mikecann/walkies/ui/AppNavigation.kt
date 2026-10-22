package com.mikecann.walkies.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** The pages along the bottom, the map first (AppNavigation.Tab in AppNavigation.swift). */
enum class AppTab(val title: String, val art: String) {
    Map("Map", "icon-map"),
    Secrets("Secrets", "icon-book"),
    Progress("Progress", "progress-shell"),
    Walks("Walks", "icon-walk"),
    Settings("Settings", "icon-gear"),
}

/** The progress page's parts, picked from the row along its top (AppNavigation.ProgressSection). */
enum class ProgressSection(val title: String) {
    Level("Level"), Quests("Quests"), Shop("Shop"), Wardrobe("Wardrobe"), Spyglass("Spyglass"),
}

/**
 * Where you are in the app (AppNavigation.swift): which tab's showing, which part of
 * the progress page, and the walk open in Walks. The map's the first tab and where the app opens.
 */
class AppNavigation {
    var tab by mutableStateOf(AppTab.Map)
    var progressSection by mutableStateOf(ProgressSection.Level)

    /** The shells chip, or the celebration's "Level up": the progress tab, at that part. */
    fun showProgress(section: ProgressSection = ProgressSection.Level) {
        progressSection = section
        tab = AppTab.Progress
    }

    /** Back to the map, for a walk replay to play over it. */
    fun showMap() {
        tab = AppTab.Map
    }
}
