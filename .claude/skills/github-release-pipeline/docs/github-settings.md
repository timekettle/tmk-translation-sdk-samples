# GitHub Settings 配置指南

## 1. 创建 Fine-grained PAT

### 位置

GitHub → 头像 → Settings → Developer settings → Personal access tokens → Fine-grained tokens

### 权限配置

| 权限 | 级别 | 原因 |
|------|------|------|
| Contents | Read and write | 创建 Tag、Release、推送 CHANGELOG |
| Pull requests | Read and write | 创建和更新 Release PR |
| Metadata | Read | 基本仓库信息读取（默认） |

### Repository access

选择 "Only select repositories" → 选择目标仓库。

---

## 2. 组织审批（组织仓库需要）

### 位置

Organization Settings → Personal access tokens → Pending requests

### 操作

找到对应的 token 请求，点击 Approve。

---

## 3. 配置 Repository Secret

### 位置

Repository → Settings → Secrets and variables → Actions → New repository secret

### 配置

- **Name:** `RELEASE_TOKEN`
- **Secret:** 粘贴 PAT

---

## 4. 开启 Actions PR 权限

### 位置

Repository → Settings → Actions → General → Workflow permissions

### 操作

- 勾选 "Allow GitHub Actions to create and approve pull requests"

---

## 5. （推荐）自动删除合并后的分支

### 位置

Repository → Settings → General → Pull Requests

### 操作

- 勾选 "Automatically delete head branches"

---

## 为什么必须使用 PAT

| Token 类型 | Release 能否触发下游 workflow |
|-----------|------------------------------|
| GITHUB_TOKEN | ❌ 不能（防递归机制） |
| Fine-grained PAT | ✅ 可以 |
| Classic PAT | ✅ 可以 |

Release Please 用 PAT 创建 Release → 触发 `on: release: types: [published]` → Build workflow 自动运行。
