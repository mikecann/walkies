package com.mikecann.walkies.sync

import com.mikecann.walkies.AppModel
import com.mikecann.walkies.FakeLocation
import com.mikecann.walkies.FakeSettings
import com.mikecann.walkies.tempStore
import com.mikecann.walkies.store.Store

import com.mikecann.walkies.convex.ConvexClient
import com.mikecann.walkies.convex.Http
import com.mikecann.walkies.model.SwiftDate
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.sync.FakeServer
import com.mikecann.walkies.sync.SyncEngine
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class UploadRelaunchTest {
    @Test fun aLostLocalUploadMarkerRetriesTheCommittedServerWalkAfterRelaunch() = runBlocking {
        val (store, root) = tempStore()
        try {
            val walk = Walk(startedAt = SwiftDate.epoch(100.0), endedAt = SwiftDate.epoch(200.0))
            store.save(walk)
            // Make the atomic marker write fail after the server accepted the walk.
            val blocked = File(root, ".sync.json.tmp")
            assertTrue(blocked.mkdir())
            val server = FakeServer()
            val client = ConvexClient(server.backend, http = server)
            var model = AppModel(store, FakeSettings(), FakeLocation())
            var engine = SyncEngine(model, store, isSignedIn = { true }, makeClient = { client }, scope = this)
            engine.sync()
            assertEquals(1, server.walks.size)
            assertFalse(walk.id in Store(root).loadSyncState().uploadedWalks)
            assertTrue(blocked.delete())
            model = AppModel(Store(root), FakeSettings(), FakeLocation())
            engine = SyncEngine(model, Store(root), isSignedIn = { true }, makeClient = { client }, scope = this)
            engine.sync()
            assertEquals(1, server.walks.size)
            val saved = Store(root).loadWalks().single()
            assertEquals(walk.id, saved.id)
            assertEquals(walk.points, saved.points)
            assertEquals(walk.endedAt, saved.endedAt)
            assertTrue(walk.id in Store(root).loadSyncState().uploadedWalks)
            assertEquals(0, engine.waiting)
        } finally { root.parentFile.deleteRecursively() }
    }

    private class FaultHttp(val server: FakeServer, var fault: String?) : Http {
        override fun send(url: String, body: ByteArray?, headers: Map<String, String>, timeoutSeconds: Int): Http.Response {
            if (url.endsWith("/upload") && fault == "upload") {
                fault = null
                return Http.Response(503, byteArrayOf())
            }
            val path = if (body != null && !url.endsWith("/upload"))
                Json.parseToJsonElement(body.decodeToString()).jsonObject["path"]?.jsonPrimitive?.content else null
            if (path == "sync:saveWalk" && fault == "save") {
                fault = null
                return Http.Response(503, byteArrayOf())
            }
            val result = server.send(url, body, headers, timeoutSeconds)
            if (path == "sync:saveWalk" && fault == "ack") {
                fault = null
                return Http.Response(503, byteArrayOf())
            }
            return result
        }
    }

    @Test fun interruptedWalkUploadsSurviveRelaunchAndRetry() = runBlocking {
        for (phase in listOf("upload", "save", "ack")) {
            val (store, root) = tempStore()
            try {
                val walk = Walk(startedAt = SwiftDate.epoch(100.0), endedAt = SwiftDate.epoch(200.0))
                store.save(walk)
                val server = FakeServer()
                val http = FaultHttp(server, phase)
                val client = ConvexClient(server.backend, http = http)
                val model = AppModel(store, FakeSettings(), FakeLocation())
                val engine = SyncEngine(model, store, isSignedIn = { true }, makeClient = { client }, scope = this)
                engine.sync()
                assertTrue(engine.status is SyncEngine.Status.Failed)
                assertFalse(walk.id in store.loadSyncState().uploadedWalks)
                assertEquals(walk.id, store.loadWalks().single().id)
                val relaunched = AppModel(store, FakeSettings(), FakeLocation())
                val again = SyncEngine(relaunched, store, isSignedIn = { true }, makeClient = { client }, scope = this)
                again.sync()
                assertEquals(SyncEngine.Status.Idle, again.status)
                assertEquals(1, server.walks.size)
                assertTrue(walk.id in store.loadSyncState().uploadedWalks)
                assertEquals(0, again.waiting)
                println("SYNC_REPLAY phase=$phase durablePending=true retried=true serverRows=1 waiting=${again.waiting}")
            } finally { root.parentFile.deleteRecursively() }
        }
    }
}
