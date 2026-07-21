# Troubleshooting

## 1. 首次接入返回 500 / Unicorn HTML

**原因：** 无 `bootstrap-sha`，Release Please 扫描全部历史，GitHub API 超时。

**解决：** `release-please-config.json` 中添加 `"bootstrap-sha": "<HEAD SHA>"`。必须使用 Manifest 模式。

---

## 2. Workflow 成功但无 Release PR

**原因：**
- bootstrap-sha 之后无 `feat:` / `fix:` commit
- commit message 格式错误（冒号后缺少空格）

**验证：** `git commit --allow-empty -m "feat: test" && git push`

---

## 3. Release PR 合并后无 Tag / Release

**原因：** PAT 权限不足或未被组织批准。

**检查：** PAT 是否包含 `Contents: Read and write`，组织是否已审批。

---

## 4. Build Workflow 未被 Release 触发

**原因：** Release 由 GITHUB_TOKEN 创建，事件被 GitHub 吞掉。

**解决：** `release-please.yml` 中 `token` 必须是 `${{ secrets.RELEASE_TOKEN }}`（PAT）。

---

## 5. workflow_dispatch 按钮不显示

**原因：** Workflow 文件不在默认分支。

**临时方案：** 添加 `push` trigger 限定到测试分支 + paths 限定到 workflow 文件自身。

---

## 6. flutter pub get 找不到 path dependency

**原因：** `working-directory` 导致相对路径不对。

**解决：** `checkout` 在仓库根目录，`flutter pub get` 在 Flutter 项目目录下执行。

---

## 7. Java 版本不匹配

| AGP 版本 | 需要 Java |
|---------|-----------|
| 7.x | 11 |
| 8.x | 17 |
| 9.x | 17 |

---

## 8. APK 上传失败

**检查：**
- `GH_TOKEN` 是否设置为 `secrets.RELEASE_TOKEN`
- upload 步骤 `working-directory` 是否为 `.`（仓库根目录）
- tag 名称是否匹配

---

## 9. push 被拒绝 (non-fast-forward)

**原因：** Release PR 合并后远程有新 commit（CHANGELOG + manifest）。

**解决：** `git stash && git pull --rebase && git stash pop`

---

## 10. 版本号不符合预期

| 配置 | 效果（版本 < 1.0.0 时） |
|------|------------------------|
| `bump-minor-pre-major: true` | BREAKING → minor（不是 major） |
| `bump-patch-for-minor-pre-major: true` | feat → patch（不是 minor） |

---

## 11. release-please--branches--xxx 分支残留

**正常行为。** Settings → Pull Requests → 勾选 "Automatically delete head branches" 自动清理。

---

## 12. 已有 tag 与 Release Please 冲突

**情况：** 项目已有 `v1.2.3` 格式的 tag，但想从该版本继续。

**解决：** manifest 中写入该版本号（如 `"1.2.3"`），不需要 bootstrap-sha（Release Please 会从最近的匹配 tag 开始扫描）。

---

## 13. Monorepo 多包场景

**配置：** `release-please-config.json` 的 `packages` 支持多路径：

```json
{
  "packages": {
    "packages/app-a": { "release-type": "simple" },
    "packages/app-b": { "release-type": "node" }
  }
}
```

每个包独立版本，独立 Release PR。

---

## 14. 已有 semantic-release 需要迁移

**步骤：**
1. 移除 `.releaserc` / `release.config.js`
2. 移除 `package.json` 中 semantic-release 依赖
3. 移除旧 release workflow 中的 semantic-release 步骤
4. 按本 Skill 接入 Release Please
5. manifest 版本设为当前最新 tag 版本
