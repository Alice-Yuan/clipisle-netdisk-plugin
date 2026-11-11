package com.clipisle.netdiskplugin

import android.app.Activity
import android.app.AlertDialog
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Build
import java.security.MessageDigest

internal object HostTrust {
 private const val HOST = "com.clipisle.app"
 fun fingerprint(context: android.content.Context): String? = try {
  val certs = if (Build.VERSION.SDK_INT >= 28) {
   val pkg = context.packageManager.getPackageInfo(HOST, PackageManager.GET_SIGNING_CERTIFICATES)
   val signing = pkg.signingInfo ?: return null
   signing.apkContentsSigners
  } else {
   @Suppress("DEPRECATION")
   context.packageManager.getPackageInfo(HOST, PackageManager.GET_SIGNATURES).signatures
  } ?: return null
  if (certs.size != 1) return null
  MessageDigest.getInstance("SHA-256").digest(certs[0].toByteArray()).joinToString("") { "%02x".format(it) }
 } catch (_: Exception) { null }
 fun isAuthorized(context: android.content.Context): Boolean {
  val current = fingerprint(context) ?: return false
  return context.getSharedPreferences("plugin_trust", 0).getString("host_sha256", null) == current
 }
 fun uidIsHost(context: android.content.Context, uid: Int) = context.packageManager.getPackagesForUid(uid)?.contains(HOST) == true
}

class PluginAccessActivity : Activity() {
 private fun warmService() {
  // Starting from the visible, already trusted activity also works on OEMs
  // which reject a cross-package background bind. No download is started here.
  startService(android.content.Intent(this, PluginService::class.java))
 }

 override fun onCreate(state: Bundle?) {
  super.onCreate(state)
  if (callingPackage != "com.clipisle.app") { finish(); return }
  if (HostTrust.isAuthorized(this)) { warmService(); setResult(RESULT_OK); finish(); return }
  val fingerprint = HostTrust.fingerprint(this) ?: run { finish(); return }
  AlertDialog.Builder(this).setTitle(nativeText("授权 ClipIsle 访问网盘插件","Allow ClipIsle to use this plugin","ClipIsle に利用を許可","ClipIsle 플러그인 사용 허용"))
   .setMessage(nativeText("允许 ClipIsle 解析分享链接并获取下载地址？","Allow ClipIsle to parse shares and resolve downloads?","ClipIsle に共有リンクの解析とダウンロード取得を許可しますか？","ClipIsle이 공유 링크와 다운로드를 처리하도록 허용할까요？") + "\n\nSHA-256:\n$fingerprint")
   .setPositiveButton(nativeText("授权","Allow","許可","허용")) { _, _ ->
    if (HostTrust.fingerprint(this) == fingerprint && getSharedPreferences("plugin_trust", 0).edit().putString("host_sha256", fingerprint).commit()) { warmService(); setResult(RESULT_OK) }
    else setResult(RESULT_CANCELED)
    finish()
   }
   .setNegativeButton(nativeText("取消","Cancel","キャンセル","취소")) { _, _ -> setResult(RESULT_CANCELED); finish() }
   .setOnCancelListener { finish() }.show()
 }
}
