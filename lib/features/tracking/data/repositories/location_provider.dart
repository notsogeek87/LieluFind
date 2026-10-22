
import 'dart:io';

import 'package:dawarich/features/tracking/application/repositories/location_provider_interface.dart';
import 'package:dawarich/features/tracking/domain/enum/location_precision.dart';
import 'package:dawarich/features/tracking/domain/models/location_fix.dart';
import 'package:dawarich/features/tracking/domain/models/location_request.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:option_result/option.dart';
import 'package:option_result/result.dart';

/// Location provider using geolocator package.
/// Automatically uses Google Fused Location Provider when available (GMS build),
/// or falls back to Android Location Manager (FOSS build with GMS excluded).
final class LocationProvider implements ILocationProvider {

  @override
  Future<Result<LocationFix, String>> getCurrent(LocationRequest request) async {
    try {
      final Position position = await Geolocator.getCurrentPosition(
        locationSettings: _toLocationSettings(request),
      );

      return Ok(_toFix(position));
    } catch (error) {
      return Err("Failed to retrieve GPS location: $error");
    }
  }

  @override
  Future<Option<LocationFix>> getLastKnown() async {
    try {
      Position? position = await Geolocator.getLastKnownPosition();

      if (position == null) {
        return const None();
      }

      return Some(_toFix(position));
    } catch (_) {
      return const None();
    }
  }

  @override
  Future<bool> isLocationServiceEnabled() async {
    return Geolocator.isLocationServiceEnabled();
  }

  @override
  Stream<LocationFix> getLocationStream(LocationRequest request) {
    final Stream<Position> positionStream = Geolocator.getPositionStream(
      locationSettings: _toLocationSettings(request, keepAwake: shouldKeepAwake(request)),
    );

    return positionStream.map(_toFix);
  }

  /// Le wakelock n'est tenu qu'en mouvement. À l'arrêt (flux passif), le garder
  /// maintenait le CPU éveillé toute la journée (8 h 48 de verrouillages
  /// mesurées) pour des positions que le téléphone calcule déjà : le point
  /// « toujours là » peut arriver avec un peu de retard, mais aucun n'est perdu.
  @visibleForTesting
  static bool shouldKeepAwake(LocationRequest request) => !request.passive;

  /// [keepAwake]: long-lived moving stream. Without a CPU wake lock, a moving
  /// phone with its screen off (Pixel/Doze) sleeps: the distance-filtered stream
  /// stays silent, the timer never fires and sharing silently stops.
  LocationSettings _toLocationSettings(LocationRequest request, {bool keepAwake = false}) {
    if (Platform.isAndroid) {
      return AndroidSettings(
        foregroundNotificationConfig: keepAwake
            ? const ForegroundNotificationConfig(
                notificationTitle: 'LieluFind',
                notificationText: 'Partage de position actif',
                enableWakeLock: true,
                setOngoing: true,
              )
            : null,
        // `lowest` = fournisseur passif côté Android : zéro calcul de position.
        accuracy: request.passive ? LocationAccuracy.lowest : _toGeolocatorAccuracy(request.precision),
        distanceFilter: request.distanceFilterMeters ?? 0,
        timeLimit: request.timeLimit,
        intervalDuration: request.intervalDuration ?? const Duration(seconds: 10),
      );
    }

    return LocationSettings(
      accuracy: _toGeolocatorAccuracy(request.precision),
      distanceFilter: request.distanceFilterMeters ?? 0,
      timeLimit: request.timeLimit,
    );
  }

  LocationAccuracy _toGeolocatorAccuracy(LocationPrecision precision) {
    switch (precision) {
      case LocationPrecision.best:
        return LocationAccuracy.best;
      case LocationPrecision.high:
        return LocationAccuracy.high;
      case LocationPrecision.balanced:
        return LocationAccuracy.medium;
      case LocationPrecision.lowPower:
        return LocationAccuracy.low;
    }
  }

  LocationFix _toFix(Position p) {
    return LocationFix(
      latitude: p.latitude,
      longitude: p.longitude,
      timestampUtc: p.timestamp,
      hAccuracyMeters: p.accuracy,

      altitudeMeters: p.altitude,
      speedMps: p.speed,
      headingDegrees: p.heading,

      altitudeAccuracyMeters: p.altitudeAccuracy,
      speedAccuracyMps: p.speedAccuracy,
      headingAccuracyDegrees: p.headingAccuracy,

      provider: p.isMocked ? 'mock' : null,
      isMocked: p.isMocked,
    );
  }

}