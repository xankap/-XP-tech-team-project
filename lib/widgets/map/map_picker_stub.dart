import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../theme/app_theme.dart';

/// Non-web / test stub for interactive map picker.
/// Provides an interactive coordinate fine-tuning and city-jump picker
/// with complete mock/test support.
Widget buildPlatformMapPicker({
  required LatLng initialPosition,
  required ValueChanged<LatLng> onLocationPicked,
  String? stationName,
}) {
  return _StubMapPicker(
    initialPosition: initialPosition,
    onLocationPicked: onLocationPicked,
    stationName: stationName,
  );
}

class _StubMapPicker extends StatefulWidget {
  final LatLng initialPosition;
  final ValueChanged<LatLng> onLocationPicked;
  final String? stationName;

  const _StubMapPicker({
    required this.initialPosition,
    required this.onLocationPicked,
    this.stationName,
  });

  @override
  State<_StubMapPicker> createState() => _StubMapPickerState();
}

class _StubMapPickerState extends State<_StubMapPicker> {
  late LatLng _current;

  final List<Map<String, dynamic>> _cities = const [
    {'name': 'Port Harcourt', 'lat': 4.8156, 'lng': 7.0498},
    {'name': 'Lagos', 'lat': 6.5244, 'lng': 3.3792},
    {'name': 'Abuja', 'lat': 9.0765, 'lng': 7.3986},
    {'name': 'Ibadan', 'lat': 7.3775, 'lng': 3.9470},
    {'name': 'Kano', 'lat': 12.0022, 'lng': 8.5920},
    {'name': 'Benin City', 'lat': 6.3350, 'lng': 5.6037},
  ];

  @override
  void initState() {
    super.initState();
    _current = widget.initialPosition;
  }

  void _nudge(double dLat, double dLng) {
    setState(() {
      _current = LatLng(
        (_current.latitude + dLat).clamp(-90.0, 90.0),
        (_current.longitude + dLng).clamp(-180.0, 180.0),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // City quick jump bar
        Container(
          color: const Color(0xFFF8FAFC),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _cities.map((c) {
                final lat = c['lat'] as double;
                final lng = c['lng'] as double;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ActionChip(
                    label: Text(c['name'] as String,
                        style: const TextStyle(fontSize: 12)),
                    onPressed: () {
                      setState(() => _current = LatLng(lat, lng));
                    },
                  ),
                );
              }).toList(),
            ),
          ),
        ),
        // Interactive Canvas / Map Area
        Expanded(
          child: Container(
            key: const Key('interactive-map-picker'),
            color: const Color(0xFFE2E8F0),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Grid background representing map tiles
                CustomPaint(
                  size: Size.infinite,
                  painter: _MapGridPainter(),
                ),
                // Center station pin
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.corporateBlue,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        widget.stationName ?? 'Plant Entrance',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                    const Icon(
                      Icons.location_on_rounded,
                      size: 44,
                      color: Color(0xFFE11D48),
                    ),
                  ],
                ),
                // Fine-tune Nudge Pad
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.95),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(
                            color: Colors.black12,
                            blurRadius: 8,
                            offset: Offset(0, 3)),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_drop_up_rounded),
                          tooltip: 'Nudge North (+10m)',
                          onPressed: () => _nudge(0.0002, 0),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_left_rounded),
                              tooltip: 'Nudge West (-10m)',
                              onPressed: () => _nudge(0, -0.0002),
                            ),
                            const Icon(Icons.touch_app_rounded,
                                size: 16, color: AppTheme.textSecondary),
                            IconButton(
                              icon: const Icon(Icons.arrow_right_rounded),
                              tooltip: 'Nudge East (+10m)',
                              onPressed: () => _nudge(0, 0.0002),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.arrow_drop_down_rounded),
                          tooltip: 'Nudge South (-10m)',
                          onPressed: () => _nudge(-0.0002, 0),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Bottom Coordinate Confirmation Card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                  color: Colors.black12, blurRadius: 10, offset: Offset(0, -2)),
            ],
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('PINNED COORDINATES:',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textSecondary)),
                    Text(
                      '${_current.latitude.toStringAsFixed(6)}, ${_current.longitude.toStringAsFixed(6)}',
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.corporateBlue),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    key: const Key('confirm-location-button'),
                    onPressed: () => widget.onLocationPicked(_current),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.corporateBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Use This Plant Location',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _MapGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFCBD5E1)
      ..strokeWidth = 1.0;

    const step = 40.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
