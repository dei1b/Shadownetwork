import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio_cache_interceptor/dio_cache_interceptor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cache/flutter_map_cache.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../domain/entities/category.dart' as messaging;
import '../../domain/entities/message_status.dart' as messaging;
import '../../domain/entities/peer.dart' as messaging;
import '../../domain/entities/peer_type.dart' as messaging;
import '../../domain/entities/sos_message.dart' as messaging;
import '../providers/local_messaging_providers.dart';
import '../../../auth/presentation/widgets/auth_background.dart';

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  int _selectedTab = 0;
  int _selectedMessageFilter = 0;
  final Set<messaging.Category> _visibleMapCategories = {
    ...messaging.Category.values,
  };
  bool _showMapPeers = true;
  bool _showMapLocation = true;

  static const String _mapFilterAllMarkers = 'all-markers';
  static const String _mapFilterPeers = 'peers';
  static const String _mapFilterLocation = 'location';

  static const LatLng _mapCenter = LatLng(7.3026, 125.6888);
  static const double _minZoom = 4;
  static const double _maxZoom = 19;
  static const double _defaultZoom = 16.1;

  final MapController _mapController = MapController();
  LatLng _currentCenter = _mapCenter;
  double _currentZoom = _defaultZoom;
  LatLng? _myPosition;
  bool _isLocating = false;
  bool _isFollowing = false;
  bool _tileLoadFailed = false;
  StreamSubscription<Position>? _positionSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startFollowing(showError: false);
    });
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
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
            _mapController.move(myPoint, _currentZoom);
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

      _mapController.move(myPoint, targetZoom);
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
    _mapController.move(_currentCenter, targetZoom);
    setState(() => _currentZoom = targetZoom);
  }

  void _zoomOut() {
    final targetZoom = (_currentZoom - 1).clamp(_minZoom, _maxZoom).toDouble();
    _mapController.move(_currentCenter, targetZoom);
    setState(() => _currentZoom = targetZoom);
  }

  void _resetNorth() {
    _mapController.rotate(0);
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      enableDrag: true,
      isDismissible: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _SosComposerSheet(
          locationText: _formatLocationText(),
          onUpdateLocation: _locateMe,
          onSend: _saveSosMessage,
        );
      },
    );
  }

  Future<void> _saveSosMessage(String body, messaging.Category category) async {
    final now = DateTime.now();
    final position = _myPosition;
    final message = messaging.SosMessage(
      id: 'sos-${now.microsecondsSinceEpoch}',
      sender: messaging.Peer(
        id: 'local-device',
        name: 'This Device',
        type: messaging.PeerType.civilian,
        isConnected: true,
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
    );

    await ref.read(saveSosMessageProvider)(message);
  }

  @override
  Widget build(BuildContext context) {
    final peers = ref.watch(nearbyPeersProvider);
    final messages = ref.watch(sosMessagesProvider);
    final tileCacheStore = ref.watch(mapTileCacheStoreProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      body: AuthBackground(
        child: Stack(
          children: [
            SafeArea(
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
                                      ? _buildMessagesTabContent(messages)
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
          ],
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
        _buildSosButton(),
        const SizedBox(height: 14),
        _buildMapCard(peers, messages, tileCacheStore),
        const SizedBox(height: 14),
        _buildActionButtons(),
        const SizedBox(height: 20),
        _buildPeersSection(peers),
        const SizedBox(height: 16),
      ],
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
                  const Text(
                    'MAP',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1F1F1F),
                      letterSpacing: 0.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  const Text(
                    'View SOS alerts and peers',
                    style: TextStyle(
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
  ) {
    final List<(String, IconData, String)> filters = [
      ('All Messages', Icons.chat_bubble_outline_rounded, 'ALL'),
      ('SOS Alerts', Icons.sos_rounded, 'SOS'),
      ('Requests', Icons.pan_tool_outlined, 'REQUEST'),
      ('Updates', Icons.campaign_outlined, 'UPDATE'),
    ];

    final String activeType = filters[_selectedMessageFilter].$3;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'MESSAGES',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                      color: Color(0xFF181818),
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'All messages from your peers',
                    style: TextStyle(
                      fontSize: 12,
                      color: Color(0xFF696969),
                      fontWeight: FontWeight.w500,
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
        messages.when(
          data: (items) {
            final feedItems = items
                .map(_messageFeedItemFromSosMessage)
                .toList();
            final filteredMessages = activeType == 'ALL'
                ? feedItems
                : feedItems.where((item) => item.type == activeType).toList();

            if (filteredMessages.isEmpty) {
              return _buildEmptyState(
                icon: Icons.chat_bubble_outline_rounded,
                message: 'No local messages yet.',
              );
            }

            return Column(
              children: filteredMessages
                  .map(_buildMessageFeedCard)
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

  Widget _buildMessageFeedCard(_MessageFeedItem item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
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
                          color: item.type == 'SOS'
                              ? const Color(0xFFE83C3D)
                              : const Color(0xFF1F1F1F),
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
                    const Icon(
                      Icons.location_on,
                      size: 16,
                      color: Color(0xFFE83C3D),
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
    );
  }

  _MessageFeedItem _messageFeedItemFromSosMessage(
    messaging.SosMessage message,
  ) {
    final type = _messageTypeForCategory(message.category);
    final accentColor = _colorForCategory(message.category);

    return _MessageFeedItem(
      title:
          '${_labelForCategory(message.category)} from ${message.sender.name}',
      description: message.body,
      distance: _distanceTextForMessage(message),
      time: _relativeTime(message.createdAt),
      badge: type,
      type: type,
      icon: _iconForCategory(message.category),
      iconColor: accentColor,
      badgeColor: accentColor,
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
    const items = [
      _NavItem(icon: Icons.home_rounded, label: 'Home'),
      _NavItem(icon: Icons.chat_bubble_outline_rounded, label: 'Messages'),
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
    final cachedTileProvider = tileCacheStore.valueOrNull == null
        ? null
        : CachedTileProvider(
            store: tileCacheStore.valueOrNull!,
            cachePolicy: CachePolicy.forceCache,
            maxStale: const Duration(days: 30),
            hitCacheOnErrorCodes: const [
              400,
              401,
              403,
              404,
              408,
              429,
              500,
              502,
              503,
              504,
            ],
            hitCacheOnNetworkFailure: true,
          );

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: _currentCenter,
            initialZoom: _currentZoom,
            minZoom: _minZoom,
            maxZoom: _maxZoom,
            onPositionChanged: (camera, hasGesture) {
              _currentCenter = camera.center;
              _currentZoom = camera.zoom;
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.shadownetwork',
              tileProvider: cachedTileProvider,
              maxNativeZoom: 19,
              panBuffer: 1,
              errorTileCallback: (_, _, _) {
                if (mounted && !_tileLoadFailed) {
                  setState(() => _tileLoadFailed = true);
                }
              },
            ),
            MarkerLayer(
              markers: [
                ..._triageMarkersFromMessages(
                  messages,
                  markerSize: markerSize,
                  visibleCategories: visibleCategories,
                ),
                if (showPeers)
                  ..._peerMarkersFromPeers(peers, markerSize: markerSize),
                if (showMyLocation)
                  Marker(
                    point: _myPosition ?? _currentCenter,
                    width: locationMarkerSize,
                    height: locationMarkerSize,
                    child: Icon(
                      Icons.location_pin,
                      size: locationMarkerSize,
                      color: const Color(0xFFE83C3D),
                    ),
                  ),
              ],
            ),
          ],
        ),
        if (showLegend) Positioned(left: 16, top: 10, child: _buildMapLegend()),
        if (showStatusBadge)
          Positioned(
            left: 10,
            top: 10,
            child: _MapStatusBadge(
              icon: _tileLoadFailed
                  ? Icons.offline_bolt_outlined
                  : Icons.layers_outlined,
              label: _mapTileStatusLabel(tileCacheStore),
              color: _tileLoadFailed
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
    );
  }

  String _mapTileStatusLabel(AsyncValue<CacheStore> tileCacheStore) {
    if (_tileLoadFailed) {
      return 'Offline fallback';
    }

    return tileCacheStore.when(
      data: (_) => 'Cached map',
      loading: () => 'Preparing cache',
      error: (_, _) => 'Live map',
    );
  }

  List<Marker> _triageMarkersFromMessages(
    AsyncValue<List<messaging.SosMessage>> messages, {
    required double markerSize,
    Set<messaging.Category>? visibleCategories,
  }) {
    final items = messages.valueOrNull ?? const <messaging.SosMessage>[];
    final activeCategories =
        visibleCategories ?? messaging.Category.values.toSet();

    return items
        .where(
          (message) =>
              activeCategories.contains(message.category) &&
              message.latitude != null &&
              message.longitude != null,
        )
        .map(
          (message) => Marker(
            point: LatLng(message.latitude!, message.longitude!),
            width: markerSize,
            height: markerSize,
            child: GestureDetector(
              onTap: () => _showMessage(
                '${_labelForCategory(message.category)}: ${message.body}',
              ),
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

  List<Marker> _peerMarkersFromPeers(
    AsyncValue<List<messaging.Peer>> peers, {
    required double markerSize,
  }) {
    final items = peers.valueOrNull ?? const <messaging.Peer>[];

    return items
        .where((peer) => peer.latitude != null && peer.longitude != null)
        .map(
          (peer) => Marker(
            point: LatLng(peer.latitude!, peer.longitude!),
            width: markerSize,
            height: markerSize,
            child: GestureDetector(
              onTap: () => _showMessage('${peer.name} nearby'),
              child: _PeerMapMarker(isConnected: peer.isConnected),
            ),
          ),
        )
        .toList(growable: false);
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
    return Row(
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
                : (_isFollowing ? 'Showing my location' : 'Show my location'),
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
                      child: _PeerCard(peer: peer),
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

class _MessageFeedItem {
  final String title;
  final String description;
  final String distance;
  final String time;
  final String badge;
  final String type;
  final IconData icon;
  final Color iconColor;
  final Color badgeColor;

  const _MessageFeedItem({
    required this.title,
    required this.description,
    required this.distance,
    required this.time,
    required this.badge,
    required this.type,
    required this.icon,
    required this.iconColor,
    required this.badgeColor,
  });
}

class _NavItem {
  final IconData icon;
  final String label;

  const _NavItem({required this.icon, required this.label});
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
    required this.onUpdateLocation,
    required this.onSend,
  });

  final String locationText;
  final Future<void> Function() onUpdateLocation;
  final Future<void> Function(String body, messaging.Category category) onSend;

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
                style: const TextStyle(color: Color(0xFF8A8A8A), fontSize: 12),
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
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
                              );
                              if (mounted) {
                                navigator.pop();
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      'SOS queued for local delivery.',
                                    ),
                                  ),
                                );
                              }
                            } catch (_) {
                              if (mounted) {
                                setState(() => _sending = false);
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text('Unable to queue SOS.'),
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

class _PeerCard extends StatelessWidget {
  const _PeerCard({required this.peer});

  final messaging.Peer peer;

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
              : _ConnectButton(onPressed: () {}),
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

class _LocationIconPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final paint = Paint()
      ..color = const Color(0xFFE83C3D)
      ..strokeWidth = 2.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(Offset(cx, cy), size.width * 0.35, paint);
    canvas.drawCircle(Offset(cx, cy), size.width * 0.12, paint);
    canvas.drawLine(Offset(cx, 0), Offset(cx, cy - size.width * 0.38), paint);
    canvas.drawLine(
      Offset(cx, cy + size.width * 0.38),
      Offset(cx, size.height),
      paint,
    );
    canvas.drawLine(Offset(0, cy), Offset(cx - size.width * 0.38, cy), paint);
    canvas.drawLine(
      Offset(cx + size.width * 0.38, cy),
      Offset(size.width, cy),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
