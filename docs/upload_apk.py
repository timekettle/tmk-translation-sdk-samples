import requests
import argparse
import textwrap
import dingtalk_notify
import feishu_notify
import tools
import os
import base64

def upload_apk_to_pyger(file_path, update_msg, api_key, password=None):
    url = "https://www.pgyer.com/apiv2/app/upload"
    data = {
        "_api_key": api_key,
        "buildUpdateDescription": update_msg,
        "buildInstallType": 2 if password else 1,  # (可选) 应用安装方式，值为(1,2,3)。1：公开，2：密码安装，3：邀请安装。
        "buildPassword": password if password else "",  # 如果没有提供密码，设置为空字符串
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
    """ 上传构建包, 目前只支持pyger """

    # 代码仓库基本信息
    git_branch = tools.get_git_cur_branch_name() # git 分支信息
    commit_id = tools.get_git_revision_short_hash() # git commit id
    commit_msg = tools.get_git_commit_msg() # git commit msg
    commit_author = tools.get_git_last_commit_author() # git commit id

    # 上传构建包
    response = upload_apk_to_pyger(file_path, commit_msg, api_key, password=password)
    if not isinstance(response, dict) or response.get('code') != 0:
        print('pyger: apk上传失败! 错误描述: ', response)
        return
    # print(response)

    # 上传im
    data = response.get('data')
    if not isinstance(data, dict):
        print('pyger: apk上传失败! 响应缺少 data 字段: ', response)
        return
    data_dict = {
        'dlink': 'https://www.pgyer.com/' + data['buildKey'], # 下载链接
        'version': data['buildVersion'],
        'buildNo': data['buildVersionNo'],
        'gitBranch': git_branch,
        'updateDescription': data['buildUpdateDescription'],
        'fileName': data['buildFileName'],
        'updatedTime': data['buildUpdated'],
        'commitId': commit_id,
        'commitAuthor': commit_author, # 代码作者
        'fileSize': str(round((float(data['buildFileSize'])/1024/1024),2)) +'MB' # 文件大小
    }

    return data_dict

def main():
    # 使用argparse从命令行获取参数
    parser = argparse.ArgumentParser(description='Upload an apk to Pgyer.')
    parser.add_argument('--path', type=str, required=True, help='Path to the apk file.')
    parser.add_argument('--key', type=str, required=True, help='Your Pgyer API Key.')
    parser.add_argument('--password', type=str, required=False, help='Password for the apk.', default=None)  # 密码参数现在是可选的

    #################################################### 临时
    parser.add_argument("--im-webhook", required=False, help="IM Webhook URL")
    parser.add_argument("--im-secret", required=False, help="IM Secret for signing (optional)")
    #################################################### 临时
    args = parser.parse_args()

    # 上传构建包
    result = upload_apk(file_path=args.path, api_key=args.key, password=args.password)
    if result is None:
        return

    # 上传im
    data_dict = {
        '下载链接': result['dlink'],
        '版本号': result['version'],
        'Build号': result['buildNo'],
        'Git分支': result['gitBranch'],
        '更新内容': result['updateDescription'],
        '文件名': result['fileName'],
        '更新时间': result['updatedTime'],
        '提交ID': result['commitId'],
        '代码作者': result['commitAuthor'],
        '文件大小': result['fileSize'],
    }

    # 更新内容详情
#     '''
#   ### [🚀Timekettle-iOS: Timekettle2022.ipa](https://www.pgyer.com/5f85d6105c4c5c931e76519357f7dd42)
#   详细信息:
#   - 版本信息: V3.4.14(12823562)
#   - 更新时间: 2026-02-06 00:26:09
#   - 分支信息: /a8c59551
#   - 代码作者: decin
#   - 文件大小: 153.2MB

#   下载链接：
#   https://www.pgyer.com/5f85d6105c4c5c931e76519357f7dd42

#   更新日志:
#   - <font color=#008000>feat: 发送消息到飞书</font><br>
#     '''
    title = "🚀Timekettle-iOS更新"
    msg = textwrap.dedent('''
                          详细信息：
                          - 版本信息：V{版本号}({Build号})
                          - 更新时间：{更新时间}
                          - 分支信息：{Git分支}/{提交ID}
                          - 代码作者：{代码作者}
                          - 文件大小：{文件大小}

                          下载链接：
                          {下载链接}

                          更新日志：
                          - <font color=#008000>{更新内容}</font>
                          '''.format(**data_dict))
    
    # 向 GITHUB_ENV 写入环境变量
    os.system(f'echo "APP_DLINK={result["dlink"]}" >> $GITHUB_ENV')
    msg_base64 = base64.b64encode(msg.encode('utf-8')).decode('utf-8')
    os.system(f'echo "APP_UPDATE_DESC_BASE64={msg_base64}" >> $GITHUB_ENV') # 更好的方式是使用多行文本形式 https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/workflow-commands-for-github-actions#example-of-a-multiline-string

    # 发送钉钉消息 
    im_webhook = args.im_webhook
    if not im_webhook:
        return
    im_secret = args.im_secret
    # dingtalk_notify.send_dingtalk_message(im_webhook, im_secret, title, msg)
    msg = tools.MarkdownFormatter.to_im_text(msg)
    feishu_notify.send_feishu_message(
        webhook=im_webhook,
        title=title,
        message=msg,
        secret=im_secret,
    )


if __name__ == "__main__":
    main()