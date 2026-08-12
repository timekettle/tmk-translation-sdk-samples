#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
蒲公英 IPA/APK 上传脚本
基于 docs/upload_apk.py，简化为独立版本
文档: https://www.pgyer.com/doc/view/api#fastUploadApp
"""

import os
import sys
import argparse
import requests
import subprocess
import base64


def get_git_cur_branch_name():
    """获取当前 Git 分支名"""
    try:
        result = subprocess.run(
            ['git', 'rev-parse', '--abbrev-ref', 'HEAD'],
            capture_output=True, text=True, check=True
        )
        return result.stdout.strip()
    except:
        return "unknown"


def get_git_revision_short_hash():
    """获取当前 Git commit 短哈希"""
    try:
        result = subprocess.run(
            ['git', 'rev-parse', '--short', 'HEAD'],
            capture_output=True, text=True, check=True
        )
        return result.stdout.strip()
    except:
        return "unknown"


def get_git_commit_msg():
    """获取最后一次 commit 信息"""
    try:
        result = subprocess.run(
            ['git', 'log', '-1', '--pretty=%B'],
            capture_output=True, text=True, check=True
        )
        return result.stdout.strip()
    except:
        return "No commit message"


def get_git_last_commit_author():
    """获取最后一次 commit 作者"""
    try:
        result = subprocess.run(
            ['git', 'log', '-1', '--pretty=%an'],
            capture_output=True, text=True, check=True
        )
        return result.stdout.strip()
    except:
        return "unknown"


def upload_apk_to_pyger(file_path, update_msg, api_key, password=None):
    """上传文件到蒲公英"""
    url = "https://www.pgyer.com/apiv2/app/upload"
    data = {
        "_api_key": api_key,
        "buildUpdateDescription": update_msg,
        "buildInstallType": 2 if password else 1,  # 1：公开，2：密码，3：邀请
        "buildPassword": password if password else "",
    }

    try:
        with open(file_path, "rb") as fp:
            files = {"file": fp}
            response = requests.post(url, data=data, files=files, timeout=120)
    except FileNotFoundError:
        return {"code": -1, "msg": f"构建包不存在: {file_path}"}
    except requests.RequestException as exc:
        return {"code": -1, "msg": f"请求蒲公英失败: {exc}"}

    try:
        return response.json()
    except ValueError:
        body_preview = (response.text or "").strip().replace("\n", " ")[:300]
        return {
            "code": -1,
            "msg": "蒲公英返回非 JSON 响应",
            "status_code": response.status_code,
            "content_type": response.headers.get("Content-Type", ""),
            "body_preview": body_preview,
        }


def upload_apk(file_path, api_key, password=None):
    """上传构建包主函数"""

    # 代码仓库基本信息
    git_branch = get_git_cur_branch_name()
    commit_id = get_git_revision_short_hash()
    commit_msg = get_git_commit_msg()
    commit_author = get_git_last_commit_author()

    print("\n" + "="*60)
    print("📦 蒲公英上传")
    print("="*60)
    print(f"📄 文件: {os.path.basename(file_path)}")
    print(f"📏 大小: {os.path.getsize(file_path) / 1024.0 / 1024.0:.2f} MB")
    print(f"🌿 分支: {git_branch}")
    print(f"🔖 Commit: {commit_id}")
    print(f"👤 作者: {commit_author}")
    print("="*60 + "\n")

    # 上传构建包
    print("⏳ 上传中，请稍候...")
    response = upload_apk_to_pyger(file_path, commit_msg, api_key, password=password)

    if not isinstance(response, dict) or response.get('code') != 0:
        print(f'\n❌ 蒲公英上传失败! 错误描述: {response}')
        sys.exit(1)

    # 解析响应
    data = response.get('data')
    if not isinstance(data, dict):
        print(f'\n❌ 蒲公英上传失败! 响应缺少 data 字段: {response}')
        sys.exit(1)

    data_dict = {
        'dlink': 'https://www.pgyer.com/' + data['buildKey'],
        'version': data['buildVersion'],
        'buildNo': data['buildVersionNo'],
        'gitBranch': git_branch,
        'updateDescription': data['buildUpdateDescription'],
        'fileName': data['buildFileName'],
        'updatedTime': data['buildUpdated'],
        'commitId': commit_id,
        'commitAuthor': commit_author,
        'fileSize': str(round((float(data['buildFileSize'])/1024/1024), 2)) + 'MB'
    }

    print("\n" + "="*60)
    print("🎉 上传成功！")
    print("="*60)
    print(f"📱 应用名称: {data['buildName']}")
    print(f"🔢 版本号: V{data_dict['version']}({data_dict['buildNo']})")
    print(f"🔑 Build Key: {data['buildKey']}")
    print(f"🔗 下载链接: {data_dict['dlink']}")
    print(f"📝 更新说明: {data_dict['updateDescription']}")
    print("="*60 + "\n")

    return data_dict


def main():
    parser = argparse.ArgumentParser(description='上传 IPA/APK 到蒲公英')
    parser.add_argument('--path', type=str, required=True, help='IPA/APK 文件路径')
    parser.add_argument('--key', type=str, required=True, help='蒲公英 API Key')
    parser.add_argument('--password', type=str, required=False, default=None, help='安装密码（可选）')
    parser.add_argument("--im-webhook", required=False, help="IM Webhook URL（暂不支持）")
    parser.add_argument("--im-secret", required=False, help="IM Secret（暂不支持）")

    args = parser.parse_args()

    # 上传构建包
    result = upload_apk(file_path=args.path, api_key=args.key, password=args.password)
    if result is None:
        sys.exit(1)

    # 写入 GitHub Actions 环境变量
    if os.getenv('GITHUB_ENV'):
        with open(os.getenv('GITHUB_ENV'), 'a') as f:
            f.write(f"APP_DLINK={result['dlink']}\n")
            f.write(f"PGYER_BUILD_KEY={result['dlink'].split('/')[-1]}\n")
            f.write(f"PGYER_DOWNLOAD_URL={result['dlink']}\n")

            # 生成更新描述（Base64 编码）
            msg = f"""详细信息：
- 版本信息：V{result['version']}({result['buildNo']})
- 更新时间：{result['updatedTime']}
- 分支信息：{result['gitBranch']}/{result['commitId']}
- 代码作者：{result['commitAuthor']}
- 文件大小：{result['fileSize']}

下载链接：
{result['dlink']}

更新日志：
- {result['updateDescription']}
"""
            msg_base64 = base64.b64encode(msg.encode('utf-8')).decode('utf-8')
            f.write(f"APP_UPDATE_DESC_BASE64={msg_base64}\n")

        print("✅ 已设置 GitHub Actions 环境变量")

    # IM 通知（TODO: 需要飞书/钉钉模块支持）
    if args.im_webhook:
        print("⚠️  IM 通知暂未实现（需要 feishu_notify/dingtalk_notify 模块）")


if __name__ == "__main__":
    main()
