import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../services/xp_api.dart';

Widget buildWebMapViewer({
  required LatLng center,
  required List<PartnerStation> stations,
  required ValueChanged<String> onStationSelected,
  required void Function(double south, double west, double north, double east)
      onBoundsChanged,
  required VoidCallback onLocateUser,
}) {
  return _WebMapViewer(
    center: center,
    stations: stations,
    onStationSelected: onStationSelected,
    onBoundsChanged: onBoundsChanged,
    onLocateUser: onLocateUser,
  );
}

class _WebMapViewer extends StatefulWidget {
  final LatLng center;
  final List<PartnerStation> stations;
  final ValueChanged<String> onStationSelected;
  final void Function(double south, double west, double north, double east)
      onBoundsChanged;
  final VoidCallback onLocateUser;

  const _WebMapViewer({
    required this.center,
    required this.stations,
    required this.onStationSelected,
    required this.onBoundsChanged,
    required this.onLocateUser,
  });

  @override
  State<_WebMapViewer> createState() => _WebMapViewerState();
}

class _WebMapViewerState extends State<_WebMapViewer> {
  late final String _viewType;
  html.IFrameElement? _iframe;
  dynamic _messageSub;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    final uniqueId = DateTime.now().microsecondsSinceEpoch;
    _viewType = 'xp-map-viewer-$uniqueId';

    final lat = widget.center.latitude;
    final lng = widget.center.longitude;
    final src = 'map_viewer.html?lat=$lat&lng=$lng';

    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final iframe = html.IFrameElement()
        ..src = src
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%';
      _iframe = iframe;
      return iframe;
    });

    _messageSub = html.window.onMessage.listen((event) {
      final data = event.data;
      if (data is! Map) return;
      if (data['type'] == 'XP_MAP_VIEWER_READY') {
        _ready = true;
        _pushStationsToIframe();
      } else if (data['type'] == 'XP_STATION_SELECTED') {
        final id = data['stationId']?.toString();
        if (id != null && mounted) widget.onStationSelected(id);
      } else if (data['type'] == 'XP_MAP_MOVED') {
        final bounds = data['bounds'];
        if (bounds is Map && mounted) {
          final s = (bounds['south'] as num?)?.toDouble() ?? 0.0;
          final w = (bounds['west'] as num?)?.toDouble() ?? 0.0;
          final n = (bounds['north'] as num?)?.toDouble() ?? 0.0;
          final e = (bounds['east'] as num?)?.toDouble() ?? 0.0;
          widget.onBoundsChanged(s, w, n, e);
        }
      } else if (data['type'] == 'XP_USER_LOCATION') {
        if (mounted) widget.onLocateUser();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _WebMapViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_ready && widget.stations != oldWidget.stations) {
      _pushStationsToIframe();
    }
    if (_ready && widget.center != oldWidget.center) {
      _iframe?.contentWindow?.postMessage({
        'type': 'XP_CENTER_ON',
        'lat': widget.center.latitude,
        'lng': widget.center.longitude,
      }, '*');
    }
  }

  void _pushStationsToIframe() {
    final list = widget.stations
        .map((s) => {
              'id': s.id,
              'name': s.name,
              'latitude': s.latitude,
              'longitude': s.longitude,
              'isAvailable': s.isAvailable,
              'pricePerKg': s.pricePerKg,
              'address': s.address,
            })
        .toList();

    _iframe?.contentWindow?.postMessage({
      'type': 'XP_UPDATE_STATIONS',
      'stations': list,
    }, '*');
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
