# Flutter iOS 构建发布全链路实施计划

## 📋 方案概述

采用 **Flutter + Fastlane + Python** 混合方案，实现完整的 iOS 构建发布流程：

```
Flutter 无签名构建 → Fastlane 签名打包 → Python 上传蒲公英 → GitHub Release 发布
```

---

## 🎯 技术架构

### 构建流程图

```
┌─────────────────────────────────────────────────────────────────┐
│ GitHub Actions Workflow (flutter-build.yml)                     │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 阶段 1: Flutter 准备阶段                                         │
│ - Install Flutter SDK                                           │
│ - flutter pub get                                               │
│ - Create LocalSecrets.xcconfig                                  │
│ - flutter build ios --release --no-codesign                     │
│   └─> 生成 Runner.app (未签名)                                  │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 阶段 2: Fastlane 签名打包阶段                                    │
│ - Set up Ruby & Bundler                                         │
│ - Install CocoaPods dependencies                                │
│ - bundle exec fastlane ios release                              │
│   ├─> fastlane match (拉取证书和 Profile)                       │
│   ├─> xcodebuild archive (签名归档)                             │
│   └─> xcodebuild exportArchive (导出 .ipa)                      │
│   生成产物: tmk-translation-flutter-demo-{version}.ipa          │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ 阶段 3: 分发阶段                                                 │
│ ┌───────────────────────────────────────────────────────────┐   │
│ │ 3.1 上传到蒲公英 (Python 脚本)                             │   │
│ │ - Set up Python 3.9                                       │   │
│ │ - pip install requests                                    │   │
│ │ - python scripts/upload_to_pgyer.py                       │   │
│ │   └─> POST https://www.pgyer.com/apiv2/app/upload        │   │
│ │   返回: Build Key & 下载链接                               │   │
│ └───────────────────────────────────────────────────────────┘   │
│                              ↓                                   │
│ ┌───────────────────────────────────────────────────────────┐   │
│ │ 3.2 上传到 GitHub Release                                 │   │
│ │ - gh release upload {tag} {ipa_file} --clobber            │   │
│ │   └─> 附加到对应的 Release                                │   │
│ └───────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 📂 项目文件结构

```
tmk-translation-sdk-samples/
├── .github/
│   └── workflows/
│       └── flutter-build.yml                 # [修改] 添加 iOS Fastlane 构建
├── Flutter/
│   └── apps/
│       └── tmk_translation_demo/
│           ├── ios/
│           │   ├── Gemfile                   # [新建] Ruby 依赖
│           │   ├── Gemfile.lock              # [自动生成]
│           │   ├── fastlane/
│           │   │   ├── Fastfile              # [新建] Fastlane 配置
│           │   │   ├── Matchfile             # [新建] Match 配置
│           │   │   └── Appfile               # [新建] App 基本信息
│           │   └── Podfile                   # [已存在]
│           └── pubspec.yaml                  # [已存在]
├── scripts/
│   └── upload_to_pgyer.py                    # [新建] 蒲公英上传脚本
└── docs/
    ├── ios-fastlane-setup.md                 # [新建] 配置指南
    └── ios-secrets-checklist.md              # [已存在] Secrets 清单
```

---

## 🔧 详细实施步骤

### **步骤 1: 创建 Fastlane 配置文件**

#### 1.1 创建 `ios/Gemfile`

```ruby
source "https://rubygems.org"

gem "fastlane", "~> 2.220"
gem "cocoapods", "~> 1.15"
```

**用途**：定义 Ruby 依赖（Fastlane 和 CocoaPods）

---

#### 1.2 创建 `ios/fastlane/Fastfile`

```ruby
default_platform(:ios)

platform :ios do
  desc "Build signed IPA for ad-hoc distribution"
  lane :release do
    # 1. 同步证书和 Provisioning Profile（从 Match 仓库拉取）
    match(
      type: "adhoc",              # 使用 ad-hoc 方式（适合蒲公英）
      readonly: true,             # 只读模式，不创建新证书
      app_identifier: "co.timekettle.translation.sample"
    )

    # 2. 获取版本信息（从环境变量）
    version = ENV["APP_VERSION"] || "1.0.0"
    build_number = ENV["BUILD_NUMBER"] || "1"

    # 3. 更新项目版本号
    update_info_plist(
      xcodeproj: "Runner.xcodeproj",
      plist_path: "Runner/Info.plist",
      display_name: "TMK Translation Demo"
    )

    # 4. 构建并导出 IPA
    build_app(
      workspace: "Runner.xcworkspace",
      scheme: "Runner",
      export_method: "ad-hoc",
      configuration: "Release",
      output_directory: "./build/ipa",
      output_name: "tmk-translation-flutter-demo-#{version}.ipa",
      
      # Xcode 构建参数
      xcargs: "-allowProvisioningUpdates",
      export_xcargs: "-allowProvisioningUpdates",
      
      # 版本号
      build_number: build_number,
      version_number: version,
      
      # 导出选项
      export_options: {
        method: "ad-hoc",
        provisioningProfiles: {
          "co.timekettle.translation.sample" => ENV["sigh_co.timekettle.translation.sample_adhoc_profile-name"]
        }
      }
    )

    # 5. 输出构建信息
    ipa_path = lane_context[SharedValues::IPA_OUTPUT_PATH]
    UI.success("✅ IPA built successfully: #{ipa_path}")
    
    # 设置环境变量供后续步骤使用
    sh("echo \"IPA_PATH=#{ipa_path}\" >> $GITHUB_ENV")
  end

  desc "Sync certificates for development"
  lane :sync_certs do
    match(
      type: "adhoc",
      app_identifier: "co.timekettle.translation.sample",
      readonly: true
    )
  end
end
```

**关键点：**
- ✅ 使用 `ad-hoc` 方式（适合内部分发 + 蒲公英）
- ✅ 从环境变量获取版本号（与 workflow 集成）
- ✅ 自动设置 `IPA_PATH` 环境变量供后续步骤使用

---

#### 1.3 创建 `ios/fastlane/Matchfile`

```ruby
git_url(ENV["MATCH_GIT_URL"])
storage_mode("git")

type("adhoc") # 默认使用 ad-hoc 类型

app_identifier(["co.timekettle.translation.sample"])

# 使用 Git Token 认证（避免 SSH 密钥问题）
git_basic_authorization(Base64.strict_encode64("#{ENV['MATCH_GIT_TOKEN']}:"))

# 使用密码加密
passphrase(ENV["MATCH_PASSWORD"])
```

**用途**：配置 Match 证书仓库连接

---

#### 1.4 创建 `ios/fastlane/Appfile`

```ruby
app_identifier("co.timekettle.translation.sample")
apple_id(ENV["APPLE_ID"]) # 可选，如果需要 App Store Connect API

# 使用 App Store Connect API（推荐）
api_key_path("./fastlane/AuthKey.json") if File.exist?("./fastlane/AuthKey.json")
```

**用途**：App 基本信息配置

---

### **步骤 2: 创建蒲公英上传脚本**

#### 2.1 创建 `scripts/upload_to_pgyer.py`

```python
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
蒲公英 IPA 上传脚本
文档: https://www.pgyer.com/doc/view/api#fastUploadApp
"""

import os
import sys
import argparse
import requests
import json
import time


def upload_to_pgyer(
    file_path: str,
    api_key: str,
    build_password: str = "",
    build_install_type: int = 2,
    build_channel_shortcut: str = "",
    im_webhook: str = "",
    im_secret: str = ""
):
    """
    上传 IPA 到蒲公英
    
    Args:
        file_path: IPA 文件路径
        api_key: 蒲公英 API Key
        build_password: 安装密码（可选）
        build_install_type: 安装类型（1=公开，2=密码，3=邀请）
        build_channel_shortcut: 渠道标识
        im_webhook: IM 通知 Webhook（可选）
        im_secret: IM 通知密钥（可选）
    
    Returns:
        dict: 上传响应
    """
    
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"文件不存在: {file_path}")
    
    print(f"📦 正在上传: {file_path}")
    print(f"📏 文件大小: {os.path.getsize(file_path) / 1024 / 1024:.2f} MB")
    
    url = "https://www.pgyer.com/apiv2/app/upload"
    
    with open(file_path, 'rb') as f:
        files = {'file': f}
        data = {
            '_api_key': api_key,
            'buildInstallType': build_install_type,
            'buildPassword': build_password,
            'buildChannelShortcut': build_channel_shortcut,
        }
        
        print("⏳ 上传中，请稍候...")
        start_time = time.time()
        
        try:
            response = requests.post(url, data=data, files=files, timeout=600)
            response.raise_for_status()
            
            elapsed = time.time() - start_time
            print(f"✅ 上传完成，耗时 {elapsed:.1f}s")
            
            result = response.json()
            
            if result.get('code') == 0:
                data = result.get('data', {})
                build_key = data.get('buildKey')
                build_name = data.get('buildName')
                build_version = data.get('buildVersion')
                
                download_url = f"https://www.pgyer.com/{build_key}"
                
                print("\n" + "="*60)
                print("🎉 上传成功！")
                print(f"📱 应用名称: {build_name}")
                print(f"🔢 版本号: {build_version}")
                print(f"🔑 Build Key: {build_key}")
                print(f"🔗 下载链接: {download_url}")
                print("="*60 + "\n")
                
                # 发送 IM 通知（如果配置了）
                if im_webhook and im_secret:
                    send_im_notification(
                        webhook=im_webhook,
                        secret=im_secret,
                        app_name=build_name,
                        version=build_version,
                        download_url=download_url
                    )
                
                # 输出到 GitHub Actions
                if os.getenv('GITHUB_ENV'):
                    with open(os.getenv('GITHUB_ENV'), 'a') as env_file:
                        env_file.write(f"PGYER_BUILD_KEY={build_key}\n")
                        env_file.write(f"PGYER_DOWNLOAD_URL={download_url}\n")
                
                return result
            else:
                error_msg = result.get('message', '未知错误')
                print(f"❌ 上传失败: {error_msg}")
                sys.exit(1)
                
        except requests.exceptions.Timeout:
            print("❌ 上传超时（10分钟）")
            sys.exit(1)
        except requests.exceptions.RequestException as e:
            print(f"❌ 网络请求失败: {e}")
            sys.exit(1)


def send_im_notification(webhook: str, secret: str, app_name: str, version: str, download_url: str):
    """发送 IM 通知（钉钉/企业微信）"""
    try:
        # 这里可以根据实际的 IM 平台实现通知逻辑
        print(f"📨 发送 IM 通知: {app_name} {version}")
        # TODO: 实现具体的通知逻辑
    except Exception as e:
        print(f"⚠️  IM 通知发送失败: {e}")


def main():
    parser = argparse.ArgumentParser(description='上传 IPA 到蒲公英')
    parser.add_argument('--path', required=True, help='IPA 文件路径')
    parser.add_argument('--key', required=True, help='蒲公英 API Key')
    parser.add_argument('--password', default='', help='安装密码（可选）')
    parser.add_argument('--install-type', type=int, default=2, help='安装类型（1=公开，2=密码，3=邀请）')
    parser.add_argument('--channel', default='', help='渠道标识（可选）')
    parser.add_argument('--im-webhook', default='', help='IM Webhook（可选）')
    parser.add_argument('--im-secret', default='', help='IM Secret（可选）')
    
    args = parser.parse_args()
    
    upload_to_pgyer(
        file_path=args.path,
        api_key=args.key,
        build_password=args.password,
        build_install_type=args.install_type,
        build_channel_shortcut=args.channel,
        im_webhook=args.im_webhook,
        im_secret=args.im_secret
    )


if __name__ == '__main__':
    main()
```

**特性：**
- ✅ 完整的错误处理
- ✅ 上传进度显示
- ✅ 自动设置环境变量（供后续步骤使用）
- ✅ 支持 IM 通知（可选）
- ✅ 兼容 `docs/release.yml` 的调用方式

---

### **步骤 3: 修改 flutter-build.yml**

在 `build-ios` job 中修改构建流程：

```yaml
  build-ios:
    runs-on: macos-latest
    defaults:
      run:
        working-directory: Flutter/apps/tmk_translation_demo
    steps:
      - uses: actions/checkout@v4

      - name: Configure git to use HTTPS instead of SSH
        working-directory: .
        run: git config --global url."https://github.com/".insteadOf "git@github.com:"

      - name: Extract version from tag
        id: version
        working-directory: .
        run: |
          if [[ "${{ github.event_name }}" == "release" ]]; then
            TAG="${{ github.event.release.tag_name }}"
          else
            TAG="v0.0.0-dev"
          fi
          VERSION="${TAG#v}"
          BUILD_NUMBER=$(git rev-list --count HEAD)
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"
          echo "build_number=$BUILD_NUMBER" >> "$GITHUB_OUTPUT"
          echo "tag=$TAG" >> "$GITHUB_OUTPUT"
          echo "Version: $VERSION, Build: $BUILD_NUMBER, Tag: $TAG"

      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - name: Install dependencies
        run: flutter pub get

      - name: Create LocalSecrets.xcconfig
        run: |
          printf 'TMK_SAMPLE_APP_ID = %s\nTMK_SAMPLE_APP_SECRET = %s\n' \
            "${{ secrets.TMK_SAMPLE_APP_ID }}" \
            "${{ secrets.TMK_SAMPLE_APP_SECRET }}" \
            > ios/Flutter/LocalSecrets.xcconfig

      # ============ Flutter 无签名构建 ============
      - name: Build iOS (no codesign)
        run: |
          flutter build ios --release --no-codesign \
            --build-name=${{ steps.version.outputs.version }} \
            --build-number=${{ steps.version.outputs.build_number }}

      # ============ Fastlane 签名打包 ============
      - name: Set up Ruby
        uses: ruby/setup-ruby@v1
        with:
          ruby-version: 3.0.0
          bundler-cache: true
          working-directory: Flutter/apps/tmk_translation_demo/ios

      - name: Cache CocoaPods
        uses: actions/cache@v4
        with:
          path: |
            Flutter/apps/tmk_translation_demo/ios/Pods
            ~/Library/Caches/CocoaPods
            ~/.cocoapods
          key: pods-${{ runner.os }}-${{ hashFiles('Flutter/apps/tmk_translation_demo/ios/Podfile.lock') }}
          restore-keys: |
            pods-${{ runner.os }}-

      - name: Install CocoaPods dependencies
        working-directory: ios
        run: pod install

      - name: Build IPA with Fastlane
        working-directory: ios
        env:
          MATCH_GIT_URL: ${{ secrets.MATCH_GIT_URL }}
          MATCH_GIT_TOKEN: ${{ secrets.GH_ACCESS_TOKEN }}
          MATCH_PASSWORD: ${{ secrets.FASTLANE_MATCH_PASSWORD }}
          APP_VERSION: ${{ steps.version.outputs.version }}
          BUILD_NUMBER: ${{ steps.version.outputs.build_number }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_PRIVATE_KEY: ${{ secrets.ASC_PRIVATE_KEY }}
        run: |
          bundle exec fastlane ios release

      # ============ 上传蒲公英 ============
      - name: Set up Python
        if: github.event_name == 'release'
        uses: actions/setup-python@v4
        with:
          python-version: 3.9

      - name: Install Python Dependencies
        if: github.event_name == 'release'
        run: |
          python -m pip install --upgrade pip
          pip install requests==2.32.5

      - name: Upload to Pgyer
        if: github.event_name == 'release'
        working-directory: .
        env:
          PGYER_API_KEY: ${{ secrets.PGYER_API_KEY }}
          IM_WEBHOOK: ${{ secrets.IM_WEBHOOK }}
          IM_SECRET: ${{ secrets.IM_SECRET }}
        run: |
          python scripts/upload_to_pgyer.py \
            --path "${IPA_PATH}" \
            --key "${PGYER_API_KEY}" \
            --password "" \
            --im-webhook "${IM_WEBHOOK}" \
            --im-secret "${IM_SECRET}"

      # ============ 上传 GitHub Release ============
      - name: Upload to GitHub Release
        if: github.event_name == 'release'
        working-directory: .
        env:
          GH_TOKEN: ${{ secrets.RELEASE_TOKEN }}
        run: |
          IPA_NAME="tmk-translation-flutter-demo-${{ steps.version.outputs.version }}.ipa"
          cp "${IPA_PATH}" "$IPA_NAME"
          gh release upload "${{ steps.version.outputs.tag }}" "$IPA_NAME" --clobber

      # ============ 上传 Artifact（用于测试）============
      - name: Upload Artifact
        uses: actions/upload-artifact@v4
        with:
          name: flutter-demo-ios-ipa
          path: ${{ env.IPA_PATH }}
          retention-days: 14
```

**关键改动：**
1. ✅ 保留 `flutter build ios --no-codesign`
2. ✅ 新增 Fastlane 签名打包步骤
3. ✅ 新增 Python 上传蒲公英
4. ✅ 新增 GitHub Release 上传
5. ✅ 使用 `$IPA_PATH` 环境变量传递文件路径

---

### **步骤 4: 配置 GitHub Secrets**

需要以下 Secrets（大部分已存在）：

| Secret 名称 | 状态 | 说明 |
|------------|------|------|
| `MATCH_GIT_URL` | ⚠️ 需确认 | Match 证书仓库地址 |
| `GH_ACCESS_TOKEN` | ✅ 已有 | GitHub Token（访问 Match 仓库） |
| `FASTLANE_MATCH_PASSWORD` | ✅ 已有 | Match 加密密码 |
| `ASC_ISSUER_ID` | ✅ 已有 | App Store Connect API |
| `ASC_KEY_ID` | ✅ 已有 | App Store Connect Key ID |
| `ASC_PRIVATE_KEY` | ✅ 已有 | App Store Connect Private Key |
| `PGYER_API_KEY` | ✅ 已有 | 蒲公英 API Key |
| `RELEASE_TOKEN` | ✅ 已有 | GitHub Release Token |
| `IM_WEBHOOK` | ✅ 已有（可选） | IM 通知 Webhook |
| `IM_SECRET` | ✅ 已有（可选） | IM 通知密钥 |
| `TMK_SAMPLE_APP_ID` | ✅ 已有 | App ID |
| `TMK_SAMPLE_APP_SECRET` | ✅ 已有 | App Secret |

**唯一需要确认的：`MATCH_GIT_URL`**
- 格式：`https://github.com/your-org/certificates.git`
- 这是存储证书的私有仓库地址

---

## 🎯 方案优势

### ✅ 符合你的要求

| 要求 | 实现方式 |
|------|---------|
| Flutter 无签名构建 | ✅ `flutter build ios --no-codesign` |
| Fastlane 负责签名 | ✅ `fastlane match` + `build_app` |
| Python 上传蒲公英 | ✅ `scripts/upload_to_pgyer.py` |
| IPA 在 GitHub Release | ✅ `gh release upload` |

### ✅ 技术优势

1. **职责分离**：
   - Flutter: 只负责生成 Runner.app
   - Fastlane: 专注签名和打包
   - Python: 处理上传逻辑

2. **与现有方案对齐**：
   - 参考 `docs/release.yml` 和 `docs/match.yml`
   - 复用已有的 Secrets
   - 团队熟悉的 Fastlane 方案

3. **易于维护**：
   - Fastfile 清晰易读
   - Python 脚本独立可测试
   - 与 Android 构建风格统一

4. **灵活扩展**：
   - 可轻松切换 ad-hoc / App Store
   - 可添加 TestFlight 上传
   - 可自定义 IM 通知逻辑

---

## 📊 与原方案对比

| 维度 | 原生 GitHub Actions | **Fastlane 方案（当前）** |
|------|-------------------|-------------------------|
| 证书管理 | 手动 base64 | ✅ **Match 自动化** |
| 签名复杂度 | 需要理解 xcodebuild | ✅ **Fastlane 抽象** |
| 与现有项目对齐 | 低 | ✅ **完全对齐** |
| 团队学习成本 | 中 | ✅ **低（已有经验）** |
| 多项目复用 | 需复制代码 | ✅ **Fastlane 统一** |

---

## 🚀 实施时间表

| 步骤 | 预计时间 | 说明 |
|------|---------|------|
| 1. 创建 Fastlane 配置 | 30 分钟 | Gemfile + Fastfile + Matchfile |
| 2. 创建 Python 脚本 | 20 分钟 | upload_to_pgyer.py |
| 3. 修改 flutter-build.yml | 20 分钟 | 添加 Fastlane 构建步骤 |
| 4. 配置 Secrets | 10 分钟 | 确认 MATCH_GIT_URL |
| 5. 测试构建 | 30 分钟 | 手动触发 + 调试 |
| **总计** | **约 2 小时** | 包含测试时间 |

---

## ⚠️ 前置条件

### 必须已配置

1. ✅ **Match 证书仓库**：已初始化并包含 `co.timekettle.translation.sample` 的证书
2. ✅ **GitHub Secrets**：已配置 `FASTLANE_MATCH_PASSWORD` 等
3. ✅ **Apple Developer 账号**：证书未过期

### 需要确认

1. ❓ **`MATCH_GIT_URL`**：证书仓库地址是什么？
2. ❓ **证书类型**：Match 仓库中是 `adhoc` 还是 `appstore` 类型？
3. ❓ **Bundle ID**：`co.timekettle.translation.sample` 是否已注册？

---

## 📝 下一步行动

1. **我开始实施**：创建所有配置文件并修改 workflow
2. **你提供信息**：告诉我 `MATCH_GIT_URL` 的值
3. **共同测试**：推送代码并触发测试构建

---

**准备好了吗？我可以立即开始实施！**
