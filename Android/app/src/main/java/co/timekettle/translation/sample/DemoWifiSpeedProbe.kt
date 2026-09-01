package co.timekettle.translation.sample

import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicReference

/**
 * Demo 侧进房 Wi-Fi 测速：
 * - 业务延迟：对当前 Demo 配置的业务 baseURL 发轻量请求测 RTT（与鉴权/建房同机房链路）
 * - 带宽：对公共大文件源连续下行最多 10s，按总字节 / 总耗时得到平均吞吐（kbps）
 *
 * 页面退出时调用 [cancel]，中断进行中的连接与读流。
 */
enum class DemoWifiSpeedStatus {
    IDLE,
    RUNNING,
    DONE,
    CANCELLED,
    FAILED,
}

data class DemoWifiSpeedSnapshot(
    val status: DemoWifiSpeedStatus = DemoWifiSpeedStatus.IDLE,
    /** 10s 窗口平均下行带宽（kilobits per second） */
    val bandwidthKbps: Double? = null,
    val latencyMs: Long? = null,
    val elapsedMs: Long? = null,
    val errorMessage: String? = null,
) {
    val isBandwidthPoor: Boolean
        get() = bandwidthKbps != null && bandwidthKbps < POOR_BANDWIDTH_KBPS

    fun formatBandwidth(): String {
        val kbps = bandwidthKbps ?: return "-"
        return if (kbps >= 1000.0) {
            String.format("%.2fMbps", kbps / 1000.0)
        } else {
            String.format("%.0fkbps", kbps)
        }
    }

    fun formatLatency(): String {
        val ms = latencyMs ?: return "-"
        return "${ms}ms"
    }

    fun displayLine(): String {
        return when (status) {
            DemoWifiSpeedStatus.IDLE -> "测速 -"
            DemoWifiSpeedStatus.RUNNING -> {
                val bw = if (bandwidthKbps != null) formatBandwidth() else "…"
                val lat = formatLatency()
                val elapsed = elapsedMs?.let { "${it / 1000}s" } ?: "…"
                "测速中 $elapsed  带宽 $bw  业务延迟 $lat"
            }
            DemoWifiSpeedStatus.DONE -> "带宽 ${formatBandwidth()}  业务延迟 ${formatLatency()}"
            DemoWifiSpeedStatus.CANCELLED -> "测速已取消"
            DemoWifiSpeedStatus.FAILED -> "测速失败 ${errorMessage ?: ""}".trim()
        }
    }

    companion object {
        const val POOR_BANDWIDTH_KBPS = 100.0
        const val MEASURE_WINDOW_MS = 10_000L
    }
}

class DemoWifiSpeedProbe(
    private val downloadUrls: List<String> = DEFAULT_DOWNLOAD_URLS,
    private val measureWindowMs: Long = DemoWifiSpeedSnapshot.MEASURE_WINDOW_MS,
) {
    private class ProbeRun(val latencyUrls: List<String>) {
        @Volatile var cancelled = false
        val worker = AtomicReference<Thread?>(null)
        val activeConnection = AtomicReference<HttpURLConnection?>(null)

        fun cancel() {
            cancelled = true
            activeConnection.getAndSet(null)?.disconnectQuietly()
            worker.get()?.interrupt()
        }
    }

    private val activeRun = AtomicReference<ProbeRun?>(null)

    /**
     * @param businessBaseUrl Demo 当前生效的业务 API 根地址（与 SDK [SampleSdkConfig] / 网络环境一致）
     */
    fun start(
        businessBaseUrl: String,
        onUpdate: (DemoWifiSpeedSnapshot) -> Unit,
    ) {
        cancel()
        val run = ProbeRun(latencyUrlsForBusinessBase(businessBaseUrl))
        activeRun.set(run)
        publish(run, onUpdate, DemoWifiSpeedSnapshot(status = DemoWifiSpeedStatus.RUNNING, elapsedMs = 0))
        val thread = Thread({
            try {
                runProbe(run, onUpdate)
            } catch (t: Throwable) {
                if (isCancelled(run)) {
                    publish(run, onUpdate, DemoWifiSpeedSnapshot(status = DemoWifiSpeedStatus.CANCELLED))
                } else {
                    publish(
                        run,
                        onUpdate,
                        DemoWifiSpeedSnapshot(
                            status = DemoWifiSpeedStatus.FAILED,
                            errorMessage = t.message ?: t.javaClass.simpleName,
                        ),
                    )
                }
            } finally {
                run.worker.compareAndSet(Thread.currentThread(), null)
                run.activeConnection.getAndSet(null)?.disconnectQuietly()
                activeRun.compareAndSet(run, null)
            }
        }, "demo-wifi-speed-probe")
        run.worker.set(thread)
        thread.start()
    }

    fun cancel() {
        activeRun.getAndSet(null)?.cancel()
    }

    private fun isCancelled(run: ProbeRun): Boolean = run.cancelled || activeRun.get() !== run

    private fun publish(
        run: ProbeRun,
        onUpdate: (DemoWifiSpeedSnapshot) -> Unit,
        snapshot: DemoWifiSpeedSnapshot,
    ) {
        if (!isCancelled(run)) onUpdate(snapshot)
    }

    private fun runProbe(run: ProbeRun, onUpdate: (DemoWifiSpeedSnapshot) -> Unit) {
        if (isCancelled(run)) {
            return
        }

        val latency = measureLatency(run)
        if (isCancelled(run)) {
            return
        }
        publish(
            run,
            onUpdate,
            DemoWifiSpeedSnapshot(
                status = DemoWifiSpeedStatus.RUNNING,
                latencyMs = latency,
                elapsedMs = 0,
            ),
        )

        val startMs = System.currentTimeMillis()
        var totalBytes = 0L
        var lastPublishMs = 0L
        val buffer = ByteArray(64 * 1024)
        var lastError: Exception? = null
        var openedAny = false

        while (!isCancelled(run)) {
            val now = System.currentTimeMillis()
            val elapsed = now - startMs
            if (elapsed >= measureWindowMs) break

            val remainingMs = measureWindowMs - elapsed
            var roundBytes = 0L
            var roundOk = false
            for (url in downloadUrls) {
                if (isCancelled(run) || System.currentTimeMillis() - startMs >= measureWindowMs) break
                val conn = openConnection(url)
                if (isCancelled(run)) {
                    conn.disconnectQuietly()
                    break
                }
                run.activeConnection.set(conn)
                try {
                    conn.connectTimeout = 8_000
                    conn.readTimeout = remainingMs.toInt().coerceIn(1_000, 10_000)
                    conn.connect()
                    val code = conn.responseCode
                    if (code !in 200..299) {
                        lastError = IllegalStateException("HTTP $code")
                        continue
                    }
                    openedAny = true
                    conn.inputStream.use { input ->
                        roundBytes = readUntil(
                            input = input,
                            buffer = buffer,
                            deadlineMs = startMs + measureWindowMs,
                            run = run,
                        )
                    }
                    totalBytes += roundBytes
                    roundOk = true
                    lastError = null
                    break
                } catch (e: Exception) {
                    lastError = e
                } finally {
                    run.activeConnection.compareAndSet(conn, null)
                    conn.disconnectQuietly()
                }
            }

            if (!roundOk) {
                if (totalBytes > 0) break
                throw lastError ?: IllegalStateException("测速下载失败")
            }
            // 单文件读完仍不足窗口时，换下一个 URL 继续拉，避免空转
            if (roundBytes == 0L && openedAny) {
                throw lastError ?: IllegalStateException("测速无数据")
            }

            val publishNow = System.currentTimeMillis()
            if (publishNow - lastPublishMs >= 400L) {
                lastPublishMs = publishNow
                val elapsedPublish = (publishNow - startMs).coerceAtLeast(1L)
                publish(
                    run,
                    onUpdate,
                    DemoWifiSpeedSnapshot(
                        status = DemoWifiSpeedStatus.RUNNING,
                        bandwidthKbps = bytesToKbps(totalBytes, elapsedPublish),
                        latencyMs = latency,
                        elapsedMs = elapsedPublish,
                    ),
                )
            }
        }

        if (isCancelled(run)) {
            return
        }

        if (totalBytes <= 0L) {
            throw lastError ?: IllegalStateException("测速无数据")
        }

        val elapsedFinal = (System.currentTimeMillis() - startMs).coerceAtLeast(1L)
        publish(
            run,
            onUpdate,
            DemoWifiSpeedSnapshot(
                status = DemoWifiSpeedStatus.DONE,
                bandwidthKbps = bytesToKbps(totalBytes, elapsedFinal),
                latencyMs = latency,
                elapsedMs = elapsedFinal,
            ),
        )
    }

    private fun measureLatency(run: ProbeRun): Long? {
        val urls = run.latencyUrls
        if (urls.isEmpty()) return null
        val samples = mutableListOf<Long>()
        for (url in urls) {
            if (isCancelled(run)) break
            repeat(3) {
                if (isCancelled(run)) return samples.minOrNull()
                measureLatencyOnce(run, url)?.let { samples += it }
            }
            if (samples.isNotEmpty()) break
        }
        return samples.minOrNull()
    }

    /**
     * 业务延迟只关心「能否拿到 HTTP 响应头」的 RTT。
     * 根路径常返回 401/404，仍视为可达；连不上才算失败样本。
     */
    private fun measureLatencyOnce(run: ProbeRun, url: String): Long? {
        // 优先 HEAD（更轻）；部分网关不支持再退 GET，只取 responseCode。
        for (method in listOf("HEAD", "GET")) {
            if (isCancelled(run)) return null
            val started = System.currentTimeMillis()
            val conn = openConnection(url)
            if (isCancelled(run)) {
                conn.disconnectQuietly()
                return null
            }
            run.activeConnection.set(conn)
            try {
                conn.connectTimeout = 5_000
                conn.readTimeout = 5_000
                conn.requestMethod = method
                conn.connect()
                val code = conn.responseCode
                if (code in 100..599) {
                    // 避免把整页 body 算进延迟；读到首包即可
                    if (method == "GET" && code != 204) {
                        (conn.inputStream ?: conn.errorStream)?.use { input ->
                            val buf = ByteArray(256)
                            input.read(buf)
                        }
                    }
                    return (System.currentTimeMillis() - started).coerceAtLeast(0L)
                }
            } catch (_: Exception) {
                // try next method / sample
            } finally {
                run.activeConnection.compareAndSet(conn, null)
                conn.disconnectQuietly()
            }
        }
        return null
    }

    private fun readUntil(input: InputStream, buffer: ByteArray, deadlineMs: Long, run: ProbeRun): Long {
        var readTotal = 0L
        while (!isCancelled(run) && System.currentTimeMillis() < deadlineMs) {
            val n = try {
                input.read(buffer)
            } catch (_: Exception) {
                break
            }
            if (n < 0) break
            readTotal += n
        }
        return readTotal
    }

    private fun openConnection(url: String): HttpURLConnection {
        val conn = (URL(url).openConnection() as HttpURLConnection)
        conn.instanceFollowRedirects = true
        conn.useCaches = false
        conn.setRequestProperty("Cache-Control", "no-cache")
        // Cloudflare / 部分 CDN 会拒绝自定义 UA（HTTP 403）
        conn.setRequestProperty(
            "User-Agent",
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36",
        )
        conn.setRequestProperty("Accept", "*/*")
        if (url.contains("speed.cloudflare.com")) {
            conn.setRequestProperty("Referer", "https://speed.cloudflare.com/")
            conn.setRequestProperty("Origin", "https://speed.cloudflare.com")
        }
        return conn
    }

    companion object {
        // 带宽测速多端点回退（与业务延迟无关）。
        val DEFAULT_DOWNLOAD_URLS = listOf(
            "https://speed.cloudflare.com/__down?bytes=100000000",
            "https://proof.ovh.net/files/100Mb.dat",
            "https://cachefly.cachefly.net/100mb.test",
        )

        fun latencyUrlsForBusinessBase(baseUrl: String): List<String> {
            val trimmed = baseUrl.trim()
            if (trimmed.isEmpty()) return emptyList()
            val normalized = if (trimmed.endsWith("/")) trimmed else "$trimmed/"
            return listOf(normalized)
        }

        fun bytesToKbps(bytes: Long, elapsedMs: Long): Double {
            val seconds = elapsedMs.coerceAtLeast(1L) / 1000.0
            return (bytes * 8.0) / 1000.0 / seconds
        }
    }
}

private fun HttpURLConnection.disconnectQuietly() {
    try {
        disconnect()
    } catch (_: Exception) {
        // ignore
    }
}
