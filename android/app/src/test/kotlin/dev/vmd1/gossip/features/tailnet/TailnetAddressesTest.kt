package dev.vmd1.gossip.features.tailnet

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TailnetAddressesTest {
    @Test fun acceptsTailscalesRange() {
        assertTrue(TailnetAddresses.isTailnet("100.64.0.1"))
        assertTrue(TailnetAddresses.isTailnet("100.101.12.34"))
        assertTrue(TailnetAddresses.isTailnet("100.127.255.255"))
    }

    @Test fun refusesEverythingElse() {
        assertFalse(TailnetAddresses.isTailnet("100.63.255.255"))
        assertFalse(TailnetAddresses.isTailnet("100.128.0.1"))
        assertFalse(TailnetAddresses.isTailnet("192.168.1.12"))
        assertFalse(TailnetAddresses.isTailnet("100.64.0"))
        assertFalse(TailnetAddresses.isTailnet("100.64.0.256"))
        assertFalse(TailnetAddresses.isTailnet("evil.example.com"))
    }
}
