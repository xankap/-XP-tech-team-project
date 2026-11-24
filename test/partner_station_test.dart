import 'package:flutter_test/flutter_test.dart';
import 'package:xp_gas_monitor/services/xp_api.dart';

void main() {
  PartnerStation station(String name,
          {String? phone,
          bool? isAvailable,
          double? pricePerKg,
          String? logoUrl,
          String? about}) =>
      PartnerStation.fromJson({
        'id': 'r1',
        'name': name,
        if (phone != null) 'phone': phone,
        'latitude': 4.8156,
        'longitude': 7.0498,
        if (isAvailable != null) 'isAvailable': isAvailable,
        if (pricePerKg != null) 'pricePerKg': pricePerKg,
        if (logoUrl != null) 'logoUrl': logoUrl,
        if (about != null) 'about': about,
      });

  group('PartnerStation badges and links (refill card)', () {
    test('facilityBadge derives from the registration suffix', () {
      expect(
          station('Apex Energy (LPG Refill Plant)').facilityBadge, 'LPG Plant');
      expect(station('Quick Fill (Gas Skid / Mini Station)').facilityBadge,
          'Skid');
      expect(station('Depot Nine (Cylinder Depot & Retailer)').facilityBadge,
          'Depot');
      expect(station('Door Gas (Doorstep Delivery Provider)').facilityBadge,
          'Delivery');
      expect(station('No Suffix Station').facilityBadge, 'Partner');
    });

    test('displayName strips the registration suffix', () {
      expect(
          station('Apex Energy (LPG Refill Plant)').displayName, 'Apex Energy');
      expect(station('No Suffix Station').displayName, 'No Suffix Station');
    });

    test('isAvailable defaults to true for nearby results', () {
      expect(station('A').isAvailable, isTrue);
      expect(station('A', isAvailable: false).isAvailable, isFalse);
    });

    test('telUrl is null without a phone number', () {
      expect(station('A').telUrl, isNull);
      expect(station('A', phone: '+2348012345678').telUrl.toString(),
          'tel:+2348012345678');
    });

    test('directionsUrl points at the station coordinates', () {
      expect(station('A').directionsUrl.toString(),
          'https://www.google.com/maps/dir/?api=1&destination=4.8156,7.0498');
    });
  });

  test('price per kg is decoded from the nearby API response', () {
    expect(station('A', pricePerKg: 1400).pricePerKg, 1400);
  });

  test('cylinder refill prices calculate correctly', () {
    final s = station('A', pricePerKg: 1400);
    expect(s.refillCost(6), 8400);
    expect(s.formatRefillPrice(6), '₦8400');
    expect(s.refillCost(12.5), 17500);
    expect(s.formatRefillPrice(12.5), '₦17500');
    expect(s.refillCost(25), 35000);
    expect(s.formatRefillPrice(25), '₦35000');
    expect(s.refillCost(50), 70000);
    expect(s.formatRefillPrice(50), '₦70000');

    final noPrice = station('A');
    expect(noPrice.refillCost(12.5), isNull);
    expect(noPrice.formatRefillPrice(12.5), 'Price on request');
  });

  test('logo and about decode from the nearby API response', () {
    final s = station('A',
        logoUrl: 'https://cdn.example/logo.png', about: 'Family-run plant.');
    expect(s.logoUrl, 'https://cdn.example/logo.png');
    expect(s.about, 'Family-run plant.');
    expect(station('A').logoUrl, isNull);
    expect(station('A').about, isNull);
  });
}
