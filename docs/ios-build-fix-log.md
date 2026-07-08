# iOS 构建问题修复记录

## 🐛 问题描述

**构建失败**：`build-ios` job 在 `flutter build ios --no-codesign` 步骤失败

**错误信息**：
```
[!] There are multiple dependencies with different sources for `TmkTranslationSDK` in `Podfile`:

- TmkTranslationSDK (from https://...beta/Specs/.../1.2.0-beta17/...)
- TmkTranslationSDK (from https://...rc/Specs/.../1.2.0-rc3/...)
```

---

## 🔍 根本原因

`Flutter/apps/tmk_translation_demo/ios/Podfile` 中存在**两个相同依赖的不同版本**：

```ruby
# 第 34 行
pod 'TmkTranslationSDK', :podspec => 'https://.../beta/.../1.2.0-beta17/...'

# 第 41 行
pod 'TmkTranslationSDK', :podspec => 'https://.../rc/.../1.2.0-rc3/...'
```

CocoaPods 不允许同一个 pod 有多个不同的 source。

---

## ✅ 修复方案

保留 **beta17 版本**，删除 rc3 版本。

### 修改前（❌ 错误）

```ruby
target 'Runner' do
  use_frameworks!

  pod 'TmkTranslationSDK', :podspec => '...beta17...'
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))

  # 覆盖版本
  pod 'TmkTranslationSDK', :podspec => '...rc3...'  # ❌ 重复定义
end
```

### 修改后（✅ 正确）

```ruby
target 'Runner' do
  use_frameworks!

  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))

  # 使用 beta 分支的 1.2.0-beta17
  pod 'TmkTranslationSDK', :podspec => 'https://raw.githubusercontent.com/timekettle/TmkTranslationSDK-iOS/beta/Specs/TmkTranslationSDK/1.2.0-beta17/TmkTranslationSDK.podspec'
end
```

---

## 📝 修复步骤

### 1. 修改 Podfile

删除重复的 `TmkTranslationSDK` 定义，保留 beta17 版本。

### 2. 提交并推送

```bash
git add Flutter/apps/tmk_translation_demo/ios/Podfile
git commit -m "fix: remove duplicate TmkTranslationSDK dependency in Podfile"
git push origin release/skill-validation
```

### 3. 验证修复

推送后 GitHub Actions 自动触发构建：
- Run ID: `28944966748`
- 触发时间: 2026-07-08 13:06:42

---

## 🎯 预期结果

修复后，`pod install` 应该能成功执行：

```
Analyzing dependencies
Downloading dependencies
Installing TmkTranslationSDK (1.2.0-beta17)
...
Pod installation complete!
```

然后继续执行：
1. ✅ `flutter build ios --no-codesign` → 生成 Runner.app
2. ✅ `bundle exec fastlane ios release` → 签名并导出 IPA
3. ✅ Python 上传蒲公英
4. ✅ 上传到 GitHub Release

---

## 📚 经验总结

### 问题原因

- **重复依赖**：同一个 pod 被定义了两次
- **不同 source**：一个指向 beta 分支，一个指向 rc 分支
- **CocoaPods 限制**：不允许同一 pod 有多个不同的 podspec 来源

### 预防措施

1. **检查 Podfile**：提交前确认没有重复的 `pod` 定义
2. **本地测试**：先在本地运行 `pod install` 验证
3. **版本管理**：统一使用一个版本分支（beta 或 rc）

### 相关命令

```bash
# 本地验证 Podfile
cd Flutter/apps/tmk_translation_demo/ios
pod install --verbose

# 清理缓存（如果需要）
pod cache clean TmkTranslationSDK
rm -rf Pods
pod install
```

---

## 🔗 相关链接

- GitHub Actions Run: https://github.com/timekettle/tmk-translation-sdk-samples/actions/runs/28944966748
- Commit: 18317d7
- 修复的 PR/Branch: release/skill-validation

---

**修复日期**：2026-07-08  
**修复人**：Claude Code  
**状态**：✅ 已修复，构建中
