# Fastlane Match 证书仓库说明

## 🔐 什么是 Match 仓库？

**Match** 是 Fastlane 的证书管理工具，它将 iOS 签名证书和 Provisioning Profile 统一存储在一个 **Git 仓库**中。

### 传统方式 vs Match 方式

#### ❌ 传统证书管理（痛点）
```
开发者 A 的电脑
├── 证书 A.p12 (密码: xxx)
└── Profile A.mobileprovision

开发者 B 的电脑
├── 证书 B.p12 (密码: yyy)  ⚠️ 不同的证书！
└── Profile B.mobileprovision

CI 服务器
├── 证书 ???  ⚠️ 需要手动导入
└── Profile ???
```

**问题：**
- 每个人的证书不同，容易冲突
- 证书更新后需要手动同步给所有人
- CI 配置复杂（需要 base64 编码存储）
- 证书过期后难以追踪

---

#### ✅ Match 方式（自动化）

```
GitHub: ios-certificates 仓库 (私有)
├── certs/
│   ├── development/
│   │   └── ABC1234XYZ.cer (加密存储)
│   └── adhoc/
│       └── ABC1234XYZ.cer (加密存储)
├── profiles/
│   ├── development/
│   │   └── AppStore_co.timekettle.translation.sample.mobileprovision (加密)
│   └── adhoc/
│       └── AdHoc_co.timekettle.translation.sample.mobileprovision (加密)
└── match_version.txt

所有人和 CI 都从这里拉取 ↓

开发者 A: fastlane match development
开发者 B: fastlane match development  ✅ 拉到相同的证书
CI 服务器: fastlane match adhoc       ✅ 自动配置
```

**优势：**
- ✅ 所有人使用**相同的证书**（避免冲突）
- ✅ 证书更新后，`git pull` 即可同步
- ✅ CI 配置简单（只需要仓库地址 + 密码）
- ✅ 证书**加密存储**（安全）

---

## 📂 你们的 Match 仓库

**仓库地址**：`https://github.com/timekettle/ios-certificates.git`

**当前状态**：✅ 仓库存在且可访问

**仓库结构（典型）：**
```
ios-certificates/
├── README.md
├── certs/
│   ├── development/        # 开发证书
│   │   ├── ABC1234XYZ.cer
│   │   └── ABC1234XYZ.p12
│   ├── adhoc/              # Ad-Hoc 分发证书
│   │   ├── ABC1234XYZ.cer
│   │   └── ABC1234XYZ.p12
│   └── appstore/           # App Store 分发证书
│       ├── ABC1234XYZ.cer
│       └── ABC1234XYZ.p12
├── profiles/
│   ├── development/        # 开发 Profile
│   │   └── AppStore_com.example.app.mobileprovision
│   ├── adhoc/              # Ad-Hoc Profile
│   │   └── AdHoc_com.example.app.mobileprovision
│   └── appstore/           # App Store Profile
│       └── AppStore_com.example.app.mobileprovision
└── match_version.txt       # Match 版本标识
```

---

## 🔍 检查仓库中是否有 Flutter 项目的证书

**需要确认的 Bundle ID**：`co.timekettle.translation.sample`

### 方法 1：克隆仓库查看（推荐）

```bash
# 1. 克隆证书仓库（需要有访问权限）
git clone https://github.com/timekettle/ios-certificates.git
cd ios-certificates

# 2. 解密查看（需要 MATCH_PASSWORD）
export MATCH_PASSWORD="你的密码"

# 3. 查看已有的 App
ls -la profiles/adhoc/
# 或
ls -la profiles/appstore/

# 4. 检查是否有 co.timekettle.translation.sample
grep -r "co.timekettle.translation.sample" profiles/
```

---

### 方法 2：运行 Match 命令查看

```bash
cd Flutter/apps/tmk_translation_demo/ios

# 查看 adhoc 类型的证书（只读模式）
MATCH_GIT_URL=https://github.com/timekettle/ios-certificates.git \
MATCH_PASSWORD=你的密码 \
bundle exec fastlane match adhoc \
  --app_identifier co.timekettle.translation.sample \
  --readonly
```

**预期结果：**

- ✅ **如果成功**：说明证书已存在，可以直接使用
- ❌ **如果报错**：需要先创建证书（运行不带 `--readonly` 的命令）

---

## 🆕 如果 Flutter 项目的证书不存在，如何创建？

### 步骤 1：初始化 Match（首次运行）

```bash
cd Flutter/apps/tmk_translation_demo/ios

# 创建 adhoc 证书和 Profile
MATCH_GIT_URL=https://github.com/timekettle/ios-certificates.git \
MATCH_PASSWORD=你的密码 \
APPLE_ID=your_apple_id@example.com \
bundle exec fastlane match adhoc \
  --app_identifier co.timekettle.translation.sample
```

**这会做什么：**
1. 检查 Apple Developer 账号中是否有证书
2. 如果没有，创建新的分发证书
3. 创建 Provisioning Profile（绑定 Bundle ID + 证书）
4. 加密后提交到 `ios-certificates` 仓库

---

### 步骤 2：验证证书已创建

```bash
cd ios-certificates
git pull
ls -la profiles/adhoc/
# 应该看到：AdHoc_co.timekettle.translation.sample.mobileprovision
```

---

## 🔐 Match 密码（MATCH_PASSWORD）

**作用**：加密/解密 Match 仓库中的证书

**获取方式：**
- 询问团队中配置过 `docs/release.yml` 的同事
- 或者查看 GitHub Secrets 中的 `FASTLANE_MATCH_PASSWORD`

**如果忘记密码：**
- ⚠️ 无法解密现有证书
- 需要重新初始化 Match（会创建新证书）

---

## 📋 GitHub Secrets 配置

在 `.github/workflows/flutter-build.yml` 中，Match 需要以下 Secrets：

| Secret 名称 | 值 | 说明 |
|------------|---|------|
| `MATCH_GIT_URL` | `https://github.com/timekettle/ios-certificates.git` | 证书仓库地址 |
| `MATCH_GIT_TOKEN` 或 `GH_ACCESS_TOKEN` | GitHub Personal Access Token | 访问私有仓库的 Token |
| `MATCH_PASSWORD` 或 `FASTLANE_MATCH_PASSWORD` | 加密密码 | 解密证书的密码 |

**当前状态：**
- ✅ `GH_ACCESS_TOKEN`：已有（可复用）
- ✅ `FASTLANE_MATCH_PASSWORD`：已有
- ⚠️ `MATCH_GIT_URL`：需要新增（值为上面的仓库地址）

---

## 🎯 下一步行动

### 选项 A：如果证书已存在（最可能）

✅ **直接使用**，我开始实施：
1. 创建 Fastlane 配置文件
2. 修改 flutter-build.yml
3. 添加 `MATCH_GIT_URL` secret

---

### 选项 B：如果证书不存在

你需要先运行：
```bash
cd Flutter/apps/tmk_translation_demo/ios
bundle install  # 安装 Fastlane

# 创建 adhoc 证书（需要 Apple Developer 账号）
MATCH_GIT_URL=https://github.com/timekettle/ios-certificates.git \
MATCH_PASSWORD=<从Secrets获取> \
bundle exec fastlane match adhoc \
  --app_identifier co.timekettle.translation.sample
```

然后我再实施 CI 配置。

---

## ❓ 如何确认证书是否存在？

**最简单的方法**：询问团队
- "ios-certificates 仓库中有 `co.timekettle.translation.sample` 的证书吗？"
- 或者查看 `docs/release.yml` 使用的 Bundle ID，看看 Match 是否支持

**技术方法**：克隆仓库查看（需要访问权限 + 密码）

---

**你想先确认一下证书是否存在，还是直接让我开始实施？**

如果你有 `FASTLANE_MATCH_PASSWORD` 的值，我们可以快速验证一下仓库内容。
