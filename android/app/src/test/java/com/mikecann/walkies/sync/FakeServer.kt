package com.mikecann.walkies.sync

import com.mikecann.walkies.convex.Backend
import com.mikecann.walkies.convex.Http
import com.mikecann.walkies.model.Codec
import com.mikecann.walkies.model.Ledger
import com.mikecann.walkies.model.Walk
import com.mikecann.walkies.model.uuidString
import com.mikecann.walkies.place.City
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Stands in for the Convex deployment and its file storage (SafetyServer in
 * SyncSafetyTests.swift). Called on IO threads, so everything's synchronized.
 */
class FakeServer : Http {
    val backend = Backend("https://test.convex.cloud", "https://test.convex.site")

    data class Call(val path: String, val args: JsonObject, val token: String?)

    val calls = ArrayList<Call>()
    val places = LinkedHashMap<String, Pair<Double, String>>()
    val walks = LinkedHashMap<String, String>()
    val deleted = ArrayList<String>()
    val files = HashMap<String, ByteArray>()
    /** What a function returns, standing in for the usual answer. */
    val answers = HashMap<String, (JsonObject) -> JsonElement>()
    /** Functions that answer with this raw envelope instead. */
    val failures = HashMap<String, String>()
    private var failing: String? = null
    private val garbled = HashSet<String>()
    private var gate: CountDownLatch? = null
    val downloadStarted = CountDownLatch(1)
    @Volatile var offline = false
    /** The account's ledger, merged with each one pushed as the server does (mergeLedgers in convex/progression.ts). */
    var ledger: Ledger? = null

    val paths: List<String> @Synchronized get() = calls.map { it.path }

    @Synchronized
    fun seed(city: City) {
        files[city.id.uuidString] = Codec.city(city).toString().toByteArray()
        places[city.id.uuidString] = city.lastChanged.ms to city.id.uuidString
    }

    @Synchronized
    fun seed(walk: Walk) {
        files[walk.id.uuidString] = Codec.walk(walk).toString().toByteArray()
        walks[walk.id.uuidString] = walk.id.uuidString
    }

    @Synchronized
    fun fail(id: UUID?) {
        failing = id?.uuidString
    }

    @Synchronized
    fun garble(id: UUID) {
        garbled.add(id.uuidString)
    }

    @Synchronized
    fun pauseDownloads() {
        gate = CountDownLatch(1)
    }

    fun resumeDownloads() {
        val gate = synchronized(this) { gate.also { this.gate = null } }
        gate?.countDown()
    }

    override fun send(url: String, body: ByteArray?, headers: Map<String, String>, timeoutSeconds: Int): Http.Response {
        if (offline) throw java.net.UnknownHostException("test.convex.cloud")
        if (url.startsWith("https://files.walkies.test/")) {
            downloadStarted.countDown()
            synchronized(this) { gate }?.await(10, TimeUnit.SECONDS)
            return synchronized(this) {
                val file = url.substringAfterLast('/')
                when {
                    file == failing -> Http.Response(500, ByteArray(0))
                    file in garbled -> Http.Response(200, "{\"nope\":".toByteArray())
                    else -> Http.Response(200, files.getValue(file))
                }
            }
        }
        return synchronized(this) { respond(url, body!!, headers["Authorization"]?.removePrefix("Bearer ")) }
    }

    private fun respond(url: String, body: ByteArray, token: String?): Http.Response {
        if (url == "https://sync.walkies.test/upload") {
            val id = UUID.randomUUID().uuidString
            files[id] = body
            return Http.Response(200, "{\"storageId\":\"$id\"}".toByteArray())
        }
        val call = Json.parseToJsonElement(body.decodeToString()).jsonObject
        val path = call.getValue("path").jsonPrimitive.content
        val args = call.getValue("args").jsonObject
        calls.add(Call(path, args, token))
        failures[path]?.let { return Http.Response(200, it.toByteArray()) }
        fun string(key: String) = args.getValue(key).jsonPrimitive.content
        var value: JsonElement = JsonNull
        val answer = answers[path]
        if (answer != null) {
            value = answer(args)
        } else when (path) {
            "sync:generateUploadUrl" -> value = JsonPrimitive("https://sync.walkies.test/upload")
            "sync:savePlace" -> places[string("clientId")] = args.getValue("updatedAt").jsonPrimitive.doubleOrNull!! to string("file")
            "sync:saveWalk" -> walks[string("clientId")] = string("file")
            "sync:saveProgress" -> {
                val incoming = Codec.ledger(Codec.parse(string("ledger")))
                ledger = ledger?.merged(incoming) ?: incoming
            }
            "sync:deletePlace" -> {
                deleted.add(string("clientId"))
                places.remove(string("clientId"))
            }
            "sync:snapshot" -> {
                val withUrls = args["walkUrls"]?.jsonPrimitive?.booleanOrNull != false
                value = buildJsonObject {
                    put("places", buildJsonArray {
                        for ((id, place) in places) add(buildJsonObject {
                            put("clientId", id)
                            put("updatedAt", place.first)
                            put("url", "https://files.walkies.test/${place.second}")
                        })
                    })
                    put("walks", buildJsonArray {
                        for ((id, file) in walks) add(buildJsonObject {
                            put("clientId", id)
                            put("url", if (withUrls) JsonPrimitive("https://files.walkies.test/$file") else JsonNull)
                        })
                    })
                    put("secrets", JsonArray(emptyList()))
                    put("progress", ledger?.let { JsonPrimitive(SyncEngine.progressJSON(it)) } ?: JsonNull)
                }
            }
            "sync:walkUrls" -> value = buildJsonArray {
                for (id in args.getValue("clientIds").jsonArray.map { it.jsonPrimitive.content }) {
                    val file = walks[id] ?: continue
                    add(buildJsonObject {
                        put("clientId", id)
                        put("url", "https://files.walkies.test/$file")
                    })
                }
            }
        }
        val envelope = buildJsonObject {
            put("status", "success")
            put("value", value)
        }
        return Http.Response(200, envelope.toString().toByteArray())
    }
}
