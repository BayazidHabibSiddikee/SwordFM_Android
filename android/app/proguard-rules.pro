# SwordFM ProGuard / R8 rules
# ---------------------------------------------------------------------------
# Flutter
# ---------------------------------------------------------------------------
# Flutter's embedding and method channels must not be renamed/removed.
-keep class io.flutter.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.**

# ---------------------------------------------------------------------------
# audio_service / just_audio
# ---------------------------------------------------------------------------
-keep class com.ryanheise.** { *; }
-dontwarn com.ryanheise.**

# ---------------------------------------------------------------------------
# media_kit / libmpv JNI
# ---------------------------------------------------------------------------
-keep class media.kit.** { *; }
-dontwarn media.kit.**

# ---------------------------------------------------------------------------
# Firebase (google-services plugin injects these, but keep explicit)
# ---------------------------------------------------------------------------
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**
-keep class com.google.android.gms.** { *; }
-dontwarn com.google.android.gms.**

# ---------------------------------------------------------------------------
# OkHttp / Retrofit (used by cloud storage services)
# ---------------------------------------------------------------------------
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }

# ---------------------------------------------------------------------------
# Kotlin coroutines
# ---------------------------------------------------------------------------
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-dontwarn kotlinx.coroutines.**

# ---------------------------------------------------------------------------
# SwordFM MainActivity (Bluetooth RFCOMM, method channels)
# ---------------------------------------------------------------------------
-keep class com.swordfm.swordfm.MainActivity { *; }
-keep class com.swordfm.swordfm.InstallReceiver { *; }

# ---------------------------------------------------------------------------
# Suppress warnings for missing classes in optional/platform deps
# ---------------------------------------------------------------------------
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
