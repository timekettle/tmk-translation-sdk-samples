# AndroidSample

独立 Android Studio sample，直接消费发布后的 `co.timekettle.translation:tmk-translation-sdk`，用于模拟外部集成场景。

## 特点

- 不依赖 SDK 源码 module
- 默认从 GitHub Packages 解析已发布版本
- UI 与交互逻辑与内部 demo 基本一致

## 使用方式

1. 配置 SDK 版本  
   修改 [gradle.properties](./gradle.properties) 里的 `TMK_SDK_VERSION`。

2. 配置 sample 鉴权参数  
   在 `~/.gradle/gradle.properties` 中设置：

   ```properties
   TMK_SAMPLE_APP_ID=your_app_id
   TMK_SAMPLE_APP_SECRET=your_app_secret
   ```

3. 配置 GitHub Packages 访问凭据：

   ```properties
   gpr.user=your_github_username
   gpr.key=your_github_pat
   ```

4. 默认会从 `timekettle/tmk-translation-sdk-dist` 对应的 GitHub Packages Maven 仓库解析 `co.timekettle.translation:tmk-translation-sdk`。

5. 构建 sample：

   ```bash
   ./gradlew :app:assembleDebug
   ```
