import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Manages user entitlements stored in Firestore.
///
/// The entitlement document lives at `users/{uid}` with fields:
///   - entitlement: "free" | "premium"
///   - source: "manual" | "billing" | "donation"
///   - activatedAt: Timestamp
///
/// Usage:
///   final service = EntitlementService();
///   await service.loadEntitlement(userId);
///   if (service.entitlement == Entitlement.premium) { /* unlock */ }
class EntitlementService extends ChangeNotifier {
  static const String _collection = 'users';
  static const String _fieldEntitlement = 'entitlement';
  static const String _fieldSource = 'source';
  static const String _fieldActivated = 'activatedAt';

  Entitlement _entitlement = Entitlement.free;
  String? _source;
  bool _loading = true;

  Entitlement get entitlement => _entitlement;
  String? get source => _source;
  bool get isLoading => _loading;
  bool get isPremium => _entitlement == Entitlement.premium;

  /// Loads the user's entitlement from Firestore.
  /// Call this after each signIn/signUp.
  Future<void> loadEntitlement(String uid) async {
    _loading = true;
    notifyListeners();
    try {
      final doc = await FirebaseFirestore.instance
          .collection(_collection)
          .doc(uid)
          .get();
      if (doc.exists) {
        final data = doc.data()!;
        _entitlement = data[_fieldEntitlement] == 'premium'
            ? Entitlement.premium
            : Entitlement.free;
        _source = data[_fieldSource] as String? ?? 'none';
      } else {
        _entitlement = Entitlement.free;
        _source = null;
      }
    } catch (e) {
      // If Firestore is not configured yet, default to free
      debugPrint('EntitlementService load error: $e');
      _entitlement = Entitlement.free;
      _source = null;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Upgrades a user to premium. Called after successful donation or billing.
  /// This writes to Firestore — the single source of truth for entitlements.
  Future<void> upgradeToPremium(String uid, {String source = 'manual'}) async {
    await FirebaseFirestore.instance.collection(_collection).doc(uid).set({
      _fieldEntitlement: 'premium',
      _fieldSource: source,
      _fieldActivated: FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    _entitlement = Entitlement.premium;
    _source = source;
    notifyListeners();
  }

  /// Resets entitlement to free (e.g., account deletion or refund).
  Future<void> downgradeToFree(String uid) async {
    await FirebaseFirestore.instance.collection(_collection).doc(uid).set({
      _fieldEntitlement: 'free',
      _fieldSource: FieldValue.delete(),
      _fieldActivated: FieldValue.delete(),
    }, SetOptions(merge: true));
    _entitlement = Entitlement.free;
    _source = null;
    notifyListeners();
  }
}

enum Entitlement { free, premium }
