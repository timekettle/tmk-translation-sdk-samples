# Sauce Labs Android 在线收听冒烟测试

这个测试运行 Android 原生 Sample 的「收听模式 → 在线翻译」。默认音频输入是麦克风；切到「测试音频」后，**URL 留空**时 App 使用安装包内的 `saucelabs_en_0_16k_mono_s16le.pcm`，**填写 HTTPS PCM URL 并点击「下载测试音频」且下载成功**后使用真机 App 下载到私有缓存的 PCM。URL 非空但未下载成功时不能开始收听，不会自动改用包内音频。两种测试音频都按每 20 ms 一帧（640 字节，16 kHz、单声道、16-bit little-endian PCM）推入现有 SDK 入口，结束后再推送 1 秒静音。包内音频来自用户提供的 `en_0.pcm`；它在双声道对话测试套件中是单独的左声道文件，本测试只使用这一路。

App 不对下载文件做重采样或声道转换；远程文件须预先制作为上述 PCM 格式。下载时只能核对响应、大小和哈希，无法从裸 PCM 自动证明采样率或声道数。

脚本检查测试音频已推送完成，并收到识别、翻译及有声 TTS PCM 回调。App 从第一帧测试 PCM 推入 SDK 开始计时，记录首个非空 ASR/MT 文本回调、首个音频回调及首个有声 TTS PCM 包回调。SDK 可能先回调静音音频；有声判定沿用 L3 的 PCM16LE 阈值（存在绝对值大于 2 的采样）。脚本用人工原文计算 WER、CER 与 `max(0, 100-WER)` 准确度。翻译匹配度使用 L4 的原文到译文语义评分，需要 `TMK_L4_LLM_API_KEY`；可选 `TMK_L4_LLM_MODEL`，默认 `gpt-4o`。

本目录的 [test_online_listen.py](test_online_listen.py) 是原生 Android 的单条真机测试入口：建立 Sauce Appium 会话，选择英语→中文与测试音频，可选让 App 下载 HTTPS PCM，核对下载结果，运行在线收听并写入 JSON/Markdown 报告。它不执行多语种批量测试；批量测试入口位于 Flutter 工程的 `saucelabs/` 目录。

## 准备

1. 按 [Android Sample README](../README.md) 配置 SDK 与 Sample 鉴权参数，确认鉴权服务登记的 `app_package_name` 为固定的安装包名 `co.timekettle.saas.sample`。在 `Android` 目录使用 JDK 17 执行 `./gradlew :app:assembleDebug -PTMK_SAUCE_DEVICE_DIAGNOSTICS=true`，构建带首页定位诊断按钮的 APK。省略该参数时不显示定位按钮；指定地区信号的云测要求使用带按钮的新包。
2. 将生成的 APK 上传到 Sauce Labs **同一个数据中心**的 App Management，复制该包的 File ID。
   原生 Android 与 Flutter Android 当前都使用 `co.timekettle.saas.sample`；只看包名无法区分。此脚本要求上传 [原生 Android APK](../app/build/outputs/apk/debug/tmk-translation-sdk-samples-1.3.6.apk)，并将它的 File ID 赋给 `SAUCE_APP`。若上传的是 Flutter APK，请运行 Flutter 工程里的 Sauce 脚本。
3. 在 Sauce Labs 真机列表里选择一台 Android 真机，记下设备名称或 ID。脚本使用动态名称匹配，因此也可以填设备名的正则表达式。
4. 安装 Python 依赖：`python3 -m pip install -r saucelabs/requirements.txt`。

## 运行

在 `Android` 目录设置环境变量，然后执行：

```bash
export SAUCE_USERNAME='your-username'
export SAUCE_ACCESS_KEY='your-access-key'
export SAUCE_REGION='us-west-1'
export SAUCE_APP='storage:your-file-id'
export SAUCE_DEVICE_NAME='your-android-real-device-name-or-id'
export TMK_L4_LLM_API_KEY='your-quality-evaluator-key'
python3 saucelabs/test_online_listen.py
```

### 验证 App 自己从 HTTPS 下载

先用上述构建命令重新生成 APK 并上传到 Sauce，旧 APK 没有下载入口。把 OSS 签名 URL 粘到 [test_online_listen.py](test_online_listen.py) 顶部的 `TEST_PCM_URL = "PASTE_HTTPS_PCM_URL_HERE"`，或使用环境变量（推荐，避免把签名参数写进 Git）：

```bash
export SAUCE_TEST_PCM_URL='https://你的域名/路径/en_0.pcm?...'
export SAUCE_DOWNLOAD_ONLY=1
python3 saucelabs/test_online_listen.py
```

脚本先检查 URL，再创建 Sauce 会话。它在真机 App 的收听页输入 URL、点击“下载测试音频”，由 App 发起 HTTPS GET。`TEST_DOWNLOAD`、`report.json` 和 `report.md` 记录 App 实测的域名、HTTP 状态、实际字节数、SHA-256、耗时和错误类型；脚本要求 HTTP 200、679254 字节及 SHA-256 `9167766ca3d9a18d2f5f9d24a4bbf225b952dddab946dfba88607f15c61dbcfc`。`SAUCE_DOWNLOAD_ONLY=1` 成功后即结束，不要求 LLM 评分 Key；省略它则继续把刚下载的 PCM 按原节奏推入 SDK 跑完整收听测试。URL 留空时仍使用包内 PCM。签名 URL 可能进入 Sauce 的 Appium 命令日志，因此建议使用短有效期、只读、仅此文件的地址；本地报告会掩盖完整 URL。

`SAUCE_REGION` 可用值为 `us-west-1`、`us-east-4`、`eu-central-1`、`asia-south-2`，需要账号对目标数据中心有权限。Appium 版本默认使用 Sauce 当前支持的 `latest`；如需固定版本，可设置 `SAUCE_APPIUM_VERSION=appium3-2026-10` 等当前账号可用的版本。可选的 `SAUCE_BUILD` 用于把测试结果归入指定构建。运行结果出现在 `Automated → Test Results → Real Devices`；脚本会把成功或失败状态回报给 Sauce Labs。URL 留空时 PCM 从 APK 读取；设置 URL 后由真机 App 自行从 HTTPS 下载。两种方式都不会从电脑向真机实时推送音频。

可选地在同一数据中心指定目标 GPS、语言区域和时区。未设置的信号沿用真机默认值；每次运行创建新的 Sauce 会话：

```bash
export SAUCE_TEST_LATITUDE='48.8566'
export SAUCE_TEST_LONGITUDE='2.3522'
export SAUCE_TEST_LOCALE='fr_FR'
export SAUCE_TEST_TIMEZONE='Europe/Paris'
python3 saucelabs/test_online_listen.py
```

脚本在读取 App 定位前调用 Appium 设置模拟 GPS，在创建会话时设置 Android 系统语言区域与时区。指定目标后，它核对 App 实测的 GPS、语言区域及时区；GPS 与目标的距离超过 50 km 或不能从 App 内核实，就判失败。`SAUCE_REGION` 只选择 Sauce 数据中心，不会代替 GPS 设置，也不能证明应用请求使用了哪个公网出口 IP。

## 输出

脚本在终端或 CI 日志中先打印本次会话的设备环境，再打印识别与翻译条数。例如：

```text
TEST_ENVIRONMENT={"sauce_data_center": "us-west-1", "session_id": "...", "device_name": "...", "device_locale": "en_US", "device_language": "en", "device_timezone": "America/Los_Angeles", "gps": {"latitude": 37.77, "longitude": -122.42}, "gps_source": "app_android_location", "address_summary": "United States / California / San Francisco", "geocode_status": "ok", "capture_errors": {}}
Received online listening results: ASR=2, translation=2
```

示例值不代表实际设备。`sauce_data_center` 是本次连接的 Sauce 数据中心；`device_locale`、`device_language` 和 `device_timezone` 由 Appium 的 `mobile: deviceInfo` 读取。带定位诊断按钮的 APK 会在脚本点击“读取设备定位”后，通过 Android `LocationManager` 读取 App 实测坐标，再由 `Geocoder` 解析国家、州/省、郡/县、城市、区、街道、门牌号和邮编；解析服务未必返回每一层。`gps_source` 标明来源，`gps_accuracy_m` 记录设备报告的水平精度。地址解析失败时仍保留 GPS，并在 `geocode_status`、`capture_errors.reverse_geocode` 记录原因。`app_device_locale`、`app_device_timezone` 是 App 内实测值，`sample_network_environment` 是 Sample 当前 SDK 网络环境。数据中心、GPS、语言和时区是不同的信息；本脚本的翻译方向固定为 `en-US → zh-CN`。

如果设备或权限不支持读取某项，对应值为 `null`，`capture_errors` 会记录失败的 API 和异常类型；未指定目标地区时不影响翻译测试的通过判定。脚本用 `TEST_STEP` 标记当前步骤。每次运行都会在 `saucelabs/artifacts/<session-id>/` 保存 `report.json` 和易读的 `report.md`，终端的 `TEST_REPORT` 会打印这两个文件的绝对路径。报告包含通过/失败、开始结束时间、设备环境、目标地区设置、App 实测坐标及可读地址、执行步骤、结果条数、质量指标与文本，以及失败步骤和原因。会话尚未创建就失败时，目录名以 `setup-` 开头。

失败时还会在同一目录保存截图 `failure.png` 和界面 XML `page.xml`；终端中的 `TEST_DIAGNOSTICS` 会给出路径。`artifacts/` 不纳入 Git。这些文件保存在运行脚本的电脑或 CI runner 上，不在 Sauce 真机里；若在临时 CI runner 上运行，需要由 CI 的 artifact 上传步骤保留。Sauce 的 `Automated → Test Results → Real Devices` 页面另有会话记录及平台生成的媒体和日志。报告另含首 ASR/MT/有声 TTS 回调时延、首个音频回调（含静音）、WER/CER/准确度、翻译语义匹配度及最终文本。缺少评分 Key 或评分失败时，已采集指标仍保存，但测试判失败。首个有声 TTS PCM 包并非扬声器实际出声；本测试从第一帧测试 PCM 计时，与 L4 的 trace/语音片段口径不同。

如果在 App 中手动验证，进入「收听模式 → 在线翻译」，将语言设为英语到中文，在收听页选择「测试音频」并点击「开始收听」。
