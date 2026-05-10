package com.example.shadownetwork

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.ParcelUuid
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.BufferedReader
import java.io.BufferedWriter
import java.io.IOException
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.io.OutputStreamWriter
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

internal class AndroidTransportBridge(private val activity: FlutterActivity) {
    private val context: Context = activity.applicationContext
    private val bluetoothManager =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter
    private val wifiP2pManager =
        context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    private val wifiChannel = wifiP2pManager?.initialize(context, activity.mainLooper, null)
    private val serviceUuid = ParcelUuid(SERVICE_UUID)
    private val running = AtomicBoolean(false)
    private val discoveredPeers = linkedMapOf<String, DiscoveredPeer>()
    private val inbox = mutableListOf<Map<String, Any?>>()
    private val bluetoothConnections = ConcurrentHashMap<String, ManagedConnection>()
    private val wifiConnections = ConcurrentHashMap<String, ManagedConnection>()
    private val wifiLock = Any()

    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null
    private var wifiReceiver: BroadcastReceiver? = null
    private var bluetoothServerSocket: BluetoothServerSocket? = null
    private var bluetoothAcceptThread: Thread? = null
    private var wifiServerSocket: ServerSocket? = null
    private var wifiAcceptThread: Thread? = null
    private var wifiGroupFormed = false
    private var wifiIsGroupOwner = false
    private var wifiGroupOwnerHostAddress: String? = null
    private var pendingWifiPeerId: String? = null
    private var localPeerId: String = DEFAULT_LOCAL_PEER_ID
    private var localPeerName: String = DEFAULT_LOCAL_PEER_NAME

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ensurePermissions" -> result.success(ensurePermissions())
            "getLocalPeer" -> result.success(localPeerMap())
            "getTransportStatus" -> result.success(transportStatusMap())
            "start" -> {
                localPeerId = resolveLocalPeerId(call.argument<String>("localPeerId"))
                localPeerName = resolveLocalPeerName(call.argument<String>("localPeerName"))
                start()
                result.success(true)
            }
            "stop" -> {
                stop()
                result.success(true)
            }
            "discoverPeers" -> result.success(currentPeers())
            "sendEnvelope" -> {
                val peerId = call.argument<String>("peerId")
                val envelope = call.argument<Map<*, *>>("envelope")
                if (peerId.isNullOrBlank() || envelope == null) {
                    result.error(
                        "INVALID_ARGUMENT",
                        "sendEnvelope requires peerId and envelope arguments.",
                        null,
                    )
                    return
                }
                if (!ensurePermissions()) {
                    result.error(
                        "PERMISSIONS_REQUIRED",
                        "Bluetooth/Wi-Fi Direct permissions are not granted yet.",
                        null,
                    )
                    return
                }
                start()

                Thread {
                    try {
                        sendEnvelopeInternal(peerId, envelope)
                        postResult(result) { success(null) }
                    } catch (throwable: Throwable) {
                        postResult(result) {
                            this.error(
                                "TRANSPORT_SEND_FAILED",
                                throwable.message ?: "Failed to send envelope.",
                                null,
                            )
                        }
                    }
                }.start()
            }
            "receiveEnvelopes" -> {
                val drained = synchronized(inbox) {
                    inbox.toList().also { inbox.clear() }
                }
                result.success(drained)
            }
            else -> result.notImplemented()
        }
    }

    fun stop() {
        running.set(false)
        stopBle()
        stopWifiDirect()
        closeBluetoothServer()
        closeWifiServer()
        bluetoothConnections.values.toList().forEach(ManagedConnection::close)
        wifiConnections.values.toList().forEach(ManagedConnection::close)
        bluetoothConnections.clear()
        wifiConnections.clear()
        synchronized(discoveredPeers) {
            discoveredPeers.replaceAll { _, peer -> peer.copy(isConnected = false) }
        }
    }

    private fun postResult(
        result: MethodChannel.Result,
        block: MethodChannel.Result.() -> Unit,
    ) {
        activity.runOnUiThread {
            result.block()
        }
    }

    private fun currentPeers(): List<Map<String, Any?>> {
        return synchronized(discoveredPeers) {
            discoveredPeers.values.map(DiscoveredPeer::toPlatformMap)
        }
    }

    private fun localPeerMap(): Map<String, Any?> {
        ensureLocalIdentity()
        return linkedMapOf(
            "id" to localPeerId,
            "name" to localPeerName,
            "type" to "civilian",
            "isConnected" to running.get(),
            "signalStrength" to null,
        )
    }

    private fun transportStatusMap(): Map<String, Any?> {
        val peers = currentPeers()
        val connectedPeerCount = peers.count { it["isConnected"] == true }
        return linkedMapOf(
            "localPeer" to localPeerMap(),
            "permissionsGranted" to hasRequiredPermissions(),
            "isRunning" to running.get(),
            "discoveredPeerCount" to peers.size,
            "connectedPeerCount" to connectedPeerCount,
        )
    }

    private fun ensureLocalIdentity() {
        localPeerId = resolveLocalPeerId(localPeerId)
        localPeerName = resolveLocalPeerName(localPeerName)
    }

    private fun ensurePermissions(): Boolean {
        val missing = missingPermissions()

        if (missing.isNotEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            activity.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST_CODE)
            return false
        }

        return true
    }

    private fun hasRequiredPermissions(): Boolean = missingPermissions().isEmpty()

    private fun missingPermissions(): List<String> {
        return requiredPermissions().filter {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requiredPermissions(): List<String> {
        val permissions = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions.add(Manifest.permission.BLUETOOTH_SCAN)
            permissions.add(Manifest.permission.BLUETOOTH_ADVERTISE)
            permissions.add(Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            permissions.add(Manifest.permission.BLUETOOTH)
            permissions.add(Manifest.permission.BLUETOOTH_ADMIN)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            permissions.add(Manifest.permission.NEARBY_WIFI_DEVICES)
        }

        return permissions.distinct()
    }

    private fun start() {
        ensureLocalIdentity()
        if (!ensurePermissions()) {
            return
        }
        if (running.compareAndSet(false, true)) {
            startBluetoothSocketServer()
            startWifiSocketServer()
        }
        startBle()
        startWifiDirect()
    }

    @SuppressLint("MissingPermission")
    private fun startBle() {
        val adapter = bluetoothAdapter ?: return
        if (!adapter.isEnabled || advertiseCallback != null || scanCallback != null) return

        advertiser = adapter.bluetoothLeAdvertiser
        scanner = adapter.bluetoothLeScanner

        advertiser?.let { bleAdvertiser ->
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                .setConnectable(false)
                .build()
            val data = AdvertiseData.Builder()
                .addServiceUuid(serviceUuid)
                .addServiceData(serviceUuid, localPeerId.toByteArray(Charsets.UTF_8))
                .setIncludeDeviceName(false)
                .build()

            advertiseCallback = object : AdvertiseCallback() {}
            bleAdvertiser.startAdvertising(settings, data, advertiseCallback)
        }

        scanner?.let { bleScanner ->
            val filter = ScanFilter.Builder()
                .setServiceUuid(serviceUuid)
                .build()
            val settings = ScanSettings.Builder()
                .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
                .build()

            scanCallback = object : ScanCallback() {
                override fun onScanResult(callbackType: Int, result: ScanResult) {
                    val serviceData = result.scanRecord?.getServiceData(serviceUuid)
                    val peerId = serviceData
                        ?.toString(Charsets.UTF_8)
                        ?.takeIf { it.isNotBlank() }
                        ?: "ble:${result.device.address}"
                    if (peerId == localPeerId) return

                    rememberPeer(
                        DiscoveredPeer(
                            id = peerId,
                            name = result.scanRecord?.deviceName
                                ?: result.device.name
                                ?: "BLE Peer",
                            transport = TransportKind.BLUETOOTH,
                            bluetoothAddress = result.device.address,
                            isConnected = bluetoothConnections[peerId]?.isActive == true,
                            signalStrength = normalizeRssi(result.rssi),
                        ),
                    )
                }
            }
            bleScanner.startScan(listOf(filter), settings, scanCallback)
        }
    }

    @SuppressLint("MissingPermission")
    private fun stopBle() {
        advertiseCallback?.let { advertiser?.stopAdvertising(it) }
        scanCallback?.let { scanner?.stopScan(it) }
        advertiseCallback = null
        scanCallback = null
    }

    @SuppressLint("MissingPermission")
    private fun startWifiDirect() {
        val manager = wifiP2pManager ?: return
        val channel = wifiChannel ?: return

        if (wifiReceiver != null) {
            return
        }

        if (wifiReceiver == null) {
            wifiReceiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    when (intent.action) {
                        WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> {
                            manager.requestPeers(channel) { peerList ->
                                peerList.deviceList.forEach(::rememberWifiPeer)
                            }
                        }
                        WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                            manager.requestConnectionInfo(channel) { info ->
                                manager.requestGroupInfo(channel) { group ->
                                    handleWifiConnectionChanged(info, group)
                                }
                            }
                        }
                        WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                            if (intent.getIntExtra(
                                    WifiP2pManager.EXTRA_WIFI_STATE,
                                    WifiP2pManager.WIFI_P2P_STATE_DISABLED,
                                ) != WifiP2pManager.WIFI_P2P_STATE_ENABLED
                            ) {
                                clearWifiState()
                            }
                        }
                    }
                }
            }
        }

        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(wifiReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(wifiReceiver, filter)
        }

        manager.discoverPeers(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = Unit
            override fun onFailure(reason: Int) = Unit
        })
    }

    @SuppressLint("MissingPermission")
    private fun stopWifiDirect() {
        val manager = wifiP2pManager
        val channel = wifiChannel
        if (manager != null && channel != null) {
            manager.stopPeerDiscovery(channel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() = Unit
                override fun onFailure(reason: Int) = Unit
            })
            manager.removeGroup(channel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() = Unit
                override fun onFailure(reason: Int) = Unit
            })
        }

        wifiReceiver?.let {
            runCatching { context.unregisterReceiver(it) }
        }
        wifiReceiver = null
        clearWifiState()
    }

    private fun clearWifiState() {
        synchronized(wifiLock) {
            wifiGroupFormed = false
            wifiIsGroupOwner = false
            wifiGroupOwnerHostAddress = null
            pendingWifiPeerId = null
        }
        wifiConnections.values.toList().forEach(ManagedConnection::close)
        wifiConnections.clear()
        synchronized(discoveredPeers) {
            discoveredPeers.replaceAll { _, peer ->
                if (peer.transport == TransportKind.WIFI_DIRECT) {
                    peer.copy(isConnected = false)
                } else {
                    peer
                }
            }
        }
    }

    private fun handleWifiConnectionChanged(info: WifiP2pInfo, group: WifiP2pGroup?) {
        synchronized(wifiLock) {
            wifiGroupFormed = info.groupFormed
            wifiIsGroupOwner = info.isGroupOwner
            wifiGroupOwnerHostAddress = info.groupOwnerAddress?.hostAddress
        }

        if (!info.groupFormed) {
            clearWifiState()
            return
        }

        val connectedAddresses = mutableSetOf<String>()
        group?.owner?.deviceAddress?.let(connectedAddresses::add)
        group?.clientList?.forEach { client -> connectedAddresses.add(client.deviceAddress) }

        synchronized(discoveredPeers) {
            discoveredPeers.replaceAll { _, peer ->
                if (peer.transport == TransportKind.WIFI_DIRECT) {
                    peer.copy(
                        isConnected = peer.deviceAddress != null &&
                            connectedAddresses.contains(peer.deviceAddress),
                    )
                } else {
                    peer
                }
            }
        }

        if (!info.isGroupOwner) {
            val ownerPeerId = group?.owner?.deviceAddress?.let(::findPeerIdByWifiAddress)
                ?: synchronized(wifiLock) { pendingWifiPeerId }
            val hostAddress = info.groupOwnerAddress?.hostAddress
            if (!ownerPeerId.isNullOrBlank() && !hostAddress.isNullOrBlank()) {
                startWifiClientSocket(ownerPeerId, hostAddress)
            }
        }
    }

    private fun rememberWifiPeer(device: WifiP2pDevice) {
        val peerId = "wifi:${device.deviceAddress}"
        rememberPeer(
            DiscoveredPeer(
                id = peerId,
                name = device.deviceName ?: "Wi-Fi Direct Peer",
                transport = TransportKind.WIFI_DIRECT,
                deviceAddress = device.deviceAddress,
                isConnected = device.status == WifiP2pDevice.CONNECTED ||
                    wifiConnections[peerId]?.isActive == true,
            ),
        )
    }

    private fun rememberPeer(peer: DiscoveredPeer) {
        synchronized(discoveredPeers) {
            val existing = discoveredPeers[peer.id]
            discoveredPeers[peer.id] = if (existing == null) {
                peer
            } else {
                existing.merge(peer)
            }
        }
    }

    private fun findPeer(peerId: String): DiscoveredPeer? {
        return synchronized(discoveredPeers) { discoveredPeers[peerId] }
    }

    private fun findPeerIdByWifiAddress(deviceAddress: String): String? {
        return synchronized(discoveredPeers) {
            discoveredPeers.values.firstOrNull {
                it.transport == TransportKind.WIFI_DIRECT &&
                    it.deviceAddress == deviceAddress
            }?.id
        }
    }

    private fun resolveLocalPeerId(requestedPeerId: String?): String {
        val requested = requestedPeerId?.trim().orEmpty().ifBlank { DEFAULT_LOCAL_PEER_ID }
        if (requested != DEFAULT_LOCAL_PEER_ID) {
            return requested
        }

        val androidId = Settings.Secure.getString(
            context.contentResolver,
            Settings.Secure.ANDROID_ID,
        )?.takeLast(8)

        return if (androidId.isNullOrBlank()) {
            "${DEFAULT_LOCAL_PEER_ID}-${UUID.randomUUID().toString().take(8)}"
        } else {
            "${DEFAULT_LOCAL_PEER_ID}-$androidId"
        }
    }

    private fun resolveLocalPeerName(requestedPeerName: String?): String {
        return requestedPeerName?.trim()
            ?.takeIf { it.isNotBlank() && it != DEFAULT_LOCAL_PEER_NAME }
            ?: Build.MODEL
            ?: DEFAULT_LOCAL_PEER_NAME
    }

    @SuppressLint("MissingPermission")
    private fun startBluetoothSocketServer() {
        val adapter = bluetoothAdapter ?: return
        if (!adapter.isEnabled || bluetoothServerSocket != null) return

        bluetoothServerSocket = adapter.listenUsingInsecureRfcommWithServiceRecord(
            BLUETOOTH_SERVICE_NAME,
            SERVICE_UUID,
        )
        bluetoothAcceptThread = Thread {
            while (running.get()) {
                val serverSocket = bluetoothServerSocket ?: break
                try {
                    val socket = serverSocket.accept() ?: continue
                    initializeAcceptedConnection(
                        socket = BluetoothTransportSocket(socket),
                        transport = TransportKind.BLUETOOTH,
                    )
                } catch (_: IOException) {
                    if (!running.get()) {
                        break
                    }
                }
            }
        }.apply {
            name = "ShadowNetwork-BluetoothAccept"
            start()
        }
    }

    private fun closeBluetoothServer() {
        runCatching { bluetoothServerSocket?.close() }
        bluetoothServerSocket = null
        bluetoothAcceptThread = null
    }

    private fun startWifiSocketServer() {
        if (wifiServerSocket != null) return

        wifiServerSocket = ServerSocket().apply {
            reuseAddress = true
            bind(InetSocketAddress(WIFI_DIRECT_PORT))
        }
        wifiAcceptThread = Thread {
            while (running.get()) {
                val serverSocket = wifiServerSocket ?: break
                try {
                    val socket = serverSocket.accept() ?: continue
                    socket.tcpNoDelay = true
                    socket.keepAlive = true
                    initializeAcceptedConnection(
                        socket = TcpTransportSocket(socket),
                        transport = TransportKind.WIFI_DIRECT,
                    )
                } catch (_: IOException) {
                    if (!running.get()) {
                        break
                    }
                }
            }
        }.apply {
            name = "ShadowNetwork-WifiAccept"
            start()
        }
    }

    private fun closeWifiServer() {
        runCatching { wifiServerSocket?.close() }
        wifiServerSocket = null
        wifiAcceptThread = null
    }

    private fun initializeAcceptedConnection(
        socket: TransportSocket,
        transport: String,
    ) {
        Thread {
            try {
                val reader = BufferedReader(InputStreamReader(socket.inputStream(), Charsets.UTF_8))
                val writer = BufferedWriter(OutputStreamWriter(socket.outputStream(), Charsets.UTF_8))
                val helloLine = reader.readLine()
                    ?: throw IOException("Socket closed before handshake.")
                val hello = JSONObject(helloLine)
                val peerId = hello.optString("peerId").ifBlank {
                    throw IOException("Handshake missing peerId.")
                }
                val peerName = hello.optString("peerName").ifBlank { "Nearby Peer" }

                val connection = ManagedConnection(
                    peerId = peerId,
                    peerName = peerName,
                    transport = transport,
                    socket = socket,
                    reader = reader,
                    writer = writer,
                )
                registerConnection(connection)
                rememberPeer(
                    DiscoveredPeer(
                        id = peerId,
                        name = peerName,
                        transport = transport,
                        bluetoothAddress = hello.optString("bluetoothAddress").ifBlank { null },
                        isConnected = true,
                    ),
                )
                connection.start()
                connection.sendHello()
            } catch (_: Throwable) {
                runCatching { socket.close() }
            }
        }.start()
    }

    private fun registerConnection(connection: ManagedConnection) {
        val store = connectionStore(connection.transport)
        store.put(connection.peerId, connection)?.close()
        rememberPeer(
            DiscoveredPeer(
                id = connection.peerId,
                name = connection.peerName,
                transport = connection.transport,
                isConnected = true,
            ),
        )
    }

    private fun onConnectionClosed(connection: ManagedConnection) {
        connectionStore(connection.transport).remove(connection.peerId, connection)
        synchronized(discoveredPeers) {
            val existing = discoveredPeers[connection.peerId] ?: return
            discoveredPeers[connection.peerId] = existing.copy(isConnected = false)
        }
    }

    private fun connectionStore(transport: String): ConcurrentHashMap<String, ManagedConnection> {
        return if (transport == TransportKind.WIFI_DIRECT) {
            wifiConnections
        } else {
            bluetoothConnections
        }
    }

    private fun handleIncomingFrame(connection: ManagedConnection, frame: JSONObject) {
        when (frame.optString("type")) {
            "hello" -> {
                val peerName = frame.optString("peerName").ifBlank { connection.peerName }
                val bluetoothAddress = frame.optString("bluetoothAddress").ifBlank { null }
                rememberPeer(
                    DiscoveredPeer(
                        id = connection.peerId,
                        name = peerName,
                        transport = connection.transport,
                        bluetoothAddress = bluetoothAddress,
                        isConnected = true,
                    ),
                )
            }
            "envelope" -> {
                synchronized(inbox) {
                    inbox.add(
                        mapOf(
                            "messageHash" to frame.getString("messageHash"),
                            "payloadJson" to frame.getString("payloadJson"),
                            "hopCount" to frame.getInt("hopCount"),
                            "receivedAt" to frame.getString("receivedAt"),
                            "expiresAt" to frame.getString("expiresAt"),
                        ),
                    )
                }
            }
        }
    }

    private fun sendEnvelopeInternal(peerId: String, envelope: Map<*, *>) {
        val peer = findPeer(peerId)
            ?: throw IOException("Peer $peerId is not available for transport.")
        val messageHash = envelope["messageHash"] as? String
            ?: throw IOException("Envelope is missing messageHash.")
        val payloadJson = envelope["payloadJson"] as? String
            ?: throw IOException("Envelope is missing payloadJson.")
        val hopCount = (envelope["hopCount"] as? Number)?.toInt()
            ?: throw IOException("Envelope is missing hopCount.")
        val receivedAt = envelope["receivedAt"] as? String
            ?: throw IOException("Envelope is missing receivedAt.")
        val expiresAt = envelope["expiresAt"] as? String
            ?: throw IOException("Envelope is missing expiresAt.")

        val envelopeJson = JSONObject().apply {
            put("type", "envelope")
            put("messageHash", messageHash)
            put("payloadJson", payloadJson)
            put("hopCount", hopCount)
            put("receivedAt", receivedAt)
            put("expiresAt", expiresAt)
        }

        val sent = when (peer.transport) {
            TransportKind.WIFI_DIRECT -> runCatching {
                ensureWifiConnection(peer).sendFrame(envelopeJson)
                true
            }.getOrElse {
                if (peer.bluetoothAddress != null) {
                    ensureBluetoothConnection(peer).sendFrame(envelopeJson)
                    true
                } else {
                    throw it
                }
            }
            else -> {
                ensureBluetoothConnection(peer).sendFrame(envelopeJson)
                true
            }
        }

        if (!sent) {
            throw IOException("Transport failed to deliver envelope to $peerId.")
        }
    }

    @SuppressLint("MissingPermission")
    private fun ensureBluetoothConnection(peer: DiscoveredPeer): ManagedConnection {
        bluetoothConnections[peer.id]?.takeIf { it.isActive }?.let { return it }

        val adapter = bluetoothAdapter ?: throw IOException("Bluetooth is unavailable.")
        if (!adapter.isEnabled) {
            throw IOException("Bluetooth is disabled.")
        }

        val address = peer.bluetoothAddress
            ?: throw IOException("Peer ${peer.id} has no Bluetooth address.")
        val device: BluetoothDevice = adapter.getRemoteDevice(address)
        val socket = device.createInsecureRfcommSocketToServiceRecord(SERVICE_UUID)
        socket.connect()

        return createOutgoingConnection(
            peer = peer,
            transport = TransportKind.BLUETOOTH,
            socket = BluetoothTransportSocket(socket),
        )
    }

    @SuppressLint("MissingPermission")
    private fun ensureWifiConnection(peer: DiscoveredPeer): ManagedConnection {
        wifiConnections[peer.id]?.takeIf { it.isActive }?.let { return it }

        val manager = wifiP2pManager ?: throw IOException("Wi-Fi Direct is unavailable.")
        val channel = wifiChannel ?: throw IOException("Wi-Fi Direct channel is unavailable.")
        val deviceAddress = peer.deviceAddress
            ?: throw IOException("Peer ${peer.id} has no Wi-Fi Direct address.")

        synchronized(wifiLock) {
            pendingWifiPeerId = peer.id
        }

        val config = WifiP2pConfig().apply {
            this.deviceAddress = deviceAddress
            groupOwnerIntent = 0
        }

        manager.connect(channel, config, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = Unit
            override fun onFailure(reason: Int) = Unit
        })

        val deadline = System.currentTimeMillis() + WIFI_CONNECT_TIMEOUT_MS
        while (System.currentTimeMillis() < deadline) {
            wifiConnections[peer.id]?.takeIf { it.isActive }?.let { return it }
            Thread.sleep(250)
        }

        val hostAddress = synchronized(wifiLock) { wifiGroupOwnerHostAddress }
        if (!hostAddress.isNullOrBlank() && !wifiIsGroupOwner) {
            return startWifiClientSocket(peer.id, hostAddress)
        }

        throw IOException("Timed out connecting to ${peer.id} over Wi-Fi Direct.")
    }

    private fun startWifiClientSocket(peerId: String, hostAddress: String): ManagedConnection {
        wifiConnections[peerId]?.takeIf { it.isActive }?.let { return it }

        val client = Socket()
        client.connect(InetSocketAddress(hostAddress, WIFI_DIRECT_PORT), SOCKET_CONNECT_TIMEOUT_MS)
        client.tcpNoDelay = true
        client.keepAlive = true

        val peer = findPeer(peerId) ?: DiscoveredPeer(
            id = peerId,
            name = "Wi-Fi Direct Peer",
            transport = TransportKind.WIFI_DIRECT,
            isConnected = true,
        )

        return createOutgoingConnection(
            peer = peer,
            transport = TransportKind.WIFI_DIRECT,
            socket = TcpTransportSocket(client),
        )
    }

    private fun createOutgoingConnection(
        peer: DiscoveredPeer,
        transport: String,
        socket: TransportSocket,
    ): ManagedConnection {
        val reader = BufferedReader(InputStreamReader(socket.inputStream(), Charsets.UTF_8))
        val writer = BufferedWriter(OutputStreamWriter(socket.outputStream(), Charsets.UTF_8))
        val connection = ManagedConnection(
            peerId = peer.id,
            peerName = peer.name,
            transport = transport,
            socket = socket,
            reader = reader,
            writer = writer,
        )
        registerConnection(connection)
        connection.start()
        connection.sendHello()
        return connection
    }

    private fun normalizeRssi(rssi: Int): Int {
        val bounded = ((rssi + 100) * 100) / 60
        return bounded.coerceIn(0, 100)
    }

    private inner class ManagedConnection(
        val peerId: String,
        val peerName: String,
        val transport: String,
        private val socket: TransportSocket,
        private val reader: BufferedReader,
        private val writer: BufferedWriter,
    ) {
        @Volatile
        var isActive: Boolean = true
            private set

        fun start() {
            Thread {
                try {
                    while (isActive) {
                        val line = reader.readLine() ?: break
                        handleIncomingFrame(this, JSONObject(line))
                    }
                } catch (_: Throwable) {
                    // Connection teardown is handled below.
                } finally {
                    close()
                }
            }.start()
        }

        fun sendHello() {
            val hello = JSONObject().apply {
                put("type", "hello")
                put("peerId", localPeerId)
                put("peerName", localPeerName)
                bluetoothAdapter?.address?.takeIf { it.isNotBlank() }?.let { address ->
                    put("bluetoothAddress", address)
                }
            }
            sendFrame(hello)
        }

        fun sendFrame(frame: JSONObject) {
            synchronized(writer) {
                if (!isActive) {
                    throw IOException("Connection to $peerId is closed.")
                }
                writer.write(frame.toString())
                writer.newLine()
                writer.flush()
            }
        }

        fun close() {
            if (!isActive) {
                return
            }
            isActive = false
            runCatching { socket.close() }
            onConnectionClosed(this)
        }
    }

    private data class DiscoveredPeer(
        val id: String,
        val name: String,
        val transport: String,
        val deviceAddress: String? = null,
        val bluetoothAddress: String? = null,
        val isConnected: Boolean = false,
        val signalStrength: Int? = null,
    ) {
        fun merge(other: DiscoveredPeer): DiscoveredPeer {
            return copy(
                name = if (other.name.isNotBlank()) other.name else name,
                deviceAddress = other.deviceAddress ?: deviceAddress,
                bluetoothAddress = other.bluetoothAddress ?: bluetoothAddress,
                isConnected = other.isConnected || isConnected,
                signalStrength = other.signalStrength ?: signalStrength,
            )
        }

        fun toPlatformMap(): Map<String, Any?> {
            return linkedMapOf(
                "id" to id,
                "name" to name,
                "type" to "unknown",
                "isConnected" to isConnected,
                "signalStrength" to signalStrength,
                "transport" to transport,
                "deviceAddress" to deviceAddress,
                "bluetoothAddress" to bluetoothAddress,
            )
        }
    }

    private interface TransportSocket {
        fun inputStream(): InputStream
        fun outputStream(): OutputStream
        fun close()
    }

    private class BluetoothTransportSocket(
        private val socket: BluetoothSocket,
    ) : TransportSocket {
        override fun inputStream(): InputStream = socket.inputStream

        override fun outputStream(): OutputStream = socket.outputStream

        override fun close() {
            socket.close()
        }
    }

    private class TcpTransportSocket(
        private val socket: Socket,
    ) : TransportSocket {
        override fun inputStream(): InputStream = socket.getInputStream()

        override fun outputStream(): OutputStream = socket.getOutputStream()

        override fun close() {
            socket.close()
        }
    }

    private object TransportKind {
        const val BLUETOOTH = "bluetooth"
        const val WIFI_DIRECT = "wifi_direct"
    }

    companion object {
        const val CHANNEL_NAME = "shadownetwork/android_transport"
        private const val BLUETOOTH_SERVICE_NAME = "ShadowNetworkTransport"
        private const val DEFAULT_LOCAL_PEER_ID = "local-device"
        private const val DEFAULT_LOCAL_PEER_NAME = "This Device"
        private const val PERMISSION_REQUEST_CODE = 4207
        private const val WIFI_DIRECT_PORT = 8988
        private const val SOCKET_CONNECT_TIMEOUT_MS = 10_000
        private const val WIFI_CONNECT_TIMEOUT_MS = 20_000L
        private val SERVICE_UUID: UUID =
            UUID.fromString("9f7a7770-1b31-4f1d-8f99-6d7a9f50a101")
    }
}
