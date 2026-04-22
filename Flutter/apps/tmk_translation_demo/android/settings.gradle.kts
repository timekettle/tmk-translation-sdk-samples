pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
        maven(url = "https://maven.aliyun.com/repository/public")
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.PREFER_PROJECT)

    val githubPackagesOwner = providers.gradleProperty("TMK_GITHUB_PACKAGES_OWNER")
        .orElse("timekettle")
        .get()
    val githubPackagesRepo = providers.gradleProperty("TMK_GITHUB_PACKAGES_REPOSITORY")
        .orElse("tmk-translation-sdk-dist")
        .get()
    val githubPackagesUser = providers.gradleProperty("gpr.user")
        .orElse(providers.environmentVariable("GPR_USER"))
        .orElse(providers.environmentVariable("GITHUB_ACTOR"))
    val githubPackagesToken = providers.gradleProperty("gpr.key")
        .orElse(providers.environmentVariable("GPR_KEY"))
        .orElse(providers.environmentVariable("GH_ACCESS_TOKEN"))

    repositories {
        google()
        mavenCentral()
        maven(url = "https://maven.aliyun.com/repository/public")
        maven(url = "https://mvnrepo.jiagouyun.com/repository/maven-releases")
        maven {
            name = "GitHubPackagesTmkTranslationSdk"
            url = uri("https://maven.pkg.github.com/$githubPackagesOwner/$githubPackagesRepo")
            credentials {
                username = githubPackagesUser.orNull ?: ""
                password = githubPackagesToken.orNull ?: ""
            }
        }
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}

include(":app")
