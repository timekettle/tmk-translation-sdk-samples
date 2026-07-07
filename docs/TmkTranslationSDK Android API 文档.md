# TmkTranslationSDK Android API 文档

# TmkTranslationSDK Android API 文档

## 文档版本信息

|项目|说明|
|---|---|
|当前文档适配版本|v1\.2\.0|
|最近更新日期|2026\-06\-24|

## 本次更新

当前版本更新内容：

- 新增频道语言列表接口 getOnlineSupportedLanguages\(version, callback\) 与 getOfflineSupportedLanguages\(version, callback\)，通过 TmkLocaleListCallback 返回 TmkLocaleListResponse（含按 code 去重的 localeOptions），用于驱动语言选择 UI；接口不依赖鉴权，内置磁盘快照缓存，网络失败或无增量时回退缓存。

- 建房接口改为通过 TmkTranslationRoomConfig 创建：createTmkTranslationRoom\(config, callback\) 在建房时即完成在线对话链路准备，回调返回的房间已含 dialog 数据，可直接用于建通道；原无参重载仅保留兼容、不再推荐。

- 新增 TmkTranslationSDK\.sdkVersion 接口，可获取当前 SDK 版本号。

- 新增离线 License 鉴权能力，离线能力可在 verifyAuth\(callback\) 后通过 isOfflineTranslationSupported\(\) 判断。

- 新增离线模型包管理能力，可查询模型包状态、下载语言对模型、取消下载并异步检查模型是否就绪。

- 新增离线一对一 TTS 输出声道模式，可选择单声道或立体声输出。

- 新增通道状态、错误和事件处理契约，便于业务侧统一处理启动、运行、重连、失败和释放状态。

- TmkTranslationException 新增 actualErrorCode / actualErrorMessage / actualErrorDomain 字段：来自后台或底层（native）的原始错误，errorCode 始终为统一 SDK 错误码，原始错误码与信息保留在这三个字段中，便于排障且不破坏统一码契约；离线 License 失败的 native 返回码（1001–1099）也通过 actualErrorCode 暴露。该改动为纯增量、向后兼容，原有按 errorCode 的用法无需修改。

- 新增在线 bubble\_end 事件与 TTS 高亮事件说明，业务侧可按 bubble\_id 标记气泡结束，并按 session\_id / chunk\_id 更新播放高亮。

- 新增在线翻译引擎策略设置与运行中切换说明，支持 AUTOMATIC、FAST、ACCURATE。

- 新增在线房间能力设置与运行中切换说明，支持单 ASR、ASR\+MT 文本输出、ASR\+MT\+TTS 语音输出。

- Android 全局配置补齐在线鉴权上下文、网络环境和自定义服务端地址设置说明。

- 网络环境枚举为 DEV、TEST、PRE，历史区域环境不再作为公开接入枚举。

- releaseChannel\(\) 释放当前通道时会异步关闭当前在线房间；页面退出、切换房间或切换语言对时建议优先使用。

- 新增 Android release 混淆加固维护说明，覆盖公开 API、离线模型、状态模型、音色和埋点 SPI 的 keep 规则。

## 简介

TmkTranslationSDK 用于将业务侧采集的 PCM 音频接入翻译能力，并向业务侧返回：

- 识别文本

- 翻译文本

- 翻译后的 PCM 音频

- 通道状态与错误信息

- 诊断日志与离线模型状态

当前 SDK 同时支持：

- 在线翻译

- 离线翻译

- 收听模式（单声道）

- 一对一模式（双声道）

本文面向外部接入方，重点说明：

- SDK 初始化与鉴权

- 在线/离线接入流程

- 所有公开接口与数据模型

- 常见使用方式与注意事项

---

## 接入前准备

### 2\.1 环境要求

|项目|说明|
|---|---|
|最低系统版本|minSdk 28|
|Java/Kotlin 目标版本|11|
|发布产物|co\.timekettle\.translation:tmk\-translation\-sdk|
|运行环境|Android 真机或可访问音频/网络能力的测试设备|

### 2\.2 权限要求

在线模式需要网络权限：

```Plain Text
<uses-permission android:name="android.permission.INTERNET" />
```

如果业务侧自行录音并向 SDK 推送 PCM，需要声明麦克风权限：

```Plain Text
<uses-permission android:name="android.permission.RECORD_AUDIO" />
```

> SDK 负责消费业务侧传入的 PCM 数据；录音权限申请、录音器管理和用户授权提示由宿主 App 负责。
> 
> 

### 2\.3 依赖配置

#### 2\.3\.1 通过Maven Central安装

可通过Maven Central安装，以具体版本号为准

```Plain Text
dependencies {
    implementation("co.timekettle.translation:tmk-translation-sdk:1.2.0")
}
```

如具体发布版本与本文不一致，请以发布说明为准。

#### 2\.3\.2 通过下载安装

AAR下载地下：

https://github\.com/timekettle/tmk\-translation\-sdk/releases/download/v\{version\}/tmk\-translation\-sdk\-\{version\}\.aar

请替换version为具体版本号，如下：

https://github\.com/timekettle/tmk\-translation\-sdk/releases/download/v1\.2\.0\-rc3/tmk\-translation\-sdk\-1\.2\.0\-rc3\.aar



设置必要的Android依赖库

### 2\.4 网络配置

生产环境建议使用 HTTPS。若联调环境使用 HTTP，需要按 Android 要求配置 networkSecurityConfig 允许明文流量：

```Plain Text
<network-security-config>
    <base-config cleartextTrafficPermitted="true" />
</network-security-config>
```

## 核心流程总览

### 3\.0 startInitAfter解释

startInitAfter是内部属性，是createTranslationChannel传listener时startInitAfter就是true,接口关系具体可参数以下表格

|重载签名|内部|行为|
|---|---|---|
|createTranslationChannel\(context, config, callback\)|false|只 init \+ join,不自动 start|
|createTranslationChannel\(context, config, callback, options\)|false|同上,可配置超时|
|createTranslationChannel\(context, config, listener, callback\)|true|init \+ join \+ 自动start,创建即可推流|
|createTranslationChannel\(context, config, listener, callback, options\)|true|同上,可配置超时|

### 3\.1 在线翻译

在线模式典型流程：

1. sdkInit

2. getOnlineSupportedLanguages\(version, callback\)

3. verifyAuth

4. createTmkTranslationRoom

5. createTranslationChannel 需要startInitAfter = true

6. channel\.pushStreamAudioData

7. releaseChannel

8. destroy

### 3\.2 离线翻译

离线模式典型流程：

1. sdkInit

2. getOfflineSupportedLanguages\(version, callback\)

3. verifyAuth

4. isOfflineTranslationSupported

5. isOfflineModelReady 或 downloadOfflineModels

6. createTmkTranslationRoom

7. createTranslationChannel（config\.mode = TranslationMode\.OFFLINE）

8. pushStreamAudioData

9. releaseChannel

10. destroy

Android 当前离线通道仍通过统一的 createTranslationChannel 入口创建，并要求配置 room。离线模式不会使用在线 RTC/RTM 状态原因，但通道生命周期和回调入口与在线保持一致。

### 3\.3 回调线程说明

SDK 对外异步回调会切回主线程后再回调业务方，包括：

- verifyAuth

- createTranslationChannel 的启动型重载

- TmkOfflineModelDownloadListener

- checkOfflineModelReadyAsync

- updateSpeaker 结果回调

TmkTranslationListener 的状态、文本、音频、事件回调可直接用于更新 UI；业务侧仍应避免在回调中执行耗时任务。

### 3\.4 在线与离线的主要区别

|项目|在线翻译|离线翻译|
|---|---|---|
|是否依赖 verifyAuth|是|建议先鉴权，用于确认离线能力|
|是否需要房间对象|需要|当前 Android 统一入口仍需要|
|是否需要离线模型|不需要|需要|
|通道创建接口|createTranslationChannel|createTranslationChannel|
|运行状态原因|包含 RTC/RTM、网络、服务端原因|主要来自模型、pipeline、离线鉴权和引擎状态|

---

## 初始化与鉴权

### 4\.1 TmkTranslationSDK

Android SDK 入口是 Kotlin object：

```Plain Text
TmkTranslationSDK
```

#### sdkVersion

获取当前 SDK 版本号，返回不带前缀的语义化版本字符串（如 1\.2\.0）。该属性为静态只读，无需初始化即可读取。

```Plain Text
@JvmStatic
val sdkVersion: String
```

示例：

```Plain Text
val version = TmkTranslationSDK.sdkVersion // "1.2.0"
```

Java 调用：

```Plain Text
String version = TmkTranslationSDK.getSdkVersion();
```

### 4\.2 sdkInit\(context, config\)

用于初始化 SDK 全局配置。

```Plain Text
fun sdkInit(context: Context, config: TmkTransGlobalConfig)
```

参数说明：

|参数|说明|
|---|---|
|context|建议传入 ApplicationContext，SDK 内部会保存 application context|
|config|SDK 全局配置对象|

行为说明：

- 初始化鉴权、诊断日志、MMKV 和埋点基础设施。

- 不会自动触发鉴权。

- 调用 destroy\(\) 后，如需继续使用，必须重新调用 sdkInit\(context, config\)。

示例：

```Plain Text
val globalConfig = TmkTransGlobalConfig.Builder()
    .setAuth("your_app_id", "your_app_secret")
    .setDiagnosisEnabled(true)
    .setDiagnosisConsoleEnabled(false)
    .build()

TmkTranslationSDK.sdkInit(applicationContext, globalConfig)
```

### 4\.3 verifyAuth\(callback\)

执行在线/离线鉴权。

```Plain Text
fun verifyAuth(callback: AuthCallback)
```

回调说明：

```Plain Text
interface AuthCallback {
    fun onSuccess()
    fun onError(errorId: Int, e: Exception)
}
```

行为说明：

- 首次调用前必须完成 sdkInit\(context, config\)。

- 在线翻译必须先鉴权成功。

- verifyAuth\(callback\) 内部会先执行在线鉴权；在线鉴权成功后，如果服务端开启离线能力，会继续尝试 License 获取和离线鉴权，用于记录离线支持状态。

- 对齐 iOS：最终 onSuccess/onError 只由在线鉴权结果决定；离线开关关闭、License 获取失败或离线 License 鉴权失败都不会导致本次 verifyAuth\(callback\) 失败，但会影响离线能力状态。

- 并发调用 verifyAuth\(callback\) 时，SDK 会合并同一轮鉴权请求，并把结果回调给所有等待方。

示例：

```Plain Text
TmkTranslationSDK.verifyAuth(object : AuthCallback {
    override fun onSuccess() {
        val offlineEnabled = TmkTranslationSDK.isOfflineTranslationSupported()
    }

    override fun onError(errorId: Int, e: Exception) {
        // errorId 通常对应 TmkTranslationException.ErrorCodes
        // 如需后台/native 原始错误码，可读取 (e as? TmkTranslationException)?.actualErrorCode
    }
})
```

### 4\.4 isOfflineTranslationSupported\(\)

查询当前鉴权上下文是否支持离线翻译。

```Plain Text
fun isOfflineTranslationSupported(): Boolean
```

返回值：

- true：当前鉴权上下文支持离线翻译。

- false：当前账号未开通离线翻译能力，或尚未完成鉴权。

注意：

- 建议在 verifyAuth\(callback\) 成功后再调用。

- verifyAuth\(callback\) 成功仅表示在线鉴权成功；如果后台未开启离线能力，当前接口仍会返回 false。

---

## 全局配置 TmkTransGlobalConfig

### 5\.1 TmkTransGlobalConfig\.Builder

|Builder 方法|说明|
|---|---|
|setAuth\(appId, secret\)|设置业务鉴权凭据|
|setOnlineAuthContext\(tenantId, externalUserId, installId\)|设置在线鉴权扩展上下文，externalUserId 优先级高于 installId|
|setDiagnosisEnabled\(enabled\)|是否启用 SDK 诊断日志，默认 true|
|setDiagnosisConsoleEnabled\(enabled\)|是否同步输出诊断日志到控制台，默认 true|
|setNetworkEnvironment\(environment\)|设置预置网络环境|
|setNetworkBaseURL\(url\)|设置自定义服务端地址，优先级高于预置环境|
|build\(\)|构建 TmkTransGlobalConfig|

### 5\.2 TmkTranslationNetworkEnvironment

SDK 内置环境枚举：

```Plain Text
enum class TmkTranslationNetworkEnvironment {
    DEV,
    TEST,
    PRE
}
```

建议：

- DEV 仅用于开发调试，对外接入请优先使用 TEST 或 Timekettle 指定环境。

- setNetworkBaseURL\(url\) 一般只用于联调或特殊接入，不建议线上随意切换。

- 自定义地址必须是合法 http 或 https URL；SDK 会在构建配置时做基础格式归一。

### 5\.3 凭据说明

appId / clientSecret 是业务鉴权凭据，建议通过 Gradle properties、环境变量或 CI Secret 注入，不要写入公开仓库。

```Plain Text
val appId = BuildConfig.TMK_APP_ID
val appSecret = BuildConfig.TMK_APP_SECRET

val config = TmkTransGlobalConfig.Builder()
    .setAuth(appId, appSecret)
    .setOnlineAuthContext(
        tenantId = "your_tenant_id",
        externalUserId = "your_external_user_id",
        installId = "your_install_id"
    )
    .setNetworkEnvironment(TmkTranslationNetworkEnvironment.TEST)
    .build()
```

说明：

- tenantId、externalUserId、installId 均为可选扩展参数，按 Timekettle 为接入方分配的鉴权策略填写。

- 同时传入 externalUserId 和 installId 时，SDK 使用 externalUserId 作为业务用户维度，忽略 installId。

---

## 支持语言说明

### 6\.1 Android 当前公开能力

Android 提供获取在线 / 离线翻译当前支持语言列表的公开接口，用于驱动语言选择 UI。两个接口都依赖 sdkInit\(context, config\)、不依赖鉴权，内部带磁盘快照缓存：网络失败或服务端无增量时回退本地缓存。

```Plain Text
@JvmStatic
@JvmOverloads
fun getOnlineSupportedLanguages(
    version: String? = null,
    callback: TmkLocaleListCallback,
): Cancelable

@JvmStatic
@JvmOverloads
fun getOfflineSupportedLanguages(
    version: String? = null,
    callback: TmkLocaleListCallback,
): Cancelable
```

参数说明：

|参数|必填|说明|
|---|---|---|
|version|否|本地缓存版本号；不传时优先复用 SDK 已保存的版本号发起增量请求。|
|callback|是|TmkLocaleListCallback，onSuccess\(response\) 返回语言列表，onError\(errorId, e\) 返回统一错误。|

返回值：Cancelable，可取消的请求句柄。

回调与数据模型：

```Plain Text
interface TmkLocaleListCallback {
    fun onSuccess(response: TmkLocaleListResponse)
    fun onError(errorId: Int, e: Exception)
}

data class TmkLocaleListResponse(
    val version: String?,                 // 服务端配置版本号
    val languages: List<TmkLocaleLanguage>,
) {
    val localeOptions: List<TmkLocaleItem> // 展平并按 code 去重，可直接用于语言选择 UI
}

data class TmkLocaleLanguage(
    val code: String,        // 语言编码，例如 en
    val displayName: String, // 语言展示名称，例如 英语
    val locales: List<TmkLocaleItem>, // 该语言下的地区/口音；离线配置可为空
)

data class TmkLocaleItem(
    val code: String,        // 地区/口音编码，例如 en-US
    val displayName: String, // 地区/口音展示名称，例如 美国
)
```

> localeOptions 会按 code 去重并保留首次出现顺序：服务端可能把同一 code（如粤语 zh\-HK）下发在多个语言分组下，去重后避免 UI 出现重复选项。
> 
> 

示例：

```Plain Text
TmkTranslationSDK.getOnlineSupportedLanguages(callback = object : TmkLocaleListCallback {
    override fun onSuccess(response: TmkLocaleListResponse) {
        val options = response.localeOptions.map { "${it.displayName}(${it.code})" }
        // 用 options 刷新语言选择 UI
    }
    override fun onError(errorId: Int, e: Exception) {
        // 统一错误处理
    }
})
```

### 6\.2 在线与离线语言差异

|项目|在线|离线|
|---|---|---|
|语言代码|通常使用 BCP\-47，例如 zh\-CN、en\-US|可传 zh、zh\-CN、zh\-HK、en、en\-US 等，SDK 会归一为主语言标签|
|当前主要支持|以在线服务配置为准|由 License scope 与已下载的离线模型决定；当前服务端 scope 未下发语种限制，可用语种取决于对应模型是否下载完整|
|不支持语言|创建房间/通道或运行时返回错误|SDK 层不做语种白名单拦截；缺少对应模型时在模型资源校验阶段报 OFFLINE\_MODEL\_NOT\_READY，底层引擎拒绝非法 locale 时才返回 2001113 / INVALID\_LANGUAGE\_CODE|

业务侧需要让用户重新选择支持语言后再重试。在线模式建议重新创建对话；离线模式建议先确认对应语种模型已下载完整，再重新初始化离线通道并重新检查模型资源。

---

## 在线翻译：房间与通道

### 7\.1 房间类型 TmkTranslationRoom

```Plain Text
data class TmkTranslationRoom(
    var roomId: String
)
```

公开方法：

|方法|说明|
|---|---|
|updateRoomLocale\(sourceLocales, targetLocales, callback\)|运行中更新在线房间语言；要求当前 room 已有关联的 active channel|
|updateTranslateEngine\(engine, callback\)|运行中切换在线翻译引擎策略|
|updateScenario\(scenario, callback\)|运行中切换在线房间能力|

updateRoomLocale\(\.\.\.\) 成功后会返回 Result\<Unit\>，extraData 中包含更新后的 source\_locales 与 target\_locale。如果当前房间没有活动在线通道，会返回 INVALID\_STATE。语言切换只影响切换后新建的气泡：正在进行的旧气泡会保留其创建时锁定的源/目标语言（旧气泡译文文本仍是旧语言，标签也应保持旧语言）；一对一场景下，sourceLocales 对应左声道、targetLocales 对应右声道，左右两侧气泡的源/目标语言方向各自正确。业务侧无需为旧气泡手动纠正语言标签。

updateTranslateEngine\(\.\.\.\) 成功后会返回 Result\<Unit\>，extraData\["translate\_engine"\] 为当前切换的引擎值；该能力仅影响在线房间，通常对后续服务端处理生效。

updateScenario\(\.\.\.\) 成功后会返回 Result\<Unit\>，extraData\["scenario"\] 为当前房间能力值。业务侧应按新能力调整 UI、播放和结果展示。

### 7\.2 createTmkTranslationRoom\(config, callback\)

创建翻译房间。推荐使用 TmkTranslationRoomConfig 配置对象创建在线房间：

```Plain Text
fun createTmkTranslationRoom(
    config: TmkTranslationRoomConfig,
    callback: CreateRoomCallback,
): Cancelable
```

TmkTranslationRoomConfig 为建房专用配置（与通道配置 TmkTransChannelConfig 区分，仅包含建房所需参数）：

```Plain Text
class TmkTranslationRoomConfig private constructor() {
    var scenario: Scenario?                     // 必填，通道场景：LISTEN / ONE_TO_ONE
    var sourceLang: String                      // 源语言，默认 "en"
    var targetLang: String                      // 目标语言，默认 "zh"
    var speakers: List<TmkSpeaker>              // 在线建房初始 TTS 音色，可空
    var onlineTranslateEngine: TmkOnlineTranslateEngine // 在线引擎初始策略，默认 AUTOMATIC
    var translateMode:TmkTranslateDeliveryMode   //翻译下发模式，默认DEFUALT
    var roomScenario: TmkRoomScenario           // 在线房间初始能力，默认 TRANSLATE_SPEECH_TO_SPEECH

    class Builder {
        fun setScenario(scenario: Scenario): Builder
        fun setSourceLang(langCode: String): Builder
        fun setTargetLang(langCode: String): Builder
        fun setSpeakers(speakers: List<TmkSpeaker>): Builder
        fun setOnlineTranslateEngine(engine: TmkOnlineTranslateEngine): Builder
        fun setTranslateMode(mode: TmkTranslateDeliveryMode): Builder
        fun setRoomScenario(roomScenario: TmkRoomScenario): Builder
        fun build(): TmkTranslationRoomConfig   // scenario 未设置会抛 IllegalArgumentException
    }
}
```

回调说明：

```Plain Text
interface CreateRoomCallback {
    fun onSuccess(room: TmkTranslationRoom)
    fun onError(errorId: Int, e: Exception)
}
```

行为说明：

- 必须先调用 sdkInit\(context, config\)。

- SDK 在建房时即向服务端完成在线对话链路准备，onSuccess 返回的 TmkTranslationRoom 已包含创建通道所需的 dialog 数据（roomNo、订阅信息等）；业务侧无需再等到通道启动。

- 返回 Cancelable，可在回调前取消建房请求。

- 建房成功若检测到已有房间/通道，SDK 会先释放旧会话再切换到新房间。

- scenario 决定通道场景（LISTEN / ONE\_TO\_ONE），roomScenario 决定初始在线房间能力，onlineTranslateEngine 决定初始在线引擎策略；运行中可分别通过 room\.updateScenario\(\.\.\.\)、room\.updateTranslateEngine\(\.\.\.\) 切换。

- 回调在主线程触发。

示例：

```Plain Text
val roomConfig = TmkTranslationRoomConfig.Builder()
    .setScenario(Scenario.LISTEN)
    .setSourceLang("zh-CN")
    .setTargetLang("en-US")
    .setRoomScenario(TmkRoomScenario.TRANSLATE_SPEECH_TO_SPEECH)
    .build()

val cancelable = TmkTranslationSDK.createTmkTranslationRoom(roomConfig, object : CreateRoomCallback {
    override fun onSuccess(room: TmkTranslationRoom) {
        // room 已含 dialog 数据，可直接用于构建 TmkTransChannelConfig
    }
    override fun onError(errorId: Int, e: Exception) { }
})
```

> 兼容的无参重载 createTmkTranslationRoom\(callback\) 仅生成本地 roomId、不预备在线链路，已不再作为推荐接入方式，新接入请使用上面的 config 重载。
> 
> 

---

## 通道配置 TmkTransChannelConfig

### 8\.1 Scenario

|枚举|说明|
|---|---|
|LISTEN|收听/单声道听译|
|ONE\_TO\_ONE|一对一/双声道同传|
|PRESENTATION|演讲模式，当前文档不作为主接入流程展开|
|LISTEN\_FAR|远场听译，当前文档不作为主接入流程展开|

### 8\.2 TranslationMode

|枚举|说明|
|---|---|
|ONLINE|在线翻译|
|OFFLINE|离线翻译|
|AUTO|自动模式，当前不建议作为生产主流程|
|MIX|混合模式，当前不建议作为生产主流程|

### 8\.3 EngineType

|枚举|说明|
|---|---|
|ONLINE|在线引擎|
|OFFLINE|离线引擎|

### 8\.4 TransModeType

在线底层引擎模式类型：

|枚举|说明|
|---|---|
|LISTEN|听译模式|
|ONE\_TO\_ONE|同传模式|
|PRESENTATION|演讲模式|
|LISTEN\_FAR|远场听译|
|NONE|未指定|

### 8\.4\.1 TmkRoomScenario

在线房间能力：

|枚举|说明|
|---|---|
|RECOGNIZE|单 ASR，只输出识别文本|
|TRANSLATE\_SPEECH\_TO\_TEXT|ASR\+MT，输出文本翻译，不要求 TTS 语音合成|
|TRANSLATE\_SPEECH\_TO\_SPEECH|ASR\+MT\+TTS，输出识别文本、翻译文本和翻译音频|

建房/创建通道时可通过 TmkTransChannelConfig\.Builder\.setRoomScenario\(\.\.\.\) 设置初始能力，运行中可通过 room\.updateScenario\(\.\.\.\) 切换。

### 8\.4\.2 TmkOnlineTranslateEngine

在线翻译引擎策略：

|枚举|值|说明|
|---|---|---|
|AUTOMATIC|""|由服务端自动选择|
|FAST|"g\_001"|快速模式|
|ACCURATE|"o\_001"|精准模式|

在线翻译返回模式：

|枚举|值|说明|
|---|---|---|
|*DEFAULT*|""|由服务端自动选择|
|*PARTIAL*|"partial"|*中间态下发*|
|*STABLE*|"stable"|*稳定态下发*|

创建通道时可通过 setOnlineTranslateEngine\(\.\.\.\) 设置初始策略，运行中可通过 room\.updateTranslateEngine\(\.\.\.\) 切换。

### 8\.5 TmkTransChannelConfig\.Builder

|Builder 方法|说明|
|---|---|
|setRoom\(room\)|设置房间对象|
|setMode\(mode\)|设置翻译模式|
|setScenario\(scenario\)|设置场景|
|setTransModeType\(type\)|设置在线底层模式类型|
|setSourceLang\(langCode\)|设置源语言，如 "zh\-CN"|
|setTargetLang\(langCode\)|设置目标语言，如 "en\-US"|
|setSampleRate\(rate\)|设置 PCM 采样率，建议 16000|
|setChannelNum\(num\)|设置输入声道数，收听为 1，一对一为 2|
|setSpeakers\(speakers\)|设置在线/离线 TTS 音色|
|setOnlineTranslateEngine\(engine\)|设置在线翻译引擎初始策略|
|setRoomScenario\(roomScenario\)|设置在线房间初始能力|
|setOfflineAudioChannelMode\(mode\)|设置离线一对一 TTS 输出通道模式，默认 STEREO|
|setModelRootDirectory\(directory\)|设置离线模型根目录；不设置时使用 SDK 默认目录|
|addExtraParams\(key, value\)|高级扩展参数，例如 enable\_mt、enable\_tts|
|build\(\)|构建 TmkTransChannelConfig|

说明：

- setRoomScenario\(TmkRoomScenario\.RECOGNIZE\)：单 ASR，只输出识别文本。

- setRoomScenario\(TmkRoomScenario\.TRANSLATE\_SPEECH\_TO\_TEXT\)：ASR\+MT 文本输出，不要求 TTS。

- setRoomScenario\(TmkRoomScenario\.TRANSLATE\_SPEECH\_TO\_SPEECH\)：ASR\+MT\+TTS 语音输出。

- addExtraParams\("enable\_mt", "false"\) 和 addExtraParams\("enable\_tts", "false"\) 主要影响离线模型需求和离线 pipeline 行为；在线房间能力请优先使用 setRoomScenario\(\.\.\.\) / updateScenario\(\.\.\.\)。

### 8\.6 音色与离线输出通道模型

```Plain Text
enum class SpeakerChannel {
    LEFT,
    RIGHT
}

enum class SpeakerGender {
    MALE,
    FEMALE
}

data class TmkSpeaker(
    val channel: SpeakerChannel,
    val gender: SpeakerGender,
)
```

SpeakerChannel\.LEFT 对应左声道；SpeakerChannel\.RIGHT 对应右声道。收听模式通常只配置 LEFT；一对一模式可分别配置左右声道音色。

```Plain Text
enum class TmkOfflineAudioChannelMode {
    MONO,
    STEREO
}
```

|枚举|说明|
|---|---|
|MONO|离线一对一 TTS 按单声道输出，适合业务侧自行管理播放声道|
|STEREO|默认值，离线一对一 TTS 混成立体声输出|

### 8\.7 创建通道接口（在线/离线统一入口）

仅创建并初始化通道，不自动启动：

```Plain Text
fun createTranslationChannel(
    context: Context,
    config: TmkTransChannelConfig,
    callback: CreateChannelCallback,
)
```

创建、绑定监听器并自动启动通道：

```Plain Text
fun createTranslationChannel(
    context: Context,
    config: TmkTransChannelConfig,
    listener: TmkTranslationListener?,
    callback: CreateChannelCallback,
)
```

回调说明：

```Plain Text
interface CreateChannelCallback {
    fun onSuccess(channel: TmkTranslationChannel)
    fun onError(errorId: Int, e: Exception)
}
```

差异说明：

- 三参数重载：onSuccess 表示通道初始化完成，业务侧需要调用 channel\.setTranslationListener\(listener\) 和 channel\.start\(\)。

- 四参数重载：SDK 会先绑定 listener 再启动通道；onSuccess 表示通道已进入可运行或降级可用状态。

### 8\.8 在线通道创建示例

> 以下 room 来自 7\.2 的 createTmkTranslationRoom\(config, callback\)，建房成功后即可直接用于构建通道配置。
> 
> 

#### 收听模式

```Plain Text
val channelConfig = TmkTransChannelConfig.Builder()
    .setRoom(room)
    .setMode(TranslationMode.ONLINE)
    .setScenario(Scenario.LISTEN)
    .setTransModeType(TransModeType.LISTEN)
    .setSourceLang("zh-CN")
    .setTargetLang("en-US")
    .setSampleRate(16000)
    .setChannelNum(1)
    .build()
```

#### 一对一模式

```Plain Text
val channelConfig = TmkTransChannelConfig.Builder()
    .setRoom(room)
    .setMode(TranslationMode.ONLINE)
    .setScenario(Scenario.ONE_TO_ONE)
    .setTransModeType(TransModeType.ONE_TO_ONE)
    .setSourceLang("zh-CN")
    .setTargetLang("en-US")
    .setSpeakers(
        listOf(
            TmkSpeaker(SpeakerChannel.LEFT, SpeakerGender.FEMALE),
            TmkSpeaker(SpeakerChannel.RIGHT, SpeakerGender.MALE),
        )
    )
    .setSampleRate(16000)
    .setChannelNum(2)
    .build()
```

一对一模式下，sourceLang 对应左声道，targetLang 对应右声道。输入 PCM 为双声道交织数据。

---

## 离线模型管理

离线模式需要预先下载模型文件。业务侧优先使用 TmkTranslationSDK 暴露的离线模型接口，不需要直接调用底层离线库。

### 9\.1 默认离线模型目录

```Plain Text
fun defaultOfflineModelRootDirectory(): String
fun defaultOfflineModelRootDirectory(context: Context): String
```

说明：

- 无参重载要求 SDK 已初始化。

- Context 重载可在 sdkInit 前查询下载目录。

- 创建离线通道时可通过 setModelRootDirectory\(modelRootDir\) 显式传入。

### 9\.2 downloadOfflineModels\(\.\.\.\)

下载指定语言对所需的离线模型资源。

```Plain Text
fun downloadOfflineModels(
    context: Context,
    srcLang: String,
    dstLang: String,
    scenario: Scenario = Scenario.ONE_TO_ONE,
    needMt: Boolean = true,
    needTts: Boolean = true,
    listener: TmkOfflineModelDownloadListener? = null,
)
```

另有不带 context 的重载，以及可传 modelRootDirectory 的重载。

前置条件：

- 已调用 sdkInit\(context, config\)。

- 已调用 verifyAuth\(callback\)。

- isOfflineTranslationSupported\(\) 返回 true。

如果前置条件不满足，SDK 会通过 listener\.onOfflineModelError\(code, message\) 显式回调原因，不会静默失败。

### 9\.3 downloadChineseEnglishOfflineModels\(\.\.\.\)

下载中英双向离线模型。

```Plain Text
fun downloadChineseEnglishOfflineModels(listener: TmkOfflineModelDownloadListener? = null)
fun downloadChineseEnglishOfflineModels(context: Context, listener: TmkOfflineModelDownloadListener? = null)
fun downloadChineseEnglishOfflineModels(modelRootDirectory: String, listener: TmkOfflineModelDownloadListener? = null)
fun downloadChineseEnglishOfflineModels(context: Context, modelRootDirectory: String, listener: TmkOfflineModelDownloadListener? = null)
```

兼容命名 downloadChineseEnglish\(\.\.\.\) 与上述能力等价。

### 9\.4 cancelOfflineModelDownload\(\)

取消当前正在进行的离线模型下载。

```Plain Text
fun cancelOfflineModelDownload()
```

取消属于用户主动行为，业务侧不应弹 fatal 错误框，应恢复下载按钮或显示已取消状态。

### 9\.5 getOfflineModelPackageInfos\(\.\.\.\)

查询指定语言对关联的离线模型资源包状态。

```Plain Text
fun getOfflineModelPackageInfos(
    context: Context,
    srcLang: String,
    dstLang: String,
    scenario: Scenario = Scenario.ONE_TO_ONE,
    needMt: Boolean = true,
    needTts: Boolean = true,
): List<TmkOfflineModelPackageInfo>
```

另有不带 context 的重载，以及可传 modelRootDirectory 的重载。

### 9\.6 模型就绪检查接口

#### 单类模型就绪检查

可分别检查 ASR、MT、TTS 模型及 TTS 公共数据包是否就绪：

```Plain Text
fun isAsrModelReady(langCode: String, modelRootDirectory: String? = null): Boolean
fun isMtModelReady(srcLang: String, dstLang: String, modelRootDirectory: String? = null): Boolean
fun isTtsModelReady(langCode: String, modelRootDirectory: String? = null): Boolean
fun isTtsDataReady(modelRootDirectory: String? = null): Boolean
```

说明：

- isAsrModelReady：检查指定语言的 ASR 模型是否就绪。

- isMtModelReady：检查指定源/目标语言对的 MT 模型是否就绪。

- isTtsModelReady：检查指定语言的 TTS 模型是否就绪。

- isTtsDataReady：检查公共 TTS 数据包是否就绪。

- 语言代码会按主语言标签归一（如 zh\-CN、zh\-HK 归一为 zh）。

- 每个方法都提供带 context 的重载（首个参数为 context: Context），可在 sdkInit 之前查询；不带 context 时使用 SDK 初始化时的 Context。

- modelRootDirectory 传 null 时使用默认模型根目录。

#### 组合就绪检查

按场景一次性检查某语言对所需的全部模型：

同步检查：

```Plain Text
fun isOfflineModelReady(
    context: Context,
    srcLang: String,
    dstLang: String,
    scenario: Scenario = Scenario.ONE_TO_ONE,
    needMt: Boolean = true,
    needTts: Boolean = true,
): Boolean
```

异步检查：

```Plain Text
fun checkOfflineModelReadyAsync(
    context: Context,
    srcLang: String,
    dstLang: String,
    scenario: Scenario = Scenario.ONE_TO_ONE,
    needMt: Boolean = true,
    needTts: Boolean = true,
    completion: (Boolean) -> Unit,
)
```

异步回调会切回主线程。

### 9\.7 离线场景所需模型说明

#### 收听模式 Scenario\.LISTEN

默认需要：

- 源语言 ASR，例如 asr/zh

- 源到目标 MT，例如 mt/zh2en

- 目标语言 TTS，例如 tts/en

- TTS 公共数据，例如 tts/espeak\-ng\-data

如通过 addExtraParams\("enable\_mt", "false"\) 或 addExtraParams\("enable\_tts", "false"\) 关闭翻译或 TTS，对应模型需求会减少。

#### 一对一模式 Scenario\.ONE\_TO\_ONE

默认需要双向模型：

- 左右语言 ASR，例如 asr/zh、asr/en

- 双向 MT，例如 mt/zh2en、mt/en2zh

- 左右语言 TTS，例如 tts/zh、tts/en

- TTS 公共数据，例如 tts/espeak\-ng\-data

### 9\.8 离线通道创建示例

#### 离线收听

```Plain Text
val modelRootDir = TmkTranslationSDK.defaultOfflineModelRootDirectory(context)

val channelConfig = TmkTransChannelConfig.Builder()
    .setRoom(room)
    .setMode(TranslationMode.OFFLINE)
    .setScenario(Scenario.LISTEN)
    .setSourceLang("zh-CN")
    .setTargetLang("en-US")
    .setSampleRate(16000)
    .setChannelNum(1)
    .setModelRootDirectory(modelRootDir)
    .build()
```

#### 离线一对一

```Plain Text
val modelRootDir = TmkTranslationSDK.defaultOfflineModelRootDirectory(context)

val channelConfig = TmkTransChannelConfig.Builder()
    .setRoom(room)
    .setMode(TranslationMode.OFFLINE)
    .setScenario(Scenario.ONE_TO_ONE)
    .setSourceLang("zh-CN")
    .setTargetLang("en-US")
    .setSpeakers(
        listOf(
            TmkSpeaker(SpeakerChannel.LEFT, SpeakerGender.FEMALE),
            TmkSpeaker(SpeakerChannel.RIGHT, SpeakerGender.MALE),
        )
    )
    .setOfflineAudioChannelMode(TmkOfflineAudioChannelMode.STEREO)
    .setSampleRate(16000)
    .setChannelNum(2)
    .setModelRootDirectory(modelRootDir)
    .build()
```

---

## 通道对象 TmkTranslationChannel

### 10\.1 pushStreamAudioData\(data, channelCount, extraChunk\)

向通道推送 PCM 音频。

```Plain Text
fun pushStreamAudioData(
    data: ByteArray,
    channelCount: Int,
    extraChunk: ByteArray?,
)
```

参数说明：

|参数|说明|
|---|---|
|data|16\-bit little\-endian PCM|
|channelCount|声道数，收听为 1，一对一为 2|
|extraChunk|扩展音频块，普通接入可传 null|

行为说明：

- start\(\) 前推流无效。

- 通道状态不允许推流时，SDK 会忽略音频数据。

- 建议按 20ms 粒度持续推流。

- 采样率和声道数必须与 TmkTransChannelConfig 一致。

### 10\.2 生命周期方法

|方法|说明|
|---|---|
|setTranslationListener\(listener\)|启动通道（createTranslationChannel的startInitAfter参数为false时，才需要调用）|
|start\(\)|启动通道（createTranslationChannel的startInitAfter参数为false时，才需要调用一次）|
|destroy\(\)|停止、释放资源并清除回调|

页面退出、切换模式、切换房间或切换语言对时，优先调用 TmkTranslationSDK\.releaseChannel\(\) 释放当前会话并关闭在线房间。如果业务侧需要等待最终 ASR/MT/TTS 结果，可先 stop\(\)，等待结果回调后再调用 releaseChannel\(\)。

### 10\.3 状态与能力查询

|方法|说明|
|---|---|
|currentRuntimeState\(\)|获取当前通道状态快照|
|getTranslationMode\(\)|获取当前翻译模式|
|getScenario\(\)|获取当前场景|
|getChanelEngineType\(\)|获取当前底层引擎类型|
|getTranslationListener\(\)|获取当前 listener|

### 10\.4 运行中更新能力

更新 TTS 音色：

```Plain Text
fun updateSpeaker(
    speakers: List<TmkSpeaker>,
    callback: ActionCallback,
): Cancelable
```

回调说明：

```Plain Text
interface ActionCallback {
    fun onSuccess(result: Result<Unit>)
    fun onError(errorId: Int, e: Exception)
}
```

说明：

- 在线通道通过当前 room 和 active channel 更新服务端音色。

- 离线通道通过当前引擎更新本地 TTS 音色。

- 返回的 Cancelable 只能取消尚未执行的设置任务，已生效的音色不会回滚。

---

## 监听器与回调数据

### 11\.1 TmkTranslationListener

```Plain Text
interface TmkTranslationListener {
    fun onRecognized(
        fromEngine: AbstractChannelEngine?,
        r: Result<String>?,
        isFinal: Boolean,
    )

    fun onTranslate(
        fromEngine: AbstractChannelEngine?,
        r: Result<String>?,
        isFinal: Boolean,
    )

    fun onAudioDataReceive(
        fromEngine: AbstractChannelEngine?,
        r: Result<String>?,
        data: ByteArray,
        channelCount: Int,
    )

    fun onError(code: Int, msg: String)
    fun onEvent(eventName: String, args: Any?)
    fun onStateChanged(
        fromEngine: AbstractChannelEngine?,
        snapshot: TmkTranslationChannelStateSnapshot,
    )
}
```

### onRecognized\(\.\.\.\)

识别文本回调。

|参数|说明|
|---|---|
|r\.data|ASR 文本|
|isFinal / r\.isLast|是否为最终结果|
|r\.srcCode|源语言|
|r\.extraData\["channel"\]|一对一模式下的声道标识，通常 "1" 为左，"2" 为右|
|r\.extraData\["bubble\_id"\]|文本气泡 ID；在线来自服务端，离线由 SDK 独立生成|
|r\.extraData\["chunk\_id"\]|文本分片 ID；在线来自服务端，离线由 SDK 生成|

### onTranslate\(\.\.\.\)

翻译文本回调。

|参数|说明|
|---|---|
|r\.data|MT 文本|
|isFinal / r\.isLast|是否为最终结果|
|r\.srcCode / r\.dstCode|源语言与目标语言|
|r\.extraData\["channel"\]|一对一模式下的声道标识|
|r\.extraData\["bubble\_id"\]|文本气泡 ID；在线来自服务端，离线由 SDK 独立生成|
|r\.extraData\["chunk\_id"\]|文本分片 ID；在线来自服务端，离线由 SDK 生成|

### onAudioDataReceive\(\.\.\.\)

翻译后的 TTS PCM 音频回调。

|参数|说明|
|---|---|
|data|PCM 16\-bit 音频数据|
|channelCount|本次回调音频声道数|
|r\.extraData\["channel"\]|一对一模式下的来源声道|
|r\.extraData\["audio\_route"\]|当本次回调为双声道 PCM 且上游未提供该字段时，SDK 补充为 "stereo"；单声道回调不强制补充|
|r\.extraData\["bubble\_id"\]|离线 TTS 对应文本气泡 ID|
|r\.extraData\["chunk\_id"\]|离线 TTS 对应文本分片 ID|

离线一对一如果配置 TmkOfflineAudioChannelMode\.STEREO，SDK 会按双声道输出；如果配置 MONO，业务侧需要自行按声道缓存和播放。

### onError\(code, msg\)

翻译链路错误回调。业务侧应结合错误码、onStateChanged 中的 snapshot\.reason 和当前模式决定恢复方式。

### onEvent\(eventName, args\)

事件回调用于诊断、弱提示和补充状态，不应替代识别、翻译、音频和状态回调。 在线 online\_bubble\_end 事件表示服务端下发了某个 bubble\_id 的结束标记，args 为 Result\<String\>，可从 result\.bubbleId 或 result\.extraData\["bubble\_id"\] 读取气泡 ID。该事件仅建议用于业务展示态标记，不阻止后续同一 bubble 的文本更新；未收到该事件也不代表 bubble 一定未结束。

在线 online\_tts\_state 事件表示服务端下发的 TTS 播放状态。args 为 Result\<String\>，常见字段如下：

|字段|说明|
|---|---|
|result\.sessionId / extraData\["session\_id"\]|在线语音段 ID，可用于源文片段高亮|
|result\.bubbleId / extraData\["bubble\_id"\]|在线气泡 ID|
|extraData\["chunk\_id"\]|在线翻译片段 ID，可用于译文片段高亮|
|extraData\["is\_end"\] / result\.isLast|是否结束本次 TTS 高亮；true 时业务侧应取消对应高亮|

高亮属于 App/Demo 展示逻辑，SDK 只负责透传事件和稳定字段。建议源文按 session\_id 命中，译文按 chunk\_id 命中。

### onStateChanged\(\.\.\.\)

通道状态回调。App 应以该回调作为通道 UI 状态的单一来源，不要自行把 STARTING 伪造为 RUNNING，也不要因单次弱网事件主动销毁通道。

### 11\.2 Result\<T\>

|字段|说明|
|---|---|
|sessionId|会话 ID；在线优先取服务端 session\_id，缺失时回退 chunk\_id，仍缺失为 "0"；离线由 SDK 生成|
|bubbleId|结果气泡 ID；在线取服务端 bubble\_id，缺失时回退 sid\_\<sessionId\>；离线由 SDK 独立生成|
|data|结果数据|
|srcCode|源语言|
|dstCode|目标语言|
|isLast|是否为最终结果|
|extraData|附加数据，例如一对一声道、trace 信息、bubble\_id、chunk\_id、TTS audio\_route 等|

离线结果 ID 生成规则：

- sessionId、bubbleId、extraData\["chunk\_id"\] 均由 SDK 使用“毫秒级时间戳 \+ 同毫秒内递增序号”生成。

- bubbleId 独立生成，不等同于 sessionId。

- 同一段离线 ASR/MT/TTS 结果复用同一组公开 ID；一对一左右声道按声道和原始离线 session 维度分别生成，避免同时产出时冲突。

- 在线 extraData 只保留服务端/翻译结果实际携带的数据，不会为了补齐 sessionId 合成 extraData\["session\_id"\]。

### 11\.3 通道状态模型

```Plain Text
data class TmkTranslationChannelStateSnapshot(
    val state: TmkTranslationChannelState,
    val reason: TmkTranslationChannelStateReason,
    val code: Int? = null,
    val message: String = "",
    val isRecoverable: Boolean = true,
    val updatedAtMs: Long = System.currentTimeMillis(),
)
```

TmkTranslationChannelState：

|state|说明|
|---|---|
|IDLE|空闲|
|STARTING|启动中|
|RUNNING|正常运行|
|RECONNECTING|网络或在线链路正在恢复|
|DEGRADED|降级可用|
|STOPPING|停止中|
|STOPPED|已停止|
|FAILED|已失败|

常见 TmkTranslationChannelStateReason：

|reason|说明|
|---|---|
|NONE|无特殊原因|
|START\_REQUESTED / STARTED|启动请求或启动完成|
|STOP\_REQUESTED / STOPPED|停止请求或停止完成|
|NETWORK\_UNAVAILABLE / NETWORK\_RESTORED|网络不可用或恢复|
|RTC\_CONNECTING / RTC\_CONNECTED / RTC\_INTERRUPTED / RTC\_LOST|在线 RTC 状态|
|RTC\_KEEP\_ALIVE\_TIMEOUT|在线保活超时|
|RTC\_TOKEN\_REQUESTED / RTC\_TOKEN\_WILL\_EXPIRE|在线 token 续期相关状态|
|SESSION\_EXPIRED|在线会话过期|
|INVALID\_CONFIGURATION|配置错误|
|PERMISSION\_DENIED|权限不足|
|BANNED\_BY\_SERVER / SERVICE\_REJECTED|服务端拒绝或对话不可继续|
|MESSAGE\_CHANNEL\_FAILURE|在线消息通道异常|
|ENGINE\_ERROR|引擎内部错误|

### 11\.4 状态回调处理契约

|state|常见 reason|App 推荐处理|
|---|---|---|
|IDLE|NONE|显示待启动或初始化状态，不推流。|
|STARTING|START\_REQUESTED / RTC\_CONNECTING / RTC\_CONNECTED|显示“通道连接中/正在加载”，禁止重复创建。RTC\_CONNECTED 不代表完整业务链路已 ready。|
|RUNNING|STARTED / RTC\_CONNECTED / NETWORK\_RESTORED|显示通道可用，允许采集，清除弱网或重连提示。|
|DEGRADED|NETWORK\_UNAVAILABLE / MESSAGE\_CHANNEL\_FAILURE / RTC\_TOKEN\_REQUESTED / RTC\_TOKEN\_WILL\_EXPIRE|显示非阻塞弱网或能力受损提示，不停止录音/播放。|
|RECONNECTING|NETWORK\_UNAVAILABLE / RTC\_INTERRUPTED / RTC\_LOST / MESSAGE\_CHANNEL\_FAILURE|显示连接恢复中，禁止重复创建，等待 SDK 恢复或升级为失败。|
|STOPPING|STOP\_REQUESTED|禁用操作按钮，等待停止完成。|
|STOPPED|STOPPED|清理 UI 状态或离开页面。|
|FAILED|SESSION\_EXPIRED / INVALID\_CONFIGURATION / PERMISSION\_DENIED / BANNED\_BY\_SERVER / SERVICE\_REJECTED / RTC\_KEEP\_ALIVE\_TIMEOUT / ENGINE\_ERROR|停止录音/播放，按错误码提示用户重新创建、重新初始化、下载模型、重新鉴权或离开。|

离线通道不产生 RTC\_CONNECTING、RTC\_CONNECTED、RTC\_INTERRUPTED、RTC\_LOST、RTC\_KEEP\_ALIVE\_TIMEOUT、MESSAGE\_CHANNEL\_FAILURE 等 RTC/RTM 原因。

### 11\.5 事件回调处理契约

|事件类型|常见事件|App 推荐处理|
|---|---|---|
|在线运行事件|online\_started、online\_stopped、online\_runtime\_state\_changed|日志和 UI 辅助；UI 状态以 onStateChanged 为准。|
|在线消息事件|online\_stream\_message\_raw、online\_stream\_message\_parsed、online\_notification、notification、online\_bubble\_end|诊断为主；close\_room 类通知需要停止当前会话引用，并提示用户重新创建或离开；online\_bubble\_end 仅标记对应 bubble\_id 已收到结束信号，不改变原有 bubble 划分，也不阻止后续内容更新。|
|在线 TTS 高亮事件|online\_tts\_state|按 session\_id / chunk\_id 更新播放高亮，诊断为主。|
|在线弱网事件|online\_network\_quality、online\_rtc\_stats、online\_remote\_audio\_stats、online\_local\_audio\_stats|连续采样后显示弱网提示，不直接释放通道。|
|在线远端离线事件|online\_remote\_user\_offline|当 is\_expected\_service\_uid=true 时，说明服务端音频/翻译订阅 uid 离线，对话不可继续，应提示重新创建或离开。|
|离线 pipeline 事件|offline\_pipeline\_state、offline\_stream\_message\_parsed、offline\_audio\_metadata|诊断和日志为主；UI 仍以 onStateChanged 和业务结果回调为准。|
|离线结果辅助事件|offline\_asr\_partial、offline\_asr\_final、offline\_mt\_partial、offline\_mt\_final、offline\_tts\_output、offline\_tts\_state、offline\_recognition\_failure|可用于诊断或弱提示；正式文本和音频展示以识别、翻译、音频回调为准。|
|模型下载事件|offline\_model\_cancelled、offline\_model\_update\_required、下载进度、解压进度、模型包状态变化|更新模型列表和进度；取消不弹错误框，需更新时禁止直接启动离线通道。|

### 11\.6 离线模型包状态处理契约

|package state|App 推荐处理|
|---|---|
|READY|显示已就绪；所有必需包 ready 后可创建离线通道。|
|NEEDS\_DOWNLOAD|显示待下载，禁止启动离线通道。|
|NEEDS\_UPDATE|显示需更新，引导重新下载。|
|RESUMABLE|显示可续传，点击下载继续。|
|DOWNLOADING|显示下载进度，允许取消。|
|UNZIPPING|显示解压进度，避免重复触发下载。|
|FAILED|显示失败，允许重试。|
|CANCELLED|显示已取消，允许重新下载，不弹错误框。|

---

## 错误模型与统一错误码表

### 12\.1 TmkTranslationException

Android 对外错误通常通过 TmkTranslationException 或错误码返回：

```Plain Text
class TmkTranslationException : Exception {
    // 对外统一错误码（2001xxx/2002xxx/2003xxx，见下表）。
    val errorCode: Int
    // 底层原始错误码（后台业务码、HTTP 状态码或 native 返回码等）；无原始码时为 null。
    val actualErrorCode: Int?
    // 底层原始错误信息；无原始信息时为 null。
    val actualErrorMessage: String?
    // 底层原始错误域，用于区分原始码来源，如 "backend"、"OfflineLicenseApplyStatus"；无时为 null。
    val actualErrorDomain: String?
}
```

错误码规则：凡来自后台或底层（native）的原始错误，errorCode 始终是上表中的统一 SDK 错误码，原始错误码与信息保留在 actualErrorCode / actualErrorMessage / actualErrorDomain 中，便于业务侧排障而不破坏统一码契约。纯 SDK 内部错误（如未初始化、状态非法、超时）这三个字段为 null。

主要回调入口：

- AuthCallback\.onError

- CreateRoomCallback\.onError

- CreateChannelCallback\.onError

- ActionCallback\.onError

- TmkTranslationListener\.onError

- TmkTranslationChannelStateSnapshot\.code

### 12\.2 统一错误码表

以下表格合并 SDK 统一错误码、Android 离线引擎诊断码和离线 License 鉴权组件码。业务 UI 主要消费回调中的顶层错误码；离线引擎和 License 组件码用于脱敏后的诊断排障。

|code|constantName|适用范围/分类|说明|处理契约|
|---|---|---|---|---|
|2001101|SDK\_NOT\_INITIALIZED|common/state|SDK 未初始化。|提示初始化失败，先完成 sdkInit，不要继续建房或建通道。|
|2001102|AUTHENTICATION\_FAILED|common/caller|在线鉴权失败，或离线 License 鉴权失败导致离线能力无法确认。|提示重新鉴权；离线能力失败时引导联网重试或检查账号权限。|
|2001103|ROOM\_CREATION\_FAILED|online/network|在线房间创建失败。|允许用户重试创建；连续失败时离开当前对话并记录诊断。|
|2001104|CHANNEL\_CREATION\_FAILED|common/rtcRtm|在线通道创建失败，或离线通道组装失败。|在线重新创建对话；离线重新初始化通道并检查模型资源。|
|2001105|ENGINE\_NOT\_SUPPORTED|common/rtcRtm|当前 SDK、账号或配置不支持该引擎能力。|提示能力不支持，停止当前流程。|
|2001106|INVALID\_CONFIGURATION|common/caller|配置非法，包括语言、声道、音色、appId、channel 等参数不合法。|修正配置后再创建；不要用旧配置重复重试。|
|2001107|NETWORK\_UNAVAILABLE|common/network|网络不可用；也可能出现在模型下载、鉴权、语言列表等网络请求失败场景。|reconnecting 时提示恢复中；下载或请求失败时提供重试入口。|
|2001108|AUDIO\_PROCESSING\_ERROR|common/audio|采集、播放、推 PCM 或音频会话异常。|停止录音/播放，在线重建对话，离线重新初始化。|
|2001109|TTS\_SYNTHESIS\_ERROR|common/rtcRtm|在线或离线 TTS 合成异常；离线 stage == tts 优先映射到该错误。|单句失败可弱提示；连续失败或通道失败时重建/重新初始化。|
|2001110|TRANSLATION\_ERROR|common/rtcRtm|在线翻译异常；离线 ASR/MT 阶段失败。|单句失败可弱提示；通道失败时在线重建，离线重新初始化。|
|2001111|SESSION\_EXPIRED|online/network|在线会话或 RTC/RTM token 已过期。|停止当前会话，提示用户重新创建对话。|
|2001112|QUOTA\_EXCEEDED|common/network|账号或应用服务配额不足。|提示配额不足并停止当前流程。|
|2001113|INVALID\_LANGUAGE\_CODE|common/caller|语言代码非法或底层引擎拒绝当前 locale。离线 SDK 不做语种白名单拦截，归一 zh\-CN、zh\-HK 等到 zh 后按 License scope 与模型资源放行；此码现仅在底层引擎运行期判定 locale 非法时产生。|引导重新选择支持语言；在线重新创建对话，离线确认对应语种模型已下载后重新初始化通道。|
|2001114|ENGINE\_INITIALIZATION\_FAILED|common/rtcRtm|引擎初始化失败；离线 creation failed、load timeout 或模型加载超时。|允许重试；多次失败时提示检查 SDK 资源和离线模型完整性。|
|2001115|BUFFER\_OVERFLOW|common/audio|音频输入或输出缓冲超过处理能力。|降低推流频率或重启采集；严重时重建通道。|
|2001116|THREAD\_INTERRUPTED|common/internal|工作线程被中断。|允许重试；若持续出现，记录诊断并重建流程。|
|2001117|OFFLINE\_MODEL\_NOT\_READY|offline/model|模型缺失、校验失败、下载失败、离线鉴权未通过或账号未开通离线能力。|引导下载、更新模型或重新鉴权；不要直接启动离线通道。|
|2001999|UNKNOWN\_ERROR|common/internal|未知错误或底层错误无法映射。|记录诊断，在线重建对话，离线重新初始化。|
|2002001|NETWORK\_INVALID\_URL|common/caller|网络 URL、模型下载 URL 或后台地址配置错误。|提示配置错误，停止当前流程。|
|2002002|NETWORK\_TRANSPORT\_ERROR|common/network|网络传输失败，包括 DNS、TLS、超时或模型下载失败。|提供重试；模型下载场景保留续传/重试入口。|
|2002003|NETWORK\_HTTP\_STATUS\_ERROR|common/network|HTTP 非成功状态。|401/403 优先重新鉴权，5xx 可重试，其他状态按服务端文案处理。|
|2002004|NETWORK\_RESPONSE\_DECODING\_ERROR|common/network|响应、manifest 或语言列表解析失败。|提示服务响应异常，记录诊断。|
|2002005|NETWORK\_BUSINESS\_ERROR|common/network|服务端业务错误。|展示服务端错误文案；必要时重新鉴权或离开当前流程。|
|2002006|REQUEST\_CANCELLED|common/network|用户取消、页面退出、主动停止或音色设置被取消。|不弹错误框，仅恢复 UI 到已取消/已停止状态。|
|2003002|INVALID\_STATE|common/state|当前状态不允许操作；例如通道释放后继续调用。|重复停止可忽略；关键路径失败时重建或重新初始化。|
|2003003|DEPENDENCY\_UNAVAILABLE|common/rtcRtm|必要依赖、离线库或模型能力不可用。|提示 SDK/资源异常，停止当前流程并记录诊断。|
|2003004|RTC\_OPERATION\_FAILED|online/rtcRtm|实时链路操作失败，包括 RTC/RTM 启动失败、发消息失败、服务端订阅 uid 离线或底层 RTC 错误。|提示重新创建或离开；online\_remote\_user\_offline 且 is\_expected\_service\_uid=true 时当前对话不可继续。|
|2003005|MESSAGE\_DECODING\_FAILED|common/rtcRtm|在线/离线消息解析失败。|仅记录日志，不直接关闭通道。|
|2003006|AUDIO\_CHANNEL\_CREATION\_FAILED|common/audio|音频通道创建失败。|停止采集并提示重建/重新初始化。|
|2003007|TRACK\_EVENT\_NOT\_CONFIGURED|common/internal|埋点未配置。|不影响翻译主流程，可忽略或记录日志。|
|2003008|TRACK\_EVENT\_INVALID\_EVENT\_NAME|common/caller|埋点事件名为空或非法。|不影响翻译主流程，可忽略或修正埋点配置。|
|2004001|ERROR\_ASR\_INIT\_FAILED|offline/diagnostic|ASR Session 创建失败，常见于模型文件缺失。|作为底层诊断码处理；检查 ASR 模型后重新初始化离线通道。|
|2004002|ERROR\_MT\_INIT\_FAILED|offline/diagnostic|MT Session 创建失败。|作为底层诊断码处理；检查 MT 模型后重新初始化离线通道。|
|2004003|ERROR\_TTS\_INIT\_FAILED|offline/diagnostic|TTS Session 创建失败。|作为底层诊断码处理；检查 TTS 模型和 espeak\-ng\-data 后重新初始化。|
|2004004|ERROR\_ASR\_RUNTIME|offline/diagnostic|ASR 运行时错误。|弱提示或重新初始化；保留诊断日志。|
|2004005|ERROR\_MT\_RUNTIME|offline/diagnostic|MT 翻译运行时异常。|弱提示或重新初始化；保留诊断日志。|
|2004006|ERROR\_TTS\_RUNTIME|offline/diagnostic|TTS 合成运行时异常。|弱提示或重新初始化；保留诊断日志。|
|2004007|ERROR\_MODEL\_NOT\_FOUND|offline/diagnostic|模型文件不存在。|引导下载或更新模型，禁止直接启动离线通道。|
|2004008|ERROR\_MODEL\_DOWNLOAD\_FAILED|offline/diagnostic|模型下载失败。|恢复下载按钮，允许重试或续传。|

离线 License 鉴权失败时，Android 统一回调对外错误码 2001102 / AUTHENTICATION\_FAILED（TmkTranslationException\.errorCode）；底层 native LicenseCore 的返回码不作为独立对外错误码，而是结构化保留在异常字段中：actualErrorCode = native 返回码（1001–1099），actualErrorMessage = OfflineLicenseApplyStatus\.diagnosticSummary（如 UNAUTHORIZED\_SCOPE\_OR\_MODEL\(1008\)），actualErrorDomain = "OfflineLicenseApplyStatus"，仅用于排障。该枚举（co\.timekettle\.offlinesdk\.OfflineLicenseApplyStatus）取值如下：

|OfflineLicenseApplyStatus|actualErrorCode|触发场景|
|---|---|---|
|EMPTY\_CONTENT|1001|License 内容为空。|
|DECRYPT\_OR\_PARSE\_FAILED|1002|License 解密或解析失败。|
|SIGNATURE\_INVALID|1003|License 签名无效。|
|CLIENT\_PACKAGE\_OR\_DEVICE\_MISMATCH|1004|client、包名或设备绑定不匹配。|
|MODEL\_KEY\_EMPTY|1005|模型密钥为空。|
|EXPIRED\_OR\_NOT\_YET\_VALID|1006|License 已过期或尚未生效。|
|UNSUPPORTED|1007|License 版本或算法不支持。|
|UNAUTHORIZED\_SCOPE\_OR\_MODEL|1008|当前 scope 或模型未授权。|
|INTERNAL\_ERROR|1098|离线 License 鉴权内部错误。|
|UNKNOWN|1099|未知 native 返回码。|

补充说明：

- 后台业务/RTC 命令失败（如建房、运行中切换引擎/能力/语言、音色更新）时，errorCode 为统一 SDK 码（如 ROOM\_CREATION\_FAILED、RTC\_OPERATION\_FAILED、NETWORK\_BUSINESS\_ERROR），后台原始码保留在 actualErrorCode、actualErrorDomain="backend"。

- 离线通道底层 ASR/MT/TTS 组件码可能被 SDK 映射为 2001109、2001110、2001114 或 2001117 后回调业务侧；组件码用于定位具体离线阶段。

- 离线 License 鉴权失败时，对外统一表现为 2001102 / AUTHENTICATION\_FAILED，native 返回码见上表。诊断日志可以记录 OfflineLicenseApplyStatus 诊断枚举和 native LicenseCore 返回码，但不能上传原始 License、clientSecret 或设备私钥。

---

## 离线模型下载监听器

### 13\.1 TmkOfflineModelPackageState

|枚举|说明|
|---|---|
|READY|资源包已完整就绪|
|NEEDS\_DOWNLOAD|资源包未下载|
|NEEDS\_UPDATE|资源包需要更新|
|RESUMABLE|存在断点文件，可继续下载|
|DOWNLOADING|正在下载|
|UNZIPPING|正在解压|
|FAILED|下载或解压失败|
|CANCELLED|下载已取消|

### 13\.2 TmkOfflineModelPackageInfo

|字段|说明|
|---|---|
|packageKey|包键，例如 asr/zh、mt/zh2en|
|type|包类型，例如 asr、mt、tts|
|name|包名称|
|state|包状态|
|index / total|当前包序号与总包数|
|downloadedBytes / totalBytes|下载进度；未知总大小时 totalBytes = \-1|
|unzipProgress|解压进度，取值 0\.0\~1\.0|
|localDirectory|本地目录|

### 13\.3 TmkOfflineModelDownloadListener

```Plain Text
interface TmkOfflineModelDownloadListener {
    fun onOfflineModelEvent(name: String, args: Any?) = Unit
    fun onOfflineModelDownloadProgress(
        fileName: String,
        index: Int,
        total: Int,
        downloaded: Long,
        fileTotal: Long,
    ) = Unit
    fun onOfflineModelUnzipProgress(fileName: String, progress: Double) = Unit
    fun onOfflineModelReady() = Unit
    fun onOfflineModelPackageInfosChanged(
        packages: List<TmkOfflineModelPackageInfo>,
    ) = Unit
    fun onOfflineModelError(code: Int, message: String) = Unit
}
```

SDK 保证这些回调都在主线程触发，可直接更新 UI。

---

## 诊断能力

Android 当前通过 TmkTransGlobalConfig 的诊断开关控制日志：

|配置|说明|
|---|---|
|setDiagnosisEnabled\(enabled\)|是否启用 SDK 诊断日志|
|setDiagnosisConsoleEnabled\(enabled\)|是否同步输出诊断日志到控制台|

诊断日志可用于排查鉴权、建房、建通道、离线模型、在线 RTC/RTM 和离线 pipeline 问题。上传诊断日志前需要完成用户授权、脱敏和访问控制，不应记录或上传原始 License、clientSecret、设备私钥或完整用户隐私数据。

---

## PCM 工具与音频要求

SDK 接收业务侧推送的 PCM：

- 格式：16\-bit little\-endian PCM

- 推荐采样率：16000

- 收听模式：单声道

- 一对一模式：双声道交织数据

- 推荐帧长：约 20ms

业务侧需要保证录音器输出与 TmkTransChannelConfig 中的 sampleRate、channelNum 一致。

---

## 可取消请求句柄

### 16\.1 Cancelable

updateSpeaker\(\.\.\.\) 返回 Cancelable：

```Plain Text
interface Cancelable {
    val isCanceled: Boolean
    fun cancel()
}
```

取消只影响尚未执行或尚未回调的任务，已生效的音色设置不会回滚。REQUEST\_CANCELLED 属于主动取消类错误，业务侧不应弹 fatal 错误框。

---

## 资源释放与生命周期

### 17\.1 TmkTranslationChannel\.destroy\(\)

停止通道、释放底层资源、清除 listener，并从全局通道集合中移除。该方法只作用于单个通道对象；页面退出、切换模式、切换房间或切换语言对时，建议使用 TmkTranslationSDK\.releaseChannel\(\) 作为会话级释放入口。

### 17\.2 TmkTranslationSDK\.releaseChannel\(\)

释放当前翻译通道和当前会话相关资源：

```Plain Text
fun releaseChannel()
```

行为说明：

- 停止并销毁当前通道，清空当前房间引用。

- 如果当前在线房间已创建成功，SDK 会异步调用关房流程，避免服务端遗留预建房间。

- 不会清空 sdkInit\(context, config\) 的全局配置，也不会清空鉴权状态。

- 释放后可以直接重新创建房间与通道。

建议：

- 页面退出、切换模式、切换房间或切换语言对时，优先调用 TmkTranslationSDK\.releaseChannel\(\)。

- 调用 releaseChannel\(\) 后，业务侧不需要再对同一房间重复触发关房。

### 17\.3 TmkTranslationSDK\.destroy\(\)

释放 SDK 全局资源：

```Plain Text
fun destroy()
```

行为说明：

- 销毁当前所有 TmkTranslationChannel。

- 释放在线共享资源和埋点会话。

- 清空全局配置并重置初始化状态。

- 后续如需继续使用，必须重新调用 sdkInit\(context, config\) 和 verifyAuth\(callback\)。

---

## 最小接入示例

### 18\.1 在线收听最小示例

```Plain Text
val globalConfig = TmkTransGlobalConfig.Builder()
    .setAuth("your_app_id", "your_app_secret")
    .build()

TmkTranslationSDK.sdkInit(applicationContext, globalConfig)

TmkTranslationSDK.verifyAuth(object : AuthCallback {
    override fun onSuccess() {
        TmkTranslationSDK.createTmkTranslationRoom(object : CreateRoomCallback {
            override fun onSuccess(room: TmkTranslationRoom) {
                val channelConfig = TmkTransChannelConfig.Builder()
                    .setRoom(room)
                    .setMode(TranslationMode.ONLINE)
                    .setScenario(Scenario.LISTEN)
                    .setTransModeType(TransModeType.LISTEN)
                    .setSourceLang("zh-CN")
                    .setTargetLang("en-US")
                    .setSampleRate(16000)
                    .setChannelNum(1)
                    .build()

                TmkTranslationSDK.createTranslationChannel(
                    applicationContext,
                    channelConfig,
                    listener,
                    object : CreateChannelCallback {
                        override fun onSuccess(channel: TmkTranslationChannel) {
                            // 四参数重载已自动 start，之后可开始推 PCM
                        }

                        override fun onError(errorId: Int, e: Exception) { }
                    }
                )
            }

            override fun onError(errorId: Int, e: Exception) { }
        })
    }

    override fun onError(errorId: Int, e: Exception) { }
})

//关闭引擎
TmkTranslationSDK.releaseChannel()
```

### 18\.2 离线收听最小示例

```Plain Text
if (!TmkTranslationSDK.isOfflineTranslationSupported()) {
    // 提示当前账号未开通离线能力或尚未完成鉴权
    return
}

TmkTranslationSDK.checkOfflineModelReadyAsync(
    context = applicationContext,
    srcLang = "zh-CN",
    dstLang = "en-US",
    scenario = Scenario.LISTEN,
    needMt = true,
    needTts = true,
) { ready ->
    if (!ready) {
        TmkTranslationSDK.downloadOfflineModels(
            context = applicationContext,
            srcLang = "zh-CN",
            dstLang = "en-US",
            scenario = Scenario.LISTEN,
            listener = offlineModelListener,
        )
        return@checkOfflineModelReadyAsync
    }

    TmkTranslationSDK.createTmkTranslationRoom(object : CreateRoomCallback {
        override fun onSuccess(room: TmkTranslationRoom) {
            val channelConfig = TmkTransChannelConfig.Builder()
                .setRoom(room)
                .setMode(TranslationMode.OFFLINE)
                .setScenario(Scenario.LISTEN)
                .setSourceLang("zh-CN")
                .setTargetLang("en-US")
                .setSampleRate(16000)
                .setChannelNum(1)
                .setModelRootDirectory(
                    TmkTranslationSDK.defaultOfflineModelRootDirectory(applicationContext)
                )
                .build()

            TmkTranslationSDK.createTranslationChannel(
                applicationContext,
                channelConfig,
                listener,
                createChannelCallback,
            )
        }

        override fun onError(errorId: Int, e: Exception) { }
    })
}
//关闭引擎
TmkTranslationSDK.releaseChannel()
```

### 18\.3 一对一模式与收听模式的区别

|项目|收听模式|一对一模式|
|---|---|---|
|Scenario|LISTEN|ONE\_TO\_ONE|
|channelNum|1|2|
|输入 PCM|单声道|双声道交织|
|语言方向|sourceLang \-\> targetLang|左声道 sourceLang \-\> targetLang，右声道 targetLang \-\> sourceLang|
|TTS 播放|单路播放|建议按声道缓存后统一播放|

---

## 常见问题

### 19\.1 为什么在线能力需要先调用 verifyAuth\(callback\)？

在线建房、建通道和 token 获取依赖鉴权结果。未鉴权或鉴权失败时，创建通道可能返回 SDK\_NOT\_INITIALIZED、AUTHENTICATION\_FAILED、ROOM\_CREATION\_FAILED 或 CHANNEL\_CREATION\_FAILED。

### 19\.2 为什么离线翻译也建议先调用 verifyAuth\(callback\)？

离线能力由账号权限和 License 鉴权共同决定。verifyAuth\(callback\) 成功后，业务侧需要通过 isOfflineTranslationSupported\(\) 判断当前账号是否开通离线能力，再下载模型或创建离线通道。

### 19\.3 为什么离线模型下载成功过，之后又可能不能使用？

模型资源可能被用户清理、版本需要更新、模型根目录改变，或本地 manifest 与当前下载源不一致。创建离线通道前应重新调用 isOfflineModelReady\(\.\.\.\) 或 getOfflineModelPackageInfos\(\.\.\.\)。

### 19\.4 为什么在线和离线的语言 code 不完全一样？

在线语言由服务端配置决定，常使用完整 BCP\-47 代码。离线引擎使用主语言标签加载模型，SDK 会把 zh\-CN、zh\-HK 等归一为 zh。离线可用语种由 License scope 与已下载的离线模型共同决定，SDK 层不再做语种白名单拦截：缺少对应模型时在模型资源校验阶段报 OFFLINE\_MODEL\_NOT\_READY，仅当底层引擎运行期判定 locale 非法时才返回 2001113 / INVALID\_LANGUAGE\_CODE。

### 19\.5 为什么当前建议使用 16000 采样率？

当前在线/离线链路均按 16k PCM 作为推荐输入规格。采样率和声道数与配置不一致会导致识别效果下降、无结果或音频处理错误。

### 19\.6 为什么离线一对一模式需要双声道输入？

离线一对一内部会把左右声道拆分成两条 pipeline：左声道按 sourceLang \-\> targetLang 处理，右声道按 targetLang \-\> sourceLang 处理。输入不是双声道交织 PCM 时，声道归属和翻译方向会错误。

### 19\.7 为什么 onRecognized\(\.\.\.\) 和 onTranslate\(\.\.\.\) 会多次回调？

ASR 和 MT 可能返回中间结果和最终结果。业务侧应通过 isFinal 或 r\.isLast 区分是否为最终文本。

### 19\.8 stop\(\)、destroy\(\) 和 releaseChannel\(\) 有什么区别？

stop\(\) 停止当前数据流，适合等待最终结果后再释放。destroy\(\) 只释放单个通道对象。TmkTranslationSDK\.releaseChannel\(\) 是会话级释放入口，会释放当前通道、清空当前房间引用，并在在线房间已创建时异步关房，适合页面退出、切换通道或异常恢复。

### 19\.9 AUTO / MIX 可以直接用于生产吗？

当前文档只建议生产接入使用 ONLINE 或 OFFLINE。AUTO / MIX 属于保留能力或内部策略，不建议三方业务直接作为主流程。

### 19\.10 isOfflineTranslationSupported\(\) 返回 false 怎么办？

先确认已完成 sdkInit\(context, config\) 和 verifyAuth\(callback\)，并确认账号已开通离线能力。如果仍为 false，不要启动离线模型下载或离线通道，应提示用户检查账号权限或联系后台配置。

### 19\.11 为什么切换新房间或新通道前建议先释放旧资源？

旧通道可能仍持有 RTC/RTM、离线 pipeline、音频播放、房间引用或回调引用。切换前先调用 TmkTranslationSDK\.releaseChannel\(\) 可以避免旧异步回调污染新页面状态，并避免在线房间遗留。

### 19\.12 离线 License 解密或解析失败怎么办？

SDK 会尝试清理本地离线授权状态并重新签发 License。重新签发仍失败时，业务侧应提示用户检查网络、账号权限、包名和鉴权配置后重试。

### 19\.13 clientSecret 变更后离线 License 还能用吗？

旧 License 可能无法继续解密。联网时 SDK 会尝试重新签发 License；离线无网络时无法重新签发，业务侧应提示用户联网重新鉴权。

---

## Android release 混淆与加固

Android release AAR 需要保持公开 API、离线模型、状态模型、音色、在线翻译引擎和埋点 SPI 的必要 keep 规则。当前规则由 SDK 工程的 proguard\-rules\.pro、consumer\-rules\.pro 和构建校验任务维护。

接入方通常无需额外配置；如果宿主 App 自定义 R8 规则导致 SDK public API、错误码、模型路径辅助类或回调模型被混淆，应优先参考发布产物随附的 consumer rules。

---

## Demo/示例索引

|文件|说明|
|---|---|
|Android/app/src/main/java/co/timekettle/translation/OnlineListenViewModel\.kt|在线收听 Demo|
|Android/app/src/main/java/co/timekettle/translation/Online1v1ViewModel\.kt|在线一对一 Demo|
|Android/app/src/main/java/co/timekettle/translation/OfflineListenViewModel\.kt|离线收听 Demo|
|Android/app/src/main/java/co/timekettle/translation/Offline1v1ViewModel\.kt|离线一对一 Demo|
|Android/libraryTranslation/src/main/java/co/timekettle/translation/TmkTranslationSDK\.kt|SDK 入口|
|Android/libraryTranslation/src/main/java/co/timekettle/translation/TmkTranslationChannel\.kt|通道对象|
|Android/libraryTranslation/src/main/java/co/timekettle/translation/offlinemodel/TmkOfflineModelDownloadListener\.kt|离线模型下载监听器|

## 版本信息

当前文档适配 TmkTranslationSDK Android v1\.2\.0。如果 SDK 版本、发布产物或后台能力发生变化，应同步更新本文档、iOS 文档和共享运行状态错误事件契约。



