import java.util.Properties
plugins {
 id("com.android.application")
 id("dev.flutter.flutter-gradle-plugin")
}
val keys = Properties()
val keysFile = rootProject.file("key.properties")
if (keysFile.isFile) keysFile.inputStream().use { keys.load(it) }
android {
 namespace = "com.clipisle.netdiskplugin"
 compileSdk = flutter.compileSdkVersion
 ndkVersion = flutter.ndkVersion
 compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
 defaultConfig {
  applicationId = "com.clipisle.netdiskplugin"
  minSdk = 26
  targetSdk = flutter.targetSdkVersion
  versionCode = flutter.versionCode
  versionName = flutter.versionName
 }
 signingConfigs {
  if (keysFile.isFile) create("release") {
   keyAlias = keys.getProperty("keyAlias"); keyPassword = keys.getProperty("keyPassword")
   storeFile = file(keys.getProperty("storeFile")); storePassword = keys.getProperty("storePassword")
  }
 }
 buildTypes { release { signingConfig = signingConfigs.findByName("release") } }
}
flutter { source = "../.." }
