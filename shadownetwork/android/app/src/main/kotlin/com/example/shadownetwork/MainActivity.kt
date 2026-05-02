package com.example.shadownetwork

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
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
import android.net.wifi.p2p.WifiP2pDevice
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.ParcelUuid
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

class MainActivity : FlutterActivity() {
    private lateinit var androidTransport: AndroidTransportBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        androidTransport = AndroidTransportBridge(this)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            AndroidTransportBridge.CHANNEL_NAME,
        ).setMethodCallHandler(androidTransport::handle)
    }

    override fun onDestroy() {
        if (::androidTransport.isInitialized) {
            androidTransport.stop()
        }
        super.onDestroy()
    }
}

private class AndroidTransportBridge(private val activity: FlutterActivity) {
    private val context: Context = activity.applicationContext
    private val bluetoothManager =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter
    private val wifiP2pManager =
        context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    private val wifiChannel = wifiP2pManager?.initialize(context, activity.mainLooper, null)
    private val serviceUuid = ParcelUuid(SERVICE_UUID)
    private val discoveredPeers = linkedMapOf<String, MutableMap<String, Any?>>()
    private val inbox = mutableListOf<Map<String, Any?>>()

    private var advertiser: BluetoothLeAdvertiser? = null
    private var scanner: BluetoothLeScanner? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null
    private var wifiReceiver: BroadcastReceiver? = null
    private var localPeerId: String = "android-local"
    private var localPeerName: String = "Android Device"

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "ensurePermissions" -> result.success(ensurePermissions())
            "start" -> {
                localPeerId = call.argument<String>("localPeerId") ?: localPeerId
                localPeerName = call.argument<String>("localPeerName") ?: localPeerName
                start()
                result.success(true)
            }
            "stop" -> {
                stop()
                result.success(true)
            }
            "discoverPeers" -> result.success(discoveredPeers.values.toList())
            "sendEnvelope" -> {
                result.error(
                    "TRANSPORT_NOT_CONNECTED",
                    "Android BLE/Wi-Fi Direct discovery is available, but payload socket transfer is not connected yet.",
                    null,
                )
            }
            "receiveEnvelopes" -> {
                val drained = inbox.toList()
                inbox.clear()
                result.success(drained)
            }
            else -> result.notImplemented()
        }
    }

    fun stop() {
        stopBle()
        stopWifiDirect()
    }

    private fun ensurePermissions(): Boolean {
        val missing = requiredPermissions().filter {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }

        if (missing.isNotEmpty() && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            activity.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST_CODE)
            return false
        }

        return true
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
        if (!ensurePermissions()) {
            return
        }

        startBle()
        startWifiDirect()
    }

    @SuppressLint("MissingPermission")
    private fun startBle() {
        val adapter = bluetoothAdapter ?: return
        if (!adapter.isEnabled) return

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

                    discoveredPeers[peerId] = mutableMapOf(
                        "id" to peerId,
                        "name" to (result.scanRecord?.deviceName ?: result.device.name ?: "BLE Peer"),
                        "type" to "unknown",
                        "isConnected" to false,
                        "signalStrength" to result.rssi.coerceIn(0, 100),
                        "transport" to "ble",
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

        if (wifiReceiver == null) {
            wifiReceiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context, intent: Intent) {
                    if (intent.action == WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION) {
                        manager.requestPeers(channel) { peerList ->
                            peerList.deviceList.forEach(::rememberWifiPeer)
                        }
                    }
                }
            }
        }

        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
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
        }

        wifiReceiver?.let {
            runCatching { context.unregisterReceiver(it) }
        }
        wifiReceiver = null
    }

    private fun rememberWifiPeer(device: WifiP2pDevice) {
        val peerId = "wifi:${device.deviceAddress}"
        discoveredPeers[peerId] = mutableMapOf(
            "id" to peerId,
            "name" to device.deviceName,
            "type" to "unknown",
            "isConnected" to (device.status == WifiP2pDevice.CONNECTED),
            "signalStrength" to null,
            "transport" to "wifi_direct",
            "deviceAddress" to device.deviceAddress,
        )
    }

    companion object {
        const val CHANNEL_NAME = "shadownetwork/android_transport"
        private const val PERMISSION_REQUEST_CODE = 4207
        private val SERVICE_UUID: UUID = UUID.fromString("9f7a7770-1b31-4f1d-8f99-6d7a9f50a101")
    }
}
