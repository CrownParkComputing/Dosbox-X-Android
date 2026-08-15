plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.dosboxx.dosboxx_launcher"
    // Pinned rather than inherited: Play compliance is checked against these
    // numbers, so they are stated here where a person can read them.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.dosboxx.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // The store app's floor, kept deliberately: the native core is built
        // against a modern API and 64-bit/x86_64 only. Letting Flutter widen
        // this would offer the app to devices the emulator cannot run on.
        minSdk = 28
        targetSdk = 36
        versionCode = flutter.versionCode
        // Only the ABIs we ship libmain.so for. Without this the bundle also
        // carries an armeabi-v7a variant holding Flutter but no emulator.
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            // The store key, exactly as the old module took it: from the
            // environment, never committed. Same key = the update lands on
            // the existing listing and keeps every user's game library.
            val ksPath = System.getenv("ANDROID_KEYSTORE_PATH")
            val ksPass = System.getenv("ANDROID_KEYSTORE_PASSWORD")
            val alias = System.getenv("ANDROID_KEY_ALIAS")
            val keyPass = System.getenv("ANDROID_KEY_PASSWORD")
            if (ksPath != null && ksPass != null && alias != null && keyPass != null) {
                storeFile = file(ksPath)
                storePassword = ksPass
                keyAlias = alias
                keyPassword = keyPass
            }
        }
    }

    buildTypes {
        debug {
            // Rides alongside the Play Store install instead of fighting its
            // version code and signature - and, more to the point, instead of
            // requiring an uninstall that would erase the store app's game
            // library. Test data lives in the .test app's own sandbox.
            applicationIdSuffix = ".test"
        }
        release {
            // Signed with the store key when the environment supplies it;
            // otherwise the bundle comes out unsigned rather than silently
            // debug-signed, which Play would reject at upload with a
            // confusing error.
            if (System.getenv("ANDROID_KEYSTORE_PATH") != null) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

flutter {
    source = "../.."
}
