plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.peerm.peerm_app"
    // permission_handler_android (notification permission) requires 37.
    // gradle.properties keeps flutter.compileSdkVersion in sync.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.peerm.peerm_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

            // R8 minification is on for release. Keep the classes that
            // youtubedl-android / commons-compress need at runtime (see
            // proguard-rules.pro) so "Add from link" downloads don't crash.
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    packaging {
        jniLibs {
            // youtubedl-android needs its native libs extracted at install
            // time (it unzips libpython/ffmpeg at runtime), so use legacy
            // packaging instead of uncompressed-in-APK.
            useLegacyPackaging = true
            // libpython.zip.so / libffmpeg.zip.so are ZIP archives with a .so
            // name; llvm-strip can't parse them, so never try to strip them.
            doNotStrip += "**/libffmpeg.zip.so"
            doNotStrip += "**/libpython.zip.so"
        }
        resources {
            excludes += "META-INF/proguard/androidx-*.pro"
        }
    }

    lint {
        checkReleaseBuilds = false
        disable += "MissingDimensionActivityCreator"
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
