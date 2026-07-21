import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 读取 local.properties 中的本地配置
val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.inputStream().use { localProperties.load(it) }
}

val sampleAppId = providers.environmentVariable("TMK_SAMPLE_APP_ID")
    .orElse(providers.gradleProperty("TMK_SAMPLE_APP_ID"))
    .orElse(localProperties.getProperty("TMK_SAMPLE_APP_ID") ?: "")
    .get()
val sampleAppSecret = providers.environmentVariable("TMK_SAMPLE_APP_SECRET")
    .orElse(providers.gradleProperty("TMK_SAMPLE_APP_SECRET"))
    .orElse(localProperties.getProperty("TMK_SAMPLE_APP_SECRET") ?: "")
    .get()

android {
    namespace = "co.timekettle.saas.sample"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "co.timekettle.saas.sample"
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
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    applicationVariants.all {
        val variantTaskName = name.replaceFirstChar { character ->
            if (character.isLowerCase()) {
                character.titlecase()
            } else {
                character.toString()
            }
        }
        val artifactName = "tmk-translation-sdk-samples-${versionName ?: "1.0.0"}.apk"
        val compatibilityArtifactName = "app-$name.apk"

        outputs.all {
            val apkOutput = this as com.android.build.gradle.internal.api.ApkVariantOutputImpl
            apkOutput.outputFileName = artifactName
        }

        val syncNamedFlutterApk = tasks.register("sync${variantTaskName}NamedFlutterApk") {
            doLast {
                copy {
                    from(layout.buildDirectory.file("outputs/apk/$dirName/$artifactName"))
                    into(layout.buildDirectory.dir("outputs/flutter-apk"))
                }
                copy {
                    from(layout.buildDirectory.file("outputs/apk/$dirName/$artifactName"))
                    into(layout.buildDirectory.dir("outputs/flutter-apk"))
                    rename { compatibilityArtifactName }
                }
            }
        }

        tasks.named("assemble$variantTaskName").configure {
            finalizedBy(syncNamedFlutterApk)
        }
    }

    buildFeatures {
        buildConfig = true
    }
}

flutter {
    source = "../.."
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}
