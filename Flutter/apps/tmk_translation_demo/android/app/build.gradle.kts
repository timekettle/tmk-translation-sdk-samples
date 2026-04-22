plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val sampleAppId = providers.environmentVariable("TMK_SAMPLE_APP_ID")
    .orElse(providers.gradleProperty("TMK_SAMPLE_APP_ID"))
    .orElse("")
    .get()
val sampleAppSecret = providers.environmentVariable("TMK_SAMPLE_APP_SECRET")
    .orElse(providers.gradleProperty("TMK_SAMPLE_APP_SECRET"))
    .orElse("")
    .get()

android {
    namespace = "co.timekettle.translation.sample"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "co.timekettle.translation.sample"
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["tmkSampleAppId"] = sampleAppId
        manifestPlaceholders["tmkSampleAppSecret"] = sampleAppSecret
        buildConfigField("String", "TMK_SAMPLE_APP_ID", "\"$sampleAppId\"")
        buildConfigField("String", "TMK_SAMPLE_APP_SECRET", "\"$sampleAppSecret\"")
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        buildConfig = true
    }
}

flutter {
    source = "../.."
}
