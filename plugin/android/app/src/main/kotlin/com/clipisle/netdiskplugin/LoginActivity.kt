package com.clipisle.netdiskplugin
import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.webkit.*
import android.widget.*
import org.json.JSONObject
class LoginActivity : Activity() {
 private lateinit var web: WebView
 private lateinit var status: TextView
 private var platform=""
 private lateinit var progress: ProgressBar
 private lateinit var retry: Button

 private fun capture(save: Boolean = false): Boolean {
  val host=if(platform=="baidu") "https://pan.baidu.com/" else "https://pan.quark.cn/"
  val raw=CookieManager.getInstance().getCookie(host) ?: return false
  val names=raw.split(';').filter { it.substringAfter('=',"").isNotBlank() }.map { it.trim().substringBefore('=') }
  val valid=if(platform=="baidu") "BDUSS" in names else "__puus" in names
  if(!valid) return false
  if(save) SecureStore(this).write("credential.$platform",raw)
  CookieManager.getInstance().flush()
  return true
 }
 override fun onCreate(state: Bundle?) {
  super.onCreate(state)
  if(callingPackage!="com.clipisle.app" || !HostTrust.isAuthorized(this)) { finish(); return }
  platform=intent.getStringExtra("platform") ?: ""
  if(platform !in setOf("baidu","quark")) { finish(); return }
  val root=LinearLayout(this).apply { orientation=LinearLayout.VERTICAL; setBackgroundColor(Color.rgb(248,245,239)); setPadding(12,32,12,8) }
  val bar=LinearLayout(this)
  bar.addView(Button(this).apply { text=nativeText("返回","Back","戻る","뒤로"); setOnClickListener { finish() } })
  status=TextView(this).apply { text=if(platform=="baidu") nativeText("百度网盘登录","Baidu sign-in","Baidu ログイン","Baidu 로그인") else nativeText("夸克网盘登录","Quark sign-in","Quark ログイン","Quark 로그인"); textSize=17f; gravity=android.view.Gravity.CENTER }
  bar.addView(status,LinearLayout.LayoutParams(0,64,1f))
  bar.addView(Button(this).apply { text=nativeText("完成","Done","完了","완료"); setOnClickListener { complete() } })
  root.addView(bar)
  web=WebView(this)
  web.settings.useWideViewPort=true; web.settings.loadWithOverviewMode=true
  web.settings.builtInZoomControls=true; web.settings.displayZoomControls=false
  web.settings.javaScriptEnabled=true; web.settings.domStorageEnabled=true
  web.settings.userAgentString=if(platform=="quark")
   "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
   else "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
  if(platform=="quark") {
   val widthDp=resources.displayMetrics.widthPixels/resources.displayMetrics.density
   web.setInitialScale((100*widthDp/1280f).toInt().coerceIn(20,100))
  }
  progress=ProgressBar(this,null,android.R.attr.progressBarStyleHorizontal).apply { max=100 }
  root.addView(progress,LinearLayout.LayoutParams(-1,6))
  retry=Button(this).apply {
   text=nativeText("页面加载失败，点击重试","Page failed to load. Retry","読み込めませんでした・再試行","페이지 로드 실패 · 다시 시도")
   visibility=android.view.View.GONE
   setOnClickListener { visibility=android.view.View.GONE; web.reload() }
  }
  root.addView(retry)
  web.webChromeClient=object:WebChromeClient() {
   override fun onProgressChanged(v:WebView,value:Int) { progress.progress=value; progress.visibility=if(value<100) android.view.View.VISIBLE else android.view.View.GONE }
  }
  web.settings.allowFileAccess=false; web.settings.allowContentAccess=false
  web.settings.mixedContentMode=WebSettings.MIXED_CONTENT_NEVER_ALLOW
  CookieManager.getInstance().setAcceptCookie(true)
  CookieManager.getInstance().setAcceptThirdPartyCookies(web,false)
  web.webViewClient=object: WebViewClient() {
   override fun onPageStarted(v:WebView,url:String,icon:android.graphics.Bitmap?) { retry.visibility=android.view.View.GONE; progress.visibility=android.view.View.VISIBLE }
   override fun onReceivedError(v:WebView,request:WebResourceRequest,error:WebResourceError) {
    if(request.isForMainFrame) { retry.visibility=android.view.View.VISIBLE; progress.visibility=android.view.View.GONE }
   }
   override fun onReceivedHttpError(v:WebView,request:WebResourceRequest,response:WebResourceResponse) {
    if(request.isForMainFrame && response.statusCode>=400) { retry.visibility=android.view.View.VISIBLE; progress.visibility=android.view.View.GONE }
   }
   override fun shouldOverrideUrlLoading(v:WebView,request:WebResourceRequest):Boolean {
    val u=request.url; val h=u.host ?: return true
    val roots=if(platform=="baidu") listOf("baidu.com") else listOf("quark.cn","uc.cn")
    return u.scheme!="https" || roots.none { h==it || h.endsWith(".$it") }
   }
   override fun onPageFinished(v:WebView,url:String) { try {
    if(platform=="quark") {
     val manager=CookieManager.getInstance()
     fun hasLogin(origin:String)=(manager.getCookie(origin) ?: "").split(';').any { it.trim().startsWith("__puus=") && it.substringAfter('=').isNotBlank() }
     android.util.Log.i("NetdiskLogin","quark pageFinished panLogin=${hasLogin("https://pan.quark.cn/")} apiLogin=${hasLogin("https://drive-pc.quark.cn/")}")
    }
    if(capture()) status.text=nativeText("已登录，点击完成","Signed in. Tap Done","ログイン済み・完了を押す","로그인됨 · 완료를 누르세요") } catch (_:Exception) {} }
  }
  root.addView(web,LinearLayout.LayoutParams(-1,0,1f)); setContentView(root)
  val requested=intent.getStringExtra("url")?.let { Uri.parse(it) }
  val share = requested?.takeIf { platform=="baidu" && it.scheme=="https" && it.host=="pan.baidu.com" && it.userInfo==null && it.port == -1 && (it.path?.startsWith("/s/")==true || it.path=="/share/init") }
  web.loadUrl(share?.toString() ?: if(platform=="baidu") "https://pan.baidu.com/disk/main#/index" else "https://pan.quark.cn/?fr=pc&platform=pc")
 }
 private fun complete() { try {
  if(!capture(true)) { Toast.makeText(this,nativeText("请先完成网页登录","Complete sign-in first","先にログインしてください","먼저 로그인하세요"),Toast.LENGTH_SHORT).show(); return }
  setResult(RESULT_OK,Intent().putExtra("result",JSONObject().put("ok",true).put("loginComplete",true).toString())); finish()
 } catch (_:Exception) { Toast.makeText(this,nativeText("保存登录状态失败，请重试","Could not save sign-in. Retry.","ログイン状態を保存できませんでした","로그인을 저장하지 못했습니다"),Toast.LENGTH_SHORT).show() } }
 override fun onDestroy() { if(::web.isInitialized) { web.stopLoading(); web.destroy() }; super.onDestroy() }
}
