plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing config.
//
// Resolution order, first match wins:
//   1. Env vars ANDROID_KEYSTORE_PATH / ANDROID_KEYSTORE_PASSWORD /
//      ANDROID_KEY_ALIAS / ANDROID_KEY_PASSWORD (matching the legacy
//      Dosbox-X-Android build.gradle, so the GitHub Actions secrets carry
//      over unchanged: ANDROID_KEYSTORE_BASE64 is decoded by the CI workflow
//      to a temp .jks and the path is exported).
//   2. `key.properties` next to this file -- a checked-out keystore + four
//      credentials, for local dev where the env vars aren't.
//
// Both keep the signing key for the existing `com.dosboxx.app` Play Store
// listing, so Retro-Dosbox ships as an in-place upgrade rather than a
// brand-new app. If neither source provides a keystore (the normal state
// for a fresh checkout / CI run that isn't signing), release falls back
// to the debug keystore and prints a one-line warning rather than
// failing the build -- otherwise `flutter build apk --debug` against a
// clean tree would refuse to run.
//
// No actual .jks is committed; `key.properties` and `*.jks` are gitignored.
import java.util.Properties

data class KeystoreConfig(
    val path: String,
    val storePassword: String,
    val keyAlias: String,
    val keyPassword: String,
)

fun resolveKeystore(): KeystoreConfig? {
    val envPath = System.getenv("ANDROID_KEYSTORE_PATH")
    val envStorePw = System.getenv("ANDROID_KEYSTORE_PASSWORD")
    val envAlias = System.getenv("ANDROID_KEY_ALIAS")
    val envKeyPw = System.getenv("ANDROID_KEY_PASSWORD")
    if (envPath != null && envStorePw != null && envAlias != null && envKeyPw != null) {
        logger.lifecycle("release: using keystore from ANDROID_KEYSTORE_PATH env var")
        return KeystoreConfig(envPath, envStorePw, envAlias, envKeyPw)
    }

    val propsFile = rootProject.file("key.properties")
    if (propsFile.exists()) {
        val p = Properties().apply { load(propsFile.inputStream()) }
        val path = p["storeFile"] as String?
        val storePw = p["storePassword"] as String?
        val alias = p["keyAlias"] as String?
        val keyPw = p["keyPassword"] as String?
        if (path != null && storePw != null && alias != null && keyPw != null) {
            logger.lifecycle("release: using keystore from ${propsFile.absolutePath}")
            return KeystoreConfig(path, storePw, alias, keyPw)
        }
    }

    logger.warn(
        "release: no ANDROID_KEYSTORE_* env vars and no key.properties; " +
            "falling back to the debug keystore. This build will not be " +
            "accepted by Play Console."
    )
    return null
}

val keystoreConfig = resolveKeystore()

// Floor for the Android version code. The predecessor app reached 5; 100
// leaves room for anything published from the old project before this one
// lands, while staying far below Play's int32 ceiling.
val DOSBOX_VERSION_CODE_BASE = 100

android {
    namespace = "com.crownpark.retrodosbox"
    // Pinned, not flutter.compileSdkVersion. The whole Retro-* family states
    // its SDK levels outright: a floating value takes whatever the Flutter
    // on the build machine happens to default to, which is how Play
    // compliance ends up depending on which laptop or runner did the build.
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
        // applicationId is intentionally `com.dosboxx.app`: this Flutter app
        // replaces the legacy Java app in place on Play Store. Existing users
        // receive it as an update, reviews and download counts carry over,
        // and the existing signing key keeps working for upgrades. The display
        // name is "Retro-Dosbox" (AndroidManifest label) and the Kotlin
        // namespace is "com.crownpark.retrodosbox" for code consistency --
        // applicationId and namespace are independent concepts.
        applicationId = "com.dosboxx.app"
        // 28 matches the Java app this replaces. The dynamic CPU core and the
        // storage model both assume a reasonably modern platform, and going
        // lower has no audience.
        minSdk = 28
        // Pinned, not inherited from the Flutter SDK.
        //
        // Play refuses updates to any app whose target is more than a year
        // behind the latest Android release - 36 or higher from 31 August
        // 2026. flutter.targetSdkVersion floats with whichever Flutter runs
        // the build, so an older SDK on a runner or another machine could drop
        // it under the bar without a line of this project changing. The app
        // this one replaces already targets 36; going backwards would be a
        // regression nobody asked for.
        targetSdk = 36
        // The Play listing for com.dosboxx.app holds version code 5, from the
        // Java app this one replaces. Play never accepts a code at or below
        // what is already published, and the pubspec restarted at 1, so the
        // build number is lifted clear of the old line rather than colliding
        // with it.
        versionCode = DOSBOX_VERSION_CODE_BASE + flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // Only the ABIs libdosboxcore is actually built for. Listing an
            // ABI with no .so produces an APK that installs and then fails at
            // dlopen, which is a much worse outcome than not shipping it.
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }
    // And again on the build types, which is what actually decides it.
    //
    // The Flutter Gradle Plugin clears ndk.abiFilters on every build type and
    // refills it from its own hardcoded list, which always includes
    // armeabi-v7a. AGP then UNIONS that with the defaultConfig filter above,
    // so defaultConfig alone can never subtract an ABI - and it did not: the
    // built APK carried an armeabi-v7a slice with libapp.so and libflutter.so
    // but no libdosboxcore.so and no libSDL2.so, because jniLibs only has
    // arm64-v8a and x86_64. That is exactly the install-then-dlopen-failure
    // the comment above warns about, shipped to every 32-bit device Play
    // would have served it to.
    //
    // This block runs after the plugin's apply(), so clearing here is what
    // decides the packaged set.
    buildTypes.configureEach {
        ndk {
            abiFilters.clear()
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    signingConfigs {
        create("release") {
            if (keystoreConfig != null) {
                storeFile = file(keystoreConfig.path)
                storePassword = keystoreConfig.storePassword
                keyAlias = keystoreConfig.keyAlias
                keyPassword = keystoreConfig.keyPassword
            }
        }
    }

    packaging {
        jniLibs {
            // The bridge and DOSBox-X open resources by path and dlopen at
            // runtime, which needs the libraries extracted on disk rather than
            // loaded from inside the APK.
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // R8 runs on release. Without proguard-rules.pro it strips the
            // SDL Java methods that libSDL2.so resolves by name at
            // JNI_OnLoad, and the app aborts before the first frame.
            proguardFiles(
                getDefaultProguardFile("proguard-android.txt"),
                "proguard-rules.pro",
            )
            signingConfig = if (keystoreConfig != null) {
                signingConfigs.getByName("release")
            } else {
                // Fallback for dev/CI: sign with the debug key so
                // `flutter run --release` still works on a fresh tree.
                // A build that ships without the release keystore is wrong;
                // the warning above is the explicit signal.
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}