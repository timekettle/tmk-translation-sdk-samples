# AndroidSample

独立 Android Studio sample，直接消费发布后的 `co.timekettle.translation:tmk-translation-sdk`，用于模拟外部集成场景。

## 特点

- 不依赖仓库内 `Android/libraryTranslation` 源码 module
- 优先从 `mavenLocal()` 解析 SDK，方便本地联调
- 也支持从 GitHub Packages 解析已发布版本
- UI 与交互逻辑大体拷贝自 `Android/app`

## 使用方式

1. 配置 SDK 版本  
   修改 [gradle.properties](./gradle.properties) 里的 `TMK_SDK_VERSION`。

2. 配置 sample 鉴权参数  
   在 `~/.gradle/gradle.properties` 或 `AndroidSample/gradle.properties` 中设置：

   ```properties
   TMK_SAMPLE_APP_ID=your_app_id
   TMK_SAMPLE_APP_SECRET=your_app_secret
   ```

3. 如果通过 GitHub Packages 拉取 SDK，再配置：

   ```properties
   gpr.user=your_github_username
   gpr.key=your_github_pat
   ```

4. 如果本地联调 SDK，可先把主库发布到本地 Maven：

   ```bash
   cd ../Android
   ./gradlew :libraryTranslation:publishMavenPublicationToMavenLocal
   ```

5. 构建 sample：

   ```bash
   cd ../AndroidSample
   ./gradlew :app:assembleDebug
   ```

