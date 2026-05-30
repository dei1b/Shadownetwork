import 'dart:async';

import 'package:flutter/services.dart';

import '../../domain/entities/peer.dart';
import '../../domain/entities/peer_type.dart';
import '../../domain/entities/scf_envelope.dart';
import '../../domain/entities/transport_status.dart';
import '../../domain/services/scf_transport.dart';
import '../models/relay_payload_codec.dart';

class AndroidScfTransport implements ScfTransport {
  AndroidScfTransport({
    this.localPeerId = 'local-device',
    this.localPeerName = 'This Device',
    MethodChannel? channel,
  }) : _channel =
           channel ?? const MethodChannel('shadownetwork/android_transport') {
    _channel.setMethodCallHandler(_handleNativeRelayEvent);
  }

  final MethodChannel _channel;
  final String localPeerName;
  static final StreamController<void> _relayEvents =
      StreamController<void>.broadcast();

  @override
  final String localPeerId;

  @override
  Stream<void> get relayEvents => _relayEvents.stream;

  static Future<void> _handleNativeRelayEvent(MethodCall call) async {
    if (call.method == 'onRelayEvent') {
      _relayEvents.add(null);
    }
  }

  @override
  Future<Peer> getLocalPeer() async {
    final map = await _channel.invokeMethod<Map<Object?, Object?>>(
      'getLocalPeer',
    );
    return _peerFromPlatformMap(map);
  }

  @override
  Future<TransportStatus> getStatus() async {
    final map = await _channel.invokeMethod<Map<Object?, Object?>>(
      'getTransportStatus',
    );
    final localPeerMap = map?['localPeer'] as Map<Object?, Object?>?;

    return TransportStatus(
      localPeer: _peerFromPlatformMap(localPeerMap),
      permissionsGranted: map?['permissionsGranted'] as bool? ?? false,
      isRunning: map?['isRunning'] as bool? ?? false,
      discoveredPeerCount: map?['discoveredPeerCount'] as int? ?? 0,
      connectedPeerCount: map?['connectedPeerCount'] as int? ?? 0,
    );
  }

  Future<bool> ensurePermissions() async {
    return await _channel.invokeMethod<bool>('ensurePermissions') ?? false;
  }

  Future<bool> start() async {
    return await _channel.invokeMethod<bool>('start', {
          'localPeerId': localPeerId,
          'localPeerName': localPeerName,
        }) ??
        false;
  }

  Future<void> stop() async {
    await _channel.invokeMethod<void>('stop');
  }

  @override
  Future<List<Peer>> discoverPeers() async {
    await ensurePermissions();
    await start();

    final rows = await _channel.invokeListMethod<Object?>('discoverPeers');
    if (rows == null) {
      return const [];
    }

    return rows
        .whereType<Map<Object?, Object?>>()
        .map(_peerFromPlatformMap)
        .toList(growable: false);
  }

  @override
  Future<Peer> connectPeer(Peer peer) async {
    final map = await _channel.invokeMethod<Map<Object?, Object?>>(
      'connectPeer',
      {'peerId': peer.id},
    );
    return _peerFromPlatformMap(map);
  }

  @override
  Future<void> sendEnvelope({
    required Peer peer,
    required ScfEnvelope envelope,
  }) async {
    await _channel.invokeMethod<void>('sendEnvelope', {
      'peerId': peer.id,
      'envelope': _envelopeToPlatformMap(envelope),
    });
  }

  @override
  Future<List<ScfEnvelope>> receiveEnvelopes() async {
    final rows = await _channel.invokeListMethod<Object?>('receiveEnvelopes');
    if (rows == null) {
      return const [];
    }

    return rows
        .whereType<Map<Object?, Object?>>()
        .map(_envelopeFromPlatformMap)
        .toList(growable: false);
  }

  Peer _peerFromPlatformMap(Map<Object?, Object?>? map) {
    if (map == null) {
      return Peer(
        id: localPeerId,
        name: localPeerName,
        type: PeerType.civilian,
        isConnected: false,
      );
    }

    return Peer(
      id: map['id']! as String,
      name: (map['name'] as String?)?.trim().isNotEmpty == true
          ? map['name']! as String
          : 'Nearby Peer',
      type: _peerTypeFromName(map['type'] as String?),
      isConnected: map['isConnected'] as bool? ?? false,
      signalStrength: map['signalStrength'] as int?,
    );
  }

  PeerType _peerTypeFromName(String? value) {
    if (value == null) {
      return PeerType.unknown;
    }

    return PeerType.values.where((type) => type.name == value).firstOrNull ??
        PeerType.unknown;
  }

  Map<String, Object?> _envelopeToPlatformMap(ScfEnvelope envelope) {
    return {
      'messageHash': envelope.messageHash,
      'payloadJson': envelope.payloadJson,
      'hopCount': envelope.hopCount,
      'receivedAt': envelope.receivedAt.toUtc().toIso8601String(),
      'expiresAt': envelope.expiresAt.toUtc().toIso8601String(),
    };
  }

  ScfEnvelope _envelopeFromPlatformMap(Map<Object?, Object?> map) {
    final payloadJson = map['payloadJson']! as String;
    return ScfEnvelope(
      messageHash: map['messageHash']! as String,
      payloadJson: payloadJson,
      hopCount: map['hopCount']! as int,
      receivedAt: DateTime.parse(map['receivedAt']! as String),
      expiresAt: DateTime.parse(map['expiresAt']! as String),
      payloadType: RelayPayloadCodec.payloadType(payloadJson),
    );
  }
}
