pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
        maven(url = "https://maven.aliyun.com/repository/public")
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)

    val githubPackagesOwner = providers.gradleProperty("TMK_GITHUB_PACKAGES_OWNER")
        .orElse("timekettle")
        .get()
    val githubPackagesRepo = providers.gradleProperty("TMK_GITHUB_PACKAGES_REPOSITORY")
        .orElse("tmk-translation-sdk")
        .get()
    val githubPackagesUser = providers.gradleProperty("gpr.user")
        .orElse(providers.environmentVariable("GPR_USER"))
        .orElse(providers.environmentVariable("GITHUB_ACTOR"))
    val githubPackagesToken = providers.gradleProperty("gpr.key")
        .orElse(providers.environmentVariable("GPR_KEY"))
        .orElse(providers.environmentVariable("GH_ACCESS_TOKEN"))

    repositories {
        mavenLocal()
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
        maven {
            name = "GitHubPackagesTmkTranslationSdkDist"
            url = uri("https://maven.pkg.github.com/$githubPackagesOwner/tmk-translation-sdk-dist")
            credentials {
                username = githubPackagesUser.orNull ?: ""
                password = githubPackagesToken.orNull ?: ""
            }
        }
    }
}

rootProject.name = "TmkTranslationAndroidSample"
include(":app")
