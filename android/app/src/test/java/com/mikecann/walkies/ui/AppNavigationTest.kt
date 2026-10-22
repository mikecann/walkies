package com.mikecann.walkies.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class AppNavigationTest {
    @Test
    fun opensOnTheMapAtLevel() {
        val navigation = AppNavigation()
        assertEquals(AppTab.Map, navigation.tab)
        assertEquals(ProgressSection.Level, navigation.progressSection)
    }

    @Test
    fun showingProgressSwitchesTabAndSection() {
        val navigation = AppNavigation()
        navigation.showProgress(ProgressSection.Shop)
        assertEquals(AppTab.Progress, navigation.tab)
        assertEquals(ProgressSection.Shop, navigation.progressSection)
        // The celebration's "Level up" goes back to the rewards.
        navigation.showProgress()
        assertEquals(ProgressSection.Level, navigation.progressSection)
    }

    @Test
    fun pickingASectionStaysOnProgress() {
        val navigation = AppNavigation()
        navigation.showProgress()
        for (section in ProgressSection.entries) {
            navigation.progressSection = section
            assertEquals(section, navigation.progressSection)
            assertEquals(AppTab.Progress, navigation.tab)
        }
    }

    @Test
    fun watchingAgainGoesBackToTheMap() {
        val navigation = AppNavigation()
        navigation.tab = AppTab.Walks
        navigation.showMap()
        assertEquals(AppTab.Map, navigation.tab)
    }

    @Test
    fun tabsAndSectionsInOrder() {
        assertEquals(listOf("Map", "Secrets", "Progress", "Walks", "Settings"), AppTab.entries.map { it.title })
        assertEquals(listOf("Level", "Quests", "Shop", "Wardrobe", "Spyglass"), ProgressSection.entries.map { it.title })
    }
}
