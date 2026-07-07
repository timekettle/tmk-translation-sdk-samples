# Project Discovery Checklist

在执行任何修改前，收集以下信息。

## 仓库基础

- [ ] 组织/仓库名称
- [ ] 默认分支名称
- [ ] 总 commit 数
- [ ] 是否有 Git Tag（列出最近 5 个）
- [ ] 是否有 GitHub Release（列出最近 3 个）
- [ ] 仓库是否为私有
- [ ] 是否为组织仓库（影响 PAT 审批）

## CI/CD 现状

- [ ] `.github/workflows/` 是否存在
- [ ] 已有哪些 Workflow（列出文件名和触发条件）
- [ ] 是否已有 Release 自动化方案
  - [ ] release-please（检查 `release-please-config.json` / `.release-please-manifest.json`）
  - [ ] semantic-release（检查 `.releaserc*` / `release.config.*`）
  - [ ] 自定义脚本
  - [ ] 无
- [ ] 是否有 CHANGELOG.md
- [ ] 是否有 `.github/CODEOWNERS`
- [ ] 已有 Workflow 的 permissions 配置

## 项目类型检测

- [ ] 是否为 Flutter 项目（存在 `pubspec.yaml`）
- [ ] 是否为 Node.js 项目（存在 `package.json`）
- [ ] 是否为 Java/Kotlin 项目（存在 `build.gradle*`）
- [ ] 是否为 Monorepo（多个 pubspec.yaml / package.json）

## Flutter 项目详情（如适用）

- [ ] Flutter 工程路径（pubspec.yaml 所在目录）
- [ ] App name（pubspec.yaml 中 `name` 字段）
- [ ] Dart SDK 版本约束
- [ ] Flutter SDK 版本约束
- [ ] 支持的平台（android/ ios/ web/ macos/ linux/ windows/）
- [ ] 是否有 path dependency
- [ ] Path dependency 列表及路径

## Android 构建详情（如适用）

- [ ] AGP 版本
- [ ] Gradle 版本（wrapper）
- [ ] Java 版本要求
- [ ] 签名配置（debug / release keystore / 无）
- [ ] `key.properties` 是否存在
- [ ] build.gradle 中 release signingConfig 配置
- [ ] applicationId / namespace

## 已有构建配置

- [ ] 是否已有 Build Workflow
- [ ] 构建产物类型（APK / AAB / IPA）
- [ ] 产物上传方式（Release Assets / Artifact / 外部存储）
- [ ] 是否有缓存配置
- [ ] 是否有矩阵构建（多平台）

## Secrets 和权限

- [ ] 已配置的 Repository Secrets 列表
- [ ] 是否有 RELEASE_TOKEN 或类似 PAT
- [ ] Actions workflow permissions 设置（read / write）
- [ ] 是否允许 Actions 创建 PR

## 命令参考

```bash
# 默认分支
git remote show origin | sed -n '/HEAD branch/s/.*: //p'

# Tag 列表
git tag -l | sort -V | tail -10

# Release 列表
gh release list --limit 5

# Commit 数量
git rev-list --count HEAD

# 已有 workflow
find .github/workflows -type f 2>/dev/null

# Release Please 配置
find . -maxdepth 1 -name "*release-please*" -o -name ".release-please*" 2>/dev/null

# Flutter pubspec 位置
find . -name "pubspec.yaml" -not -path "*/.*" -not -path "*/build/*"

# AGP 版本
grep -r "com.android.application.*version" --include="*.gradle*" 2>/dev/null

# Gradle wrapper 版本
cat */android/gradle/wrapper/gradle-wrapper.properties 2>/dev/null | grep distributionUrl
```
