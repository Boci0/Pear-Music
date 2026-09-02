import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing configuration, loaded from the gitignored key.properties.
// Present on local dev machines and reconstructed in CI from GitHub Secrets.
// If key.properties (or its keystore) is missing we fall back to debug signing
// so local builds and `flutter run --release` still work.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
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

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Use the dedicated release keystore when available so in-app
            // updates can overwrite the previously published APK. Fall back
            // to debug signing only for local dev when key.properties is absent.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

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

dependencies {
    implementation("androidx.media:media:1.7.0")
}

flutter {
    source = "../.."
}
