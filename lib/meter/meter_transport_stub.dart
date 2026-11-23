// Web build: no classic Bluetooth.
import 'meter_transport.dart';

MeterTransport createTransport() => const UnsupportedMeterTransport();
MeterPermissions createPermissions() => const AlwaysGrantedPermissions();
