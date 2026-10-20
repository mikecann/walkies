package com.mikecann.walkies.auth

import com.mikecann.walkies.convex.ConvexClient
import com.mikecann.walkies.convex.ConvexException
import com.mikecann.walkies.convex.Http
import com.mikecann.walkies.sync.FakeServer
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** Account.swift's session handling, the sign-in callback and the client's error shapes. */
class AccountTest {
    private var now = 1_790_000_000_000.0

    private fun session(expiresIn: Double, refresh: String = "refresh-1") = Session(
        accessToken = "access-1", accessTokenExpiresAt = now + expiresIn,
        refreshToken = refresh, refreshTokenExpiresAt = now + 30 * 86_400_000.0,
        userId = "user-1", name = "Emu", email = "emu@example.com", picture = "https://example.com/emu.png",
    )

    private fun tokens(access: String, refresh: String, expiresIn: Double = 3_600_000.0) = buildJsonObject {
        put("accessToken", access)
        put("accessTokenExpiresAt", now + expiresIn)
        put("refreshToken", refresh)
        put("refreshTokenExpiresAt", now + 30 * 86_400_000.0)
        put("userId", "user-1")
    }

    private fun account(server: FakeServer, vault: SessionVault) = Account(vault, server.backend, server, clock = { now })

    @Test
    fun aTokenWithMoreThanFiveSecondsLeftIsUsedAsIs() = runBlocking {
        val server = FakeServer()
        val account = account(server, SessionVault.Memory(session(expiresIn = 5_001.0)))
        assertEquals("access-1", account.client()!!.token)
        assertTrue(server.calls.isEmpty())
    }

    @Test
    fun aTokenAboutToRunOutIsRefreshedOnceKeepingTheProfile() = runBlocking {
        val server = FakeServer()
        server.answers["auth:refreshSession"] = { args ->
            assertEquals("refresh-1", args["refreshToken"]!!.jsonPrimitive.content)
            buildJsonObject {
                put("kind", "rotated")
                put("tokens", tokens("access-2", "refresh-2"))
            }
        }
        val vault = SessionVault.Memory(session(expiresIn = 5_000.0))
        val account = account(server, vault)
        // Several at once still refresh once: refresh tokens rotate.
        val clients = (0 until 3).map { async { account.client() } }.awaitAll()
        assertEquals(listOf("access-2", "access-2", "access-2"), clients.map { it!!.token })
        assertEquals(1, server.calls.count { it.path == "auth:refreshSession" })
        val saved = vault.session!!
        assertEquals("refresh-2", saved.refreshToken)
        assertEquals("Emu", saved.name)
        assertEquals("emu@example.com", saved.email)
        assertEquals("https://example.com/emu.png", saved.picture)
        // And it's good for a while now.
        assertEquals("access-2", account.client()!!.token)
        assertEquals(1, server.calls.count { it.path == "auth:refreshSession" })
    }

    @Test
    fun aRefreshTheServerTurnsDownSignsOut() = runBlocking {
        val server = FakeServer()
        server.answers["auth:refreshSession"] = { buildJsonObject { put("kind", "invalid") } }
        val vault = SessionVault.Memory(session(expiresIn = -1.0))
        val account = account(server, vault)
        var heard = 0
        account.listen { heard++ }
        assertNull(account.client())
        assertFalse(account.isSignedIn)
        assertNull(vault.session)
        assertEquals(1, heard)
    }

    @Test
    fun offlineKeepsTheSessionForLater() = runBlocking {
        val server = FakeServer()
        server.offline = true
        val vault = SessionVault.Memory(session(expiresIn = 0.0))
        val account = account(server, vault)
        assertNull(account.client())
        assertTrue(account.isSignedIn)
        assertEquals("refresh-1", vault.session!!.refreshToken)
    }

    @Test
    fun signingOutForgetsTheSessionAndTellsTheServer() = runBlocking {
        val server = FakeServer()
        val vault = SessionVault.Memory(session(expiresIn = 60_000.0))
        val account = account(server, vault)
        account.signOut()
        assertFalse(account.isSignedIn)
        assertNull(vault.session)
        assertEquals("auth:signOut", server.calls.single().path)
        assertEquals("refresh-1", server.calls.single().args["refreshToken"]!!.jsonPrimitive.content)
    }

    @Test
    fun theGoogleSignInComesBackThroughWalkiesSignedIn() = runBlocking {
        val server = FakeServer()
        server.answers["auth:startSignInWithGoogle"] = { args ->
            assertEquals("https://test.convex.site/app/signed-in", args["redirectTo"]!!.jsonPrimitive.content)
            buildJsonObject {
                put("redirect", "https://accounts.google.com/o/oauth2/v2/auth?x=1")
                put("state", "state-1")
            }
        }
        server.answers["auth:completeSignInWithGoogle"] = { args ->
            assertEquals("code 1/2", args["code"]!!.jsonPrimitive.content)
            assertEquals("state-1", args["state"]!!.jsonPrimitive.content)
            buildJsonObject {
                put("status", "complete")
                put("tokens", tokens("access-9", "refresh-9"))
            }
        }
        server.answers["users:me"] = {
            buildJsonObject {
                put("name", "Mike")
                put("email", "mike@example.com")
                put("picture", "https://example.com/mike.png")
            }
        }
        val vault = SessionVault.Memory()
        val account = account(server, vault)
        val pending = account.startSignInWithGoogle()
        assertEquals("https://accounts.google.com/o/oauth2/v2/auth?x=1", pending.page)
        account.completeSignInWithGoogle("walkies://signed-in?convexAuthCode=code%201%2F2", pending.state)
        assertTrue(account.isSignedIn)
        assertEquals("Mike", account.displayName)
        assertEquals("https://example.com/mike.png", account.picture)
        assertEquals("user-1", account.userId)
        assertEquals("access-9", vault.session!!.accessToken)
        assertEquals("access-9", server.calls.single { it.path == "users:me" }.token)
    }

    @Test
    fun aMissingProfileDoesNotStopSignIn() = runBlocking {
        val server = FakeServer()
        server.failures["users:me"] = """{"status":"error","errorMessage":"nope"}"""
        val account = account(server, SessionVault.Memory())
        account.finishSignIn(buildJsonObject {
            put("status", "complete")
            put("tokens", tokens("a", "r"))
        })
        assertTrue(account.isSignedIn)
        assertNull(account.displayName)
    }

    @Test
    fun theCallbackIsReadLikeTheIPhoneDoes() {
        assertEquals(SignInCallback.Result.Code("abc"), SignInCallback.parse("walkies://signed-in?convexAuthCode=abc"))
        assertEquals(SignInCallback.Result.Code("a+b/c"), SignInCallback.parse("walkies://signed-in?state=x&convexAuthCode=a%2Bb%2Fc"))
        assertEquals(SignInCallback.Result.Code("abc"), SignInCallback.parse("WALKIES://Signed-In?convexAuthCode=abc"))
        assertEquals(SignInCallback.Result.Cancelled, SignInCallback.parse("walkies://signed-in?convexAuthError=access_denied"))
        // An error wins over a code, as on the iPhone.
        assertEquals(SignInCallback.Result.Failed, SignInCallback.parse("walkies://signed-in?convexAuthError=server_error&convexAuthCode=abc"))
        assertEquals(SignInCallback.Result.Failed, SignInCallback.parse("walkies://signed-in"))
        assertEquals(SignInCallback.Result.Failed, SignInCallback.parse("walkies://signed-in?convexAuthCode="))
        assertEquals(SignInCallback.Result.Failed, SignInCallback.parse("walkies://join/ABCDEFGH?convexAuthCode=abc"))
        assertFalse(SignInCallback.matches("https://test.convex.site/app/signed-in?convexAuthCode=abc"))
        assertFalse(SignInCallback.matches("walkies://join/ABCDEFGH"))
        assertTrue(SignInCallback.matches("walkies://signed-in?convexAuthCode=abc"))
    }

    @Test
    fun cancelledOnGooglesPageSaysNothing() = runBlocking {
        val account = account(FakeServer(), SessionVault.Memory())
        try {
            account.completeSignInWithGoogle("walkies://signed-in?convexAuthError=access_denied", "state")
            fail()
        } catch (e: SignInError) {
            assertSame(SignInError.Cancelled, e)
            assertNull(signInMessage(e))
        }
    }

    @Test
    fun theSessionSurvivesTheVaultsJson() {
        val s = session(expiresIn = 1.0)
        assertEquals(s, Session.parse(s.toJson().toString()))
        assertNull(Session.parse("""{"accessToken":"a"}"""))
        assertNull(Session.parse("not json"))
    }

    // The client's error shapes (Convex.swift).

    private fun result(body: String, status: Int = 200): JsonElement =
        ConvexClient.result("x:y", Http.Response(status, body.toByteArray()))

    @Test
    fun convexErrorsComeBackWithTheirCodesAndFriendlyMessages() {
        assertEquals(JsonNull, result("""{"status":"success","value":null}"""))
        assertEquals(1, (result("""{"status":"success","value":{"a":1}}""") as JsonObject).size)
        try {
            result("""{"status":"error","errorMessage":"Uncaught ConvexError","errorData":{"code":"TEAM_FULL","message":"full"}}""")
            fail()
        } catch (e: ConvexException.Coded) {
            assertEquals("TEAM_FULL", e.code)
            assertEquals("This team is full. A team can have up to 8 members.", e.message)
        }
        try {
            result("""{"status":"error","errorMessage":"Uncaught ConvexError","errorData":"Too many requests. Try again in a minute."}""")
            fail()
        } catch (e: ConvexException.Server) {
            assertEquals("Too many requests. Try again in a minute.", e.message)
        }
        try {
            result("""{"status":"error","errorMessage":"Server Error"}""")
            fail()
        } catch (e: ConvexException.Server) {
            assertEquals("Server Error", e.message)
        }
        try {
            result("<html>bad gateway</html>", status = 502)
            fail()
        } catch (e: ConvexException.BadResponse) {
            assertEquals(502, e.status)
            assertEquals("Something went wrong on the Walkies server. Try again in a minute.", signInMessage(e))
        }
    }
}
