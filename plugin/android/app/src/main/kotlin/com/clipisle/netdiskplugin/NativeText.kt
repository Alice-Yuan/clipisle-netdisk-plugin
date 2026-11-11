package com.clipisle.netdiskplugin
internal fun nativeText(zh:String,en:String,ja:String,ko:String):String = when(java.util.Locale.getDefault().language) {
 "en" -> en; "ja" -> ja; "ko" -> ko; else -> zh
}
