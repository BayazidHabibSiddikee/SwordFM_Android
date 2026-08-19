import 'package:flutter_test/flutter_test.dart';
import 'package:swordfm/services/auth_service.dart';

void main() {
  group('AuthService', () {
    group('errorMessage', () {
      test('weak-password returns helpful message', () {
        final e = Exception('[firebase_auth/weak-password] The password must be 6 characters long or more.');
        expect(AuthService.errorMessage(e), contains('6'));
      });

      test('email-already-in-use returns helpful message', () {
        final e = Exception('[firebase_auth/email-already-in-use] The account already exists for that email.');
        expect(AuthService.errorMessage(e), contains('already registered'));
      });

      test('wrong-password returns helpful message', () {
        final e = Exception('[firebase_auth/wrong-password] The password is invalid.');
        expect(AuthService.errorMessage(e), contains('Incorrect password'));
      });

      test('user-not-found returns helpful message', () {
        final e = Exception('[firebase_auth/user-not-found] There is no user record.');
        expect(AuthService.errorMessage(e), contains('No account found'));
      });

      test('generic error returns fallback message', () {
        final e = Exception('Some unknown error');
        expect(AuthService.errorMessage(e), contains('Authentication failed'));
      });
    });


  });
}
