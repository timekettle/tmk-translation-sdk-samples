plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt.android)
}

val sampleSdkVersion = providers.gradleProperty("TMK_SDK_VERSION").orElse("1.0.0").get()
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
    compileSdk {
        version = release(36)
    }

    defaultConfig {
        applicationId = "co.timekettle.translation.sample"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "1.0.0"

        ndk {
            abiFilters += listOf("arm64-v8a")
        }

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "TMK_SAMPLE_APP_ID", "\"$sampleAppId\"")
        buildConfigField("String", "TMK_SAMPLE_APP_SECRET", "\"$sampleAppSecret\"")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    applicationVariants.all {
        outputs.all {
            val apkOutput = this as com.android.build.gradle.internal.api.ApkVariantOutputImpl
            apkOutput.outputFileName = "tmk-translation-sdk-samples-${versionName ?: "1.0.0"}.apk"
        }
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_11)
    }
}

dependencies {
    implementation("co.timekettle.translation:tmk-translation-sdk:$sampleSdkVersion")

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.lifecycle.runtime.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.graphics)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material3)

    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    implementation(libs.hilt.navigation.compose)

    implementation(libs.voyager.navigator)
    implementation(libs.voyager.transitions)

    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.espresso.core)
    androidTestImplementation(platform(libs.androidx.compose.bom))
    androidTestImplementation(libs.androidx.compose.ui.test.junit4)
    debugImplementation(libs.androidx.compose.ui.tooling)
    debugImplementation(libs.androidx.compose.ui.test.manifest)
}
