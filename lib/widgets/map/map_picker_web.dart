import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

Widget buildPlatformMapPicker({
  required LatLng initialPosition,
  required ValueChanged<LatLng> onLocationPicked,
  String? stationName,
}) {
  return _WebMapPicker(
    initialPosition: initialPosition,
    onLocationPicked: onLocationPicked,
    stationName: stationName,
  );
}

class _WebMapPicker extends StatefulWidget {
  final LatLng initialPosition;
  final ValueChanged<LatLng> onLocationPicked;
  final String? stationName;

  const _WebMapPicker({
    required this.initialPosition,
    required this.onLocationPicked,
    this.stationName,
  });

  @override
  State<_WebMapPicker> createState() => _WebMapPickerState();
}

class _WebMapPickerState extends State<_WebMapPicker> {
  late final String _viewType;
  html.IFrameElement? _iframe;
  dynamic _messageSub;

  @override
  void initState() {
    super.initState();
    final uniqueId = DateTime.now().microsecondsSinceEpoch;
    _viewType = 'xp-map-picker-$uniqueId';

    final lat = widget.initialPosition.latitude;
    final lng = widget.initialPosition.longitude;
    final name = Uri.encodeComponent(widget.stationName ?? 'Gas Plant');
    final src = 'map_picker.html?lat=$lat&lng=$lng&name=$name';

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
      if (data is Map && data['type'] == 'XP_MAP_LOCATION_PICKED') {
        final pickedLat = (data['latitude'] as num?)?.toDouble() ??
            (data['lat'] as num?)?.toDouble();
        final pickedLng = (data['longitude'] as num?)?.toDouble() ??
            (data['lng'] as num?)?.toDouble();
        if (pickedLat != null && pickedLng != null && mounted) {
          widget.onLocationPicked(LatLng(pickedLat, pickedLng));
        }
      }
    });
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
