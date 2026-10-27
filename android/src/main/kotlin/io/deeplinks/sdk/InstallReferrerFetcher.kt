package io.deeplinks.sdk

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener

class InstallReferrerFetcher(private val context: Context, private val store: InstallStore) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val pending = mutableListOf<(String?) -> Unit>()
    private var inFlight = false

    fun fetch(callback: (String?) -> Unit) {
        store.get(CACHE_KEY)?.let {
            callback(it)
            return
        }
        pending.add(callback)
        if (inFlight) return
        inFlight = true
        connect(0)
    }

    private fun connect(attempt: Int) {
        val client = try {
            InstallReferrerClient.newBuilder(context).build()
        } catch (_: Exception) {
            finish(null)
            return
        }
        var settled = false
        val listener = object : InstallReferrerStateListener {
            override fun onInstallReferrerSetupFinished(responseCode: Int) {
                if (settled) return
                settled = true
                when (responseCode) {
                    InstallReferrerClient.InstallReferrerResponse.OK -> {
                        val referrer = try {
                            client.installReferrer.installReferrer
                        } catch (_: Exception) {
                            null
                        }
                        close(client)
                        if (referrer != null) store.put(CACHE_KEY, referrer)
                        finish(referrer)
                    }
                    InstallReferrerClient.InstallReferrerResponse.SERVICE_UNAVAILABLE,
                    InstallReferrerClient.InstallReferrerResponse.SERVICE_DISCONNECTED -> {
                        close(client)
                        retryOrFinish(attempt)
                    }
                    else -> {
                        close(client)
                        finish(null)
                    }
                }
            }

            override fun onInstallReferrerServiceDisconnected() {
                if (settled) return
                settled = true
                close(client)
                retryOrFinish(attempt)
            }
        }
        try {
            client.startConnection(listener)
        } catch (_: Exception) {
            settled = true
            retryOrFinish(attempt)
        }
    }

    private fun retryOrFinish(attempt: Int) {
        if (attempt < MAX_RETRIES) {
            mainHandler.postDelayed({ connect(attempt + 1) }, RETRY_DELAY_MS)
        } else {
            finish(null)
        }
    }

    private fun close(client: InstallReferrerClient) {
        try {
            client.endConnection()
        } catch (_: Exception) {
        }
    }

    private fun finish(referrer: String?) {
        mainHandler.post {
            val callbacks = pending.toList()
            pending.clear()
            inFlight = false
            callbacks.forEach { it(referrer) }
        }
    }

    companion object {
        const val CACHE_KEY = "install_referrer_cache"
        private const val MAX_RETRIES = 1
        private const val RETRY_DELAY_MS = 500L
    }
}
