import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Versions are declared in settings.gradle.kts. Both must come after the Flutter plugin:
    // they attach to the variants it configures, and applied earlier they find none.
    id("com.google.gms.google-services")
    id("com.google.firebase.crashlytics")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")

if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// Facebook Ads conversion reporting.
//
// Neither value is a secret — both ship inside every installed app, and the App ID is visible in
// any ad the campaign runs — but they are per-environment, so they follow key.properties above
// rather than being committed. `facebook.properties.example` is the template.
//
// A missing or blank file is a supported state, not an error. It flips AutoInitEnabled to false,
// the SDK never initialises, and the app behaves exactly as it did before Facebook existed. That
// gate is load-bearing: an empty `com.facebook.sdk.ApplicationId` still reaches the SDK's
// initialising ContentProvider on launch, and it throws there — before the first frame, on a
// fresh clone, for a feature the developer may not even be working on.
val facebookProperties = Properties()
val facebookPropertiesFile = rootProject.file("facebook.properties")

if (facebookPropertiesFile.exists()) {
    facebookProperties.load(FileInputStream(facebookPropertiesFile))
}

val facebookAppId = (facebookProperties["appId"] as String? ?: "").trim()
val facebookClientToken = (facebookProperties["clientToken"] as String? ?: "").trim()
val facebookConfigured = facebookAppId.isNotEmpty() && facebookClientToken.isNotEmpty()

android {
    namespace = "com.spacewire.circle360"
    // Pinned above flutter.compileSdkVersion (36) because flutter_secure_storage's AAR metadata
    // requires 37 or later, and the build fails outright without it. Compiling against a newer
    // SDK is backward compatible and independent of targetSdk, which still follows Flutter.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        // Off by default from AGP 9, which this project is on. The Facebook App ID and Client
        // Token below are generated rather than checked in, and generating them is what keeps the
        // credentials in one place.
        resValues = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.spacewire.circle360"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Generated rather than checked in as res/values/strings.xml, so the credentials live in
        // exactly one place. String resources rather than raw manifest values because an App ID
        // is all digits: `android:value="2559…"` is parsed as an integer and overflows, which is
        // the classic way this integration fails silently.
        resValue("string", "facebook_app_id", facebookAppId)
        resValue("string", "facebook_client_token", facebookClientToken)

        // Off unless both credentials are present — see the note above facebookProperties.
        manifestPlaceholders["facebookAutoInit"] = facebookConfigured.toString()
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
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
    // Reads the campaign referrer the Play link carried, which is what decides whether a device
    // runs Circle360 or SunioMax. See InstallReferrer.kt.
    implementation("com.android.installreferrer:installreferrer:2.2")
}

flutter {
    source = "../.."
}
