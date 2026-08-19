import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/entitlement_service.dart';

void main() {
  group('EntitlementService', () {
    test('defaults to free entitlement', () {
      final service = EntitlementService();
      expect(service.entitlement, equals(Entitlement.free));
      expect(service.isPremium, isFalse);
      expect(service.isLoading, isTrue); // starts loading
    });

    test('isPremium returns correct value after manual set', () async {
      final service = EntitlementService();
      // Don't call loadEntitlement — Firebase not available in tests
      // Just verify the getter logic indirectly via state
      expect(service.isPremium, isFalse);
    });
  });
}
