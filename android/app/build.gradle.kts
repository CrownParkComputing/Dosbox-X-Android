plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.crownparkcomputing.retrodos"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.crownparkcomputing.retrodos"
        // 28: bionic gained iconv_open there, and DOSBox-X needs it.
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
        ndk {
            // Only the ABI the core has actually been built for. Listing more
            // ships an APK that installs and then fails to load a library.
            abiFilters += "arm64-v8a"
        }
    }

    // The core is a prebuilt .so from android/build-core.sh, not something
    // Gradle compiles; it just gets packaged.
    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")

    packaging {
        jniLibs {
            // 18 MB of emulator does not benefit from being compressed in the
            // APK and then decompressed at load.
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
        debug {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    // SDL3's own Java glue, produced by the SDL3 Android build.
    implementation(files("libs/SDL3.jar"))

    // DocumentFile is how a SAF tree is walked; activity gives us the
    // ActivityResultLauncher the folder picker needs.
    implementation("androidx.documentfile:documentfile:1.0.1")
    implementation("androidx.activity:activity-ktx:1.9.3")
}
