import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../app/theme/app_colors.dart';
import '../app/theme/app_typography.dart';
import '../data/models/tracked_person.dart';
import 'app_icon.dart';
import '../app/assets.dart';
import 'avatar.dart';

/// The map every post-onboarding screen sits on.
///
/// OpenStreetMap tiles — no API key. Interaction is off by default because on most screens
/// the map is scenery behind a sheet; Home turns it on.
class MapBackground extends StatelessWidget {
  const MapBackground({
    super.key,
    required this.center,
    this.markers = const [],
    this.focused,
    this.me,
    this.interactive = false,
    this.zoom = 15,
    this.controller,
  });

  final LatLng center;
  final List<TrackedPerson> markers;

  /// When set, this person gets the enlarged marker and a place chip above it.
  final TrackedPerson? focused;

  /// This device's own position. Drawn as a plain dot rather than an avatar so it never reads
  /// as one of the people being tracked.
  final LatLng? me;
  final bool interactive;
  final double zoom;
  final MapController? controller;

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCenter: center,
        initialZoom: zoom,
        interactionOptions: InteractionOptions(
          flags: interactive ? InteractiveFlag.all & ~InteractiveFlag.rotate : InteractiveFlag.none,
        ),
        backgroundColor: const Color(0xFFF2F4F7),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.spacewire.circle360',
          tileProvider: NetworkTileProvider(),
        ),
        if (me != null)
          MarkerLayer(
            markers: [
              Marker(
                point: me!,
                width: 28,
                height: 28,
                child: const _SelfMarker(),
              ),
            ],
          ),
        // Filtered here as well as by the caller: a person without a fix has no point to draw,
        // and flutter_map would otherwise need a non-null one anyway.
        if (markers.any((p) => p.isMappable))
          MarkerLayer(
            markers: [
              for (final person in markers)
                if (person.isMappable)
                  Marker(
                    point: person.position!,
                    width: 76,
                    height: focused?.id == person.id ? 110 : 76,
                    alignment: Alignment.bottomCenter,
                    child: _PersonMarker(
                      person: person,
                      focused: focused?.id == person.id,
                    ),
                  ),
            ],
          ),
      ],
    );
  }
}

/// "You are here" — a brand-blue dot with a white collar, the platform convention.
class _SelfMarker extends StatelessWidget {
  const _SelfMarker();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.brand,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.surface, width: 3),
        boxShadow: const [AppColors.floatingShadow],
      ),
    );
  }
}

class _PersonMarker extends StatelessWidget {
  const _PersonMarker({required this.person, required this.focused});

  final TrackedPerson person;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (focused) ...[
          // There is no reverse-geocoding backend, so the chip carries how fresh the fix is
          // instead of a street name. That is the more useful of the two anyway — a stale
          // position at a named street reads as more trustworthy than it is.
          PlaceChip(
            label: person.placeLabel.isNotEmpty ? person.placeLabel : person.freshness,
          ),
          const SizedBox(height: 6),
        ],
        Avatar(
          asset: person.avatarAsset,
          size: focused ? 62 : 48,
          showPresence: person.isOnline,
          ring: Colors.white,
        ),
      ],
    );
  }
}

/// White pill naming where someone is — "High Street".
class PlaceChip extends StatelessWidget {
  const PlaceChip({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: const [AppColors.floatingShadow],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppIcon(Svg.placePin, size: 20),
          const SizedBox(width: 4),
          Text(label, style: AppText.chip),
        ],
      ),
    );
  }
}
