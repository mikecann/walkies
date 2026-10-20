package com.mikecann.walkies.auth

import com.mikecann.walkies.convex.ConvexClient
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * A fresh test account on the dev deployment, without Google: the iPhone's
 * `-testSignIn -testUserName` (Account.swift). Only in debug builds; release has a
 * stand-in that does nothing, so none of this ships. The server only allows it
 * where WALKIES_TEST_SIGNIN=1, which is dev.
 *
 * `adb shell am start -n com.mikecann.walkies/.MainActivity --ez testSignIn true --es testUserName "Emu"`
 */
object TestSignIn {
    const val AVAILABLE = true

    suspend fun signIn(account: Account, name: String?) {
        val result = ConvexClient(account.backend, http = account.http).mutation(
            "auth:signInForTesting",
            buildJsonObject { name?.trim()?.takeIf { it.isNotEmpty() }?.let { put("name", it) } },
        )
        account.finishSignIn(result)
    }
}
