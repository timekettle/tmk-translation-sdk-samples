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
        // GitHub Packages 作为兜底仓库（低于 mavenCentral），
        // 仅用于解析尚未发布到 Maven Central 的预发布版本（rc/beta 等）。
        // 正式版优先从 mavenCentral 获取，避免 GitHub Packages 的不完整包覆盖正式版。
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

rootProject.name = "TmkTranslationAndroidSample"
include(":app")
