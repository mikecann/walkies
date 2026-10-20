package com.mikecann.walkies.auth

import com.mikecann.walkies.sync.FakeServer
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Debug builds only, like the test sign-in itself. */
class TestSignInTest {
    private fun tokens() = buildJsonObject {
        put("accessToken", "a")
        put("accessTokenExpiresAt", 1_790_000_000_000.0 + 3_600_000.0)
        put("refreshToken", "r")
        put("refreshTokenExpiresAt", 1_790_000_000_000.0 + 86_400_000.0)
        put("userId", "user-1")
    }

    @Test
    fun testSignInUsesTheDevOnlyMutation() = runBlocking {
        val server = FakeServer()
        server.answers["auth:signInForTesting"] = { args ->
            assertEquals("Emu", args["name"]!!.jsonPrimitive.content)
            buildJsonObject {
                put("status", "complete")
                put("tokens", tokens())
            }
        }
        server.answers["users:me"] = { buildJsonObject { put("name", "Emu") } }
        val account = Account(SessionVault.Memory(), server.backend, server, clock = { 1_790_000_000_000.0 })
        assertTrue(TestSignIn.AVAILABLE)
        TestSignIn.signIn(account, " Emu ")
        assertEquals("Emu", account.displayName)
    }
}
