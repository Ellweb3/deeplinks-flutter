package io.deeplinks.sdk

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class InstallStoreTest {
    @Test
    fun valuesPersistAcrossInstances() {
        val dir = Files.createTempDirectory("dm").toFile()
        InstallStore(dir).apply {
            put("install_instance_id", "abc")
            put("deferred_done", "1")
            remove("deferred_done")
        }
        val reopened = InstallStore(dir)
        assertEquals("abc", reopened.get("install_instance_id"))
        assertNull(reopened.get("deferred_done"))
    }

    @Test
    fun corruptFileIsTreatedAsEmpty() {
        val dir = Files.createTempDirectory("dm").toFile()
        dir.resolve(InstallStore.FILE_NAME).writeText("{not json")
        val store = InstallStore(dir)
        assertNull(store.get("anything"))
        store.put("k", "v")
        assertEquals("v", InstallStore(dir).get("k"))
    }
}
