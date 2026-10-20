package com.mikecann.walkies.auth

import com.mikecann.walkies.convex.Backend
import com.mikecann.walkies.convex.ConvexClient
import com.mikecann.walkies.convex.ConvexException
import com.mikecann.walkies.convex.Http
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put
import java.io.IOException
import java.net.URI
import java.net.URLDecoder
import java.util.logging.Logger

/** Session tokens from Convex Auth, plus who they belong to (Session in Account.swift). */
data class Session(
    val accessToken: String,
    /** Milliseconds since 1970, as Convex Auth sends them. */
    val accessTokenExpiresAt: Double,
    val refreshToken: String,
    val refreshTokenExpiresAt: Double,
    val userId: String,
    val name: String? = null,
    val email: String? = null,
    /** Their Google photo. */
    val picture: String? = null,
) {
    fun toJson(): JsonObject = buildJsonObject {
        put("accessToken", accessToken)
        put("accessTokenExpiresAt", accessTokenExpiresAt)
        put("refreshToken", refreshToken)
        put("refreshTokenExpiresAt", refreshTokenExpiresAt)
        put("userId", userId)
        name?.let { put("name", it) }
        email?.let { put("email", it) }
        picture?.let { put("picture", it) }
    }

    companion object {
        /** Null when anything it needs is missing. */
        fun from(json: JsonElement?): Session? {
            val o = json as? JsonObject ?: return null
            fun string(key: String) = (o[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
            fun number(key: String) = (o[key] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull
            return Session(
                accessToken = string("accessToken") ?: return null,
                accessTokenExpiresAt = number("accessTokenExpiresAt") ?: return null,
                refreshToken = string("refreshToken") ?: return null,
                refreshTokenExpiresAt = number("refreshTokenExpiresAt") ?: return null,
                userId = string("userId") ?: return null,
                name = string("name"),
                email = string("email"),
                picture = string("picture"),
            )
        }

        fun parse(text: String): Session? = try {
            from(Json.parseToJsonElement(text))
        } catch (e: Exception) {
            null
        }
    }
}

/** Where the session's kept: the Android Keystore on the phone, memory in tests. */
interface SessionVault {
    fun load(): Session?
    fun save(session: Session)
    fun delete()

    class Memory(var session: Session? = null) : SessionVault {
        override fun load() = session
        override fun save(session: Session) {
            this.session = session
        }
        override fun delete() {
            session = null
        }
    }
}

sealed class SignInError(message: String?) : Exception(message) {
    /** Closed the sign-in page, or said no on Google's: nothing to say. */
    data object Cancelled : SignInError(null)
    data object Failed : SignInError("Something went wrong signing in. Try again.")
    /** The sign-in page couldn't open. */
    class Sheet(code: Int) : SignInError("Couldn't open the sign-in page ($code). Try again.")
}

/** The line under the sign-in buttons for this error (SignInView.swift), or null for nothing. */
fun signInMessage(error: Throwable): String? = when (error) {
    is SignInError.Cancelled -> null
    is IOException -> "Can't reach Walkies (${error.javaClass.simpleName}). Check your connection and try again."
    is ConvexException -> "Something went wrong on the Walkies server. Try again in a minute."
    else -> error.message ?: "Something went wrong signing in. Try again."
}

/**
 * Where Google's sign-in comes back to: the deployment's /app/signed-in page passes
 * its query on to `walkies://signed-in`, which MainActivity catches.
 */
object SignInCallback {
    sealed interface Result {
        data class Code(val code: String) : Result
        data object Cancelled : Result
        data object Failed : Result
    }

    /** Whether this link is the sign-in coming back, rather than something else for the app. */
    fun matches(uri: String): Boolean {
        val parsed = runCatching { URI(uri) }.getOrNull() ?: return false
        return parsed.scheme.equals("walkies", ignoreCase = true) && parsed.host.equals("signed-in", ignoreCase = true)
    }

    fun parse(uri: String): Result {
        if (!matches(uri)) return Result.Failed
        val query = query(URI(uri).rawQuery)
        query["convexAuthError"]?.let { error ->
            log.severe("Google said $error")
            return if (error == "access_denied") Result.Cancelled else Result.Failed
        }
        val code = query["convexAuthCode"]?.takeIf { it.isNotEmpty() } ?: return Result.Failed
        return Result.Code(code)
    }

    /** The first value of each parameter, decoded. */
    private fun query(raw: String?): Map<String, String> {
        val out = LinkedHashMap<String, String>()
        for (part in raw.orEmpty().split('&')) {
            if (part.isEmpty()) continue
            val eq = part.indexOf('=')
            val key = decode(if (eq < 0) part else part.substring(0, eq))
            val value = if (eq < 0) "" else decode(part.substring(eq + 1))
            out.putIfAbsent(key, value)
        }
        return out
    }

    private fun decode(s: String) = URLDecoder.decode(s, Charsets.UTF_8)
}

/** A Google sign-in that's been started: the page to open, and the state to finish it with. */
data class PendingSignIn(val page: String, val state: String)

/**
 * Signing in through Convex Auth (Account.swift). Google's sign-in page runs in a
 * Custom Tab that ends on the deployment's own site, which bounces to
 * walkies://signed-in with a one-time code. The session lives in a [SessionVault].
 * Apple sign-in isn't on Android. Lives on the main thread.
 */
class Account(
    private val vault: SessionVault,
    val backend: Backend,
    val http: Http = Http.Default,
    /** Milliseconds since 1970. */
    private val clock: () -> Double = { System.currentTimeMillis().toDouble() },
) {
    data class Profile(val signedIn: Boolean, val name: String?, val email: String?, val picture: String?) {
        constructor(session: Session?) : this(session != null, session?.name, session?.email, session?.picture)
    }

    /**
     * The tokens. Listeners don't hear about these changing: they change every few
     * minutes as the access token is refreshed.
     */
    var session: Session? = vault.load()
        private set(value) {
            field = value
            val next = Profile(value)
            if (next != profile) {
                profile = next
                for (listener in listeners.toList()) listener()
            }
        }

    /** What the screens show about who's signed in. Only changes on sign-in, sign-out or a new name, email or photo. */
    var profile = Profile(session)
        private set

    private val listeners = ArrayList<() -> Unit>()

    /** Calls [listener] when the profile changes. Returns a function that stops it. */
    fun listen(listener: () -> Unit): () -> Unit {
        listeners.add(listener)
        return { listeners.remove(listener) }
    }

    val isSignedIn get() = profile.signedIn
    /** Who's signed in, for tying this phone's data to them. */
    val userId: String? get() = session?.userId
    /** The name to show for whoever's signed in. */
    val displayName: String? get() = profile.name ?: profile.email
    val email: String? get() = profile.email
    /** Your photo for your head on the place chip. */
    val picture: String? get() = profile.picture

    private var refreshing: CompletableDeferred<Session?>? = null

    /** Reads the session again, say after the vault couldn't be read at launch. */
    fun loadSession() {
        session = vault.load()
    }

    // Signing in

    /** Asks Convex Auth for Google's sign-in page, ending back on this deployment's site. */
    suspend fun startSignInWithGoogle(): PendingSignIn {
        log.info("Google: starting on ${backend.site}")
        val start = ConvexClient(backend, http = http).mutation(
            "auth:startSignInWithGoogle",
            buildJsonObject { put("redirectTo", backend.signedInPage) },
        ) as? JsonObject ?: throw SignInError.Failed
        val page = (start["redirect"] as? JsonPrimitive)?.content ?: throw SignInError.Failed
        val state = (start["state"] as? JsonPrimitive)?.content ?: throw SignInError.Failed
        if (!page.startsWith("https://")) throw SignInError.Failed
        return PendingSignIn(page, state)
    }

    /** Finishes a Google sign-in with the walkies://signed-in link it came back on. */
    suspend fun completeSignInWithGoogle(callback: String, state: String) {
        val code = when (val result = SignInCallback.parse(callback)) {
            is SignInCallback.Result.Code -> result.code
            SignInCallback.Result.Cancelled -> throw SignInError.Cancelled
            SignInCallback.Result.Failed -> throw SignInError.Failed
        }
        val result = ConvexClient(backend, http = http).mutation(
            "auth:completeSignInWithGoogle",
            buildJsonObject {
                put("code", code)
                put("state", state)
            },
        )
        log.info("Google: finished with ${((result as? JsonObject)?.get("status") as? JsonPrimitive)?.content}")
        finishSignIn(result)
    }

    /** Keeps the tokens from a completed sign-in, with who they belong to. */
    internal suspend fun finishSignIn(result: JsonElement) {
        val o = result as? JsonObject ?: throw SignInError.Failed
        if ((o["status"] as? JsonPrimitive)?.content != "complete") throw SignInError.Failed
        var tokens = Session.from(o["tokens"]) ?: throw SignInError.Failed
        // Who this is, for Settings. Not essential, so a hiccup here doesn't stop sign-in.
        try {
            tokens = withProfile(tokens, ConvexClient(backend, tokens.accessToken, http).query("users:me"))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            log.info("Couldn't read the profile: $e")
        }
        save(tokens)
    }

    /**
     * Picks up a new name or photo for someone who's already signed in, such as a
     * photo saved after they first signed in. Once a launch is plenty.
     */
    suspend fun refreshProfile() {
        val client = client() ?: return
        val me = try {
            client.query("users:me")
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            return
        }
        val tokens = session ?: return
        save(withProfile(tokens, me))
    }

    private fun withProfile(tokens: Session, me: JsonElement): Session {
        val o = me as? JsonObject ?: return tokens
        fun string(key: String) = (o[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
        return tokens.copy(name = string("name"), email = string("email"), picture = string("picture"))
    }

    // Using the session

    /**
     * A client with a fresh access token, refreshing it first if it's about to run out.
     * Null when signed out or the session has ended.
     */
    suspend fun client(): ConvexClient? {
        val current = session ?: return null
        // Access tokens can be short-lived (a minute on some deployments), so only
        // refresh in the last few seconds, not on every call.
        if (current.accessTokenExpiresAt - clock() > 5_000) return ConvexClient(backend, current.accessToken, http)
        return refreshedSession()?.let { ConvexClient(backend, it.accessToken, http) }
    }

    /** One refresh at a time: refresh tokens rotate, so two at once would trip over each other. */
    private suspend fun refreshedSession(): Session? {
        refreshing?.let { return it.await() }
        val current = session ?: return null
        val waiting = CompletableDeferred<Session?>()
        refreshing = waiting
        var refreshed: Session? = null
        try {
            val result = ConvexClient(backend, http = http).mutation(
                "auth:refreshSession",
                buildJsonObject { put("refreshToken", current.refreshToken) },
            ) as? JsonObject
            val tokens = Session.from(result?.get("tokens"))
            if ((result?.get("kind") as? JsonPrimitive)?.content != "rotated" || tokens == null) {
                // Only if nobody's signed in or out meanwhile.
                if (session?.refreshToken == current.refreshToken) clear()
            } else if (session?.refreshToken == current.refreshToken) {
                refreshed = tokens.copy(name = current.name, email = current.email, picture = current.picture)
                save(refreshed)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Offline or the server's having a moment: keep the session and try later.
            log.info("Couldn't refresh the session: $e")
        } finally {
            waiting.complete(refreshed)
            refreshing = null
        }
        return refreshed
    }

    /** Signed out here straight away, so nothing can sync while the server's told. */
    suspend fun signOut() {
        val refreshToken = session?.refreshToken
        clear()
        if (refreshToken != null) {
            try {
                ConvexClient(backend, http = http).mutation("auth:signOut", buildJsonObject { put("refreshToken", refreshToken) })
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                log.info("Couldn't tell the server about signing out: $e")
            }
        }
    }

    private fun save(tokens: Session) {
        session = tokens
        vault.save(tokens)
    }

    private fun clear() {
        session = null
        vault.delete()
    }
}

private val log: Logger = Logger.getLogger("walkies.signin")
