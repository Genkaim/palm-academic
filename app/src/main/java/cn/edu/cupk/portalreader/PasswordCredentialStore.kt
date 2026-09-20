package cn.edu.cupk.portalreader

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class SavedPasswordCredential(val username: String, val password: String)

/** Stores an optional remembered password encrypted by a non-exportable Android Keystore key. */
object PasswordCredentialStore {
    private const val PREFS = "remembered_password"
    private const val KEY_PAYLOAD_LEGACY = "encrypted_payload"
    private const val KEY_PAYLOAD_PREFIX = "encrypted_payload_"
    private const val KEY_ALIAS = "palm_academic_password_v1"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val IV_SIZE = 12

    fun load(
        context: Context,
        schoolId: String = SchoolAdapterRepository.activeSchoolId()
    ): SavedPasswordCredential? {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val payloadKey = payloadKey(schoolId)
        val encoded = preferences.getString(payloadKey, null)
            ?: preferences.getString(KEY_PAYLOAD_LEGACY, null)?.takeIf { schoolId == "cupk" }
            ?: return null
        return runCatching {
            val combined = Base64.decode(encoded, Base64.NO_WRAP)
            require(combined.size > IV_SIZE)
            val cipher = Cipher.getInstance(TRANSFORMATION).apply {
                init(
                    Cipher.DECRYPT_MODE,
                    getOrCreateKey(),
                    GCMParameterSpec(128, combined.copyOfRange(0, IV_SIZE))
                )
            }
            val json = JSONObject(
                String(cipher.doFinal(combined.copyOfRange(IV_SIZE, combined.size)), Charsets.UTF_8)
            )
            SavedPasswordCredential(
                username = json.getString("username"),
                password = json.getString("password")
            ).takeIf { it.username.isNotBlank() && it.password.isNotBlank() }
        }.getOrElse {
            clear(context, schoolId)
            null
        }
    }

    fun save(
        context: Context,
        username: String,
        password: String,
        schoolId: String = SchoolAdapterRepository.activeSchoolId()
    ) {
        require(username.isNotBlank() && password.isNotBlank())
        val plaintext = JSONObject()
            .put("username", username.trim())
            .put("password", password)
            .toString()
            .toByteArray(Charsets.UTF_8)
        val cipher = Cipher.getInstance(TRANSFORMATION).apply {
            init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        }
        val ciphertext = cipher.doFinal(plaintext)
        val combined = cipher.iv + ciphertext
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(payloadKey(schoolId), Base64.encodeToString(combined, Base64.NO_WRAP))
            .remove(KEY_PAYLOAD_LEGACY)
            .commit()
    }

    fun clear(context: Context, schoolId: String = SchoolAdapterRepository.activeSchoolId()) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(payloadKey(schoolId))
            .run { if (schoolId == "cupk") remove(KEY_PAYLOAD_LEGACY) else this }
            .commit()
    }

    private fun payloadKey(schoolId: String) = "$KEY_PAYLOAD_PREFIX$schoolId"

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
            init(
                KeyGenParameterSpec.Builder(
                    KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
                )
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build()
            )
            generateKey()
        }
    }
}
