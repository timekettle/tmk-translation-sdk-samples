# AndroidSample

独立 Android Studio sample，直接消费发布后的 `co.timekettle.translation:tmk-translation-sdk`，用于模拟外部集成场景。

## 特点

- 不依赖 SDK 源码 module
- 从 Maven 仓库解析已发布 SDK；GitHub Packages 用于兜底获取尚未发布到 Maven Central 的版本
- UI 与交互逻辑与内部 demo 基本一致

## 使用方式

1. 配置 SDK 版本  
   修改 [gradle.properties](./gradle.properties) 里的 `TMK_SDK_VERSION`。

   APK 的应用 ID 固定为 `co.timekettle.saas.sample`。鉴权服务为 App ID 登记的 `app_package_name` 必须是这个值。源码中的 `co.timekettle.translation.sample` 是 Kotlin/资源的编译命名空间，不是安装包名。

2. 配置 sample 鉴权参数  
   在 `~/.gradle/gradle.properties` 中设置：

   ```properties
   TMK_SAMPLE_APP_ID=your_app_id
   TMK_SAMPLE_APP_SECRET=your_app_secret
   ```

3. 在本地构建 APK：

   ```bash
   ./gradlew :app:assembleDebug
   ```

   已缓存全部依赖时，也可以使用 `./gradlew --offline :app:assembleDebug`。

4. 仅当所用 SDK 版本需要从 GitHub Packages 下载时，在 `~/.gradle/gradle.properties` 中配置访问凭据：

   ```properties
   gpr.user=your_github_username
   gpr.key=your_github_pat
   ```

   GitHub Packages 仓库是 `timekettle/tmk-translation-sdk-dist`。Gradle 在本地生成 APK，并按仓库顺序解析 SDK 依赖；当依赖需要从 GitHub Packages 获取时才需要凭据。Sauce Labs 使用构建出的 APK。

Sauce Labs 真机的在线收听单条测试及 HTTPS PCM 下载步骤见 [云测快速上手](saucelabs/README.md)。
