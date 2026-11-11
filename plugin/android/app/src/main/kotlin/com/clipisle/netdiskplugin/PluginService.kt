package com.clipisle.netdiskplugin
import android.app.Service
import android.content.Intent
import android.os.*
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
class PluginService : Service() {
 private lateinit var engine: FlutterEngine
 private lateinit var channel: MethodChannel
 private val handler = Handler(Looper.getMainLooper())
 private val pending = mutableListOf<() -> Unit>()
 private var ready = false
 private var active = 0
 private val stopIdle = Runnable { stopSelf() }
 override fun onStartCommand(intent: Intent?,flags: Int,startId: Int): Int {
  handler.removeCallbacks(stopIdle); handler.postDelayed(stopIdle,30_000)
  return START_NOT_STICKY
 }
 override fun onUnbind(intent: Intent): Boolean {
  handler.postDelayed(stopIdle,30_000); return false
 }
 private val messenger = Messenger(object : Handler(Looper.getMainLooper()) {
  override fun handleMessage(msg: Message) {
   if (msg.what != 1 || msg.replyTo == null || !HostTrust.uidIsHost(this@PluginService,msg.sendingUid)) return
   val id = msg.data.getString("requestId") ?: return
   val method = msg.data.getString("method") ?: return
   val raw = msg.data.getString("arguments") ?: "{}"
   val reply = msg.replyTo
   fun respond(value: String) { try { reply.send(Message.obtain(null,2).apply { data=Bundle().apply { putString("requestId",id); putString("result",value) } }) } catch (_: Exception) {} }
   if (id.length > 256 || method.length > 128 || raw.length > 128*1024) { respond("{\"ok\":false,\"code\":\"INVALID_ARGUMENT\"}"); return }
   if (!HostTrust.isAuthorized(this@PluginService)) { respond("{\"ok\":true,\"requestUi\":{\"type\":\"launch\",\"action\":\"com.clipisle.plugin.NETDISK_AUTHORIZE\"}}"); return }
   if (active >= 12) { respond("{\"ok\":false,\"message\":\"插件正忙，请稍后重试\"}"); return }
   active++
   var completed = false
   var timeout: Runnable? = null
   fun finish(value: String) { if (!completed) { completed=true; active--; timeout?.let { handler.removeCallbacks(it) }; respond(if(value.toByteArray().size <= 480*1024) value else "{\"ok\":false,\"message\":\"文件列表过大\"}") } }
   timeout = Runnable {
    if(!completed) {
     val args = try { JSONObject(raw) } catch (_:Exception) { JSONObject() }
     val cancel = JSONObject().put("requestId",args.optString("requestId",id))
     if(ready) channel.invokeMethod("invoke",mapOf("method" to "cancelInput","arguments" to cancel.toString()))
     finish("{\"ok\":false,\"code\":\"TIMEOUT\"}")
    }
   }
   handler.postDelayed(timeout!!,110_000)
   val call = call@{
    if (completed) return@call
    channel.invokeMethod("invoke",mapOf("method" to method,"arguments" to JSONObject(raw).apply { if(!has("requestId")) put("requestId",id) }.toString()),object : MethodChannel.Result {
     override fun success(result: Any?) { finish(result as? String ?: "{\"ok\":false}") }
     override fun error(code: String,message: String?,details: Any?) { finish("{\"ok\":false,\"message\":\"插件操作失败\"}") }
     override fun notImplemented() { finish("{\"ok\":false,\"code\":\"NOT_IMPLEMENTED\"}") }
    })
   }
   if (ready) call() else pending.add(call)
  }
 })
 override fun onCreate() {
  super.onCreate()
  val store=SecureStore(this)
  engine=FlutterEngine(this)
  channel=MethodChannel(engine.dartExecutor.binaryMessenger,"com.clipisle.netdisk/runtime")
  channel.setMethodCallHandler { call,result ->
   try { when(call.method) {
    "ready" -> { ready=true; pending.toList().also { pending.clear() }.forEach { it() }; result.success(null) }
    "read" -> result.success(store.read(call.argument<String>("key")!!))
    "compareAndSetCredential" -> result.success(store.compareAndSet(
     call.argument<String>("key")!!,call.argument<String>("expected")!!,call.argument<String>("value")!!))
    "write" -> {
     val key=call.argument<String>("key")!!; val value=call.argument<String>("value")
     store.write(key,value)
     if(key.startsWith("credential.") && value==null) {
      // Web cookies belong only to this plugin. Other saved platform accounts
      // remain encrypted and usable; the next login starts with a clean browser.
      android.webkit.WebStorage.getInstance().deleteAllData()
      android.webkit.CookieManager.getInstance().removeAllCookies {
       android.webkit.CookieManager.getInstance().flush(); result.success(null)
      }
     } else result.success(null)
    }
    else -> result.notImplemented()
   } } catch (_: Exception) { result.error("STORAGE_ERROR","私密存储不可用",null) }
  }
  engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
 }
 override fun onBind(intent: Intent): IBinder { handler.removeCallbacks(stopIdle); return messenger.binder }
 override fun onDestroy() { pending.clear(); handler.removeCallbacksAndMessages(null); channel.setMethodCallHandler(null); engine.destroy(); super.onDestroy() }
}
