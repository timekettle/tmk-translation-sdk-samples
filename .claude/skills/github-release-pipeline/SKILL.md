---
name: github-release-pipeline
description: 为 GitHub 项目接入或迁移自动发版流程。支持新项目、已有 CI、已有 Release 等任意起点。
triggers:
  - "接入自动发版"
  - "配置 Release Please"
  - "自动构建"
  - "GitHub Release Pipeline"
  - "配置 CI/CD 发版"
  - "迁移发版流程"
---

# GitHub Release Pipeline Skill

为任意 GitHub 项目接入完整的自动发版流程。

## 适用场景

| 项目状态 | 支持 |
|---------|------|
| 全新项目，无任何 CI | ✅ Bootstrap |
| 已有 CI，无 Release 流程 | ✅ Add Pipeline |
| 已有 Release/Tag，需迁移 | ✅ Migration |
| 已有 Release Please，需升级 | ✅ Upgrade |
| 已满足要求 | ✅ Review Only |

## 执行流程

```
Phase 1: Project Discovery → 分析仓库现状
Phase 2: Capability Analysis → 判断策略类型
Phase 3: Migration Plan → 生成迁移方案（不修改代码）
Phase 4: Execution → 确认后逐步实施并验证
```

**核心原则：分析 → 规划 → 确认 → 执行。永远不跳过前三步直接修改仓库。**

## 能力

- ✔ 自动发现项目结构和现有 CI 配置
- ✔ 接入 Release Please（Manifest 模式）
- ✔ 创建 Release Workflow
- ✔ 创建 Build Workflow（Flutter APK / AAB）
- ✔ 版本号自动注入
- ✔ 自动上传 Release Assets
- ✔ 兼容已有 Workflow（增量修改，不覆盖）
- ✔ 支持 Monorepo
- ✔ 提供完整 Troubleshooting

## 目录结构

```
.claude/skills/github-release-pipeline/
├── SKILL.md               ← Skill 定义（本文件）
├── templates/
│   ├── release-please.yml
│   ├── flutter-build.yml
│   ├── release-please-config.json
│   └── release-please-manifest.json
└── docs/
    ├── discovery-checklist.md
    ├── github-settings.md
    └── troubleshooting.md
```

---

## Phase 1: Project Discovery

自动检测以下信息，输出 Discovery Report。

### 仓库基础

```bash
# 默认分支
git remote show origin | grep "HEAD branch"

# 是否有 tag
git tag -l | head -20

# 是否有 release
gh release list --limit 5

# commit 数量
git rev-list --count HEAD
```

### CI/CD 现状

```bash
# 已有 workflow
find .github/workflows -type f -name "*.yml" -o -name "*.yaml" 2>/dev/null

# 是否已有 release-please
find . -name "release-please*" -o -name ".release-please*" 2>/dev/null

# 是否有 semantic-release
find . -name ".releaserc*" -o -name "release.config.*" 2>/dev/null
grep -r "semantic-release" package.json .github/ 2>/dev/null
```

### 项目类型

```bash
# Flutter 项目
find . -name "pubspec.yaml" -not -path "*/.*"

# Flutter 平台支持
ls <flutter-path>/android/ <flutter-path>/ios/ <flutter-path>/web/ 2>/dev/null

# Android 签名
find . -name "key.properties" -o -name "*.keystore" -o -name "*.jks" 2>/dev/null

# AGP 版本
grep -r "com.android.application" --include="*.gradle*" -l
```

### Discovery Report 模板

```markdown
## Project Discovery Report

### 仓库信息
- 组织/仓库: <org>/<repo>
- 默认分支: <branch>
- Commit 数量: <count>
- 是否有 Tag: <yes/no> (列出最近 5 个)
- 是否有 Release: <yes/no> (列出最近 3 个)

### CI/CD 现状
- .github/workflows/ 存在: <yes/no>
- 已有 Workflow: <列表>
- Release 方案: <none / release-please / semantic-release / manual / 自定义>
- CHANGELOG: <exists / not exists>

### 项目类型
- 类型: <Flutter / Node / Java / 其他>
- Flutter 工程路径: <path>
- 支持平台: <Android / iOS / Web / ...>
- Android 签名: <debug / release / none>
- Java 版本要求: <version>
- AGP 版本: <version>
- Gradle 版本: <version>
- Path dependencies: <列表>

### 已有构建配置
- Build Workflow: <exists / not exists>
- 构建产物: <APK / AAB / IPA / 无>
- 产物上传: <Release Assets / Artifact / 无>
```

---

## Phase 2: Capability Analysis

根据 Discovery Report 选择策略：

| 条件 | 策略 | 说明 |
|------|------|------|
| 无 .github/，无 tag，无 release | **Bootstrap** | 从零配置 |
| 有 CI，无 release 相关 workflow | **Add Pipeline** | 增量添加 release + build |
| 有 release/tag，有手动 workflow | **Migration** | 迁移到自动化，保留已有 |
| 有 release-please (旧版/非 manifest) | **Upgrade** | 升级到 manifest 模式 |
| 有 release-please manifest + build | **Review Only** | 检查配置，输出建议 |

### 策略选择逻辑

```
if no .github/ and no tags:
    → Bootstrap
elif has workflows but no release-please:
    if has semantic-release:
        → Migration (from semantic-release)
    elif has manual release workflow:
        → Migration (from manual)
    else:
        → Add Pipeline
elif has release-please:
    if manifest mode with config.json:
        → Review Only
    else:
        → Upgrade (to manifest mode)
```

---

## Phase 3: Migration Plan

生成方案文档，包含以下章节：

```markdown
## Migration Plan

### 策略: <Bootstrap / Add Pipeline / Migration / Upgrade / Review Only>
### 原因: <为什么选择该策略>

### 保留
- <已有的 workflow/配置，不会被修改>

### 新增
- <需要创建的文件列表>

### 修改
- <需要修改的文件及修改内容>

### 删除
- <需要移除的文件（如有）>

### GitHub Settings
- [ ] RELEASE_TOKEN Secret
- [ ] PAT 权限
- [ ] 组织审批
- [ ] Actions PR 权限

### 参数
- release-branch: <value>
- bootstrap-sha: <value>
- initial-version: <value>
- flutter-app-path: <value>
- app-name: <value>
- java-version: <value>

### 风险点
- <可能导致失败的因素>

### 验证方案
- <逐步验证步骤>
```

**输出方案后停止，等待用户确认再执行。**

---

## Phase 4: Execution

用户确认后，按以下原则执行：

1. **增量修改** — 不覆盖已有 workflow，不删除已有配置（除非 Migration Plan 明确说明）
2. **逐步验证** — 每完成一个文件/配置，说明预期行为
3. **先 Release 后 Build** — 先验证版本管理，再验证构建
4. **可回滚** — 所有修改可通过 git revert 撤销

### 执行顺序

```
1. 创建 release-please-config.json + manifest
2. 创建/修改 release-please.yml
3. Push → 验证 workflow 运行
4. 触发 Release PR → 验证版本计算
5. 合并 PR → 验证 Tag + Release 创建
6. 创建 flutter-build.yml
7. Push → 验证构建成功
8. 触发完整链路 → 验证 APK 上传到 Release Assets
```

---

## 约束条件

1. **永远先分析再修改** — 不假设项目为空仓库
2. **Manifest 模式** — 必须使用 config + manifest 文件，避免全量扫描
3. **bootstrap-sha** — 首次接入必须配置，否则 GitHub API 超时
4. **PAT 不是 GITHUB_TOKEN** — Release 事件触发下游 workflow 的唯一方式
5. **release-type: simple** — 不修改项目版本文件，CI 从 tag 动态注入
6. **不覆盖已有 workflow** — 新增文件或增量修改
7. **模板使用占位符** — 不包含任何项目特定信息
