import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../../auth/presentation/widgets/auth_background.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _selectedTab = 0;
  int _selectedMessageFilter = 0;

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
  StreamSubscription<Position>? _positionSubscription;

  final List<_PeerData> _peers = const [
    _PeerData(
      name: 'Peer_01',
      id: 'ID: 7A:3F:2B:11:9E:A0',
      signal: SignalStrength.strong,
      connected: true,
    ),
    _PeerData(
      name: 'Peer_02',
      id: 'ID: 07:3C:2B:11:9E:A0',
      signal: SignalStrength.weak,
      connected: false,
    ),
    _PeerData(
      name: 'Peer_03',
      id: 'ID: 07:3C:2B:11:9E:A0',
      signal: SignalStrength.weak,
      connected: false,
    ),
  ];

  final List<_MessageFeedItem> _messages = const [
    _MessageFeedItem(
      title: 'SOS from Rescuer_01',
      description: 'We need immediate medical assistance.',
      distance: '2.4 km away',
      time: '10:32 AM',
      badge: 'SOS',
      type: 'SOS',
      icon: Icons.warning,
      iconColor: Color(0xFFE83C3D),
      badgeColor: Color(0xFFE83C3D),
    ),
    _MessageFeedItem(
      title: 'Food Request',
      description: 'Need food and water for 5 people.',
      distance: '1.8 km away',
      time: '09:15 AM',
      badge: 'REQUEST',
      type: 'REQUEST',
      icon: Icons.restaurant,
      iconColor: Color(0xFFF39C12),
      badgeColor: Color(0xFFF39C12),
    ),
    _MessageFeedItem(
      title: 'Water Available',
      description: 'We have clean drinking water available.',
      distance: '3.1 km away',
      time: '08:47 AM',
      badge: 'UPDATE',
      type: 'UPDATE',
      icon: Icons.opacity,
      iconColor: Color(0xFF3F66C4),
      badgeColor: Color(0xFF3F66C4),
    ),
    _MessageFeedItem(
      title: 'Shelter Available',
      description: 'Safe shelter open for anyone in need.',
      distance: '4.2 km away',
      time: 'Yesterday',
      badge: 'UPDATE',
      type: 'UPDATE',
      icon: Icons.home,
      iconColor: Color(0xFF24A646),
      badgeColor: Color(0xFF24A646),
    ),
    _MessageFeedItem(
      title: 'Transport Help Needed',
      description: 'Need transport for injured person.',
      distance: '5.6 km away',
      time: 'Yesterday',
      badge: 'REQUEST',
      type: 'REQUEST',
      icon: Icons.directions_bus,
      iconColor: Color(0xFF7E3EB8),
      badgeColor: Color(0xFFF39C12),
    ),
    _MessageFeedItem(
      title: 'General Update',
      description: 'Bridge ahead is damaged. Avoid the route.',
      distance: '6.3 km away',
      time: '2 days ago',
      badge: 'UPDATE',
      type: 'UPDATE',
      icon: Icons.more_horiz,
      iconColor: Color(0xFF777777),
      badgeColor: Color(0xFF3F66C4),
    ),
  ];

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
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: AuthBackground(
        child: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildLogo(),
                          Transform.translate(
                            offset: const Offset(0, -25),
                            child: _selectedTab == 1
                                ? _buildMessagesTabContent()
                                : _buildHomeTabContent(),
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

  Widget _buildHomeTabContent() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        _buildSosButton(),
        const SizedBox(height: 14),
        _buildMapCard(),
        const SizedBox(height: 14),
        _buildActionButtons(),
        const SizedBox(height: 20),
        _buildPeersSection(),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildMessagesTabContent() {
    final List<(String, IconData, String)> filters = [
      ('All Messages', Icons.chat_bubble_outline_rounded, 'ALL'),
      ('SOS Alerts', Icons.sos_rounded, 'SOS'),
      ('Requests', Icons.pan_tool_outlined, 'REQUEST'),
      ('Updates', Icons.campaign_outlined, 'UPDATE'),
    ];

    final String activeType = filters[_selectedMessageFilter].$3;
    final List<_MessageFeedItem> filteredMessages = activeType == 'ALL'
        ? _messages
        : _messages.where((item) => item.type == activeType).toList();

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
        ...filteredMessages.map((message) => _buildMessageFeedCard(message)),
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 78,
            height: 78,
            decoration: BoxDecoration(
              color: item.iconColor,
              shape: BoxShape.circle,
            ),
            child: Icon(item.icon, color: Colors.white, size: 38),
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
                        fontSize: 12,
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
                    fontSize: 14,
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
                        fontSize: 14,
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
        'assets/home/home_map.png',
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

  Widget _buildMapCard() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: SizedBox(
        height: 180,
        width: double.infinity,
        child: Stack(
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
                  maxNativeZoom: 19,
                  panBuffer: 1,
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _myPosition ?? _currentCenter,
                      width: 40,
                      height: 40,
                      child: const Icon(
                        Icons.location_pin,
                        size: 40,
                        color: Color(0xFFE83C3D),
                      ),
                    ),
                  ],
                ),
              ],
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
              bottom: 10,
              child: _MapControlButton(icon: Icons.explore, onTap: _resetNorth),
            ),
          ],
        ),
      ),
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
                : const _LocationIcon(),
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
            labelColor: const Color(0xFF851C1B),
            subtitle: 'View all messages',
            onTap: () => setState(() => _selectedTab = 1),
          ),
        ),
      ],
    );
  }

  Widget _buildPeersSection() {
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
        ...List.generate(_peers.length, (i) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _PeerCard(peer: _peers[i]),
          );
        }),
      ],
    );
  }
}

enum SignalStrength { strong, weak }

class _PeerData {
  final String name;
  final String id;
  final SignalStrength signal;
  final bool connected;

  const _PeerData({
    required this.name,
    required this.id,
    required this.signal,
    required this.connected,
  });
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

class _SosComposerSheet extends StatefulWidget {
  const _SosComposerSheet({
    required this.locationText,
    required this.onUpdateLocation,
  });

  final String locationText;
  final Future<void> Function() onUpdateLocation;

  @override
  State<_SosComposerSheet> createState() => _SosComposerSheetState();
}

class _SosComposerSheetState extends State<_SosComposerSheet> {
  static const _categories = [
    (icon: Icons.accessibility_new, label: 'Rescue'),
    (icon: Icons.restaurant, label: 'Food'),
    (icon: Icons.opacity, label: 'Water'),
    (icon: Icons.local_hospital, label: 'Medical'),
    (icon: Icons.home, label: 'Shelter'),
    (icon: Icons.directions_bus, label: 'Transport'),
    (icon: Icons.info, label: 'Information'),
    (icon: Icons.more_horiz, label: 'Other'),
  ];

  late final TextEditingController _messageController;
  int _selectedCategory = 0;
  bool _updatingLocation = false;

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
                    onPressed: () => Navigator.of(context).pop(),
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
                    onPressed: () => Navigator.of(context).pop(),
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

  final _PeerData peer;

  @override
  Widget build(BuildContext context) {
    final isConnected = peer.connected;
    final isStrong = peer.signal == SignalStrength.strong;

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
                  peer.id,
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

class _LocationIcon extends StatelessWidget {
  const _LocationIcon();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: CustomPaint(painter: _LocationIconPainter()),
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
      ..color = const Color(0xFF851C1B)
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
