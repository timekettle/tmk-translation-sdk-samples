package co.timekettle.translation.sample

import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

object DiagnosisExportUtils {
    fun zipDirectory(sourceDir: File, outputFile: File): File {
        require(sourceDir.exists() && sourceDir.isDirectory) { "diagnosis directory does not exist" }
        outputFile.parentFile?.mkdirs()
        if (outputFile.exists()) outputFile.delete()
        ZipOutputStream(FileOutputStream(outputFile)).use { zip ->
            sourceDir.walkTopDown()
                .filter { it.isFile }
                .sortedBy { it.relativeTo(sourceDir).path }
                .forEach { file ->
                    val entryName = file.relativeTo(sourceDir).invariantSeparatorsPath
                    zip.putNextEntry(ZipEntry(entryName))
                    FileInputStream(file).use { input -> input.copyTo(zip) }
                    zip.closeEntry()
                }
        }
        return outputFile
    }
}
