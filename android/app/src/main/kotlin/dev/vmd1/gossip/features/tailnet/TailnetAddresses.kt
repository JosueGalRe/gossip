package dev.vmd1.gossip.features.tailnet

import android.content.Context
import dev.vmd1.gossip.transport.TransportManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Tailscale, set up by itself: this device publishes its tailnet address as the [SLOT] state slot and keeps every
 * paired device's, so the fallback dial reaches a device that left the local network without anyone typing its
 * address. A fallback address entered by hand still wins. Only addresses in Tailscale's range (100.64.0.0/10) are
 * kept, so a peer can't point this device's dials anywhere else.
 */
class TailnetAddresses(context: Context) {
    private val prefs = context.getSharedPreferences("tailnet_hosts", Context.MODE_PRIVATE)

    /** The tailnet address [deviceId] last published, if any. */
    fun hostFor(deviceId: String): String? = prefs.getString(deviceId, null)

    fun start(
        scope: CoroutineScope,
        setState: (slot: String, value: JsonElement?) -> Unit,
        stateChanges: Flow<TransportManager.StateChange>
    ) {
        // Tailscale comes and goes (and its address with it); the core ignores an unchanged value.
        scope.launch {
            var published = false
            var last: String? = null
            while (isActive) {
                val own = ownAddress()
                if (!published || own != last) {
                    setState(SLOT, own?.let { buildJsonObject { put("ipv4", it) } })
                    published = true
                    last = own
                }
                delay(60_000)
            }
        }
        scope.launch {
            stateChanges.collect { change ->
                if (change.slot != SLOT) return@collect
                val ip = (change.value as? JsonObject)?.get("ipv4")?.jsonPrimitive?.contentOrNull?.takeIf(::isTailnet)
                prefs.edit().apply { if (ip == null) remove(change.deviceId) else putString(change.deviceId, ip) }.apply()
            }
        }
    }

    companion object {
        const val SLOT = "network.tailnet"

        /** An IPv4 address in Tailscale's 100.64.0.0/10. */
        fun isTailnet(ip: String): Boolean {
            val parts = ip.split('.').map { it.toIntOrNull() ?: return false }
            return parts.size == 4 && parts.all { it in 0..255 } && parts[0] == 100 && parts[1] in 64..127
        }

        /** This device's tailnet address while Tailscale is connected (its VPN interface), else `null`. */
        fun ownAddress(): String? = runCatching {
            NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp }
                .flatMap { it.inetAddresses.toList() }
                .filterIsInstance<Inet4Address>()
                .mapNotNull { it.hostAddress }
                .firstOrNull(::isTailnet)
        }.getOrNull()
    }
}
