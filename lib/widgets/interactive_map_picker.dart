import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../theme/app_theme.dart';
import 'map/map_picker_view.dart';

class InteractiveMapPickerScreen extends StatelessWidget {
  final LatLng initialPosition;
  final String? stationName;

  const InteractiveMapPickerScreen({
    super.key,
    required this.initialPosition,
    this.stationName,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(stationName != null && stationName!.trim().isNotEmpty
            ? 'Pin $stationName'
            : 'Pick Plant Location'),
        backgroundColor: AppTheme.corporateBlue,
        foregroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          tooltip: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: buildPlatformMapPicker(
        initialPosition: initialPosition,
        stationName: stationName,
        onLocationPicked: (LatLng picked) {
          Navigator.of(context).pop(picked);
        },
      ),
    );
  }
}
