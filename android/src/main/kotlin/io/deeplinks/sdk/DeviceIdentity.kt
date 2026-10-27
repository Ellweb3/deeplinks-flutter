package io.deeplinks.sdk

import java.security.MessageDigest
import java.util.UUID

object DeviceIdentity {
    private const val BROKEN_ANDROID_ID = "9774d56d682e549c"
    private const val FALLBACK_KEY = "device_id_fallback"
    private const val ID_LENGTH = 32

    fun resolve(androidId: String?, appKey: String, store: InstallStore): String {
        val stable = androidId?.trim()?.lowercase()
        if (!stable.isNullOrEmpty() && stable != BROKEN_ANDROID_ID && stable.any { it != '0' }) {
            return derive(stable, appKey)
        }
        store.get(FALLBACK_KEY)?.let { return it }
        val created = UUID.randomUUID().toString().replace("-", "")
        store.put(FALLBACK_KEY, created)
        return created
    }

    fun derive(androidId: String, appKey: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest("deeplinks:$appKey:$androidId".toByteArray())
        return digest.joinToString("") { "%02x".format(it) }.take(ID_LENGTH)
    }
}
