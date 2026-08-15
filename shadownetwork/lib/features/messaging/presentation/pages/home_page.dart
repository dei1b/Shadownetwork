import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:shadownetwork/features/app_update/domain/entities/app_update_check.dart';
import 'package:shadownetwork/features/app_update/presentation/providers/app_update_provider.dart';
import 'package:shadownetwork/features/trust/data/services/trust_bundle_store.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_access_profile.dart';
import 'package:shadownetwork/features/trust/domain/entities/trust_bundle.dart';
import 'package:shadownetwork/features/trust/domain/entities/device_trust_status.dart';
import 'package:shadownetwork/features/security/data/services/message_encryption_service.dart';

import '../../domain/entities/category.dart' as messaging;
import '../../domain/entities/message_moderation_status.dart' as messaging;
import '../../domain/entities/message_status.dart' as messaging;
import '../../domain/entities/peer.dart' as messaging;
import '../../domain/entities/peer_type.dart' as messaging;
import '../../domain/entities/sos_message.dart' as messaging;
import '../../domain/entities/conversation.dart' as messaging;
import '../../data/services/offline_panabo_tile_server.dart';
import 'conversation_page.dart';
import '../providers/local_messaging_providers.dart';
import '../providers/relay_runtime_provider.dart';
import '../utils/message_feed_filter.dart';
import '../../../auth/presentation/widgets/auth_background.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key, required this.accessProfile});

  final DeviceAccessProfile accessProfile;

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  int _selectedTab = 0;
  int _selectedMessageFilter = 0;
  int _selectedPeerFilter = 0;
  final Set<messaging.Category> _visibleMapCategories = {
    ...messaging.Category.values,
  };
  bool _showMapPeers = true;
  bool _showMapLocation = true;
  bool _isCheckingAppUpdate = false;

  bool get _isResponder => widget.accessProfile.canAccessResponderInterface;

  static const String _mapFilterAllMarkers = 'all-markers';
  static const String _mapFilterPeers = 'peers';
  static const String _mapFilterLocation = 'location';

  static const LatLng _mapCenter = LatLng(7.3026, 125.6888);
  static const double _minZoom = 10;
  static const double _maxZoom = 19;
  static const double _defaultZoom = 16.1;
  static const double _panaboNorth = 7.345;
  static const double _panaboSouth = 7.235;
  static const double _panaboEast = 125.73;
  static const double _panaboWest = 125.62;

  final OfflinePanaboTileServer _offlineTileServer = OfflinePanaboTileServer();
  ml.MapLibreMapController? _mapController;
  String? _offlineMapStyle;
  LatLng _currentCenter = _mapCenter;
  double _currentZoom = _defaultZoom;
  double _currentBearing = 0;
  LatLng? _myPosition;
  bool _isLocating = false;
  bool _isFollowing = false;
  final bool _tileLoadFailed = false;
  StreamSubscription<Position>? _positionSubscription;

  @override
  void initState() {
    super.initState();
    ml.MapLibreMap.useHybridComposition = true;
    unawaited(_startOfflineMapStyle());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startFollowing(showError: false);
    });
  }

  Future<void> _startOfflineMapStyle() async {
    try {
      final styleUri = await _offlineTileServer.start();
      if (!mounted) {
        return;
      }
      setState(() => _offlineMapStyle = styleUri.toString());
    } catch (_) {}
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    unawaited(_offlineTileServer.dispose());
    super.dispose();
  }

  Future<bool> _ensureLocationReady({bool showError = true}) async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (showError) {
        _showMessage('Location service is disabled. Please enable GPS.');
      }
      return false;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (showError) {
        _showMessage('Location permission is required to locate you.');
      }
      return false;
    }

    return true;
  }

  Future<void> _startFollowing({bool showError = true}) async {
    final canLocate = await _ensureLocationReady(showError: showError);
    if (!canLocate) {
      return;
    }

    if (!mounted) {
      return;
    }

    setState(() => _isFollowing = true);
    await _locateMe(showError: showError);

    await _positionSubscription?.cancel();
    _positionSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5,
          ),
        ).listen((position) {
          final myPoint = LatLng(position.latitude, position.longitude);
          if (!mounted) {
            return;
          }

          setState(() {
            _myPosition = myPoint;
            _currentCenter = myPoint;
          });

          if (_isFollowing) {
            _moveMap(myPoint, _currentZoom);
          }
        });
  }

  Future<void> _locateMe({bool showError = true}) async {
    if (_isLocating) {
      return;
    }

    setState(() => _isLocating = true);
    try {
      final canLocate = await _ensureLocationReady(showError: showError);
      if (!canLocate) {
        setState(() => _isFollowing = false);
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      final myPoint = LatLng(position.latitude, position.longitude);
      if (!mounted) {
        return;
      }

      final targetZoom = _currentZoom < 16 ? 16.0 : _currentZoom;

      setState(() {
        _isFollowing = true;
        _myPosition = myPoint;
        _currentCenter = myPoint;
        _currentZoom = targetZoom;
      });

      _moveMap(myPoint, targetZoom);
    } catch (_) {
      if (showError) {
        _showMessage('Unable to get current location right now.');
      }
    } finally {
      if (mounted) {
        setState(() => _isLocating = false);
      }
    }
  }

  void _zoomIn() {
    final targetZoom = (_currentZoom + 1).clamp(_minZoom, _maxZoom).toDouble();
    _moveMap(_currentCenter, targetZoom);
    setState(() => _currentZoom = targetZoom);
  }

  void _zoomOut() {
    final targetZoom = (_currentZoom - 1).clamp(_minZoom, _maxZoom).toDouble();
    _moveMap(_currentCenter, targetZoom);
    setState(() => _currentZoom = targetZoom);
  }

  void _resetNorth() {
    _mapController?.animateCamera(ml.CameraUpdate.bearingTo(0));
    setState(() => _currentBearing = 0);
  }

  void _moveMap(LatLng center, double zoom) {
    _mapController?.moveCamera(
      ml.CameraUpdate.newLatLngZoom(_toMapLibreLatLng(center), zoom),
    );
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _checkForAppUpdate() async {
    if (_isCheckingAppUpdate) {
      return;
    }

    setState(() => _isCheckingAppUpdate = true);
    try {
      final update = await ref
          .read(appUpdateServiceProvider)
          .checkLatestRelease();
      if (!mounted) {
        return;
      }

      switch (update.status) {
        case AppUpdateStatus.updateAvailable:
          final shouldDownload = await _showAppUpdateDialog(
            title: 'Update available',
            message:
                'Current: ${update.currentVersion}. Latest: ${update.latestVersion}.',
            actionLabel: 'DOWNLOAD',
          );
          if (shouldDownload == true) {
            await _openAppUpdateDownload(update);
          }
          break;
        case AppUpdateStatus.latestVersionUnknown:
          final shouldDownload = await _showAppUpdateDialog(
            title: 'Latest APK found',
            message: 'Version could not be compared. Open the download anyway?',
            actionLabel: 'OPEN',
          );
          if (shouldDownload == true) {
            await _openAppUpdateDownload(update);
          }
          break;
        case AppUpdateStatus.upToDate:
          await _showAppUpdateDialog(
            title: 'App is up to date',
            message: 'Installed version: ${update.currentVersion}.',
            actionLabel: update.canDownload ? 'VIEW APK' : 'OK',
            showCancel: update.canDownload,
          ).then((shouldOpen) async {
            if (shouldOpen == true) {
              await _openAppUpdateDownload(update);
            }
          });
          break;
        case AppUpdateStatus.noRelease:
          _showMessage(
            'No GitHub release found yet. Upload an APK release first.',
          );
          break;
        case AppUpdateStatus.noAndroidApk:
          _showMessage('Latest GitHub release has no APK asset.');
          break;
      }
    } catch (_) {
      _showMessage('Unable to check for app updates right now.');
    } finally {
      if (mounted) {
        setState(() => _isCheckingAppUpdate = false);
      }
    }
  }

  Future<void> _openAppUpdateDownload(AppUpdateCheck update) async {
    final opened = await ref
        .read(appUpdateServiceProvider)
        .openDownload(update);
    if (!opened) {
      _showMessage('Unable to open the APK download link.');
    }
  }

  Future<bool?> _showAppUpdateDialog({
    required String title,
    required String message,
    required String actionLabel,
    bool showCancel = true,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            if (showCancel)
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('CANCEL'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(actionLabel),
            ),
          ],
        );
      },
    );
  }

  Future<void> _syncRelayNow() async {
    try {
      await ref.read(relayRuntimeProvider.notifier).syncNow(force: true);
      if (!mounted) {
        return;
      }
      final status = ref.read(relayRuntimeProvider);
      _showMessage(
        'Relay sync complete. ${status.connectedPeers} peer(s), '
        '${status.lastReceivedCount} received, ${status.lastRelayedCount} relayed.',
      );
    } catch (_) {
      _showMessage('Relay sync failed.');
    }
  }

  Future<void> _connectToPeer(messaging.Peer peer) async {
    if (peer.isConnected) {
      _showMessage('${peer.name} is already connected.');
      return;
    }
    final connected = await ref
        .read(relayRuntimeProvider.notifier)
        .connectToPeer(peer);
    if (!mounted) {
      return;
    }
    _showMessage(
      connected
          ? 'Connected to nearby peer.'
          : 'Unable to connect to ${peer.name}. Keep both apps open.',
    );
  }

  String _formatLocationText() {
    final position = _myPosition;
    if (position == null) {
      return 'Locating...';
    }

    final latSuffix = position.latitude >= 0 ? 'N' : 'S';
    final lngSuffix = position.longitude >= 0 ? 'E' : 'W';
    final latValue = position.latitude.abs().toStringAsFixed(4);
    final lngValue = position.longitude.abs().toStringAsFixed(4);
    return '$latValue° $latSuffix, $lngValue° $lngSuffix';
  }

  Future<void> _openSosComposerModal() async {
    final trustBundle = await TrustBundleStore().loadBundle();
    final localPeer = await ref.read(localPeerProvider.future);
    if (!mounted) {
      return;
    }
    final hasCurrentVerifiedBundle =
        trustBundle?.isSignatureVerified == true &&
        !trustBundle!.isExpiredAt(DateTime.now());
    final trustedRecipients =
        (hasCurrentVerifiedBundle
                ? trustBundle.approvedDevices
                : const <TrustedDevice>[])
            .where((device) => device.deviceId != localPeer.id)
            .toList(growable: false);
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      enableDrag: true,
      isDismissible: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _SosComposerSheet(
          locationText: _formatLocationText(),
          trustedRecipients: trustedRecipients,
          onUpdateLocation: _locateMe,
          onSend: _saveSosMessage,
        );
      },
    );

    if (created == true && mounted) {
      await _showTaskCompletionPopup(
        title: 'SOS Created',
        message: 'Saved locally and queued for relay.',
        icon: Icons.check_rounded,
      );
    }
  }

  Future<void> _showTaskCompletionPopup({
    required String title,
    required String message,
    required IconData icon,
  }) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) {
        return _TaskCompletionPopup(title: title, message: message, icon: icon);
      },
    );
  }

  Future<void> _saveSosMessage(
    String body,
    messaging.Category category,
    TrustedDevice? recipient,
  ) async {
    final now = DateTime.now();
    final position = _myPosition;
    final localPeer = await ref.read(localPeerProvider.future);
    final runtime = ref.read(relayRuntimeProvider);
    final message = messaging.SosMessage(
      id: 'sos-${now.microsecondsSinceEpoch}',
      sender: localPeer.copyWith(
        isConnected: runtime.isRunning || runtime.connectedPeers > 0,
        lastSeenAt: now,
        latitude: position?.latitude,
        longitude: position?.longitude,
      ),
      body: body.trim(),
      category: category,
      status: messaging.MessageStatus.queued,
      createdAt: now,
      latitude: position?.latitude,
      longitude: position?.longitude,
      recipient: recipient == null ? null : _peerFromTrustedDevice(recipient),
      isEncrypted: recipient != null,
    );

    await ref.read(saveSosMessageProvider)(message);
    await ref.read(relayRuntimeProvider.notifier).syncNow(force: true);
  }

  messaging.Peer _peerFromTrustedDevice(TrustedDevice device) {
    return messaging.Peer(
      id: device.deviceId,
      name: device.ownerName,
      type: _peerTypeFromTrustedRole(device.role),
      isConnected: false,
    );
  }

  messaging.PeerType _peerTypeFromTrustedRole(String role) {
    return messaging.PeerType.values.firstWhere(
      (type) => type.name == role,
      orElse: () => messaging.PeerType.unknown,
    );
  }

  Future<void> _openConversation(
    messaging.Peer peer, {
    messaging.SosMessage? linkedSosMessage,
  }) async {
    final conversation = await ref.read(openConversationProvider)(
      remotePeer: peer,
      relatedSosMessageHash: linkedSosMessage?.messageHash,
    );
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConversationPage(
          conversation: conversation,
          linkedSosMessage: linkedSosMessage,
        ),
      ),
    );
    ref.invalidate(conversationsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final peers = ref.watch(nearbyPeersProvider);
    final messages = ref.watch(sosMessagesProvider);
    final conversations = ref.watch(conversationsProvider);
    final tileCacheStore = ref.watch(mapTileCacheStoreProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      body: AuthBackground(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: _selectedTab == 2
                    ? _buildMapTabContent(peers, messages, tileCacheStore)
                    : SingleChildScrollView(
                        physics: const BouncingScrollPhysics(),
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildLogo(),
                            Transform.translate(
                              offset: const Offset(0, -25),
                              child: _selectedTab == 1
                                  ? _buildMessagesTabContent(
                                      messages,
                                      conversations,
                                    )
                                  : _selectedTab == 3
                                  ? _buildPeersTabContent(peers)
                                  : _buildHomeTabContent(
                                      peers,
                                      messages,
                                      tileCacheStore,
                                    ),
                            ),
                          ],
                        ),
                      ),
              ),
              _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHomeTabContent(
    AsyncValue<List<messaging.Peer>> peers,
    AsyncValue<List<messaging.SosMessage>> messages,
    AsyncValue<CacheStore> tileCacheStore,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        _buildDeviceAccessBanner(),
        const SizedBox(height: 14),
        if (_isResponder)
          _buildResponderAlertButton(messages)
        else
          _buildSosButton(),
        const SizedBox(height: 14),
        _buildMapCard(peers, messages, tileCacheStore),
        const SizedBox(height: 14),
        if (_isResponder)
          _buildResponderActionButtons()
        else
          _buildActionButtons(),
        const SizedBox(height: 20),
        _buildPeersSection(peers),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildDeviceAccessBanner() {
    final profile = widget.accessProfile;
    final (
      icon,
      title,
      detail,
      background,
      foreground,
    ) = switch (profile.level) {
      DeviceAccessLevel.responder => (
        Icons.verified_user_rounded,
        'VERIFIED RESPONDER',
        '${profile.ownerName ?? 'Approved device'} - responder tools enabled',
        const Color(0xFFE83C3D),
        Colors.white,
      ),
      DeviceAccessLevel.revoked => (
        Icons.block_rounded,
        'DEVICE REVOKED',
        'Responder access is disabled. Contact the administrator.',
        const Color(0xFF7D1A1A),
        Colors.white,
      ),
      DeviceAccessLevel.keyMismatch => (
        Icons.key_off_rounded,
        'DEVICE KEY MISMATCH',
        'Register this phone key again before responder access can be restored.',
        const Color(0xFFFFE4E1),
        const Color(0xFF8B1E1E),
      ),
      DeviceAccessLevel.unregistered => (
        Icons.app_registration_rounded,
        'DEVICE NOT APPROVED',
        'Show the registration QR to an admin, then import the approved bundle.',
        const Color(0xFFFFF1D6),
        const Color(0xFF7A4B00),
      ),
      DeviceAccessLevel.outdatedBundle => (
        Icons.update_rounded,
        'TRUST BUNDLE EXPIRED',
        'Import a newly signed bundle from the PC admin. Emergency broadcast remains available.',
        const Color(0xFFFFF1D6),
        const Color(0xFF7A4B00),
      ),
      _ => (
        Icons.verified_rounded,
        'VERIFIED ${profile.roleLabel.toUpperCase()}',
        '${profile.ownerName ?? 'Approved device'} - identity key matched',
        const Color(0xFFEAF6EF),
        const Color(0xFF23613D),
      ),
    };

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: () => Navigator.of(context).pushNamed('/trust-bundle'),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(icon, color: foreground, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: foreground,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      detail,
                      style: TextStyle(
                        color: foreground.withValues(alpha: 0.85),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right_rounded, color: foreground, size: 22),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResponderAlertButton(
    AsyncValue<List<messaging.SosMessage>> messages,
  ) {
    final alertCount = messages.maybeWhen(
      data: (items) => items
          .where(
            (message) =>
                message.moderationStatus !=
                messaging.MessageModerationStatus.spam,
          )
          .length,
      orElse: () => 0,
    );

    return Material(
      color: const Color(0xFFE83C3D),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: () => setState(() {
          _selectedMessageFilter = 1;
          _selectedTab = 1;
        }),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.notification_important_rounded,
                  color: Colors.white,
                  size: 27,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'OPEN SOS ALERTS',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '$alertCount legitimate alert${alertCount == 1 ? '' : 's'} stored locally',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.arrow_forward_rounded,
                color: Colors.white,
                size: 23,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMapTabContent(
    AsyncValue<List<messaging.Peer>> peers,
    AsyncValue<List<messaging.SosMessage>> messages,
    AsyncValue<CacheStore> tileCacheStore,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildLogo(),
          Expanded(
            child: Transform.translate(
              offset: const Offset(0, -25),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  Text(
                    _isResponder ? 'RESPONDER SOS MAP' : 'MAP',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F1F1F),
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _isResponder
                        ? 'Triage legitimate emergency markers'
                        : 'View SOS alerts and peers',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF717173),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: _buildMapStack(
                        peers: peers,
                        messages: messages,
                        tileCacheStore: tileCacheStore,
                        showLegend: true,
                        showStatusBadge: false,
                        markerSize: 58,
                        locationMarkerSize: 42,
                        visibleCategories: _visibleMapCategories,
                        showPeers: _showMapPeers,
                        showMyLocation: _showMapLocation,
                        bottomOverlay: _buildMapTabActionButtons(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessagesTabContent(
    AsyncValue<List<messaging.SosMessage>> messages,
    AsyncValue<List<messaging.Conversation>> conversations,
  ) {
    final List<(String, IconData, String)> filters = [
      ('All Messages', Icons.chat_bubble_outline_rounded, 'ALL'),
      ('SOS Alerts', Icons.sos_rounded, 'SOS'),
      ('Requests', Icons.pan_tool_outlined, 'REQUEST'),
      ('Updates', Icons.campaign_outlined, 'UPDATE'),
      ('Spam', Icons.report_gmailerrorred_rounded, 'SPAM'),
      ('Quarantine', Icons.gpp_bad_rounded, 'QUARANTINE'),
    ];

    final String activeType = filters[_selectedMessageFilter].$3;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isResponder ? 'SOS ALERTS & MESSAGES' : 'MESSAGES',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F1F1F),
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _isResponder
                        ? 'Incoming emergency traffic and responder chats'
                        : 'All messages from your peers',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF717173),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                children: [
                  Container(
                    width: 80,
                    height: 42,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFBEFEF),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'All',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFAD2D2D),
                          ),
                        ),
                        SizedBox(width: 6),
                        Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: Color(0xFFAD2D2D),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.search_rounded,
                      size: 24,
                      color: Color(0xFF161616),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        const SizedBox(height: 14),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: List.generate(filters.length, (index) {
              final active = _selectedMessageFilter == index;
              return Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Material(
                  color: active
                      ? const Color(0xFFE83C3D)
                      : const Color(0xFFF2F2F2),
                  borderRadius: BorderRadius.circular(30),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(30),
                    onTap: () => setState(() => _selectedMessageFilter = index),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            filters[index].$2,
                            size: 20,
                            color: active
                                ? Colors.white
                                : const Color(0xFF5A5A5A),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            filters[index].$1,
                            style: TextStyle(
                              color: active
                                  ? Colors.white
                                  : const Color(0xFF3A3A3A),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 14),
        if (activeType == 'ALL' ||
            activeType == 'SPAM' ||
            activeType == 'QUARANTINE')
          conversations.when(
            data: (items) {
              final visibleConversations = items
                  .where((conversation) {
                    return shouldShowConversationForFilter(
                      conversation: conversation,
                      activeFilter: activeType,
                    );
                  })
                  .toList(growable: false);

              return visibleConversations.isEmpty
                  ? const SizedBox.shrink()
                  : Column(
                      children: [
                        ...visibleConversations.map(
                          (conversation) => _buildConversationCard(
                            conversation,
                            isSpam:
                                conversation.latestModerationStatus ==
                                messaging.MessageModerationStatus.spam,
                            isRevoked:
                                conversation.latestTrustStatus ==
                                DeviceTrustStatus.revoked,
                          ),
                        ),
                        const SizedBox(height: 2),
                      ],
                    );
            },
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
          ),
        messages.when(
          data: (items) {
            final feedItems = items
                .map(_messageFeedItemFromSosMessage)
                .toList();
            final filteredMessages = feedItems
                .where((item) {
                  return shouldShowSosMessageForFilter(
                    message: item.message,
                    messageType: item.type,
                    activeFilter: activeType,
                  );
                })
                .toList(growable: false);

            if (filteredMessages.isEmpty) {
              return _buildEmptyState(
                icon: Icons.chat_bubble_outline_rounded,
                message: 'No local messages yet.',
              );
            }

            return Column(
              children: filteredMessages
                  .map(
                    (item) => _buildMessageFeedCard(
                      item,
                      onTap: () => _openConversation(
                        item.message.sender,
                        linkedSosMessage: item.message,
                      ),
                    ),
                  )
                  .toList(growable: false),
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, _) => _buildEmptyState(
            icon: Icons.error_outline_rounded,
            message: 'Unable to load local messages.',
          ),
        ),
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Row(
            children: [
              Icon(Icons.shield_outlined, size: 18, color: Color(0xFFE83C3D)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Messages are stored locally and shared with nearby peers.',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF666666),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _buildPeersTabContent(AsyncValue<List<messaging.Peer>> peers) {
    final items = peers.valueOrNull ?? const <messaging.Peer>[];
    final filters = const [
      (label: 'All Peers', icon: Icons.groups_rounded),
      (label: 'Connected', icon: Icons.link_rounded),
      (label: 'Rescuers', icon: Icons.health_and_safety_outlined),
      (label: 'Nearby', icon: Icons.location_on_outlined),
    ];

    final connectedCount = items.where((peer) => peer.isConnected).length;
    final rescuerCount = items.where(_isResponderPeer).length;
    final filteredPeers = items.where(_peerMatchesSelectedFilter).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isResponder ? 'CONNECTION DIAGNOSTICS' : 'PEERS',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F1F1F),
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _isResponder
                        ? 'Monitor nearby nodes, links, and relay readiness'
                        : 'Nearby devices available for message relay',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF717173),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: _PeerUpdateButton(
                isLoading: _isCheckingAppUpdate,
                onTap: _checkForAppUpdate,
              ),
            ),
          ],
        ),
        const SizedBox(height: 22),
        _PeerStatsPanel(
          connectedCount: connectedCount,
          nearbyCount: items.length,
          rescuerCount: rescuerCount,
        ),
        const SizedBox(height: 18),
        _PeerFilterBar(
          filters: filters,
          selectedIndex: _selectedPeerFilter,
          onSelected: (index) => setState(() => _selectedPeerFilter = index),
        ),
        const SizedBox(height: 12),
        const _PeerScanningRow(),
        const SizedBox(height: 12),
        peers.when(
          data: (_) {
            if (filteredPeers.isEmpty) {
              return _buildEmptyState(
                icon: Icons.people_outline_rounded,
                message: 'No peers match this filter yet.',
              );
            }

            return Column(
              children: filteredPeers
                  .map(
                    (peer) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _PeerDirectoryCard(
                        peer: peer,
                        distanceText: _distanceTextForPeer(peer),
                        signalLabel: _signalLabelForPeer(peer),
                        signalColor: _signalColorForPeer(peer),
                        avatarColor: _avatarColorForPeer(peer),
                        typeLabel: _peerTypeLabel(peer),
                        actionLabel: _peerActionLabel(peer),
                        actionStyle: _peerActionStyle(peer),
                        onActionTap: () => _connectToPeer(peer),
                      ),
                    ),
                  )
                  .toList(growable: false),
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, _) => _buildEmptyState(
            icon: Icons.error_outline_rounded,
            message: 'Unable to load local peers.',
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: _PeerScanButton(onTap: _syncRelayNow),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildMessageFeedCard(
    _MessageFeedItem item, {
    required VoidCallback onTap,
  }) {
    final isSpam = item.isSpam;
    final isRevoked = item.trustStatus == DeviceTrustStatus.revoked;
    final cardColor = isRevoked
        ? const Color(0xFFF1F1F1)
        : isSpam
        ? const Color(0xFFFFFAF0)
        : Colors.white;
    final titleColor = isRevoked
        ? const Color(0xFF5B2020)
        : isSpam
        ? const Color(0xFF6F5315)
        : item.type == 'SOS'
        ? const Color(0xFFE83C3D)
        : const Color(0xFF1F1F1F);
    return Material(
      color: cardColor,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(8),
            border: isRevoked
                ? Border.all(color: const Color(0xFF8D5B5B))
                : isSpam
                ? Border.all(color: const Color(0xFFE5C56C))
                : null,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: item.iconColor,
                  shape: BoxShape.circle,
                ),
                child: Icon(item.icon, color: Colors.white, size: 28),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            item.title,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: titleColor,
                            ),
                          ),
                        ),
                        Text(
                          item.time,
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF888888),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      item.description,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF666666),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          Icons.location_on,
                          size: 16,
                          color: isSpam
                              ? const Color(0xFF8A6A1F)
                              : const Color(0xFFE83C3D),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          item.distance,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF585858),
                          ),
                        ),
                        const Spacer(),
                        _TrustStatusBadge(status: item.trustStatus),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: item.badgeColor,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            item.badge,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConversationCard(
    messaging.Conversation conversation, {
    bool isSpam = false,
    bool isRevoked = false,
  }) {
    final peer = conversation.remotePeer;
    final status = isSpam ? 'spam' : conversation.latestStatus?.name ?? 'ready';
    final cardColor = isRevoked
        ? const Color(0xFFF1F1F1)
        : isSpam
        ? const Color(0xFFFFFAF0)
        : Colors.white;
    return Material(
      color: cardColor,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _openConversation(peer),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(8),
            border: isRevoked
                ? Border.all(color: const Color(0xFF8D5B5B))
                : isSpam
                ? Border.all(color: const Color(0xFFE5C56C))
                : null,
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 25,
                backgroundColor: isSpam
                    ? const Color(0xFF8A6A1F)
                    : _avatarColorForPeer(peer),
                child: const Icon(Icons.person, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            peer.name,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (conversation.lastMessageAt != null)
                          Text(
                            _relativeTime(conversation.lastMessageAt!),
                            style: const TextStyle(
                              fontSize: 10,
                              color: Color(0xFF888888),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      conversation.latestBody ?? 'Open conversation',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFF666666),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _TrustStatusBadge(
                          status:
                              conversation.latestTrustStatus ??
                              DeviceTrustStatus.unknown,
                        ),
                        const SizedBox(width: 7),
                        Text(
                          status.toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: isSpam
                                ? const Color(0xFF8A6A1F)
                                : const Color(0xFFE83C3D),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (conversation.unreadCount > 0)
                Container(
                  margin: const EdgeInsets.only(left: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE83C3D),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '${conversation.unreadCount}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  _MessageFeedItem _messageFeedItemFromSosMessage(
    messaging.SosMessage message,
  ) {
    final isSpam =
        message.moderationStatus == messaging.MessageModerationStatus.spam;
    final type = isSpam ? 'SPAM' : _messageTypeForCategory(message.category);
    final accentColor = isSpam
        ? const Color(0xFF8A6A1F)
        : _colorForCategory(message.category);

    return _MessageFeedItem(
      message: message,
      title:
          '${_labelForCategory(message.category)} from ${message.trustOwnerName ?? message.sender.name}',
      description: message.body,
      distance: _distanceTextForMessage(message),
      time: _relativeTime(message.createdAt),
      badge: type,
      type: type,
      icon: isSpam
          ? Icons.report_gmailerrorred_rounded
          : _iconForCategory(message.category),
      iconColor: accentColor,
      badgeColor: accentColor,
      isSpam: isSpam,
      trustStatus: message.trustStatus,
    );
  }

  String _messageTypeForCategory(messaging.Category category) {
    return switch (category) {
      messaging.Category.rescue || messaging.Category.medical => 'SOS',
      messaging.Category.food ||
      messaging.Category.water ||
      messaging.Category.shelter ||
      messaging.Category.transport => 'REQUEST',
      messaging.Category.information || messaging.Category.other => 'UPDATE',
    };
  }

  String _labelForCategory(messaging.Category category) {
    return switch (category) {
      messaging.Category.rescue => 'Rescue Request',
      messaging.Category.food => 'Food Request',
      messaging.Category.water => 'Water Request',
      messaging.Category.medical => 'Medical SOS',
      messaging.Category.shelter => 'Shelter Request',
      messaging.Category.transport => 'Transport Request',
      messaging.Category.information => 'Information Update',
      messaging.Category.other => 'General Update',
    };
  }

  String _shortLabelForCategory(messaging.Category category) {
    return switch (category) {
      messaging.Category.rescue => 'Rescue',
      messaging.Category.food => 'Food',
      messaging.Category.water => 'Water',
      messaging.Category.medical => 'Medical',
      messaging.Category.shelter => 'Shelter',
      messaging.Category.transport => 'Transport',
      messaging.Category.information => 'Information',
      messaging.Category.other => 'Other',
    };
  }

  String _markerLabelForCategory(messaging.Category category) {
    return switch (category) {
      messaging.Category.rescue => 'RESCUE',
      messaging.Category.food => 'FOOD',
      messaging.Category.water => 'WATER',
      messaging.Category.medical => 'MED',
      messaging.Category.shelter => 'SHELTER',
      messaging.Category.transport => 'RIDE',
      messaging.Category.information => 'INFO',
      messaging.Category.other => 'OTHER',
    };
  }

  IconData _iconForCategory(messaging.Category category) {
    return switch (category) {
      messaging.Category.rescue => Icons.accessibility_new,
      messaging.Category.food => Icons.restaurant,
      messaging.Category.water => Icons.opacity,
      messaging.Category.medical => Icons.local_hospital,
      messaging.Category.shelter => Icons.home,
      messaging.Category.transport => Icons.directions_bus,
      messaging.Category.information => Icons.info,
      messaging.Category.other => Icons.more_horiz,
    };
  }

  Color _colorForCategory(messaging.Category category) {
    return switch (category) {
      messaging.Category.rescue ||
      messaging.Category.medical => const Color(0xFFE83C3D),
      messaging.Category.food ||
      messaging.Category.shelter ||
      messaging.Category.transport => const Color(0xFFF39C12),
      messaging.Category.water ||
      messaging.Category.information => const Color(0xFF3F66C4),
      messaging.Category.other => const Color(0xFF777777),
    };
  }

  String _distanceTextForMessage(messaging.SosMessage message) {
    final myPosition = _myPosition;
    final latitude = message.latitude;
    final longitude = message.longitude;
    if (myPosition == null || latitude == null || longitude == null) {
      return 'Stored locally';
    }

    final distanceMeters = const Distance().as(
      LengthUnit.Meter,
      myPosition,
      LatLng(latitude, longitude),
    );

    if (distanceMeters < 1000) {
      return '${distanceMeters.round()} m away';
    }

    return '${(distanceMeters / 1000).toStringAsFixed(1)} km away';
  }

  bool _peerMatchesSelectedFilter(messaging.Peer peer) {
    return switch (_selectedPeerFilter) {
      1 => peer.isConnected,
      2 => _isResponderPeer(peer),
      3 => peer.latitude != null && peer.longitude != null,
      _ => true,
    };
  }

  bool _isResponderPeer(messaging.Peer peer) {
    return peer.type == messaging.PeerType.responder ||
        peer.type == messaging.PeerType.authority;
  }

  String _distanceTextForPeer(messaging.Peer peer) {
    final myPosition = _myPosition;
    final latitude = peer.latitude;
    final longitude = peer.longitude;
    if (myPosition == null || latitude == null || longitude == null) {
      return 'In range';
    }

    final distanceMeters = const Distance().as(
      LengthUnit.Meter,
      myPosition,
      LatLng(latitude, longitude),
    );

    if (distanceMeters < 1000) {
      return '${distanceMeters.round()} m';
    }

    return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
  }

  String _signalLabelForPeer(messaging.Peer peer) {
    final signalStrength = peer.signalStrength;
    if (signalStrength == null || signalStrength >= 65) {
      return 'Strong Signal';
    }
    if (signalStrength >= 35) {
      return 'Medium Signal';
    }
    return 'Weak Signal';
  }

  Color _signalColorForPeer(messaging.Peer peer) {
    final signalStrength = peer.signalStrength;
    if (signalStrength == null || signalStrength >= 65) {
      return const Color(0xFF15A832);
    }
    if (signalStrength >= 35) {
      return const Color(0xFFF28B16);
    }
    return const Color(0xFF7D7D7D);
  }

  Color _avatarColorForPeer(messaging.Peer peer) {
    if (_isResponderPeer(peer)) {
      return peer.isConnected
          ? const Color(0xFFE83C3D)
          : const Color(0xFFFFC15A);
    }
    if (peer.type == messaging.PeerType.relay) {
      return const Color(0xFF5B8DEF);
    }
    if (peer.type == messaging.PeerType.unknown) {
      return const Color(0xFFD8D8D8);
    }
    return const Color(0xFF68D179);
  }

  String _peerTypeLabel(messaging.Peer peer) {
    return switch (peer.type) {
      messaging.PeerType.responder || messaging.PeerType.authority => 'Rescuer',
      messaging.PeerType.relay => 'Relay',
      messaging.PeerType.civilian => 'User',
      messaging.PeerType.unknown => 'User',
    };
  }

  String _peerActionLabel(messaging.Peer peer) {
    if (peer.isConnected) {
      return 'CONNECTED';
    }
    final signalStrength = peer.signalStrength ?? 0;
    if (signalStrength >= 45 && !_isResponderPeer(peer)) {
      return 'RELAY READY';
    }
    return 'CONNECT';
  }

  _PeerActionStyle _peerActionStyle(messaging.Peer peer) {
    if (peer.isConnected) {
      return _PeerActionStyle.filledRed;
    }
    final signalStrength = peer.signalStrength ?? 0;
    if (signalStrength >= 45 && !_isResponderPeer(peer)) {
      return _PeerActionStyle.outlineOrange;
    }
    return _PeerActionStyle.outlineRed;
  }

  String _relativeTime(DateTime dateTime) {
    final elapsed = DateTime.now().difference(dateTime);
    if (elapsed.inMinutes < 1) {
      return 'Just now';
    }
    if (elapsed.inHours < 1) {
      return '${elapsed.inMinutes}m ago';
    }
    if (elapsed.inDays < 1) {
      return '${elapsed.inHours}h ago';
    }
    if (elapsed.inDays == 1) {
      return 'Yesterday';
    }

    return '${elapsed.inDays} days ago';
  }

  Widget _buildEmptyState({required IconData icon, required String message}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: const Color(0xFFE83C3D)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Color(0xFF666666),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    final items = _isResponder
        ? const [
            _NavItem(icon: Icons.dashboard_rounded, label: 'Dashboard'),
            _NavItem(
              icon: Icons.notification_important_outlined,
              label: 'Alerts',
            ),
            _NavItem(icon: Icons.map_outlined, label: 'SOS Map'),
            _NavItem(icon: Icons.monitor_heart_outlined, label: 'Network'),
          ]
        : const [
            _NavItem(icon: Icons.home_rounded, label: 'Home'),
            _NavItem(
              icon: Icons.chat_bubble_outline_rounded,
              label: 'Messages',
            ),
            _NavItem(icon: Icons.map_outlined, label: 'Maps'),
            _NavItem(icon: Icons.people_outline_rounded, label: 'Peers'),
          ];

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 8,
            offset: const Offset(0, 1),
            spreadRadius: 1,
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(items.length, (i) {
          final active = _selectedTab == i;
          return GestureDetector(
            onTap: () => setState(() => _selectedTab = i),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  items[i].icon,
                  size: 22,
                  color: active
                      ? const Color(0xFFE73F3F)
                      : const Color(0xFF717173),
                ),
                const SizedBox(height: 2),
                Text(
                  items[i].label,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                    color: active
                        ? const Color(0xFFE73F3F)
                        : const Color(0xFF717173),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildLogo() {
    return Center(
      child: Image.asset(
        'assets/home/shadownetwork_logo.png',
        width: 170,
        fit: BoxFit.contain,
      ),
    );
  }

  Widget _buildSosButton() {
    return Material(
      color: const Color(0xFFE83C3D),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: _openSosComposerModal,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: double.infinity,
          height: 70,
          child: Row(
            children: [
              const SizedBox(width: 16),
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2.5),
                ),
                alignment: Alignment.center,
                child: const Text(
                  'SOS',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1,
                  ),
                ),
              ),
              const SizedBox(width: 18),
              const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SEND SOS MESSAGE',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'Alert your peers in the area',
                    style: TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMapCard(
    AsyncValue<List<messaging.Peer>> peers,
    AsyncValue<List<messaging.SosMessage>> messages,
    AsyncValue<CacheStore> tileCacheStore,
  ) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: 250,
        width: double.infinity,
        child: _buildMapStack(
          peers: peers,
          messages: messages,
          tileCacheStore: tileCacheStore,
          showLegend: false,
          showStatusBadge: true,
          markerSize: 56,
          locationMarkerSize: 40,
        ),
      ),
    );
  }

  Widget _buildMapStack({
    required AsyncValue<List<messaging.Peer>> peers,
    required AsyncValue<List<messaging.SosMessage>> messages,
    required AsyncValue<CacheStore> tileCacheStore,
    required bool showLegend,
    required bool showStatusBadge,
    required double markerSize,
    required double locationMarkerSize,
    Set<messaging.Category>? visibleCategories,
    bool showPeers = true,
    bool showMyLocation = true,
    Widget? bottomOverlay,
  }) {
    final isViewingPanaboArea = _isInsidePanabo(_currentCenter);

    return SizedBox.expand(
      child: Stack(
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth <= 0 || constraints.maxHeight <= 0) {
                  return const SizedBox.shrink();
                }

                final mapSize = Size(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                final mapStyle = _offlineMapStyle;
                final markers = [
                  ..._triageMarkersFromMessages(
                    messages,
                    markerSize: markerSize,
                    visibleCategories: visibleCategories,
                  ),
                  if (showPeers)
                    ..._peerMarkersFromPeers(peers, markerSize: markerSize),
                  if (showMyLocation)
                    _MapOverlayMarker(
                      id: 'my-location',
                      point: _myPosition ?? _currentCenter,
                      width: locationMarkerSize,
                      height: locationMarkerSize,
                      child: Icon(
                        Icons.location_pin,
                        size: locationMarkerSize,
                        color: const Color(0xFFE83C3D),
                      ),
                    ),
                ];
                return Stack(
                  children: [
                    if (mapStyle == null)
                      const Positioned.fill(child: _OfflineMapPreparingView())
                    else
                      Positioned.fill(
                        child: ml.MapLibreMap(
                          key: ValueKey<String>(
                            '${showLegend ? 'maplibre-full' : 'maplibre-card'}:$mapStyle',
                          ),
                          initialCameraPosition: ml.CameraPosition(
                            target: _toMapLibreLatLng(_currentCenter),
                            zoom: _currentZoom,
                            bearing: _currentBearing,
                          ),
                          styleString: mapStyle,
                          minMaxZoomPreference: const ml.MinMaxZoomPreference(
                            _minZoom,
                            _maxZoom,
                          ),
                          logoEnabled: false,
                          compassEnabled: false,
                          foregroundLoadColor: const Color(0xFFEFF2F0),
                          rotateGesturesEnabled: false,
                          tiltGesturesEnabled: false,
                          myLocationEnabled: false,
                          trackCameraPosition: true,
                          attributionButtonPosition:
                              ml.AttributionButtonPosition.bottomLeft,
                          onMapCreated: (controller) {
                            _mapController = controller;
                            if (mounted) {
                              setState(() {});
                            }
                          },
                          onCameraMove: (cameraPosition) {
                            if (!mounted) {
                              return;
                            }
                            setState(() {
                              _currentCenter = LatLng(
                                cameraPosition.target.latitude,
                                cameraPosition.target.longitude,
                              );
                              _currentZoom = cameraPosition.zoom;
                              _currentBearing = cameraPosition.bearing;
                            });
                          },
                        ),
                      ),
                    if (mapStyle != null)
                      ...markers.map(
                        (marker) => _buildProjectedMarker(marker, mapSize),
                      ),
                  ],
                );
              },
            ),
          ),
          if (showLegend)
            Positioned(left: 16, top: 10, child: _buildMapLegend()),
          if (showStatusBadge)
            Positioned(
              left: 10,
              top: 10,
              child: _MapStatusBadge(
                icon: isViewingPanaboArea
                    ? Icons.map_outlined
                    : _tileLoadFailed
                    ? Icons.offline_bolt_outlined
                    : Icons.layers_outlined,
                label: _mapTileStatusLabel(tileCacheStore),
                color: isViewingPanaboArea
                    ? const Color(0xFF2E8B57)
                    : _tileLoadFailed
                    ? const Color(0xFFF39C12)
                    : const Color(0xFF3F66C4),
              ),
            ),
          Positioned(
            right: 10,
            top: 10,
            child: Column(
              children: [
                _MapControlButton(icon: Icons.add, onTap: _zoomIn),
                const SizedBox(height: 8),
                _MapControlButton(icon: Icons.remove, onTap: _zoomOut),
              ],
            ),
          ),
          Positioned(
            right: 10,
            bottom: bottomOverlay == null ? 10 : 92,
            child: _MapControlButton(icon: Icons.explore, onTap: _resetNorth),
          ),
          if (bottomOverlay != null)
            Positioned(left: 8, right: 8, bottom: 10, child: bottomOverlay),
        ],
      ),
    );
  }

  String _mapTileStatusLabel(AsyncValue<CacheStore> tileCacheStore) {
    if (_isInsidePanabo(_currentCenter)) {
      return _offlineMapStyle == null
          ? 'Preparing offline map'
          : 'Panabo offline';
    }

    if (_tileLoadFailed) {
      return 'Offline fallback';
    }

    return tileCacheStore.when(
      data: (_) => 'Cached map',
      loading: () => 'Preparing cache',
      error: (_, _) => 'Live map',
    );
  }

  List<_MapOverlayMarker> _triageMarkersFromMessages(
    AsyncValue<List<messaging.SosMessage>> messages, {
    required double markerSize,
    Set<messaging.Category>? visibleCategories,
  }) {
    final items = messages.valueOrNull ?? const <messaging.SosMessage>[];
    final activeCategories =
        visibleCategories ?? messaging.Category.values.toSet();

    return items
        .where(
          (message) => shouldShowSosMessageOnMap(
            message: message,
            visibleCategories: activeCategories,
          ),
        )
        .map(
          (message) => _MapOverlayMarker(
            id: 'sos-${message.id}',
            point: LatLng(message.latitude!, message.longitude!),
            width: markerSize,
            height: markerSize,
            child: GestureDetector(
              onTap: () =>
                  _openConversation(message.sender, linkedSosMessage: message),
              child: _TriageMarker(
                icon: _iconForCategory(message.category),
                color: _colorForCategory(message.category),
                label: _markerLabelForCategory(message.category),
              ),
            ),
          ),
        )
        .toList(growable: false);
  }

  List<_MapOverlayMarker> _peerMarkersFromPeers(
    AsyncValue<List<messaging.Peer>> peers, {
    required double markerSize,
  }) {
    final items = peers.valueOrNull ?? const <messaging.Peer>[];

    return items
        .where((peer) => peer.latitude != null && peer.longitude != null)
        .map(
          (peer) => _MapOverlayMarker(
            id: 'peer-${peer.id}',
            point: LatLng(peer.latitude!, peer.longitude!),
            width: markerSize,
            height: markerSize,
            child: GestureDetector(
              onTap: () => _openConversation(peer),
              child: _PeerMapMarker(isConnected: peer.isConnected),
            ),
          ),
        )
        .toList(growable: false);
  }

  bool _isInsidePanabo(LatLng point) {
    return point.latitude >= _panaboSouth &&
        point.latitude <= _panaboNorth &&
        point.longitude >= _panaboWest &&
        point.longitude <= _panaboEast;
  }

  ml.LatLng _toMapLibreLatLng(LatLng point) {
    return ml.LatLng(point.latitude, point.longitude);
  }

  Widget _buildProjectedMarker(_MapOverlayMarker marker, Size mapSize) {
    final screenPoint = _projectToScreen(marker.point, mapSize);
    if (screenPoint == null) {
      return const SizedBox.shrink();
    }

    const margin = 96.0;
    if (screenPoint.dx < -margin ||
        screenPoint.dy < -margin ||
        screenPoint.dx > mapSize.width + margin ||
        screenPoint.dy > mapSize.height + margin) {
      return const SizedBox.shrink();
    }

    return Positioned(
      left: screenPoint.dx - marker.width / 2,
      top: screenPoint.dy - marker.height / 2,
      width: marker.width,
      height: marker.height,
      child: marker.child,
    );
  }

  Offset? _projectToScreen(LatLng point, Size mapSize) {
    if (!_isFiniteLatLng(point) || !_isFiniteLatLng(_currentCenter)) {
      return null;
    }

    final markerWorld = _worldPixel(point, _currentZoom);
    final centerWorld = _worldPixel(_currentCenter, _currentZoom);
    final delta = markerWorld - centerWorld;
    return Offset(mapSize.width / 2 + delta.dx, mapSize.height / 2 + delta.dy);
  }

  Offset _worldPixel(LatLng point, double zoom) {
    final scale = 512.0 * math.pow(2.0, zoom);
    final latitude = point.latitude.clamp(-85.05112878, 85.05112878);
    final sinLatitude = math.sin(latitude * math.pi / 180.0);
    final x = (point.longitude + 180.0) / 360.0 * scale;
    final y =
        (0.5 -
            math.log((1 + sinLatitude) / (1 - sinLatitude)) / (4 * math.pi)) *
        scale;
    return Offset(x, y);
  }

  bool _isFiniteLatLng(LatLng point) {
    return point.latitude.isFinite && point.longitude.isFinite;
  }

  Widget _buildMapLegend() {
    return PopupMenuButton<Object>(
      tooltip: 'Filter map markers',
      offset: const Offset(0, 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      onSelected: _handleMapLegendSelection,
      itemBuilder: (context) => [
        PopupMenuItem<Object>(
          value: _mapFilterAllMarkers,
          child: _MapLegendChoice(
            selected: _allMapMarkersSelected,
            marker: const SizedBox(
              width: 34,
              height: 34,
              child: Icon(
                Icons.layers_rounded,
                color: Color(0xFFE83C3D),
                size: 24,
              ),
            ),
            label: 'All markers',
          ),
        ),
        const PopupMenuDivider(height: 8),
        ...messaging.Category.values.map(
          (category) => PopupMenuItem<Object>(
            value: category,
            child: _MapLegendChoice(
              selected: _visibleMapCategories.contains(category),
              marker: SizedBox(
                width: 34,
                height: 34,
                child: _TriageMarker(
                  icon: _iconForCategory(category),
                  color: _colorForCategory(category),
                  label: _markerLabelForCategory(category),
                ),
              ),
              label: _shortLabelForCategory(category),
            ),
          ),
        ),
        const PopupMenuDivider(height: 8),
        PopupMenuItem<Object>(
          value: _mapFilterPeers,
          child: _MapLegendChoice(
            selected: _showMapPeers,
            marker: const SizedBox(
              width: 34,
              height: 34,
              child: _PeerMapMarker(isConnected: true),
            ),
            label: 'Peers',
          ),
        ),
        PopupMenuItem<Object>(
          value: _mapFilterLocation,
          child: _MapLegendChoice(
            selected: _showMapLocation,
            marker: const SizedBox(
              width: 34,
              height: 34,
              child: Icon(
                Icons.location_pin,
                size: 32,
                color: Color(0xFFE83C3D),
              ),
            ),
            label: 'My location',
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _legendPreviewMarker(),
            const SizedBox(width: 8),
            Text(
              _mapLegendSummaryLabel(),
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Color(0xFF1F1F1F),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 20,
              color: Color(0xFF555555),
            ),
          ],
        ),
      ),
    );
  }

  bool get _allMapMarkersSelected {
    return _visibleMapCategories.length == messaging.Category.values.length &&
        _showMapPeers &&
        _showMapLocation;
  }

  int get _selectedMapMarkerCount {
    return _visibleMapCategories.length +
        (_showMapPeers ? 1 : 0) +
        (_showMapLocation ? 1 : 0);
  }

  void _handleMapLegendSelection(Object value) {
    setState(() {
      if (value == _mapFilterAllMarkers) {
        _visibleMapCategories
          ..clear()
          ..addAll(messaging.Category.values);
        _showMapPeers = true;
        _showMapLocation = true;
        return;
      }

      if (value == _mapFilterPeers) {
        if (_allMapMarkersSelected) {
          _visibleMapCategories.clear();
          _showMapPeers = true;
          _showMapLocation = false;
        } else {
          _showMapPeers = !_showMapPeers;
        }
        return;
      }

      if (value == _mapFilterLocation) {
        if (_allMapMarkersSelected) {
          _visibleMapCategories.clear();
          _showMapPeers = false;
          _showMapLocation = true;
        } else {
          _showMapLocation = !_showMapLocation;
        }
        return;
      }

      if (value is messaging.Category) {
        if (_allMapMarkersSelected) {
          _visibleMapCategories
            ..clear()
            ..add(value);
          _showMapPeers = false;
          _showMapLocation = false;
        } else if (_visibleMapCategories.contains(value)) {
          _visibleMapCategories.remove(value);
        } else {
          _visibleMapCategories.add(value);
        }
      }
    });
  }

  Widget _legendPreviewMarker() {
    if (_visibleMapCategories.length == 1 &&
        !_showMapPeers &&
        !_showMapLocation) {
      final category = _visibleMapCategories.first;
      return SizedBox(
        width: 34,
        height: 34,
        child: _TriageMarker(
          icon: _iconForCategory(category),
          color: _colorForCategory(category),
          label: _markerLabelForCategory(category),
        ),
      );
    }

    if (_visibleMapCategories.isEmpty && _showMapPeers && !_showMapLocation) {
      return const SizedBox(
        width: 34,
        height: 34,
        child: _PeerMapMarker(isConnected: true),
      );
    }

    return const SizedBox(
      width: 34,
      height: 34,
      child: Icon(Icons.layers_rounded, color: Color(0xFFE83C3D), size: 24),
    );
  }

  String _mapLegendSummaryLabel() {
    if (_allMapMarkersSelected) {
      return 'All markers';
    }

    if (_visibleMapCategories.length == 1 &&
        !_showMapPeers &&
        !_showMapLocation) {
      return _shortLabelForCategory(_visibleMapCategories.first);
    }

    if (_selectedMapMarkerCount == 0) {
      return 'No markers';
    }

    return '$_selectedMapMarkerCount selected';
  }

  Widget _buildMapTabActionButtons() {
    return Row(
      children: [
        Expanded(
          child: _MapActionButton(
            icon: _isLocating
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: Color(0xFFE83C3D),
                    ),
                  )
                : const Icon(
                    Icons.gps_fixed_rounded,
                    color: Color(0xFFE83C3D),
                    size: 34,
                  ),
            label: 'LOCATE ME',
            subtitle: _isLocating
                ? 'Locating...'
                : (_isFollowing ? 'Show my location' : 'Find my location'),
            backgroundColor: Colors.white,
            foregroundColor: const Color(0xFFE83C3D),
            subtitleColor: const Color(0xFF7D7D7D),
            onTap: () => _startFollowing(),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _MapActionButton(
            icon: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 3),
              ),
              alignment: Alignment.center,
              child: const Text(
                'SOS',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ),
            label: 'SEND SOS',
            subtitle: 'Alert nearby peers',
            backgroundColor: const Color(0xFFE83C3D),
            foregroundColor: Colors.white,
            subtitleColor: Colors.white,
            onTap: _openSosComposerModal,
          ),
        ),
      ],
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _ActionCard(
                icon: _isLocating
                    ? const SizedBox(
                        width: 32,
                        height: 32,
                        child: Padding(
                          padding: EdgeInsets.all(6),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFFE83C3D),
                          ),
                        ),
                      )
                    : const Icon(
                        Icons.gps_fixed_rounded,
                        color: Color(0xFFE83C3D),
                        size: 34,
                      ),
                label: 'LOCATE ME',
                labelColor: const Color(0xFFE83C3D),
                subtitle: _isLocating
                    ? 'Locating...'
                    : (_isFollowing
                          ? 'Showing my location'
                          : 'Show my location'),
                onTap: () => _startFollowing(),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _ActionCard(
                icon: const _MessageIcon(),
                label: 'MESSAGES',
                labelColor: const Color(0xFFE83C3D),
                subtitle: 'View all messages',
                onTap: () => setState(() => _selectedTab = 1),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: _ActionCard(
            icon: const Icon(
              Icons.qr_code_scanner_rounded,
              color: Color(0xFFE83C3D),
              size: 34,
            ),
            label: 'TRUST BUNDLE',
            labelColor: const Color(0xFFE83C3D),
            subtitle: 'Scan admin QR or paste JSON',
            onTap: () => Navigator.of(context).pushNamed('/trust-bundle'),
          ),
        ),
      ],
    );
  }

  Widget _buildResponderActionButtons() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _ActionCard(
                icon: const Icon(
                  Icons.map_rounded,
                  color: Color(0xFFE83C3D),
                  size: 34,
                ),
                label: 'SOS MAP',
                labelColor: const Color(0xFFE83C3D),
                subtitle: 'View verified markers',
                onTap: () => setState(() => _selectedTab = 2),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _ActionCard(
                icon: const _MessageIcon(),
                label: 'CHAT FEED',
                labelColor: const Color(0xFFE83C3D),
                subtitle: 'Coordinate responses',
                onTap: () => setState(() {
                  _selectedMessageFilter = 0;
                  _selectedTab = 1;
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _ActionCard(
                icon: const Icon(
                  Icons.monitor_heart_outlined,
                  color: Color(0xFFE83C3D),
                  size: 34,
                ),
                label: 'DIAGNOSTICS',
                labelColor: const Color(0xFFE83C3D),
                subtitle: 'Peers and relay health',
                onTap: () => setState(() => _selectedTab = 3),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: _ActionCard(
                icon: const Icon(
                  Icons.gps_fixed_rounded,
                  color: Color(0xFFE83C3D),
                  size: 34,
                ),
                label: 'MY LOCATION',
                labelColor: const Color(0xFFE83C3D),
                subtitle: _isLocating ? 'Locating...' : 'Update GPS position',
                onTap: () => _startFollowing(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: _ActionCard(
            icon: const Icon(
              Icons.science_outlined,
              color: Color(0xFFE83C3D),
              size: 34,
            ),
            label: 'VALIDATION TEST',
            labelColor: const Color(0xFFE83C3D),
            subtitle: 'Record real field metrics',
            onTap: () => Navigator.of(context).pushNamed('/validation'),
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: _ActionCard(
            icon: const Icon(
              Icons.admin_panel_settings_outlined,
              color: Color(0xFFE83C3D),
              size: 34,
            ),
            label: 'DEVICE TRUST',
            labelColor: const Color(0xFFE83C3D),
            subtitle: 'View responder approval and device ID',
            onTap: () => Navigator.of(context).pushNamed('/trust-bundle'),
          ),
        ),
      ],
    );
  }

  Widget _buildPeersSection(AsyncValue<List<messaging.Peer>> peers) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'NEARBY PEERS',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF5C5C5C),
                letterSpacing: 0.5,
              ),
            ),
            const _ScanningBadge(),
          ],
        ),
        const SizedBox(height: 12),
        peers.when(
          data: (items) {
            if (items.isEmpty) {
              return _buildEmptyState(
                icon: Icons.people_outline_rounded,
                message: 'No nearby peers stored yet.',
              );
            }

            return Column(
              children: items
                  .map(
                    (peer) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _PeerCard(
                        peer: peer,
                        onConnect: () => _connectToPeer(peer),
                      ),
                    ),
                  )
                  .toList(growable: false),
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, _) => _buildEmptyState(
            icon: Icons.error_outline_rounded,
            message: 'Unable to load local peers.',
          ),
        ),
      ],
    );
  }
}

class _MapOverlayMarker {
  const _MapOverlayMarker({
    required this.id,
    required this.point,
    required this.width,
    required this.height,
    required this.child,
  });

  final String id;
  final LatLng point;
  final double width;
  final double height;
  final Widget child;
}

class _OfflineMapPreparingView extends StatelessWidget {
  const _OfflineMapPreparingView();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xFFEFF2F0)),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Color(0xFF2E8B57),
                ),
              ),
              SizedBox(width: 10),
              Text(
                'Preparing offline map',
                style: TextStyle(
                  color: Color(0xFF2E8B57),
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MessageFeedItem {
  final messaging.SosMessage message;
  final String title;
  final String description;
  final String distance;
  final String time;
  final String badge;
  final String type;
  final IconData icon;
  final Color iconColor;
  final Color badgeColor;
  final bool isSpam;
  final DeviceTrustStatus trustStatus;

  const _MessageFeedItem({
    required this.message,
    required this.title,
    required this.description,
    required this.distance,
    required this.time,
    required this.badge,
    required this.type,
    required this.icon,
    required this.iconColor,
    required this.badgeColor,
    this.isSpam = false,
    required this.trustStatus,
  });
}

class _TrustStatusBadge extends StatelessWidget {
  const _TrustStatusBadge({required this.status});

  final DeviceTrustStatus status;

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = switch (status) {
      DeviceTrustStatus.approved => (
        const Color(0xFFE4F4EA),
        const Color(0xFF1E6B3B),
      ),
      DeviceTrustStatus.unknown => (
        const Color(0xFFFFEBC2),
        const Color(0xFF765000),
      ),
      DeviceTrustStatus.revoked => (
        const Color(0xFFE5D6D6),
        const Color(0xFF7D1A1A),
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        status.displayLabel.toUpperCase(),
        style: TextStyle(
          color: foreground,
          fontSize: 9,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.25,
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;

  const _NavItem({required this.icon, required this.label});
}

enum _PeerActionStyle { filledRed, outlineRed, outlineOrange }

class _PeerUpdateButton extends StatelessWidget {
  const _PeerUpdateButton({required this.isLoading, required this.onTap});

  final bool isLoading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 46,
          height: 46,
          child: isLoading
              ? const Padding(
                  padding: EdgeInsets.all(13),
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Color(0xFFE83C3D),
                  ),
                )
              : const Icon(
                  Icons.system_update_alt_rounded,
                  size: 27,
                  color: Color(0xFFE83C3D),
                ),
        ),
      ),
    );
  }
}

class _PeerStatsPanel extends StatelessWidget {
  const _PeerStatsPanel({
    required this.connectedCount,
    required this.nearbyCount,
    required this.rescuerCount,
  });

  final int connectedCount;
  final int nearbyCount;
  final int rescuerCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: _PeerMetric(
              icon: Icons.groups_rounded,
              count: connectedCount,
              label: 'Connected',
              subtitle: 'Active peers',
              color: const Color(0xFFE83C3D),
            ),
          ),
          const _VerticalDividerLine(),
          Expanded(
            child: _PeerMetric(
              icon: Icons.wifi_rounded,
              count: nearbyCount,
              label: 'Nearby',
              subtitle: 'In range',
              color: Color(0xFF3478F6),
            ),
          ),
          const _VerticalDividerLine(),
          Expanded(
            child: _PeerMetric(
              icon: Icons.health_and_safety_rounded,
              count: rescuerCount,
              label: 'Rescuers',
              subtitle: 'Available',
              color: Color(0xFF15A832),
            ),
          ),
        ],
      ),
    );
  }
}

class _PeerMetric extends StatelessWidget {
  const _PeerMetric({
    required this.icon,
    required this.count,
    required this.label,
    required this.subtitle,
    required this.color,
  });

  final IconData icon;
  final int count;
  final String label;
  final String subtitle;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(icon, color: Colors.white, size: 28),
        ),
        const SizedBox(height: 8),
        Text(
          '$count',
          style: TextStyle(
            fontSize: 25,
            fontWeight: FontWeight.w900,
            color: color,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: Colors.black,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: Color(0xFF696969),
          ),
        ),
      ],
    );
  }
}

class _VerticalDividerLine extends StatelessWidget {
  const _VerticalDividerLine();

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, height: 88, color: const Color(0xFFE4E4E4));
  }
}

class _PeerFilterBar extends StatelessWidget {
  const _PeerFilterBar({
    required this.filters,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<({String label, IconData icon})> filters;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE8E8E8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: List.generate(filters.length, (index) {
          final filter = filters[index];
          final selected = selectedIndex == index;
          return Expanded(
            child: Material(
              color: selected ? const Color(0xFFE83C3D) : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                onTap: () => onSelected(index),
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        filter.icon,
                        size: 18,
                        color: selected
                            ? Colors.white
                            : const Color(0xFF4A4A4A),
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            filter.label,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: selected
                                  ? Colors.white
                                  : const Color(0xFF404040),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _PeerScanningRow extends StatelessWidget {
  const _PeerScanningRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: const [
          Icon(Icons.radar_rounded, color: Color(0xFF555555), size: 22),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Scanning nearby peers...',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF6B6B6B),
              ),
            ),
          ),
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              color: Color(0xFFE83C3D),
            ),
          ),
        ],
      ),
    );
  }
}

class _MapControlButton extends StatelessWidget {
  const _MapControlButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: 30,
          height: 30,
          child: Icon(icon, size: 18, color: const Color(0xFF4B4B4B)),
        ),
      ),
    );
  }
}

class _MapStatusBadge extends StatelessWidget {
  const _MapStatusBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 8,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _MapLegendChoice extends StatelessWidget {
  const _MapLegendChoice({
    required this.selected,
    required this.marker,
    required this.label,
  });

  final bool selected;
  final Widget marker;
  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 210,
      child: Row(
        children: [
          marker,
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Color(0xFF1F1F1F),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            selected
                ? Icons.check_box_rounded
                : Icons.check_box_outline_blank_rounded,
            size: 20,
            color: selected ? const Color(0xFFE83C3D) : const Color(0xFF9A9A9A),
          ),
        ],
      ),
    );
  }
}

class _MapActionButton extends StatelessWidget {
  const _MapActionButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.subtitleColor,
    required this.onTap,
  });

  final Widget icon;
  final String label;
  final String subtitle;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color subtitleColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(17),
      elevation: 5,
      shadowColor: Colors.black.withValues(alpha: 0.22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              icon,
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        label,
                        maxLines: 1,
                        style: TextStyle(
                          color: foregroundColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: subtitleColor,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TriageMarker extends StatelessWidget {
  const _TriageMarker({
    required this.icon,
    required this.color,
    required this.label,
  });

  final IconData icon;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.topCenter,
      children: [
        Container(
          width: 38,
          height: 38,
          margin: const EdgeInsets.only(top: 3),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
        Positioned(
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: color.withValues(alpha: 0.32)),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 8,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PeerMapMarker extends StatelessWidget {
  const _PeerMapMarker({required this.isConnected});

  final bool isConnected;

  @override
  Widget build(BuildContext context) {
    final color = isConnected
        ? const Color(0xFF24A646)
        : const Color(0xFF969696);

    return Stack(
      alignment: Alignment.topCenter,
      children: [
        Container(
          width: 36,
          height: 36,
          margin: const EdgeInsets.only(top: 4),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.16),
                blurRadius: 9,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: const Icon(
            Icons.person_rounded,
            color: Colors.white,
            size: 20,
          ),
        ),
        Positioned(
          bottom: 1,
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: isConnected
                  ? const Color(0xFF06820E)
                  : const Color(0xFFF0881E),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _SosComposerSheet extends StatefulWidget {
  const _SosComposerSheet({
    required this.locationText,
    required this.trustedRecipients,
    required this.onUpdateLocation,
    required this.onSend,
  });

  final String locationText;
  final List<TrustedDevice> trustedRecipients;
  final Future<void> Function() onUpdateLocation;
  final Future<void> Function(
    String body,
    messaging.Category category,
    TrustedDevice? recipient,
  )
  onSend;

  @override
  State<_SosComposerSheet> createState() => _SosComposerSheetState();
}

class _SosComposerSheetState extends State<_SosComposerSheet> {
  static const _categories = [
    (
      icon: Icons.accessibility_new,
      label: 'Rescue',
      category: messaging.Category.rescue,
    ),
    (icon: Icons.restaurant, label: 'Food', category: messaging.Category.food),
    (icon: Icons.opacity, label: 'Water', category: messaging.Category.water),
    (
      icon: Icons.local_hospital,
      label: 'Medical',
      category: messaging.Category.medical,
    ),
    (icon: Icons.home, label: 'Shelter', category: messaging.Category.shelter),
    (
      icon: Icons.directions_bus,
      label: 'Transport',
      category: messaging.Category.transport,
    ),
    (
      icon: Icons.info,
      label: 'Information',
      category: messaging.Category.information,
    ),
    (
      icon: Icons.more_horiz,
      label: 'Other',
      category: messaging.Category.other,
    ),
  ];

  late final TextEditingController _messageController;
  int _selectedCategory = 0;
  TrustedDevice? _selectedRecipient;
  bool _updatingLocation = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _messageController = TextEditingController();
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
        decoration: BoxDecoration(
          color: const Color(0xFFF6F6F7),
          borderRadius: BorderRadius.circular(22),
        ),
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 42,
                  height: 5,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD8D8D8),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: const BoxDecoration(
                      color: Color(0xFFE83C3D),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      'SOS',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Send SOS Message',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF1F1F1F),
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Alert nearby peers about your situation',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xFF737373),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text(
                'Message',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF222222),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _messageController,
                maxLength: 250,
                minLines: 3,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: 'Describe your situation...',
                  counterText: '',
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFFF2A4A5)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFFF2A4A5)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFFE83C3D)),
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '${_messageController.text.length}/250',
                  style: const TextStyle(
                    color: Color(0xFF8A8A8A),
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Category',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF222222),
                ),
              ),
              const SizedBox(height: 8),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _categories.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 1.35,
                ),
                itemBuilder: (context, index) {
                  final isSelected = _selectedCategory == index;
                  final item = _categories[index];
                  return InkWell(
                    onTap: () => setState(() => _selectedCategory = index),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFFFFF5F5)
                            : const Color(0xFFF0EEEF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFFE83C3D)
                              : Colors.transparent,
                          width: 1.2,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            item.icon,
                            color: const Color(0xFFE83C3D),
                            size: 20,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item.label,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFDD3D3D),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 10),
              const Text(
                'Receiver',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF222222),
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _selectedRecipient?.deviceId ?? 'broadcast',
                isExpanded: true,
                iconEnabledColor: const Color(0xFFE83C3D),
                dropdownColor: Colors.white,
                style: const TextStyle(
                  color: Color(0xFF222222),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFFFFF8F8),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFFF2A4A5)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFFF2A4A5)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: const BorderSide(color: Color(0xFFE83C3D)),
                  ),
                  prefixIcon: const Icon(
                    Icons.verified_user_rounded,
                    color: Color(0xFFE83C3D),
                  ),
                ),
                items: [
                  DropdownMenuItem(
                    value: 'broadcast',
                    child: _ReceiverDropdownOption(
                      title: 'Broadcast to all nearby peers',
                      subtitle: 'Visible to every receiving phone',
                      roleLabel: 'All',
                      icon: Icons.campaign_rounded,
                    ),
                  ),
                  ...widget.trustedRecipients.map(
                    (device) => DropdownMenuItem(
                      value: device.deviceId,
                      child: _ReceiverDropdownOption(
                        title: device.ownerName,
                        subtitle:
                            '${_roleLabelForTrustedDevice(device)} - ${_shortDeviceId(device.deviceId)}',
                        roleLabel:
                            '${_roleLabelForTrustedDevice(device)} - Verified',
                        icon: _iconForTrustedDevice(device),
                      ),
                    ),
                  ),
                ],
                selectedItemBuilder: (context) {
                  return [
                    const _ReceiverDropdownOption(
                      title: 'Broadcast',
                      subtitle: 'All nearby peers',
                      roleLabel: 'All',
                      icon: Icons.campaign_rounded,
                      compact: true,
                    ),
                    ...widget.trustedRecipients.map(
                      (device) => _ReceiverDropdownOption(
                        title: device.ownerName,
                        subtitle:
                            '${_roleLabelForTrustedDevice(device)} - ${_shortDeviceId(device.deviceId)}',
                        roleLabel:
                            '${_roleLabelForTrustedDevice(device)} - Verified',
                        icon: _iconForTrustedDevice(device),
                        compact: true,
                      ),
                    ),
                  ];
                },
                onChanged: (value) {
                  setState(() {
                    _selectedRecipient = value == null || value == 'broadcast'
                        ? null
                        : widget.trustedRecipients.firstWhere(
                            (device) => device.deviceId == value,
                          );
                  });
                },
              ),
              const SizedBox(height: 6),
              Text(
                _selectedRecipient == null
                    ? 'Broadcast SOS is visible to every phone that receives it.'
                    : 'Targeted SOS is encrypted. Other phones can relay it, but only ${_selectedRecipient!.ownerName} can view it.',
                style: const TextStyle(color: Color(0xFF777777), fontSize: 12),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFEFF0),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.location_on,
                      color: Color(0xFF8B1618),
                      size: 23,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Your Location',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF2C2C2C),
                              fontSize: 16,
                            ),
                          ),
                          Text(
                            widget.locationText,
                            style: const TextStyle(
                              color: Color(0xFF777777),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _updatingLocation
                          ? null
                          : () async {
                              setState(() => _updatingLocation = true);
                              await widget.onUpdateLocation();
                              if (mounted) {
                                setState(() => _updatingLocation = false);
                              }
                            },
                      icon: _updatingLocation
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.gps_fixed),
                      label: const Text('Update'),
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFFE83C3D),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _sending
                          ? null
                          : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        side: const BorderSide(color: Color(0xFFE83C3D)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      child: const Text(
                        'CANCEL',
                        style: TextStyle(
                          color: Color(0xFFD23434),
                          fontWeight: FontWeight.w800,
                          fontSize: 20,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _sending
                          ? null
                          : () async {
                              final messenger = ScaffoldMessenger.of(context);
                              final navigator = Navigator.of(context);
                              final body = _messageController.text.trim();
                              if (body.isEmpty) {
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text('Message cannot be empty.'),
                                  ),
                                );
                                return;
                              }

                              setState(() => _sending = true);
                              try {
                                await widget.onSend(
                                  body,
                                  _categories[_selectedCategory].category,
                                  _selectedRecipient,
                                );
                                if (mounted) {
                                  navigator.pop(true);
                                }
                              } catch (error) {
                                if (mounted) {
                                  setState(() => _sending = false);
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        error is MessageEncryptionException
                                            ? error.message
                                            : 'Unable to queue SOS.',
                                      ),
                                    ),
                                  );
                                }
                              }
                            },
                      icon: const Icon(Icons.near_me, color: Colors.white),
                      label: const Text(
                        'SEND SOS',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 20,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        backgroundColor: const Color(0xFFE83C3D),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReceiverDropdownOption extends StatelessWidget {
  const _ReceiverDropdownOption({
    required this.title,
    required this.subtitle,
    required this.roleLabel,
    required this.icon,
    this.compact = false,
  });

  final String title;
  final String subtitle;
  final String roleLabel;
  final IconData icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: const Color(0xFFE83C3D).withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: const Color(0xFFE83C3D), size: 15),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF222222),
                fontSize: 13,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFFE83C3D).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              roleLabel.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF8B1618),
                fontSize: 9,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ],
      );
    }

    return Row(
      children: [
        Container(
          width: compact ? 30 : 34,
          height: compact ? 30 : 34,
          decoration: BoxDecoration(
            color: const Color(0xFFE83C3D).withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: const Color(0xFFE83C3D), size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: const Color(0xFF222222),
                        fontSize: compact ? 13 : 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE83C3D).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      roleLabel.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF8B1618),
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 1),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF777777),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _roleLabelForTrustedDevice(TrustedDevice device) {
  return switch (device.role.toLowerCase()) {
    'responder' => 'Rescuer',
    'civilian' => 'Civilian',
    'relay' => 'Relay',
    'admin' => 'Admin',
    _ => device.role.isEmpty ? 'Unknown' : device.role,
  };
}

IconData _iconForTrustedDevice(TrustedDevice device) {
  return switch (device.role.toLowerCase()) {
    'responder' => Icons.health_and_safety_rounded,
    'civilian' => Icons.person_rounded,
    'relay' => Icons.hub_rounded,
    'admin' => Icons.admin_panel_settings_rounded,
    _ => Icons.devices_other_rounded,
  };
}

String _shortDeviceId(String deviceId) {
  if (deviceId.length <= 14) {
    return deviceId;
  }
  return '${deviceId.substring(0, 6)}...${deviceId.substring(deviceId.length - 5)}';
}

class _TaskCompletionPopup extends StatelessWidget {
  const _TaskCompletionPopup({
    required this.title,
    required this.message,
    required this.icon,
  });

  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 34),
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(22),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.16),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: const BoxDecoration(
                color: Color(0xFFE83C3D),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: Colors.white, size: 34),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: Color(0xFF1F1F1F),
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Color(0xFF717173),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  backgroundColor: const Color(0xFFE83C3D),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  'DONE',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  const _ActionCard({
    required this.icon,
    required this.label,
    required this.labelColor,
    required this.subtitle,
    required this.onTap,
  });

  final Widget icon;
  final String label;
  final Color labelColor;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 8,
              offset: const Offset(0, 1),
              spreadRadius: 1,
            ),
          ],
        ),
        child: Row(
          children: [
            icon,
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: labelColor,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 9, color: Color(0x80000000)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PeerDirectoryCard extends StatelessWidget {
  const _PeerDirectoryCard({
    required this.peer,
    required this.distanceText,
    required this.signalLabel,
    required this.signalColor,
    required this.avatarColor,
    required this.typeLabel,
    required this.actionLabel,
    required this.actionStyle,
    required this.onActionTap,
  });

  final messaging.Peer peer;
  final String distanceText;
  final String signalLabel;
  final Color signalColor;
  final Color avatarColor;
  final String typeLabel;
  final String actionLabel;
  final _PeerActionStyle actionStyle;
  final VoidCallback onActionTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.09),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: avatarColor.withValues(alpha: 0.24),
              shape: BoxShape.circle,
            ),
            child: Icon(
              peer.type == messaging.PeerType.relay
                  ? Icons.router_rounded
                  : Icons.phone_android_rounded,
              color: avatarColor,
              size: 30,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  peer.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF171717),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'ID: ${peer.id}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF6D6D6D),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 9,
                  runSpacing: 5,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SignalBars(
                          strength: peer.signalStrength,
                          color: signalColor,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          signalLabel,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF676767),
                          ),
                        ),
                      ],
                    ),
                    Container(
                      width: 1,
                      height: 14,
                      color: const Color(0xFFD2D2D2),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          typeLabel == 'Rescuer'
                              ? Icons.health_and_safety_outlined
                              : Icons.person_outline_rounded,
                          color: typeLabel == 'Rescuer'
                              ? const Color(0xFFE83C3D)
                              : const Color(0xFF5F5F5F),
                          size: 16,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          typeLabel,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF676767),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _PeerActionPill(
                label: actionLabel,
                style: actionStyle,
                onTap: onActionTap,
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.location_on,
                    color: Color(0xFFE83C3D),
                    size: 17,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    distanceText,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF626262),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PeerActionPill extends StatelessWidget {
  const _PeerActionPill({
    required this.label,
    required this.style,
    required this.onTap,
  });

  final String label;
  final _PeerActionStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final backgroundColor = switch (style) {
      _PeerActionStyle.filledRed => const Color(0xFFE83C3D),
      _PeerActionStyle.outlineRed => Colors.white,
      _PeerActionStyle.outlineOrange => Colors.white,
    };
    final foregroundColor = switch (style) {
      _PeerActionStyle.filledRed => Colors.white,
      _PeerActionStyle.outlineRed => const Color(0xFFE83C3D),
      _PeerActionStyle.outlineOrange => const Color(0xFFF07808),
    };
    final borderColor = switch (style) {
      _PeerActionStyle.filledRed => Colors.transparent,
      _PeerActionStyle.outlineRed => const Color(0xFFE83C3D),
      _PeerActionStyle.outlineOrange => const Color(0xFFF07808),
    };

    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          constraints: const BoxConstraints(minWidth: 100),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: borderColor, width: 1.4),
          ),
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              label,
              maxLines: 1,
              style: TextStyle(
                color: foregroundColor,
                fontSize: 12,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SignalBars extends StatelessWidget {
  const _SignalBars({required this.strength, required this.color});

  final int? strength;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final activeBars = strength == null
        ? 4
        : ((strength! / 25).ceil()).clamp(1, 4);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (index) {
        final active = index < activeBars;
        return Container(
          width: 3,
          height: 5 + (index * 3),
          margin: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
            color: active ? color : const Color(0xFFD0D0D0),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    );
  }
}

class _PeerScanButton extends StatelessWidget {
  const _PeerScanButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFE83C3D),
      shape: const CircleBorder(),
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.28),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
          ),
          child: const Icon(Icons.radar_rounded, color: Colors.white, size: 34),
        ),
      ),
    );
  }
}

class _PeerCard extends StatelessWidget {
  const _PeerCard({required this.peer, required this.onConnect});

  final messaging.Peer peer;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final isConnected = peer.isConnected;
    final signalStrength = peer.signalStrength;
    final isStrong = signalStrength == null || signalStrength >= 60;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 8,
            offset: const Offset(0, 1),
            spreadRadius: 1,
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              color: Color(0xFFFBE7E6),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: const Icon(
              Icons.phone_android_rounded,
              color: Color(0xFFB72C2B),
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  peer.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'ID: ${peer.id}',
                  style: const TextStyle(fontSize: 9, color: Color(0x80000000)),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: isStrong
                            ? const Color(0xFF06820E)
                            : const Color(0xFFF0881E),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      isStrong ? 'Strong signal' : 'Weak signal',
                      style: const TextStyle(
                        fontSize: 9,
                        color: Color(0x80000000),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          isConnected
              ? const _ConnectedBadge()
              : _ConnectButton(onPressed: onConnect),
        ],
      ),
    );
  }
}

class _ConnectedBadge extends StatelessWidget {
  const _ConnectedBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFFBE7E6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        'CONNECTED',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Color(0xFFA7191B),
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _ConnectButton extends StatelessWidget {
  const _ConnectButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF8A1D1C),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Text(
          'CONNECT',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

class _ScanningBadge extends StatefulWidget {
  const _ScanningBadge();

  @override
  State<_ScanningBadge> createState() => _ScanningBadgeState();
}

class _ScanningBadgeState extends State<_ScanningBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 1, end: 0.2).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: const Text(
        'SCANNING...',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Color(0xFFE83C3D),
          fontFamily: 'monospace',
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _MessageIcon extends StatelessWidget {
  const _MessageIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: CustomPaint(painter: _MessageIconPainter()),
    );
  }
}

class _MessageIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFE83C3D)
      ..style = PaintingStyle.fill;

    final w = size.width;
    final h = size.height;

    final bubblePath = ui.Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, w * 0.90, h * 0.75),
          const Radius.circular(8),
        ),
      )
      ..moveTo(w * 0.18, h * 0.75)
      ..lineTo(w * 0.08, h)
      ..lineTo(w * 0.38, h * 0.75)
      ..close();
    canvas.drawPath(bubblePath, paint);

    final dotPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(w * 0.25, h * 0.375), 2.5, dotPaint);
    canvas.drawCircle(Offset(w * 0.45, h * 0.375), 2.5, dotPaint);
    canvas.drawCircle(Offset(w * 0.65, h * 0.375), 2.5, dotPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
