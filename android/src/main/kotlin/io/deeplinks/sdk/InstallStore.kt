package io.deeplinks.sdk

import org.json.JSONObject
import java.io.File

class InstallStore(directory: File) {
    private val file = File(directory, FILE_NAME)
    private val lock = Any()
    private var cache: JSONObject? = null

    fun get(key: String): String? = synchronized(lock) {
        val values = load()
        if (values.has(key)) values.optString(key) else null
    }

    fun put(key: String, value: String) = synchronized(lock) {
        val values = load()
        values.put(key, value)
        persist(values)
    }

    fun remove(key: String) = synchronized(lock) {
        val values = load()
        if (values.remove(key) != null) {
            persist(values)
        }
    }

    private fun load(): JSONObject {
        cache?.let { return it }
        val loaded = try {
            if (file.exists()) JSONObject(file.readText()) else JSONObject()
        } catch (_: Exception) {
            JSONObject()
        }
        cache = loaded
        return loaded
    }

    private fun persist(values: JSONObject) {
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, "$FILE_NAME.tmp")
        temporary.writeText(values.toString())
        if (!temporary.renameTo(file)) {
            file.writeText(values.toString())
            temporary.delete()
        }
        cache = values
    }

    companion object {
        const val FILE_NAME = "deeplinks.json"
    }
}
