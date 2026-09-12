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
    // Release signing — driven by environment variables so no secrets land in VCS.
    // Set these in CI or your local ~/.gradle/gradle.properties (never commit them):
    //
    //   SWORDFM_STORE_FILE    absolute path to the release .jks / .keystore
    //   SWORDFM_STORE_PASS    keystore password
    //   SWORDFM_KEY_ALIAS     key alias inside the keystore
    //   SWORDFM_KEY_PASS      key password
    //
    // TODO: create a release keystore, set the four env-vars in CI, and remove
    //       the signingConfig fallback to "debug" in the release buildType below.
    // ---------------------------------------------------------------------------
    val storeFile   = System.getenv("SWORDFM_STORE_FILE")
    val storePass   = System.getenv("SWORDFM_STORE_PASS")
    val keyAlias    = System.getenv("SWORDFM_KEY_ALIAS")
    val keyPass     = System.getenv("SWORDFM_KEY_PASS")
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
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                // TODO: replace with the release signingConfig above before publishing.
                // Falling back to debug keys — NOT suitable for Play Store submission.
                signingConfigs.getByName("debug")
            }
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
