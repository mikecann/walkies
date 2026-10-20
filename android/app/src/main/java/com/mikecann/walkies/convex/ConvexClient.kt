package com.mikecann.walkies.convex

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.put
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URI

/**
 * The Convex deployment the app talks to (Backend in Convex.swift). Both are in Sydney.
 * Debug builds use dev, so testing never touches the real walks on anyone's phone;
 * release builds use prod. The URLs come from BuildConfig (see app/build.gradle.kts).
 */
data class Backend(val cloud: String, val site: String) {
    /** Where Google sign-in hands back to the app (see Account). */
    val signedInPage: String get() = "$site/app/signed-in"
}

/** What went wrong on the server (ConvexError in Convex.swift), with the iPhone's friendly messages. */
sealed class ConvexException(message: String) : Exception(message) {
    open val code: String? get() = null

    class Server(message: String) : ConvexException(message)

    /** A ConvexError thrown with `{ code, message }` data. */
    class Coded(override val code: String, val serverMessage: String) : ConvexException(friendly(code, serverMessage))

    class BadResponse(val status: Int) : ConvexException("The server returned an error ($status).")

    companion object {
        fun friendly(code: String, message: String) = when (code) {
            "RATE_LIMITED" -> "Too many invite attempts. Please wait up to an hour before trying again."
            "MEMBER_REMOVED" -> "You were removed from this team. Ask its creator for a new invite link."
            "TEAM_FULL" -> "This team is full. A team can have up to 8 members."
            "NOT_A_MEMBER", "TEAM_NOT_FOUND" -> "You no longer have access to this team. You may have been removed or the team has closed."
            else -> message
        }
    }
}

/** Plain HTTP, behind an interface so tests can stand in for the server. Blocking: callers move it off the main thread. */
interface Http {
    class Response(val status: Int, val body: ByteArray)

    /** POSTs [body] when it isn't null, otherwise GETs. Throws IOException when there's no answer at all. */
    fun send(url: String, body: ByteArray?, headers: Map<String, String>, timeoutSeconds: Int): Response

    /** HttpURLConnection, which needs nothing extra on Android or the JVM. */
    object Default : Http {
        override fun send(url: String, body: ByteArray?, headers: Map<String, String>, timeoutSeconds: Int): Response {
            val connection = URI(url).toURL().openConnection() as HttpURLConnection
            try {
                connection.connectTimeout = 30_000
                connection.readTimeout = timeoutSeconds * 1000
                connection.instanceFollowRedirects = true
                for ((name, value) in headers) connection.setRequestProperty(name, value)
                if (body != null) {
                    connection.requestMethod = "POST"
                    connection.doOutput = true
                    connection.setFixedLengthStreamingMode(body.size)
                    connection.outputStream.use { it.write(body) }
                }
                val status = connection.responseCode
                val stream = if (status in 200..299) connection.inputStream else connection.errorStream
                return Response(status, stream?.use { it.readBytes() } ?: ByteArray(0))
            } finally {
                connection.disconnect()
            }
        }
    }
}

/**
 * Calls Convex functions over its HTTP API (ConvexClient in Convex.swift). Plain
 * request and response is all sync needs. Results come back as JSON for the caller
 * to read; a function that returns null gives [JsonNull].
 */
class ConvexClient(
    private val backend: Backend,
    val token: String? = null,
    val http: Http = Http.Default,
) {
    suspend fun query(path: String, args: JsonObject = empty): JsonElement = call("query", path, args)

    suspend fun mutation(path: String, args: JsonObject = empty): JsonElement = call("mutation", path, args)

    /** A cold place fetch can try both Overpass servers. Cached actions return quickly. */
    suspend fun action(path: String, args: JsonObject = empty): JsonElement = call("action", path, args, timeout = 360)

    /** Uploads a file to Convex storage at a URL from `generateUploadUrl`, returning its id. */
    suspend fun upload(data: ByteArray, url: String): String {
        val response = send(url, data, mapOf("Content-Type" to "application/json"), 60)
        check(response)
        val id = (parse(response.body) as? JsonObject)?.get("storageId") as? JsonPrimitive
        return id?.takeIf { it.isString }?.content ?: throw ConvexException.BadResponse(response.status)
    }

    suspend fun download(url: String): ByteArray {
        val response = send(url, null, emptyMap(), 60)
        check(response)
        return response.body
    }

    private suspend fun call(kind: String, path: String, args: JsonObject, timeout: Int = 30): JsonElement {
        val headers = HashMap<String, String>()
        headers["Content-Type"] = "application/json"
        token?.let { headers["Authorization"] = "Bearer $it" }
        val request = buildJsonObject {
            put("path", path)
            put("args", args)
            put("format", "json")
        }
        val response = send("${backend.cloud}/api/$kind", request.toString().toByteArray(), headers, timeout)
        return result(path, response)
    }

    private suspend fun send(url: String, body: ByteArray?, headers: Map<String, String>, timeout: Int) =
        withContext(Dispatchers.IO) { http.send(url, body, headers, timeout) }

    companion object {
        val empty = JsonObject(emptyMap())

        /** Reads Convex's `{status, value, errorMessage, errorData}` envelope, or throws what went wrong. */
        internal fun result(path: String, response: Http.Response): JsonElement {
            val envelope = parse(response.body) as? JsonObject
            val status = (envelope?.get("status") as? JsonPrimitive)?.takeIf { it.isString }?.content
            if (envelope == null || status == null) {
                check(response)
                throw ConvexException.BadResponse(response.status)
            }
            if (status != "success") {
                val data = envelope["errorData"]
                if (data is JsonObject) {
                    val code = data.string("code")
                    if (code != null) throw ConvexException.Coded(code, data.string("message") ?: code)
                }
                throw ConvexException.Server(message(data) ?: envelope.string("errorMessage") ?: "Unknown error")
            }
            // Optional results (such as an unknown invite) legitimately come back null.
            return envelope["value"] ?: JsonNull
        }

        /**
         * For a ConvexError thrown on the server: its `message`, or its `code` when
         * that's all it has (Chef looks for "UNAUTHENTICATED").
         */
        private fun message(data: JsonElement?): String? = when (data) {
            is JsonPrimitive -> if (data.isString) data.content else null
            is JsonObject -> data.string("message") ?: data.string("code")
            else -> null
        }

        private fun JsonObject.string(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

        private fun parse(body: ByteArray): JsonElement? = try {
            Json.parseToJsonElement(body.decodeToString())
        } catch (e: Exception) {
            null
        }

        private fun check(response: Http.Response) {
            if (response.status !in 200..299) throw ConvexException.BadResponse(response.status)
        }
    }
}

/** True for errors that mean there was no answer: offline, a timeout, DNS. */
fun Throwable.isNetwork(): Boolean = this is IOException
