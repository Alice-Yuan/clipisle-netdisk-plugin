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
 private val prefs = context.getSharedPreferences("netdisk_secure", Context.MODE_PRIVATE)
 private fun key(): SecretKey {
  val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
  (store.getKey("netdisk", null) as? SecretKey)?.let { return it }
  return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
   init(KeyGenParameterSpec.Builder("netdisk", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
    .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
  }.generateKey()
 }
 @Synchronized fun read(name: String): String? {
  val raw = prefs.getString(name, null) ?: return null
  val bytes = Base64.decode(raw, Base64.NO_WRAP)
  val c = Cipher.getInstance("AES/GCM/NoPadding")
  c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0,12)))
  c.updateAAD(name.toByteArray())
  return String(c.doFinal(bytes.copyOfRange(12,bytes.size)), Charsets.UTF_8)
 }
 @Synchronized fun write(name: String, value: String?) {
  if (value == null) { check(prefs.edit().remove(name).commit()); return }
  require(value.toByteArray().size <= 256*1024)
  val c = Cipher.getInstance("AES/GCM/NoPadding"); c.init(Cipher.ENCRYPT_MODE,key()); c.updateAAD(name.toByteArray())
  val raw = Base64.encodeToString(c.iv+c.doFinal(value.toByteArray()), Base64.NO_WRAP)
  check(prefs.edit().putString(name,raw).commit())
 }
}
