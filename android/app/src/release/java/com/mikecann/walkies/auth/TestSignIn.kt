package com.mikecann.walkies.auth

/** Test sign-in is only in debug builds (see src/debug). */
object TestSignIn {
    const val AVAILABLE = false

    @Suppress("UNUSED_PARAMETER", "RedundantSuspendModifier")
    suspend fun signIn(account: Account, name: String?) = Unit
}
