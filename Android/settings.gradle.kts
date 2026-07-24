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

    repositories {
        google()
        mavenCentral()
        maven(url = "https://maven.aliyun.com/repository/public")
        // ft-sdk / ft-native 是 tmk-translation-sdk 的传递依赖，仅发布在观测云私有仓库
        maven(url = "https://mvnrepo.jiagouyun.com/repository/maven-releases")
        mavenLocal()
    }
}

rootProject.name = "TmkTranslationAndroidSample"
include(":app")
