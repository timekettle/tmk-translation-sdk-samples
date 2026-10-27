package co.timekettle.translation.sample

import android.content.Context
import android.os.SystemClock
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest

/** Downloads a PCM file from the device itself; no desktop-side transfer is involved. */
internal object SauceRemotePcmDownloader {
    private const val MAX_BYTES = 20L * 1024 * 1024

    data class Result(val file: File?, val diagnostic: String)

    fun fetch(context: Context, rawUrl: String): Result {
        val started = SystemClock.elapsedRealtime()
        val uri = try { URI(rawUrl) } catch (_: Exception) {
            return Result(null, diagnostic("failed", error = "invalid_url"))
        }
        if (uri.scheme != "https" || uri.host.isNullOrBlank() || uri.userInfo != null) {
            return Result(null, diagnostic("failed", error = "https_url_required"))
        }
        val url = uri.toURL()
        var connection: HttpURLConnection? = null
        var temporary: File? = null
        var status: Int? = null
        var bytes = 0L
        return try {
            val opened = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                instanceFollowRedirects = false
                connectTimeout = 15_000
                readTimeout = 60_000
                setRequestProperty("Accept", "application/octet-stream")
            }
            connection = opened
            status = opened.responseCode
            if (status != HttpURLConnection.HTTP_OK) {
                Result(null, diagnostic("failed", status, error = "http_status_$status", host = url.host,
                    durationMs = SystemClock.elapsedRealtime() - started))
            } else {
                val digest = MessageDigest.getInstance("SHA-256")
                temporary = File.createTempFile("sauce_pcm_", ".part", context.cacheDir)
                opened.inputStream.use { input ->
                    temporary!!.outputStream().use { output ->
                        val buffer = ByteArray(16 * 1024)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            bytes += count
                            if (bytes > MAX_BYTES) throw IllegalStateException("audio_too_large")
                            digest.update(buffer, 0, count)
                            output.write(buffer, 0, count)
                        }
                    }
                }
                if (bytes == 0L || bytes % 2 != 0L) throw IllegalStateException("invalid_pcm16_length")
                val sha = digest.digest().joinToString("") { "%02x".format(it) }
                val finalFile = File(context.cacheDir, "sauce_remote_test_audio.pcm")
                if (finalFile.exists() && !finalFile.delete()) throw IllegalStateException("cache_replace_failed")
                if (!temporary!!.renameTo(finalFile)) throw IllegalStateException("cache_move_failed")
                temporary = null
                Result(finalFile, diagnostic("ok", status, bytes, sha, url.host,
                    SystemClock.elapsedRealtime() - started))
            }
        } catch (error: Exception) {
            val code = if (error is IllegalStateException) error.message ?: "invalid_audio"
                else error.javaClass.simpleName
            Result(null, diagnostic("failed", status, bytes, host = url.host,
                durationMs = SystemClock.elapsedRealtime() - started, error = code))
        } finally {
            temporary?.delete()
            connection?.disconnect()
        }
    }

    fun diagnostic(
        state: String,
        httpStatus: Int? = null,
        bytes: Long? = null,
        sha256: String? = null,
        host: String? = null,
        durationMs: Long? = null,
        error: String? = null,
    ): String = JSONObject().apply {
        put("status", state)
        put("http_status", httpStatus ?: JSONObject.NULL)
        put("bytes", bytes ?: JSONObject.NULL)
        put("sha256", sha256 ?: JSONObject.NULL)
        put("host", host ?: JSONObject.NULL)
        put("duration_ms", durationMs ?: JSONObject.NULL)
        put("error", error ?: JSONObject.NULL)
    }.toString()
}
