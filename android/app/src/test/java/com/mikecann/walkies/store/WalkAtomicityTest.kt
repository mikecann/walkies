package com.mikecann.walkies.store

import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.TrackPoint
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.uuidString
import com.mikecann.walkies.tempStore
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class WalkAtomicityTest {
    @Test fun failedAtomicReplacementKeepsTheLastDurableWalkAndCanRetry() {
        val (store, root) = tempStore()
        try {
            val original = Walk(startedAt = SwiftDate.epoch(100.0), points = listOf(TrackPoint(1.0, 2.0, 100.0, 5.0)))
            store.save(original)
            val blocked = File(root, "walks/.${original.id.uuidString}.json.tmp")
            assertTrue(blocked.mkdir())
            val next = original.copy(endedAt = SwiftDate.epoch(200.0), steps = 20)
            store.save(next)
            assertEquals(original, Store(root).loadWalks().single())
            assertTrue(blocked.delete())
            store.save(next)
            assertEquals(next, Store(root).loadWalks().single())
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun interruptedTemporaryWriteCannotReplaceTheSavedWalk() {
        val (store, root) = tempStore()
        try {
            val original = Walk(startedAt = SwiftDate.epoch(100.0))
            store.save(original)
            File(root, "walks/.${original.id.uuidString}.json.tmp").writeText("{\"points\":[")
            assertEquals(original, Store(root).loadWalks().single())
        } finally { root.parentFile.deleteRecursively() }
    }

    @Test fun corruptUnsyncedWalkRemainsAvailableForRecovery() {
        val (store, root) = tempStore()
        try {
            val original = Walk(startedAt = SwiftDate.epoch(100.0))
            store.save(original)
            val file = File(root, "walks/${original.id.uuidString}.json")
            val corrupt = "{\"points\":["
            file.writeText(corrupt)
            assertTrue(Store(root).loadWalks().isEmpty())
            assertEquals(corrupt, file.readText())
            assertFalse(original.id in Store(root).loadSyncState().uploadedWalks)
        } finally { root.parentFile.deleteRecursively() }
    }
}
