package io.deeplinks.sdk

import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotEquals

class DeviceIdentityTest {
    private fun store() = InstallStore(Files.createTempDirectory("dm").toFile())

    @Test
    fun androidIdIsHashedPerAppKeyAndStable() {
        val a = DeviceIdentity.resolve("a1b2c3d4e5f60708", "dm_pk_one", store())
        assertEquals(a, DeviceIdentity.resolve("A1B2C3D4E5F60708", "dm_pk_one", store()))
        assertNotEquals(a, DeviceIdentity.resolve("a1b2c3d4e5f60708", "dm_pk_two", store()))
        assertEquals(32, a.length)
        assertNotEquals("a1b2c3d4e5f60708", a)
    }

    @Test
    fun brokenAndroidIdFallsBackToPersistedRandomId() {
        val shared = store()
        val first = DeviceIdentity.resolve("9774d56d682e549c", "dm_pk_one", shared)
        assertEquals(first, DeviceIdentity.resolve(null, "dm_pk_one", shared))
        assertEquals(first, DeviceIdentity.resolve("0000000000000000", "dm_pk_one", shared))
        assertNotEquals(first, DeviceIdentity.resolve(null, "dm_pk_one", store()))
    }
}
