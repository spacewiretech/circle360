plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.loc_360"
    // Pinned above flutter.compileSdkVersion (36) because flutter_secure_storage's AAR metadata
    // requires 37 or later, and the build fails outright without it. Compiling against a newer
    // SDK is backward compatible and independent of targetSdk, which still follows Flutter.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.loc_360"
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
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Fused location provider: the 10s interval and batching are handled by Play Services.
    implementation("com.google.android.gms:play-services-location:21.3.0")
    // ContextCompat / ActivityCompat helpers used by MainActivity and BootReceiver.
    implementation("androidx.core:core-ktx:1.13.1")
}

flutter {
    source = "../.."
}
