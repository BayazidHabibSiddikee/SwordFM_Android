import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.swordfm.swordfm"
    compileSdk = 37
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.swordfm.swordfm"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // flutter_pty (terminal) ships native libs that require API 24+;
        // flutter.minSdkVersion may be lower, causing the terminal to fail.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // ---------------------------------------------------------------------------
    // Release signing — resolved from (in priority order):
    //   1. Environment variables SWORDFM_STORE_FILE / _STORE_PASS / _KEY_ALIAS / _KEY_PASS
    //      (used in CI; no secrets on disk)
    //   2. android/key.properties  (local builds; git-ignored, never committed)
    //
    // A release build WITHOUT release signing configured is a hard error: we must
    // never ship an APK signed with debug keys (Play rejects it, and the debug
    // keystore is public so anyone could forge an update).
    // ---------------------------------------------------------------------------
    val keyPropsFile = rootProject.file("key.properties")
    val keyProps = Properties()
    if (keyPropsFile.exists()) {
        keyPropsFile.inputStream().use { stream -> keyProps.load(stream) }
    }

    fun secret(envName: String, propName: String): String? =
        System.getenv(envName)?.takeIf { it.isNotBlank() }
            ?: keyProps.getProperty(propName)?.takeIf { it.isNotBlank() }

    val storeFile = secret("SWORDFM_STORE_FILE", "storeFile")
    val storePass = secret("SWORDFM_STORE_PASS", "storePassword")
    val keyAlias  = secret("SWORDFM_KEY_ALIAS", "keyAlias")
    val keyPass   = secret("SWORDFM_KEY_PASS", "keyPassword")
    val hasReleaseSigning = listOf(storeFile, storePass, keyAlias, keyPass).all { !it.isNullOrEmpty() }

    if (hasReleaseSigning) {
        signingConfigs {
            create("release") {
                this.storeFile     = file(storeFile!!)
                this.storePassword = storePass
                this.keyAlias      = keyAlias
                this.keyPassword   = keyPass
            }
        }
    }

    buildTypes {
        release {
            // R8 full-mode + resource shrinking — reduces APK size significantly.
            // Add any necessary keep-rules to android/app/proguard-rules.pro.
            isMinifyEnabled   = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )

            if (!hasReleaseSigning) {
                // Fail the release build loudly rather than silently signing with
                // debug keys. Run:  tool/setup_release_signing.sh
                throw GradleException(
                    "Release signing is not configured.\n" +
                    "  Set SWORDFM_STORE_FILE / SWORDFM_STORE_PASS / SWORDFM_KEY_ALIAS / SWORDFM_KEY_PASS, " +
                    "or create android/key.properties (see android/key.properties.example).\n" +
                    "  Refusing to sign a release build with the debug keystore."
                )
            }
            signingConfig = signingConfigs.getByName("release")
        }
    }

    // ---------------------------------------------------------------------------
    // ABI splits — ship per-architecture APKs instead of one universal APK that
    // bundles every native lib (media_kit/libmpv, tesseract, pdf plugins...).
    // Flutter still produces a universal APK via `flutter build apk --split-per-abi`.
    // ---------------------------------------------------------------------------
    splits {
        abi {
            isEnable = project.hasProperty("splitPerAbi")
            reset()
            include("armeabi-v7a", "arm64-v8a", "x86_64")
            isUniversalApk = true
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.media:media:1.6.0")
}

