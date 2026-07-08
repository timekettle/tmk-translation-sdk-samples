# GitHub Secrets 配置状态检查

## 📊 当前状态分析

根据仓库中现有的 workflow 文件分析，发现以下 Secrets 使用情况：

### ✅ 已完全覆盖的 Secrets（4/6）

| Secret 名称 | 状态 | 用途 |
|------------|------|------|
| `IOS_CERTIFICATE_PASSWORD` | ✅ 已配置 | P12 证书密码 |
| `IOS_TEAM_ID` | ✅ 已配置 | Apple Team ID |
| `KEYCHAIN_PASSWORD` | ✅ 已配置 | CI Keychain 密码 |
| `PGYER_API_KEY` | ✅ 已配置 | 蒲公英 API Key |

---

### ⚠️ 需要验证的 Secrets（2/6）

从 grep 结果看到，仓库中可能有以下 secrets（名称可能不完整）：

| workflow 中需要的名称 | grep 提取的名称 | 状态 | 说明 |
|---------------------|----------------|------|------|
| `IOS_CERTIFICATE_P12_BASE64` | `IOS_CERTIFICATE_P` | ⚠️ **需要确认** | 名称可能被截断，或完整名称是 `IOS_CERTIFICATE_P12_BASE64` |
| `IOS_PROVISIONING_PROFILE_BASE64` | `IOS_PROVISIONING_PROFILE_BASE` | ⚠️ **需要确认** | 名称可能被截断，或完整名称是 `IOS_PROVISIONING_PROFILE_BASE64` |

**两种可能性：**

1. ✅ **已经存在完整名称**（最可能）
   - Secret 名称就是 `IOS_CERTIFICATE_P12_BASE64` 和 `IOS_PROVISIONING_PROFILE_BASE64`
   - grep 因为输出限制而截断
   - **无需额外配置**

2. ❌ **需要新建或重命名**
   - 如果 GitHub Secrets 中实际名称不是完整的，需要：
     - 方案 A：重命名现有 secrets
     - 方案 B：新建完整名称的 secrets

---

## 🔍 验证方法

### 方法 1：GitHub Web 界面检查（推荐）

1. 打开仓库页面
2. 进入 **Settings → Secrets and variables → Actions**
3. 查看 Secrets 列表，确认以下两个名称：
   - [ ] `IOS_CERTIFICATE_P12_BASE64` 是否存在？
   - [ ] `IOS_PROVISIONING_PROFILE_BASE64` 是否存在？

**如果存在**：✅ 无需任何操作，可以直接测试构建

**如果不存在**：❌ 需要添加或重命名 secrets

---

### 方法 2：触发测试构建（验证）

直接运行 workflow，观察错误信息：

```bash
# 在 GitHub Actions 页面手动触发 Flutter Build
```

**预期结果：**

- ✅ 如果构建到 "Import Code Signing Certificates" 步骤成功，说明 secrets 配置正确
- ❌ 如果报错 `secrets.IOS_CERTIFICATE_P12_BASE64 not found`，说明需要添加

---

## 🔧 修复方案（如果 Secrets 不存在）

### 如果缺失 `IOS_CERTIFICATE_P12_BASE64`

在 GitHub Secrets 中添加：

**名称**：`IOS_CERTIFICATE_P12_BASE64`

**值**：
```bash
# 在本地执行，将证书转换为 base64
base64 -i /path/to/certificate.p12 | pbcopy
# 然后粘贴到 GitHub Secret
```

---

### 如果缺失 `IOS_PROVISIONING_PROFILE_BASE64`

在 GitHub Secrets 中添加：

**名称**：`IOS_PROVISIONING_PROFILE_BASE64`

**值**：
```bash
# 在本地执行，将 Profile 转换为 base64
base64 -i /path/to/profile.mobileprovision | pbcopy
# 然后粘贴到 GitHub Secret
```

---

## 📋 最终检查清单

### 第一步：确认 Secrets 存在

登录 GitHub → Settings → Secrets，确认以下 6 个全部存在：

- [ ] `IOS_CERTIFICATE_P12_BASE64`
- [ ] `IOS_CERTIFICATE_PASSWORD`
- [ ] `IOS_PROVISIONING_PROFILE_BASE64`
- [ ] `IOS_TEAM_ID`
- [ ] `KEYCHAIN_PASSWORD`
- [ ] `PGYER_API_KEY`

### 第二步：测试构建

- [ ] 手动触发 Flutter Build workflow
- [ ] 观察 "Import Code Signing Certificates" 步骤是否成功
- [ ] 检查构建日志，确认 IPA 生成

---

## 💡 额外发现

仓库中还配置了以下有用的 Secrets（未在本次 iOS 签名构建中使用）：

| Secret 名称 | 用途 | 是否在 docs/release.yml 中使用 |
|------------|------|------------------------------|
| `ASC_ISSUER_ID` | App Store Connect API | ✅ 是（Fastlane） |
| `ASC_KEY_ID` | App Store Connect API Key ID | ✅ 是（Fastlane） |
| `ASC_PRIVATE_KEY` | App Store Connect API Private Key | ✅ 是（Fastlane） |
| `FASTLANE_MATCH_PASSWORD` | Fastlane Match 证书加密密码 | ✅ 是（Match） |
| `IM_WEBHOOK` | 钉钉/企业微信通知 Webhook | ✅ 是（通知） |
| `IM_SECRET` | 钉钉/企业微信通知密钥 | ✅ 是（通知） |

**未来优化方向（可选）：**
- 如果需要自动上传到 TestFlight，可以复用 `ASC_*` secrets
- 如果需要构建通知，可以集成 `IM_WEBHOOK` 和 `IM_SECRET`

---

## 🎯 下一步操作

1. **立即执行**：登录 GitHub 确认 Secrets 名称是否完整
2. **如果完整**：直接测试构建
3. **如果缺失**：按照上述修复方案添加 secrets
4. **测试成功后**：可以删除本文档或归档到 `archive/` 目录

---

**检查日期**：2026-07-08  
**检查人**：Claude Code
