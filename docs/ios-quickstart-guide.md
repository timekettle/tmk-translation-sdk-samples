# iOS 构建发布配置完成 - 快速启动指南

## ✅ 已完成的工作

### 📂 创建的文件

```
Flutter/apps/tmk_translation_demo/ios/
├── Gemfile                          ✅ Ruby 依赖配置
└── fastlane/
    ├── Fastfile                     ✅ Fastlane 构建脚本
    ├── Matchfile                    ✅ Match 证书配置
    └── Appfile                      ✅ App 基本信息

scripts/
└── upload_to_pgyer.py               ✅ 蒲公英上传脚本（基于 docs/upload_apk.py）

.github/workflows/
└── flutter-build.yml                ✅ 已修改（添加 Fastlane 构建流程）
```

---

## 🎯 构建流程

```
┌─────────────────────────────────────────────────────────────┐
│ GitHub Actions Trigger                                       │
│ (release published 或 push to release/skill-validation)     │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 1. Flutter 无签名构建                                        │
│    - flutter pub get                                        │
│    - flutter build ios --release --no-codesign              │
│    - 生成 Runner.app (未签名)                               │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. Fastlane 签名打包                                         │
│    - bundle exec fastlane ios release                       │
│      ├─ fastlane match adhoc (拉取证书)                     │
│      ├─ gym archive (Xcode 签名归档)                        │
│      └─ export IPA                                          │
│    - 生成: tmk-translation-flutter-demo-{version}.ipa       │
└─────────────────────────────────────────────────────────────┘
                         ↓
┌─────────────────────────────────────────────────────────────┐
│ 3. 分发（仅 release 事件触发）                               │
│    ├─ Python 上传蒲公英                                      │
│    │  └─ 返回下载链接和 Build Key                           │
│    └─ gh release upload (上传到 GitHub Release)             │
└─────────────────────────────────────────────────────────────┘
```

---

## 🔐 需要配置的 GitHub Secrets

### 必需（大部分已有）

| Secret 名称 | 状态 | 说明 |
|------------|------|------|
| `GH_ACCESS_TOKEN` | ✅ 已有 | GitHub Token（访问 Match 仓库） |
| `FASTLANE_MATCH_PASSWORD` | ✅ 已有 | Match 证书加密密码 |
| `ASC_ISSUER_ID` | ✅ 已有 | App Store Connect API Issuer ID |
| `ASC_KEY_ID` | ✅ 已有 | App Store Connect API Key ID |
| `ASC_PRIVATE_KEY` | ✅ 已有 | App Store Connect API Private Key |
| `PGYER_API_KEY` | ✅ 已有 | 蒲公英 API Key |
| `RELEASE_TOKEN` | ✅ 已有 | GitHub Release Token |
| `IM_WEBHOOK` | ✅ 已有（可选） | IM 通知 Webhook |
| `IM_SECRET` | ✅ 已有（可选） | IM 通知密钥 |
| `TMK_SAMPLE_APP_ID` | ✅ 已有 | App ID |
| `TMK_SAMPLE_APP_SECRET` | ✅ 已有 | App Secret |

### ⚠️ 唯一需要确认的

**`MATCH_GIT_URL`** (可选)：
- **不需要单独配置**（已硬编码在 workflow 中）
- 值：`https://github.com/timekettle/ios-certificates.git`
- 如果你想修改，可以添加到 Secrets 中覆盖

---

## 🚀 如何启动

### 方式 1：手动触发测试

```bash
# 1. 在 GitHub 页面
Actions → Flutter Build → Run workflow → 选择 release/skill-validation 分支

# 2. 观察构建日志
# ✅ 如果 "Build IPA with Fastlane" 步骤成功 → 证书配置正确
# ❌ 如果失败，查看错误信息
```

---

### 方式 2：发布 Release（生产）

```bash
# 1. 创建并推送 tag
git tag v1.0.0
git push origin v1.0.0

# 2. 在 GitHub 创建 Release

# 3. 自动触发构建，并：
# ✅ 上传 IPA 到蒲公英
# ✅ 上传 IPA 到 GitHub Release
# ✅ 设置环境变量（PGYER_DOWNLOAD_URL 等）
```

---

## 📦 构建产物

### 每次构建

- **GitHub Artifact**: `flutter-demo-ios-ipa`
  - 保留 14 天
  - 包含签名的 IPA 文件

### Release 事件

- **蒲公英**: 
  - 下载链接：`https://www.pgyer.com/{buildKey}`
  - 自动设置 `APP_DLINK` 环境变量

- **GitHub Release**:
  - 文件名：`tmk-translation-flutter-demo-{version}.ipa`
  - 附加到对应的 Release

---

## 🔍 验证 Match 证书是否存在

### 快速验证

```bash
cd Flutter/apps/tmk_translation_demo/ios

# 安装依赖
bundle install

# 测试拉取证书（只读模式）
MATCH_GIT_URL=https://github.com/timekettle/ios-certificates.git \
MATCH_PASSWORD=<从 Secrets 获取> \
MATCH_GIT_TOKEN=<从 Secrets 获取> \
bundle exec fastlane ios sync_certs
```

**预期结果：**
- ✅ 成功：说明证书已存在，可以直接构建
- ❌ 失败：需要先创建证书（见下方）

---

### 如果证书不存在，如何创建

```bash
cd Flutter/apps/tmk_translation_demo/ios

# 创建 adhoc 证书（需要 Apple Developer 账号权限）
MATCH_GIT_URL=https://github.com/timekettle/ios-certificates.git \
MATCH_PASSWORD=<从 Secrets 获取> \
MATCH_GIT_TOKEN=<从 Secrets 获取> \
bundle exec fastlane match adhoc \
  --app_identifier co.timekettle.translation.sample
```

这会：
1. 在 Apple Developer 中创建分发证书
2. 创建 Ad-Hoc Provisioning Profile
3. 加密后提交到 `ios-certificates` 仓库

---

## 🐛 故障排查

### 问题 1：Match 拉取证书失败

**错误信息**：`No profiles for 'co.timekettle.translation.sample'`

**解决方案**：
1. 确认 Bundle ID 是否正确：`co.timekettle.translation.sample`
2. 检查 `ios-certificates` 仓库中是否有该 Bundle ID 的证书
3. 如果没有，运行上面的 "创建证书" 命令

---

### 问题 2：Fastlane 构建失败

**错误信息**：`xcodebuild: error: Signing for "Runner" requires...`

**解决方案**：
1. 检查 Match 是否成功拉取证书（查看 workflow 日志）
2. 确认 Provisioning Profile 是否包含正确的证书
3. 确认 `ASC_*` secrets 是否配置正确

---

### 问题 3：蒲公英上传失败

**错误信息**：`蒲公英上传失败! 错误描述: ...`

**解决方案**：
1. 检查 `PGYER_API_KEY` 是否正确
2. 确认 IPA 文件大小未超过限制（通常 2GB）
3. 检查网络连接（蒲公英 API 可能有地区限制）

---

### 问题 4：GitHub Release 上传失败

**错误信息**：`gh: release not found`

**解决方案**：
1. 确认 tag 是否已创建并推送
2. 确认 Release 是否已创建
3. 检查 `RELEASE_TOKEN` 是否有 `contents: write` 权限

---

## 📝 关键文件说明

### `Fastfile`

```ruby
lane :release do
  match(type: "adhoc", readonly: true)  # 拉取证书
  gym(...)                               # 构建 IPA
end
```

- **作用**：定义构建流程
- **关键参数**：
  - `type: "adhoc"` → 使用 Ad-Hoc 方式（适合蒲公英）
  - `readonly: true` → 只读模式（不创建新证书）
  - 自动设置 `IPA_PATH` 环境变量

---

### `upload_to_pgyer.py`

- **作用**：上传 IPA/APK 到蒲公英
- **特性**：
  - 基于 `docs/upload_apk.py` 改进
  - 自动获取 Git 信息（分支、commit、作者）
  - 设置 `APP_DLINK`、`APP_UPDATE_DESC_BASE64` 环境变量
  - 兼容 `--im-webhook` 参数（IM 通知待实现）

---

## 🎉 预期结果

### 构建成功后

1. **GitHub Actions 日志**：
   ```
   ✅ IPA built successfully!
   📍 Path: /path/to/tmk-translation-flutter-demo-1.0.0.ipa
   📏 Size: 45.23 MB
   
   🎉 蒲公英上传成功！
   🔗 下载链接: https://www.pgyer.com/xxxxx
   ```

2. **GitHub Release**：
   - 附件：`tmk-translation-flutter-demo-1.0.0.ipa`

3. **蒲公英**：
   - 可以通过链接下载并安装到测试设备

---

## 🔄 后续优化（可选）

1. **App Store 发布**：
   - 修改 Fastfile 中的 `type: "appstore"`
   - 添加 `upload_to_testflight` lane

2. **IM 通知完善**：
   - 实现 `feishu_notify` 或 `dingtalk_notify` 模块
   - 在 `upload_to_pgyer.py` 中集成

3. **多环境支持**：
   - 添加 `development` / `staging` / `production` lane
   - 根据分支自动选择构建类型

---

## 📞 需要帮助？

如果遇到问题：

1. **查看完整日志**：GitHub Actions → 对应的 workflow run → 展开失败的步骤
2. **检查 Secrets**：Settings → Secrets and variables → Actions
3. **验证证书**：本地运行 `bundle exec fastlane ios sync_certs`

---

**配置完成日期**：2026-07-08  
**下一步**：推送代码并触发测试构建！🚀
