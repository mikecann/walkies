package com.mikecann.walkies.auth

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.browser.customtabs.CustomTabsIntent
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The session, sealed with an AES key that never leaves the Android Keystore (the
 * iPhone keeps it in the Keychain). A copy restored from a backup can't be opened
 * on another phone, so it just reads as signed out.
 */
class KeystoreVault(context: Context) : SessionVault {
    private val prefs = context.getSharedPreferences("walkies-session", Context.MODE_PRIVATE)

    override fun load(): Session? {
        val stored = prefs.getString(KEY, null) ?: return null
        return try {
            val sealed = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, sealed, 0, IV_SIZE))
            Session.parse(String(cipher.doFinal(sealed, IV_SIZE, sealed.size - IV_SIZE), Charsets.UTF_8))
        } catch (e: Exception) {
            null
        }
    }

    override fun save(session: Session) {
        try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, key())
            val sealed = cipher.iv + cipher.doFinal(session.toJson().toString().toByteArray(Charsets.UTF_8))
            prefs.edit().putString(KEY, Base64.encodeToString(sealed, Base64.NO_WRAP)).apply()
        } catch (e: Exception) {
            // Signed in for this launch only, rather than not at all.
            prefs.edit().remove(KEY).apply()
        }
    }

    override fun delete() {
        prefs.edit().remove(KEY).apply()
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (keyStore.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val KEY = "session"
        const val ALIAS = "walkies-session"
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_SIZE = 12
    }
}

/**
 * Google's sign-in page in a Custom Tab (SignInSheet in Account.swift). The tab ends
 * on the deployment's /app/signed-in page, which bounces to walkies://signed-in;
 * MainActivity catches that and calls [complete]. The state to finish with is kept
 * for a while, in case Android stops the app while Google's page is open.
 */
class GoogleSignIn(context: Context, private val account: Account) {
    private val prefs = context.getSharedPreferences("walkies-signin", Context.MODE_PRIVATE)

    /** Whether a sign-in's waiting to come back. */
    val waiting: Boolean get() = pendingState() != null

    /** Asks the server for Google's page and opens it. */
    suspend fun start(activity: Activity) {
        val pending = account.startSignInWithGoogle()
        prefs.edit().putString("state", pending.state).putLong("startedAt", System.currentTimeMillis()).apply()
        open(activity, pending.page)
    }

    /** Finishes with the walkies://signed-in link Google's sign-in came back on. */
    suspend fun complete(callback: String) {
        val state = pendingState() ?: throw SignInError.Failed
        forget()
        account.completeSignInWithGoogle(callback, state)
    }

    fun forget() {
        prefs.edit().remove("state").remove("startedAt").apply()
    }

    private fun pendingState(): String? {
        val startedAt = prefs.getLong("startedAt", 0)
        if (System.currentTimeMillis() - startedAt > 30 * 60 * 1000L) return null
        return prefs.getString("state", null)
    }

    private fun open(activity: Activity, page: String) {
        val uri = Uri.parse(page)
        try {
            CustomTabsIntent.Builder().setShowTitle(true).build().launchUrl(activity, uri)
        } catch (e: ActivityNotFoundException) {
            // No browser that does Custom Tabs: a plain browser still comes back the same way.
            try {
                activity.startActivity(Intent(Intent.ACTION_VIEW, uri).addCategory(Intent.CATEGORY_BROWSABLE))
            } catch (e: ActivityNotFoundException) {
                forget()
                throw SignInError.Sheet(-1)
            }
        }
    }
}
