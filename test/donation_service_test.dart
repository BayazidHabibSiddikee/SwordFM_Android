import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/donation_service.dart';

void main() {
  group('DonationService', () {
    test('bKash number constant is correct', () {
      expect(DonationService.bKashNumber, equals('+8801723977791'));
    });

    test('BNB address constant is correct', () {
      expect(DonationService.bnbAddress, 
          equals('0x1Aeb51EeA471f6B7a826DE01e2c1381b8e618894'));
    });
  });
}
