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
}) =>
    const SizedBox.shrink();
