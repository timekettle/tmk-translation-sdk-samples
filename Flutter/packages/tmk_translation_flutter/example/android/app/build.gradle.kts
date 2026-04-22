plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "co.timekettle.translation.sample"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "co.timekettle.translation.sample"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28
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
}

flutter {
    source = "../.."
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}
