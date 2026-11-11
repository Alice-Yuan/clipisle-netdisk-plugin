package com.clipisle.netdiskplugin

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class SecureStore(context: Context) {
    // All instances (Activity + Service) must serialize against the same lock.
    private companion object { val lock = Any() }
    private val prefs = context.getSharedPreferences("netdisk_secure", Context.MODE_PRIVATE)

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("netdisk", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("netdisk", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }

    fun read(name: String): String? = synchronized(lock) { readLocked(name) }
    private fun readLocked(name: String): String? {
        val raw = prefs.getString(name, null) ?: return null
        val bytes = Base64.decode(raw, Base64.NO_WRAP)
        require(bytes.size >= 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD(name.toByteArray(Charsets.UTF_8))
        return String(cipher.doFinal(bytes.copyOfRange(12, bytes.size)), Charsets.UTF_8)
    }

    fun write(name: String, value: String?) = synchronized(lock) { writeLocked(name, value) }
    private fun writeLocked(name: String, value: String?) {
        if (value == null) { check(prefs.edit().remove(name).commit()); return }
        val bytes = value.toByteArray(Charsets.UTF_8)
        require(bytes.size <= 256 * 1024)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(name.toByteArray(Charsets.UTF_8))
        val encrypted = Base64.encodeToString(cipher.iv + cipher.doFinal(bytes), Base64.NO_WRAP)
        check(prefs.edit().putString(name, encrypted).commit())
    }

    fun compareAndSet(name: String, expected: String, value: String): Boolean = synchronized(lock) {
        require(name == "credential.quark" || name == "credential.baidu")
        if (readLocked(name) != expected) return@synchronized false
        writeLocked(name, value)
        true
    }
}
