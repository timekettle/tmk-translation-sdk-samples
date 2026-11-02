package co.timekettle.translation.sample

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.attribute.BasicFileAttributes

internal enum class DemoDiagnosisEntryKind { DIRECTORY, FILE, SYMBOLIC_LINK, OTHER }
internal data class DemoDiagnosisEntry(
    val name: String,
    val relativePath: String,
    val kind: DemoDiagnosisEntryKind,
    val bytes: Long?,
    val modifiedAtMillis: Long,
)
internal enum class DemoDiagnosisDirectoryState { READY, MISSING, UNAVAILABLE, ERROR }
internal data class DemoDiagnosisSnapshot(
    val rootPath: String?,
    val relativePath: String,
    val entries: List<DemoDiagnosisEntry> = emptyList(),
    val state: DemoDiagnosisDirectoryState = DemoDiagnosisDirectoryState.READY,
    val message: String? = null,
    val totalBytes: Long? = null,
    val savedSessionCount: Int? = null,
)

/** 只读元数据服务：不读正文、不写文件，不持有 SDK 资源或导出租约。 */
internal class DemoDiagnosisBrowser(
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val listDirectory: (Path) -> List<Path> = { path -> Files.newDirectoryStream(path).use { it.toList() } },
) {
    suspend fun load(root: File?, relativePath: String): DemoDiagnosisSnapshot = withContext(dispatcher) {
        if (root == null) return@withContext DemoDiagnosisSnapshot(null, "", state = DemoDiagnosisDirectoryState.UNAVAILABLE,
            message = "诊断未启用或尚无已应用的诊断目录")
        val absolute = root.toPath().toAbsolutePath().normalize()
        try {
            require(!File(relativePath).isAbsolute) { "目录不能超出诊断根目录" }
            val directory = absolute.resolve(relativePath).normalize()
            require(directory.startsWith(absolute)) { "目录不能超出诊断根目录" }
            val rootAttributes = attributes(absolute)
            require(!rootAttributes.isSymbolicLink && rootAttributes.isDirectory) { "诊断根目录不是可浏览的真实目录" }
            val canonicalRoot = root.canonicalFile.toPath()
            checkDirectory(canonicalRoot, absolute, directory)
            val entries = mutableListOf<DemoDiagnosisEntry>()
            var changed = false
            for (child in listDirectory(directory)) {
                currentCoroutineContext().ensureActive()
                val name = child.fileName.toString()
                if (name in setOf(".session_manifest.json", "session_manifest.json", ".sdk_manifest.json", "sdk_context.json")) continue
                try {
                    checkDirectory(canonicalRoot, absolute, directory)
                    val attributes = attributes(child)
                    val kind = when {
                        attributes.isSymbolicLink -> DemoDiagnosisEntryKind.SYMBOLIC_LINK
                        attributes.isDirectory -> DemoDiagnosisEntryKind.DIRECTORY
                        attributes.isRegularFile -> DemoDiagnosisEntryKind.FILE
                        else -> DemoDiagnosisEntryKind.OTHER
                    }
                    val bytes = if (kind == DemoDiagnosisEntryKind.DIRECTORY) {
                        try { directoryUsage(canonicalRoot, absolute, child).bytes }
                        catch (_: NoSuchFileException) { changed = true; null }
                    } else attributes.size()
                    entries += DemoDiagnosisEntry(child.fileName.toString(), absolute.relativize(child).toString(), kind,
                        bytes, attributes.lastModifiedTime().toMillis())
                } catch (_: NoSuchFileException) { changed = true }
            }
            checkDirectory(canonicalRoot, absolute, directory)
            // 总览始终读取根目录；统计失败不影响已经安全读取的当前目录列表。
            val usage = try { directoryUsage(canonicalRoot, absolute, absolute) }
                catch (_: IOException) { null }
                catch (_: java.nio.file.DirectoryIteratorException) { null }
                catch (_: SecurityException) { null }
                catch (_: IllegalArgumentException) { null }
            checkDirectory(canonicalRoot, absolute, directory)
            DemoDiagnosisSnapshot(absolute.toString(), absolute.relativize(directory).toString(),
                entries.sortedWith(compareByDescending<DemoDiagnosisEntry> { it.modifiedAtMillis }.thenBy { it.name }),
                message = when {
                    usage == null -> "根目录统计暂不可用，可手动刷新"
                    changed -> "目录已变化，部分大小暂不可用，可手动刷新"
                    else -> null
                }, totalBytes = usage?.bytes, savedSessionCount = usage?.savedSessions)
        } catch (_: NoSuchFileException) {
            DemoDiagnosisSnapshot(absolute.toString(), relativePath, state = DemoDiagnosisDirectoryState.MISSING,
                message = "目录尚未创建或已被清理，可返回上级或刷新")
        } catch (error: java.nio.file.DirectoryIteratorException) {
            DemoDiagnosisSnapshot(absolute.toString(), relativePath, state = DemoDiagnosisDirectoryState.ERROR,
                message = "读取失败：${error.cause?.localizedMessage ?: error.javaClass.simpleName}")
        } catch (error: IOException) {
            DemoDiagnosisSnapshot(absolute.toString(), relativePath, state = DemoDiagnosisDirectoryState.ERROR,
                message = "读取失败：${error.localizedMessage ?: error.javaClass.simpleName}")
        } catch (error: SecurityException) {
            DemoDiagnosisSnapshot(absolute.toString(), relativePath, state = DemoDiagnosisDirectoryState.ERROR, message = "无权读取此目录")
        } catch (error: IllegalArgumentException) {
            DemoDiagnosisSnapshot(absolute.toString(), relativePath, state = DemoDiagnosisDirectoryState.ERROR, message = error.message)
        }
    }

    private fun attributes(path: Path): BasicFileAttributes = Files.readAttributes(path, BasicFileAttributes::class.java, NOFOLLOW_LINKS)

    private fun checkDirectory(canonicalRoot: Path, root: Path, directory: Path) {
        require(directory.startsWith(root)) { "目录不能超出诊断根目录" }
        var current = root
        for (part in root.relativize(directory)) {
            current = current.resolve(part)
            val attributes = attributes(current)
            require(attributes.isDirectory && !attributes.isSymbolicLink) { "符号链接不可进入" }
        }
        require(!Files.isSymbolicLink(root) && directory.toFile().canonicalFile.toPath().startsWith(canonicalRoot)) {
            "目录不能超出诊断根目录"
        }
    }

    private data class DirectoryUsage(val bytes: Long, val savedSessions: Int)

    private suspend fun directoryUsage(canonicalRoot: Path, root: Path, directory: Path): DirectoryUsage {
        var total = 0L
        var sessions = 0
        val identities = HashSet<Any>()
        val pending = java.util.ArrayDeque<Path>().apply { add(directory) }
        while (pending.isNotEmpty()) {
            currentCoroutineContext().ensureActive()
            val current = pending.removeLast()
            checkDirectory(canonicalRoot, root, current)
            for (child in listDirectory(current)) {
                currentCoroutineContext().ensureActive()
                checkDirectory(canonicalRoot, root, current)
                val attr = attributes(child)
                if (attr.isDirectory && !attr.isSymbolicLink) {
                    if (current == root && isSavedConversation(child)) sessions++
                    pending.add(child)
                } else if (attr.isRegularFile && identities.add(attr.fileKey() ?: child.toAbsolutePath().normalize())) {
                    total = if (Long.MAX_VALUE - total < attr.size()) Long.MAX_VALUE else total + attr.size()
                }
            }
        }
        return DirectoryUsage(total, sessions)
    }

    /** 仅观察已存在的根级会话目录，不解析状态、不申请租约或调用SDK维护。 */
    private fun isSavedConversation(directory: Path): Boolean {
        val name = directory.fileName.toString()
        if (name in setOf("Agora", "sdk_contexts")) return false
        for (manifest in listOf(".session_manifest.json", "session_manifest.json")) {
            try {
                if (attributes(directory.resolve(manifest)).isRegularFile) return true
            } catch (_: NoSuchFileException) { /* 无清单旧目录继续按严格SDK命名识别。 */ }
        }
        val stamp = conversationName.matchEntire(name)?.groupValues?.get(1) ?: return false
        return try {
            val formatter = java.text.SimpleDateFormat("yyyyMMdd_HHmmss", java.util.Locale.US).apply { isLenient = false }
            formatter.parse(stamp)?.let { formatter.format(it) == stamp } == true
        } catch (_: java.text.ParseException) { false }
    }

    private val conversationName = Regex("^[A-Za-z0-9][A-Za-z0-9_-]*_(?:online|offline)_([0-9]{8}_[0-9]{6})(?:_(?:[0-9a-f]{4}|[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}))?$")
}
