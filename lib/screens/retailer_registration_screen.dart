import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../services/xp_api.dart';
import '../theme/app_theme.dart';

const List<String> _kNigerianStates = [
  'Abia', 'Adamawa', 'Akwa Ibom', 'Anambra', 'Bauchi', 'Bayelsa', 'Benue', 'Borno',
  'Cross River', 'Delta', 'Ebonyi', 'Edo', 'Ekiti', 'Enugu', 'FCT - Abuja', 'Gombe',
  'Imo', 'Jigawa', 'Kaduna', 'Kano', 'Katsina', 'Kebbi', 'Kogi', 'Kwara', 'Lagos',
  'Nasarawa', 'Niger', 'Ogun', 'Ondo', 'Osun', 'Oyo', 'Plateau', 'Rivers', 'Sokoto',
  'Taraba', 'Yobe', 'Zamfara'
];

/// Screen allowing gas plants, refill stations, and retailers to register or manage their listing.
class RetailerRegistrationScreen extends StatefulWidget {
  final String? initialName;
  final String? initialPhone;
  const RetailerRegistrationScreen({super.key, this.initialName, this.initialPhone});

  @override
  State<RetailerRegistrationScreen> createState() => _RetailerRegistrationScreenState();
}

class _RetailerRegistrationScreenState extends State<RetailerRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _addressController = TextEditingController();
  final _cityController = TextEditingController();
  final _latController = TextEditingController();
  final _lngController = TextEditingController();

  String? _selectedState;
  String _selectedFacilityType = 'LPG Refill Plant';
  final List<String> _facilityTypes = [
    'LPG Refill Plant',
    'Gas Skid / Mini Station',
    'Cylinder Depot & Retailer',
    'Doorstep Delivery Provider',
  ];

  final _api = XpApi();
  bool _loading = true;
  bool _submitting = false;
  bool _fetchingLocation = false;
  bool _isEditing = false;
  bool _togglingAvailability = false;
  String? _error;
  RetailerProfile? _currentProfile;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    _cityController.dispose();
    _latController.dispose();
    _lngController.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await _api.getMyRetailer();
      if (!mounted) return;
      setState(() {
        _currentProfile = p;
        _loading = false;
        if (p != null) {
          _populateFormWithProfile(p);
        } else {
          if (widget.initialName != null && _nameController.text.isEmpty) {
            _nameController.text = widget.initialName!;
          }
          if (widget.initialPhone != null && _phoneController.text.isEmpty) {
            _phoneController.text = widget.initialPhone!;
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceAll('Exception: ', '');
        _loading = false;
      });
    }
  }

  void _populateFormWithProfile(RetailerProfile p) {
    _nameController.text = p.name;
    _phoneController.text = p.phone;
    _addressController.text = p.address;
    _cityController.text = p.cityLga ?? '';
    _latController.text = p.latitude.toStringAsFixed(6);
    _lngController.text = p.longitude.toStringAsFixed(6);

    if (p.state != null && _kNigerianStates.contains(p.state)) {
      _selectedState = p.state;
    } else {
      _selectedState = p.state;
    }
  }

  /// Formats user-entered phone number into standard E.164 (+234...) format.
  String _normalizePhone(String raw) {
    String trimmed = raw.replaceAll(RegExp(r'[\s\-()]'), '');
    if (trimmed.startsWith('0') && trimmed.length == 11) {
      return '+234${trimmed.substring(1)}';
    }
    if (!trimmed.startsWith('+') && trimmed.startsWith('234')) {
      return '+$trimmed';
    }
    return trimmed;
  }

  Future<void> _getCurrentLocation() async {
    setState(() => _fetchingLocation = true);
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        throw Exception('Location services are disabled. Please enable GPS on your device.');
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          throw Exception('Location permission was denied.');
        }
      }
      if (permission == LocationPermission.deniedForever) {
        throw Exception('Location permissions are permanently denied. Please enable them in device settings.');
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      if (!mounted) return;
      _latController.text = pos.latitude.toStringAsFixed(6);
      _lngController.text = pos.longitude.toStringAsFixed(6);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Coordinates updated from GPS.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _fetchingLocation = false);
    }
  }

  Future<void> _toggleAvailability(bool newValue) async {
    if (_currentProfile == null) return;
    setState(() => _togglingAvailability = true);
    try {
      final updated = await _api.updateRetailer(isAvailable: newValue);
      if (!mounted) return;
      setState(() {
        _currentProfile = updated;
        _togglingAvailability = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(newValue
              ? 'Gas plant is now marked OPEN & Available on the map.'
              : 'Gas plant is now marked CLOSED / Out of stock.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _togglingAvailability = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to update status: $e')),
      );
    }
  }

  /// Opens a full-screen map to fine-tune the plant's gate/entrance pin.
  /// Optional: if Maps is unavailable the manual fields and Auto-Detect GPS
  /// below keep working as fallbacks.
  Future<void> _openMapPicker() async {
    var initial = const LatLng(4.8156, 7.0498); // Port Harcourt fallback
    final lat = double.tryParse(_latController.text.trim());
    final lng = double.tryParse(_lngController.text.trim());
    if (lat != null && lat >= -90 && lat <= 90 && lng != null && lng >= -180 && lng <= 180) {
      initial = LatLng(lat, lng);
    }
    try {
      final picked = await Navigator.of(context).push<LatLng>(
        MaterialPageRoute(
          builder: (_) {
            var current = initial;
            return StatefulBuilder(
              builder: (pageContext, setPageState) => Scaffold(
                appBar: AppBar(
                  title: const Text('Pick plant location'),
                  backgroundColor: AppTheme.corporateBlue,
                  foregroundColor: Colors.white,
                ),
                body: Stack(
                  children: [
                    GoogleMap(
                      initialCameraPosition: CameraPosition(target: initial, zoom: 15),
                      markers: {
                        Marker(
                          markerId: const MarkerId('plant-pin'),
                          position: current,
                          draggable: true,
                          onDragEnd: (p) => setPageState(() => current = p),
                        ),
                      },
                      onTap: (p) => setPageState(() => current = p),
                      myLocationEnabled: false,
                      zoomControlsEnabled: true,
                    ),
                    Positioned(
                      left: 16,
                      right: 16,
                      top: 16,
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          child: Text(
                            'Tap or drag the pin to your refill gate/entrance.\n'
                            '${current.latitude.toStringAsFixed(6)}, ${current.longitude.toStringAsFixed(6)}',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                bottomNavigationBar: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(pageContext).pop(current),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.corporateBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('Use this location',
                            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
      if (!mounted || picked == null) return;
      _latController.text = picked.latitude.toStringAsFixed(6);
      _lngController.text = picked.longitude.toStringAsFixed(6);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pin location applied to coordinates.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Map is unavailable — type coordinates manually or use Auto-Detect GPS.')),
      );
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final lat = double.tryParse(_latController.text.trim());
    final lng = double.tryParse(_lngController.text.trim());

    if (lat == null || lat < -90 || lat > 90) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid latitude between -90 and 90')),
      );
      return;
    }
    if (lng == null || lng < -180 || lng > 180) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid longitude between -180 and 180')),
      );
      return;
    }

    final formattedPhone = _normalizePhone(_phoneController.text.trim());
    final fullName = _currentProfile != null
        ? _nameController.text.trim()
        : '${_nameController.text.trim()} ($_selectedFacilityType)';

    setState(() => _submitting = true);
    try {
      RetailerProfile result;
      if (_currentProfile != null) {
        // Updating existing profile
        result = await _api.updateRetailer(
          name: _nameController.text.trim(),
          phone: formattedPhone,
          address: _addressController.text.trim(),
          cityLga: _cityController.text.trim().isEmpty ? null : _cityController.text.trim(),
          state: _selectedState,
          latitude: lat,
          longitude: lng,
        );
      } else {
        // New registration
        result = await _api.registerRetailer(
          name: fullName,
          phone: formattedPhone,
          address: _addressController.text.trim(),
          cityLga: _cityController.text.trim().isEmpty ? null : _cityController.text.trim(),
          state: _selectedState,
          latitude: lat,
          longitude: lng,
        );
      }

      if (!mounted) return;
      setState(() {
        _currentProfile = result;
        _isEditing = false;
        _submitting = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_currentProfile?.status == 'approved'
              ? 'Gas plant profile updated successfully!'
              : 'Registration submitted! It is now pending admin verification.'),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      final msg = e.toString().replaceAll('Exception: ', '');
      if (msg.contains('already have a retailer profile')) {
        _loadProfile();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_currentProfile != null && !_isEditing
            ? 'Gas Plant Dashboard'
            : (_isEditing ? 'Edit Station Details' : 'Gas Plant & Retailer Sign-up')),
        backgroundColor: AppTheme.corporateBlue,
        foregroundColor: Colors.white,
        actions: [
          if (_currentProfile != null && !_isEditing)
            IconButton(
              icon: const Icon(Icons.edit_note_rounded),
              tooltip: 'Edit Details',
              onPressed: () {
                _populateFormWithProfile(_currentProfile!);
                setState(() => _isEditing = true);
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _buildErrorView()
              : _currentProfile != null && !_isEditing
                  ? _buildExistingProfileView(_currentProfile!)
                  : _buildRegistrationForm(),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 56, color: AppTheme.statusCritical),
            const SizedBox(height: 16),
            const Text(
              'Could not load station status',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              _error ?? 'An unexpected error occurred.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: _loadProfile,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExistingProfileView(RetailerProfile p) {
    Color statusColor;
    IconData statusIcon;
    String statusTitle;
    String statusSubtitle;

    switch (p.status) {
      case 'approved':
        statusColor = AppTheme.statusOK;
        statusIcon = Icons.check_circle_rounded;
        statusTitle = 'Plant Verified & Active';
        statusSubtitle = 'Your station is live on the XP Tech refill network. Nearby customers can see your location and request refills.';
        break;
      case 'rejected':
        statusColor = AppTheme.statusCritical;
        statusIcon = Icons.error_outline_rounded;
        statusTitle = 'Verification Needs Correction';
        statusSubtitle = p.statusReason ?? 'Please update your station coordinates or business info and re-submit.';
        break;
      case 'pending':
      default:
        statusColor = const Color(0xFFD97706);
        statusIcon = Icons.pending_actions_rounded;
        statusTitle = 'Awaiting Admin Approval';
        statusSubtitle = 'Your gas plant profile has been submitted. Our team validates coordinates and contact details before publishing to customers.';
        break;
    }

    return RefreshIndicator(
      onRefresh: _loadProfile,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Status card
          Card(
            elevation: 2,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Icon(statusIcon, color: statusColor, size: 54),
                  const SizedBox(height: 12),
                  Text(
                    statusTitle,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: statusColor),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    statusSubtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 14, color: AppTheme.textSecondary, height: 1.4),
                  ),
                  if (p.status == 'approved') ...[
                    const Divider(height: 32),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                p.isAvailable ? 'Status: OPEN (In Stock)' : 'Status: CLOSED (Out of Stock)',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: p.isAvailable ? AppTheme.statusOK : AppTheme.statusCritical,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                p.isAvailable
                                    ? 'Cylinder owners can route to your plant'
                                    : 'Station is hidden from active refill search',
                                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                              ),
                            ],
                          ),
                        ),
                        if (_togglingAvailability)
                          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                        else
                          Switch(
                            value: p.isAvailable,
                            activeThumbColor: AppTheme.statusOK,
                            onChanged: _toggleAvailability,
                          ),
                      ],
                    ),
                  ],
                  if (p.status == 'rejected') ...[
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () {
                        _populateFormWithProfile(p);
                        setState(() => _isEditing = true);
                      },
                      icon: const Icon(Icons.edit_rounded, color: AppTheme.statusCritical),
                      label: const Text('Edit & Re-submit'),
                      style: OutlinedButton.styleFrom(foregroundColor: AppTheme.statusCritical),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Business Details card
          Card(
            elevation: 1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const CircleAvatar(
                        backgroundColor: Color(0xFFEFF6FF),
                        child: Icon(Icons.local_gas_station_rounded, color: AppTheme.corporateBlue),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              p.name,
                              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'ID: ${p.id.substring(0, 8)}...',
                              style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 28),
                  _infoRow(Icons.phone_rounded, 'Contact Phone', p.phone),
                  _infoRow(Icons.location_on_rounded, 'Address', p.address),
                  if (p.cityLga != null || p.state != null)
                    _infoRow(Icons.map_rounded, 'City & State',
                        '${p.cityLga ?? ''}${p.cityLga != null && p.state != null ? ', ' : ''}${p.state ?? ''}'),
                  _infoRow(Icons.gps_fixed_rounded, 'GPS Coordinates',
                      '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}'),
                  if (p.createdAt != null)
                    _infoRow(Icons.calendar_today_rounded, 'Registered On',
                        '${p.createdAt!.day}/${p.createdAt!.month}/${p.createdAt!.year}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    _populateFormWithProfile(p);
                    setState(() => _isEditing = true);
                  },
                  icon: const Icon(Icons.edit_location_alt_rounded),
                  label: const Text('Update Details'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  )
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppTheme.corporateBlue),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.textMuted)),
                const SizedBox(height: 2),
                Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRegistrationForm() {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.corporateBlue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.local_gas_station_rounded, color: AppTheme.corporateBlue, size: 30),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _isEditing ? 'Update Plant Information' : 'Register LPG Plant or Firm',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.textPrimary),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Partner with XP Tech to connect with cooking gas consumers.',
                      style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          if (!_isEditing) ...[
            DropdownButtonFormField<String>(
              initialValue: _selectedFacilityType,
              decoration: InputDecoration(
                labelText: 'Facility Type *',
                prefixIcon: const Icon(Icons.business_rounded),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
              items: _facilityTypes
                  .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                  .toList(),
              onChanged: (val) {
                if (val != null) setState(() => _selectedFacilityType = val);
              },
            ),
            const SizedBox(height: 16),
          ],

          TextFormField(
            controller: _nameController,
            decoration: InputDecoration(
              labelText: 'Plant or Business Name *',
              hintText: 'e.g. Apex Energy Gas Plant',
              prefixIcon: const Icon(Icons.storefront_rounded),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            validator: (v) {
              if (v == null || v.trim().length < 2) return 'Enter a valid name (min 2 characters)';
              if (v.trim().length > 120) return 'Name cannot exceed 120 characters';
              return null;
            },
          ),
          const SizedBox(height: 16),

          TextFormField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: 'Customer Support / Orders Phone *',
              hintText: '08012345678 or +2348012345678',
              helperText: 'Nigerian format (e.g. 080... or +234...)',
              prefixIcon: const Icon(Icons.phone_rounded),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Phone number is required';
              final normalized = _normalizePhone(v.trim());
              if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(normalized)) {
                return 'Enter a valid phone number (e.g. 08012345678 or +2348012345678)';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),

          TextFormField(
            controller: _addressController,
            maxLines: 2,
            decoration: InputDecoration(
              labelText: 'Facility Physical Address *',
              hintText: 'Plot 4, Industrial Layout, Off Express Way',
              prefixIcon: const Icon(Icons.place_rounded),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
            validator: (v) {
              if (v == null || v.trim().length < 3) return 'Enter a valid address (min 3 characters)';
              if (v.trim().length > 200) return 'Address cannot exceed 200 characters';
              return null;
            },
          ),
          const SizedBox(height: 16),

          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedState,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'State *',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  items: _kNigerianStates
                      .map((s) => DropdownMenuItem(value: s, child: Text(s, overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: (v) => setState(() => _selectedState = v),
                  validator: (v) => (v == null || v.isEmpty) ? 'Select state' : null,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextFormField(
                  controller: _cityController,
                  decoration: InputDecoration(
                    labelText: 'City / LGA',
                    hintText: 'e.g. Ikeja',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // GPS Coordinates section
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.gps_fixed_rounded, size: 20, color: AppTheme.corporateBlue),
                        SizedBox(width: 8),
                        Text('GPS Coordinates *', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      ],
                    ),
                    TextButton.icon(
                      onPressed: _fetchingLocation ? null : _getCurrentLocation,
                      icon: _fetchingLocation
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.my_location_rounded, size: 16),
                      label: const Text('Auto-Detect GPS'),
                      style: TextButton.styleFrom(foregroundColor: AppTheme.corporateBlue),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Accurate coordinates place your plant on the nearby refill map for users within 10 km.',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _latController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                        decoration: InputDecoration(
                          labelText: 'Latitude',
                          hintText: '6.4520',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: Colors.white,
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _lngController,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                        decoration: InputDecoration(
                          labelText: 'Longitude',
                          hintText: '7.5105',
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                          filled: true,
                          fillColor: Colors.white,
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          // Optional map pin fine-tuning (manual fields above always work too)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _openMapPicker,
              icon: const Icon(Icons.map_rounded),
              label: const Text('Pick on Map'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.corporateBlue,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Submit & Cancel buttons
          Row(
            children: [
              if (_isEditing) ...[
                Expanded(
                  child: OutlinedButton(
                    onPressed: _submitting ? null : () => setState(() => _isEditing = false),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: _submitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.corporateBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : Text(
                          _isEditing ? 'Save Station Changes' : 'Submit for Verification',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
