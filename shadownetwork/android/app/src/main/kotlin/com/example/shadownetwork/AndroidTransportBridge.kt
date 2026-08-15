package com.example.shadownetwork

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.bluetooth.BluetoothStatusCodes
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
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Build
import android.os.BatteryManager
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

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
    private var bleGattServer: BluetoothGattServer? = null
    private val bleFrameBuffers = ConcurrentHashMap<String, StringBuilder>()
    private val bleIdentityLookups = ConcurrentHashMap.newKeySet<String>()
    private val resolvedBlePeerIds = ConcurrentHashMap<String, String>()
    private var wifiReceiver: BroadcastReceiver? = null
    private var wifiServiceRequest: WifiP2pDnsSdServiceRequest? = null
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
    private var methodChannel: MethodChannel? = null

    fun attachChannel(channel: MethodChannel) {
        methodChannel = channel
    }

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ensurePermissions" -> result.success(ensurePermissions())
            "getLocalPeer" -> result.success(localPeerMap())
            "getTransportStatus" -> result.success(transportStatusMap())
            "getBatteryStatus" -> result.success(batteryStatusMap())
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
            "connectPeer" -> {
                val peerId = call.argument<String>("peerId")
                if (peerId.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENT", "connectPeer requires peerId.", null)
                    return
                }
                start()
                Thread {
                    try {
                        val connectedPeer = connectPeerInternal(peerId)
                        postResult(result) { success(connectedPeer.toPlatformMap()) }
                    } catch (throwable: Throwable) {
                        postResult(result) {
                            this.error(
                                "TRANSPORT_CONNECT_FAILED",
                                throwable.message ?: "Failed to connect to peer.",
                                null,
                            )
                        }
                    }
                }.start()
            }
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
                        val transferResult = sendEnvelopeInternal(peerId, envelope)
                        postResult(result) { success(transferResult) }
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
        RelayForegroundService.stop(context)
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
            discoveredPeers.values
                .filter { it.isVerifiedAppPeer && it.id != localPeerId }
                .map(DiscoveredPeer::toPlatformMap)
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

    private fun batteryStatusMap(): Map<String, Any?> {
        val batteryIntent = context.registerReceiver(
            null,
            IntentFilter(Intent.ACTION_BATTERY_CHANGED),
        )
        val level = batteryIntent?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = batteryIntent?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val status = batteryIntent?.getIntExtra(
            BatteryManager.EXTRA_STATUS,
            BatteryManager.BATTERY_STATUS_UNKNOWN,
        ) ?: BatteryManager.BATTERY_STATUS_UNKNOWN
        val percent: Double? = if (level >= 0 && scale > 0) {
            level * 100.0 / scale
        } else {
            null
        }
        return mapOf(
            "percent" to percent,
            "isCharging" to (
                status == BatteryManager.BATTERY_STATUS_CHARGING ||
                    status == BatteryManager.BATTERY_STATUS_FULL
                ),
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
            permissions.add(Manifest.permission.POST_NOTIFICATIONS)
        }

        return permissions.distinct()
    }

    private fun start() {
        ensureLocalIdentity()
        if (!ensurePermissions()) {
            return
        }
        RelayForegroundService.start(context)
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

        startBleGattServer()
        advertiser = adapter.bluetoothLeAdvertiser
        scanner = adapter.bluetoothLeScanner

        advertiser?.let { bleAdvertiser ->
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
                .setConnectable(true)
                .build()
            val data = AdvertiseData.Builder()
                .addServiceUuid(serviceUuid)
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
                    // Keep the BLE packet small enough for legacy Android advertising.
                    // Read identity over GATT before exposing the peer to Flutter.
                    val address = result.device.address
                    val signalStrength = normalizeRssi(result.rssi)
                    resolvedBlePeerIds[address]?.let { peerId ->
                        findPeer(peerId)?.let { peer ->
                            rememberPeer(
                                peer.copy(
                                    bluetoothAddress = address,
                                    signalStrength = signalStrength,
                                ),
                            )
                        }
                        return
                    }
                    resolveBleIdentityInBackground(result.device, signalStrength)
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
        runCatching { bleGattServer?.close() }
        bleGattServer = null
        bleFrameBuffers.clear()
        bleIdentityLookups.clear()
        resolvedBlePeerIds.clear()
    }

    @SuppressLint("MissingPermission")
    private fun startBleGattServer() {
        if (bleGattServer != null) return

        val server = bluetoothManager.openGattServer(
            context,
            object : BluetoothGattServerCallback() {
                override fun onCharacteristicWriteRequest(
                    device: BluetoothDevice,
                    requestId: Int,
                    characteristic: BluetoothGattCharacteristic,
                    preparedWrite: Boolean,
                    responseNeeded: Boolean,
                    offset: Int,
                    value: ByteArray,
                ) {
                    val accepted = characteristic.uuid == BLE_ENVELOPE_UUID &&
                        !preparedWrite &&
                        offset == 0 &&
                        receiveBleChunk(device.address, value)
                    if (responseNeeded) {
                        bleGattServer?.sendResponse(
                            device,
                            requestId,
                            if (accepted) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE,
                            0,
                            null,
                        )
                    }
                }

                override fun onCharacteristicReadRequest(
                    device: BluetoothDevice,
                    requestId: Int,
                    offset: Int,
                    characteristic: BluetoothGattCharacteristic,
                ) {
                    if (characteristic.uuid != BLE_IDENTITY_UUID) {
                        bleGattServer?.sendResponse(
                            device,
                            requestId,
                            BluetoothGatt.GATT_FAILURE,
                            offset,
                            null,
                        )
                        return
                    }
                    val value = JSONObject().apply {
                        put("appId", APP_ID)
                        put("protocolVersion", PROTOCOL_VERSION)
                        put("peerId", localPeerId)
                        put("peerName", localPeerName)
                        put("peerType", "civilian")
                    }.toString().toByteArray(Charsets.UTF_8)
                    val response = if (offset <= value.size) {
                        value.copyOfRange(offset, value.size)
                    } else {
                        byteArrayOf()
                    }
                    bleGattServer?.sendResponse(
                        device,
                        requestId,
                        BluetoothGatt.GATT_SUCCESS,
                        offset,
                        response,
                    )
                }
            },
        ) ?: return

        val envelopeCharacteristic = BluetoothGattCharacteristic(
            BLE_ENVELOPE_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        val identityCharacteristic = BluetoothGattCharacteristic(
            BLE_IDENTITY_UUID,
            BluetoothGattCharacteristic.PROPERTY_READ,
            BluetoothGattCharacteristic.PERMISSION_READ,
        )
        val service = BluetoothGattService(
            SERVICE_UUID,
            BluetoothGattService.SERVICE_TYPE_PRIMARY,
        ).apply {
            addCharacteristic(envelopeCharacteristic)
            addCharacteristic(identityCharacteristic)
        }
        bleGattServer = server
        server.addService(service)
    }

    @SuppressLint("MissingPermission")
    private fun resolveBleIdentityInBackground(device: BluetoothDevice, signalStrength: Int) {
        val address = device.address
        if (!bleIdentityLookups.add(address)) return

        Thread {
            try {
                val peer = readBleIdentity(
                    DiscoveredPeer(
                        id = "ble:$address",
                        name = "BLE Peer",
                        transport = TransportKind.BLUETOOTH,
                        bluetoothAddress = address,
                        signalStrength = signalStrength,
                    ),
                    markConnected = false,
                )
                rememberResolvedBlePeer(address, peer)
            } catch (_: Throwable) {
                // A later scan result retries transient identity failures.
            } finally {
                bleIdentityLookups.remove(address)
            }
        }.start()
    }

    private fun rememberResolvedBlePeer(address: String, peer: DiscoveredPeer) {
        resolvedBlePeerIds[address] = peer.id
        synchronized(discoveredPeers) {
            discoveredPeers.remove("ble:$address")
        }
        rememberPeer(peer)
    }

    private fun receiveBleChunk(address: String, value: ByteArray): Boolean {
        if (value.isEmpty()) return false

        val content = value.copyOfRange(1, value.size).toString(Charsets.UTF_8)
        val completeFrame = when (value[0]) {
            BLE_FRAME_SINGLE -> content
            BLE_FRAME_START -> {
                bleFrameBuffers[address] = StringBuilder(content)
                null
            }
            BLE_FRAME_CONTINUE -> {
                val buffer = bleFrameBuffers[address] ?: return false
                buffer.append(content)
                null
            }
            BLE_FRAME_END -> {
                val buffer = bleFrameBuffers.remove(address) ?: return false
                buffer.append(content).toString()
            }
            else -> return false
        }

        if (completeFrame != null) {
            return runCatching {
                val frame = JSONObject(completeFrame)
                if (frame.optString("type") != "envelope") {
                    return false
                }
                enqueueEnvelope(frame)
                true
            }.getOrDefault(false)
        }
        return true
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
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(wifiReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(wifiReceiver, filter)
        }

        advertiseAndDiscoverWifiAppServices(manager, channel)
    }

    @SuppressLint("MissingPermission")
    private fun stopWifiDirect() {
        val manager = wifiP2pManager
        val channel = wifiChannel
        if (manager != null && channel != null) {
            wifiServiceRequest?.let { request ->
                manager.removeServiceRequest(channel, request, emptyActionListener())
            }
            manager.clearServiceRequests(channel, emptyActionListener())
            manager.clearLocalServices(channel, emptyActionListener())
            manager.stopPeerDiscovery(channel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() = Unit
                override fun onFailure(reason: Int) = Unit
            })
            manager.removeGroup(channel, object : WifiP2pManager.ActionListener {
                override fun onSuccess() = Unit
                override fun onFailure(reason: Int) = Unit
            })
        }
        wifiServiceRequest = null

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

    private fun advertiseAndDiscoverWifiAppServices(
        manager: WifiP2pManager,
        channel: WifiP2pManager.Channel,
    ) {
        val serviceRecord = mapOf(
            "app_id" to APP_ID,
            "protocol_version" to PROTOCOL_VERSION.toString(),
            "peer_id" to localPeerId,
            "peer_name" to localPeerName,
            "port" to WIFI_DIRECT_PORT.toString(),
        )
        val localService = WifiP2pDnsSdServiceInfo.newInstance(
            WIFI_SERVICE_INSTANCE,
            WIFI_SERVICE_TYPE,
            serviceRecord,
        )
        manager.clearLocalServices(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                manager.addLocalService(channel, localService, emptyActionListener())
            }

            override fun onFailure(reason: Int) = Unit
        })

        manager.setDnsSdResponseListeners(
            channel,
            { _, _, _ -> Unit },
            { _, record, device ->
                rememberVerifiedWifiPeer(device, record)
            },
        )

        val request = WifiP2pDnsSdServiceRequest.newInstance(WIFI_SERVICE_TYPE)
        wifiServiceRequest = request
        manager.clearServiceRequests(channel, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                manager.addServiceRequest(channel, request, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        manager.discoverServices(channel, emptyActionListener())
                    }

                    override fun onFailure(reason: Int) = Unit
                })
            }

            override fun onFailure(reason: Int) = Unit
        })
    }

    private fun emptyActionListener(): WifiP2pManager.ActionListener {
        return object : WifiP2pManager.ActionListener {
            override fun onSuccess() = Unit
            override fun onFailure(reason: Int) = Unit
        }
    }

    private fun rememberVerifiedWifiPeer(device: WifiP2pDevice, record: Map<String, String>) {
        if (record["app_id"] != APP_ID ||
            record["protocol_version"] != PROTOCOL_VERSION.toString()
        ) {
            return
        }
        val peerId = record["peer_id"]?.trim()?.takeIf { it.isNotBlank() } ?: return
        if (peerId == localPeerId) return
        rememberPeer(
            DiscoveredPeer(
                id = peerId,
                name = record["peer_name"]?.takeIf { it.isNotBlank() }
                    ?: device.deviceName
                    ?: "Shadow Network Peer",
                peerType = "civilian",
                transport = TransportKind.WIFI_DIRECT,
                deviceAddress = device.deviceAddress,
                isConnected = device.status == WifiP2pDevice.CONNECTED ||
                    wifiConnections[peerId]?.isActive == true,
                isVerifiedAppPeer = true,
            ),
        )
    }

    private fun rememberPeer(peer: DiscoveredPeer) {
        var shouldNotify = false
        synchronized(discoveredPeers) {
            val existing = discoveredPeers[peer.id]
            val merged = if (existing == null) {
                shouldNotify = peer.isVerifiedAppPeer && peer.id != localPeerId
                peer
            } else {
                existing.merge(peer).also { mergedPeer ->
                    shouldNotify = mergedPeer.isVerifiedAppPeer &&
                        mergedPeer.id != localPeerId &&
                        (mergedPeer.transport != existing.transport ||
                            mergedPeer.isConnected != existing.isConnected ||
                            mergedPeer.deviceAddress != existing.deviceAddress ||
                            mergedPeer.bluetoothAddress != existing.bluetoothAddress)
                }
            }
            discoveredPeers[peer.id] = merged
        }
        if (shouldNotify) {
            notifyRelayEvent("peer_available")
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
                validateHello(hello)
                val peerId = hello.getString("peerId")
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
                        isVerifiedAppPeer = true,
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

    private fun validateHello(hello: JSONObject) {
        if (hello.optString("type") != "hello" ||
            hello.optString("appId") != APP_ID ||
            hello.optInt("protocolVersion", -1) != PROTOCOL_VERSION
        ) {
            throw IOException("Peer is not a compatible Shadow Network node.")
        }
        val peerId = hello.optString("peerId").trim()
        if (peerId.isBlank()) {
            throw IOException("Handshake missing peerId.")
        }
        if (peerId == localPeerId) {
            throw IOException("Ignoring local Shadow Network peer.")
        }
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
                runCatching { validateHello(frame) }.getOrElse {
                    connection.close()
                    return
                }
                val peerName = frame.optString("peerName").ifBlank { connection.peerName }
                val bluetoothAddress = frame.optString("bluetoothAddress").ifBlank { null }
                rememberPeer(
                    DiscoveredPeer(
                        id = connection.peerId,
                        name = peerName,
                        transport = connection.transport,
                        bluetoothAddress = bluetoothAddress,
                        isConnected = true,
                        isVerifiedAppPeer = true,
                    ),
                )
            }
            "envelope" -> {
                enqueueEnvelope(frame)
            }
        }
    }

    private fun enqueueEnvelope(frame: JSONObject) {
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
        notifyRelayEvent("envelope_available")
    }

    private fun notifyRelayEvent(type: String) {
        activity.runOnUiThread {
            methodChannel?.invokeMethod("onRelayEvent", mapOf("type" to type))
        }
    }

    private fun connectPeerInternal(peerId: String): DiscoveredPeer {
        val peer = findPeer(peerId)
            ?: throw IOException("Peer $peerId is not available for connection.")
        if (peer.transport == TransportKind.WIFI_DIRECT) {
            return runCatching {
                ensureWifiConnection(peer)
                peer.copy(isConnected = true)
            }.getOrElse {
                if (peer.bluetoothAddress.isNullOrBlank()) {
                    throw it
                }
                readBleIdentity(peer.copy(transport = TransportKind.BLUETOOTH), markConnected = true)
            }.also(::rememberPeer)
        }

        val connected = readBleIdentity(peer, markConnected = true)
        val address = connected.bluetoothAddress
            ?: throw IOException("Connected BLE peer has no device address.")
        rememberResolvedBlePeer(address, connected)
        return connected
    }

    private fun sendEnvelopeInternal(
        peerId: String,
        envelope: Map<*, *>,
    ): Map<String, Any?> {
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

        val transfer = when (peer.transport) {
            TransportKind.WIFI_DIRECT -> runCatching {
                ensureWifiConnection(peer).sendFrame(envelopeJson)
                mapOf(
                    "transport" to TransportKind.WIFI_DIRECT,
                    "fallbackUsed" to false,
                )
            }.getOrElse {
                if (peer.bluetoothAddress.isNullOrBlank()) {
                    throw it
                }
                sendBleEnvelope(peer.copy(transport = TransportKind.BLUETOOTH), envelopeJson)
                mapOf(
                    "transport" to TransportKind.BLUETOOTH,
                    "fallbackUsed" to true,
                )
            }
            else -> {
                sendBleEnvelope(peer, envelopeJson)
                mapOf(
                    "transport" to TransportKind.BLUETOOTH,
                    "fallbackUsed" to false,
                )
            }
        }
        return transfer
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
    private fun sendBleEnvelope(peer: DiscoveredPeer, frame: JSONObject) {
        val adapter = bluetoothAdapter ?: throw IOException("Bluetooth is unavailable.")
        if (!adapter.isEnabled) {
            throw IOException("Bluetooth is disabled.")
        }
        val address = peer.bluetoothAddress
            ?: throw IOException("Peer ${peer.id} has no Bluetooth address.")
        val chunks = bleFrameChunks(frame)
        val completed = CountDownLatch(1)
        val nextIndex = AtomicInteger(0)
        val failure = AtomicReference<IOException?>()

        val callback = object : BluetoothGattCallback() {
            private fun fail(message: String) {
                failure.compareAndSet(null, IOException(message))
                completed.countDown()
            }

            private fun writeNext(gatt: BluetoothGatt) {
                val characteristic = gatt.getService(SERVICE_UUID)
                    ?.getCharacteristic(BLE_ENVELOPE_UUID)
                    ?: run {
                        fail("Nearby BLE peer does not expose the relay service.")
                        return
                    }
                val index = nextIndex.getAndIncrement()
                val chunk = chunks.getOrNull(index) ?: run {
                    completed.countDown()
                    return
                }
                val started = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    gatt.writeCharacteristic(
                        characteristic,
                        chunk,
                        BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
                    ) == BluetoothStatusCodes.SUCCESS
                } else {
                    characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                    characteristic.value = chunk
                    gatt.writeCharacteristic(characteristic)
                }
                if (!started) {
                    fail("Unable to write relay payload over BLE.")
                }
            }

            override fun onConnectionStateChange(
                gatt: BluetoothGatt,
                status: Int,
                newState: Int,
            ) {
                if (status != BluetoothGatt.GATT_SUCCESS ||
                    newState != BluetoothProfile.STATE_CONNECTED
                ) {
                    fail("Unable to connect to ${peer.id} over BLE.")
                    return
                }
                if (!gatt.discoverServices()) {
                    fail("Unable to discover ${peer.id} BLE relay service.")
                }
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    fail("BLE relay service discovery failed for ${peer.id}.")
                    return
                }
                writeNext(gatt)
            }

            override fun onCharacteristicWrite(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    fail("BLE payload delivery failed for ${peer.id}.")
                } else if (nextIndex.get() < chunks.size) {
                    writeNext(gatt)
                } else {
                    completed.countDown()
                }
            }
        }

        val device = adapter.getRemoteDevice(address)
        val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        } else {
            device.connectGatt(context, false, callback)
        }

        try {
            if (!completed.await(BLE_SEND_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                throw IOException("Timed out sending relay payload to ${peer.id} over BLE.")
            }
            failure.get()?.let { throw it }
            rememberPeer(peer.copy(isConnected = true))
        } finally {
            runCatching { gatt.disconnect() }
            runCatching { gatt.close() }
        }
    }

    @SuppressLint("MissingPermission")
    private fun readBleIdentity(peer: DiscoveredPeer, markConnected: Boolean): DiscoveredPeer {
        val adapter = bluetoothAdapter ?: throw IOException("Bluetooth is unavailable.")
        val address = peer.bluetoothAddress
            ?: throw IOException("Peer ${peer.id} has no Bluetooth address.")
        val completed = CountDownLatch(1)
        val resolved = AtomicReference<DiscoveredPeer?>()
        val failure = AtomicReference<IOException?>()
        val finished = AtomicBoolean(false)
        val discoveryStarted = AtomicBoolean(false)

        val callback = object : BluetoothGattCallback() {
            private fun fail(message: String) {
                if (finished.compareAndSet(false, true)) {
                    failure.set(IOException(message))
                    completed.countDown()
                }
            }

            private fun discover(gatt: BluetoothGatt) {
                if (discoveryStarted.compareAndSet(false, true) && !gatt.discoverServices()) {
                    fail("Unable to discover ${peer.name} BLE identity service.")
                }
            }

            private fun completeIdentity(value: ByteArray, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    fail("Unable to read ${peer.name} BLE identity.")
                    return
                }
                if (finished.get()) return
                try {
                    val identity = JSONObject(value.toString(Charsets.UTF_8))
                    if (identity.optString("appId") != APP_ID ||
                        identity.optInt("protocolVersion", -1) != PROTOCOL_VERSION
                    ) {
                        fail("Nearby BLE device is not a compatible Shadow Network peer.")
                        return
                    }
                    val identityPeerId = identity.optString("peerId").trim()
                    if (identityPeerId.isBlank() || identityPeerId == localPeerId) {
                        fail("Nearby BLE peer identity is invalid.")
                        return
                    }
                    val identified = DiscoveredPeer(
                        id = identityPeerId,
                        name = identity.optString("peerName").ifBlank { "Nearby Peer" },
                        peerType = identity.optString("peerType").ifBlank { "civilian" },
                        transport = TransportKind.BLUETOOTH,
                        bluetoothAddress = address,
                        isConnected = markConnected,
                        signalStrength = peer.signalStrength,
                        isVerifiedAppPeer = true,
                    )
                    if (finished.compareAndSet(false, true)) {
                        resolved.set(identified)
                        completed.countDown()
                    }
                } catch (_: Throwable) {
                    fail("Received an invalid BLE identity from ${peer.name}.")
                }
            }

            override fun onConnectionStateChange(
                gatt: BluetoothGatt,
                status: Int,
                newState: Int,
            ) {
                if (status != BluetoothGatt.GATT_SUCCESS ||
                    newState != BluetoothProfile.STATE_CONNECTED
                ) {
                    fail("Unable to connect to ${peer.name} over BLE.")
                    return
                }
                if (!gatt.requestMtu(BLE_IDENTITY_MTU)) {
                    discover(gatt)
                }
            }

            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
                discover(gatt)
            }

            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    fail("BLE identity service discovery failed for ${peer.name}.")
                    return
                }
                val characteristic = gatt.getService(SERVICE_UUID)
                    ?.getCharacteristic(BLE_IDENTITY_UUID)
                    ?: run {
                        fail("Nearby BLE peer does not expose identity.")
                        return
                    }
                if (!gatt.readCharacteristic(characteristic)) {
                    fail("Unable to request ${peer.name} BLE identity.")
                }
            }

            @Suppress("DEPRECATION")
            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                status: Int,
            ) {
                if (characteristic.uuid == BLE_IDENTITY_UUID) {
                    completeIdentity(characteristic.value ?: byteArrayOf(), status)
                }
            }

            override fun onCharacteristicRead(
                gatt: BluetoothGatt,
                characteristic: BluetoothGattCharacteristic,
                value: ByteArray,
                status: Int,
            ) {
                if (characteristic.uuid == BLE_IDENTITY_UUID) {
                    completeIdentity(value, status)
                }
            }
        }

        val device = adapter.getRemoteDevice(address)
        val gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        } else {
            device.connectGatt(context, false, callback)
        }

        try {
            if (!completed.await(BLE_IDENTITY_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
                throw IOException("Timed out reading identity from ${peer.name}.")
            }
            failure.get()?.let { throw it }
            return resolved.get() ?: throw IOException("No identity received from ${peer.name}.")
        } finally {
            runCatching { gatt.disconnect() }
            runCatching { gatt.close() }
        }
    }

    private fun bleFrameChunks(frame: JSONObject): List<ByteArray> {
        val payload = frame.toString().toByteArray(Charsets.UTF_8)
        if (payload.size <= BLE_CHUNK_PAYLOAD_BYTES) {
            return listOf(byteArrayOf(BLE_FRAME_SINGLE) + payload)
        }

        val chunks = mutableListOf<ByteArray>()
        var offset = 0
        while (offset < payload.size) {
            val end = minOf(offset + BLE_CHUNK_PAYLOAD_BYTES, payload.size)
            val marker = when {
                offset == 0 -> BLE_FRAME_START
                end == payload.size -> BLE_FRAME_END
                else -> BLE_FRAME_CONTINUE
            }
            chunks.add(byteArrayOf(marker) + payload.copyOfRange(offset, end))
            offset = end
        }
        return chunks
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
                put("appId", APP_ID)
                put("protocolVersion", PROTOCOL_VERSION)
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
        val peerType: String = "unknown",
        val transport: String,
        val deviceAddress: String? = null,
        val bluetoothAddress: String? = null,
        val isConnected: Boolean = false,
        val signalStrength: Int? = null,
        val isVerifiedAppPeer: Boolean = false,
    ) {
        fun merge(other: DiscoveredPeer): DiscoveredPeer {
            val preferredTransport = when {
                transport == TransportKind.WIFI_DIRECT -> transport
                other.transport == TransportKind.WIFI_DIRECT -> other.transport
                else -> other.transport
            }
            return copy(
                name = if (other.name.isNotBlank()) other.name else name,
                peerType = if (other.peerType != "unknown") other.peerType else peerType,
                transport = preferredTransport,
                deviceAddress = other.deviceAddress ?: deviceAddress,
                bluetoothAddress = other.bluetoothAddress ?: bluetoothAddress,
                isConnected = other.isConnected || isConnected,
                signalStrength = other.signalStrength ?: signalStrength,
                isVerifiedAppPeer = isVerifiedAppPeer || other.isVerifiedAppPeer,
            )
        }

        fun toPlatformMap(): Map<String, Any?> {
            return linkedMapOf(
                "id" to id,
                "name" to name,
                "type" to peerType,
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
        private const val APP_ID = "shadownetwork"
        private const val PROTOCOL_VERSION = 1
        private const val WIFI_SERVICE_INSTANCE = "ShadowNetwork"
        private const val WIFI_SERVICE_TYPE = "_shadownetwork._tcp"
        private const val DEFAULT_LOCAL_PEER_ID = "local-device"
        private const val DEFAULT_LOCAL_PEER_NAME = "This Device"
        private const val PERMISSION_REQUEST_CODE = 4207
        private const val WIFI_DIRECT_PORT = 8988
        private const val SOCKET_CONNECT_TIMEOUT_MS = 10_000
        private const val WIFI_CONNECT_TIMEOUT_MS = 20_000L
        private const val BLE_SEND_TIMEOUT_MS = 15_000L
        private const val BLE_IDENTITY_TIMEOUT_MS = 10_000L
        private const val BLE_IDENTITY_MTU = 256
        // One protocol byte plus 18 payload bytes fits the default ATT MTU.
        private const val BLE_CHUNK_PAYLOAD_BYTES = 18
        private const val BLE_FRAME_SINGLE: Byte = 0x01
        private const val BLE_FRAME_START: Byte = 0x02
        private const val BLE_FRAME_CONTINUE: Byte = 0x03
        private const val BLE_FRAME_END: Byte = 0x04
        private val SERVICE_UUID: UUID =
            UUID.fromString("9f7a7770-1b31-4f1d-8f99-6d7a9f50a101")
        private val BLE_ENVELOPE_UUID: UUID =
            UUID.fromString("9f7a7771-1b31-4f1d-8f99-6d7a9f50a101")
        private val BLE_IDENTITY_UUID: UUID =
            UUID.fromString("9f7a7772-1b31-4f1d-8f99-6d7a9f50a101")
    }
}
