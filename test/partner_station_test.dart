import 'package:flutter_test/flutter_test.dart';
import 'package:xp_gas_monitor/services/xp_api.dart';

void main() {
  PartnerStation station(String name, {String? phone, bool? isAvailable}) =>
      PartnerStation.fromJson({
        'id': 'r1',
        'name': name,
        if (phone != null) 'phone': phone,
        'latitude': 4.8156,
        'longitude': 7.0498,
        if (isAvailable != null) 'isAvailable': isAvailable,
      });

  group('PartnerStation badges and links (refill card)', () {
    test('facilityBadge derives from the registration suffix', () {
      expect(station('Apex Energy (LPG Refill Plant)').facilityBadge, 'LPG Plant');
      expect(station('Quick Fill (Gas Skid / Mini Station)').facilityBadge, 'Skid');
      expect(station('Depot Nine (Cylinder Depot & Retailer)').facilityBadge, 'Depot');
      expect(station('Door Gas (Doorstep Delivery Provider)').facilityBadge, 'Delivery');
      expect(station('No Suffix Station').facilityBadge, 'Partner');
    });

    test('displayName strips the registration suffix', () {
      expect(station('Apex Energy (LPG Refill Plant)').displayName, 'Apex Energy');
      expect(station('No Suffix Station').displayName, 'No Suffix Station');
    });

    test('isAvailable defaults to true for nearby results', () {
      expect(station('A').isAvailable, isTrue);
      expect(station('A', isAvailable: false).isAvailable, isFalse);
    });

    test('telUrl is null without a phone number', () {
      expect(station('A').telUrl, isNull);
      expect(station('A', phone: '+2348012345678').telUrl.toString(), 'tel:+2348012345678');
    });

    test('directionsUrl points at the station coordinates', () {
      expect(station('A').directionsUrl.toString(),
          'https://www.google.com/maps/search/?api=1&query=4.8156,7.0498');
    });
  });
}
