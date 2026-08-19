import 'package:firebase_auth/firebase_auth.dart' as fa;

/// Wraps firebase_auth to provide a clean service interface for the app.
/// Handles signup, signin, signout, password reset, email verification, and
/// account management.
class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  fa.FirebaseAuth get _auth => fa.FirebaseAuth.instance;

  /// Stream of the current auth state (null = not signed in).
  Stream<fa.User?> get authStateChanges => _auth.authStateChanges();

  /// Current user, or null if not signed in.
  fa.User? get currentUser => _auth.currentUser;

  /// Whether the current user has verified their email address.
  bool get isEmailVerified => currentUser?.emailVerified ?? false;

  /// Returns true if the user is signed in AND has verified their email.
  bool get isAuthenticated =>
      currentUser != null && currentUser!.emailVerified;

  // ─── Sign Up ────────────────────────────────────────────────────────────────

  /// Creates a new account with [email] and [password].
  /// Sends a verification email automatically.
  Future<fa.UserCredential> signUp({
    required String email,
    required String password,
  }) async {
    _validateInput(email, password);
    return await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
  }

  // ─── Sign In ────────────────────────────────────────────────────────────────

  /// Signs in with [email] and [password].
  Future<fa.UserCredential> signIn({
    required String email,
    required String password,
  }) async {
    _validateInput(email, password);
    return await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
  }

  // ─── Sign Out ───────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    await _auth.signOut();
  }

  // ─── Password Reset ─────────────────────────────────────────────────────────

  /// Sends a password reset email to [email].
  Future<void> sendPasswordResetEmail(String email) async {
    await _auth.sendPasswordResetEmail(email: email);
  }

  // ─── Email Verification ─────────────────────────────────────────────────────

  /// Sends a verification email to the currently signed-in user.
  Future<void> sendEmailVerification() async {
    final user = _auth.currentUser;
    if (user != null) {
      await user.sendEmailVerification();
    }
  }

  /// Refreshes the user's metadata (e.g. emailVerified flag).
  /// Call this after the user verifies their email via the link.
  Future<void> reloadUser() async {
    final user = _auth.currentUser;
    if (user != null) {
      await user.reload();
    }
  }

  // ─── Account Updates ────────────────────────────────────────────────────────

  /// Updates the account password.
  Future<void> updatePassword(String newPassword) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('No user signed in');
    if (newPassword.length < 6) {
      throw Exception('Password must be at least 6 characters');
    }
    await user.updatePassword(newPassword);
  }

  /// Deletes the current account. Signs out afterward.
  Future<void> deleteAccount() async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('No user signed in');
    await user.delete();
  }

  // ─── Helpers ────────────────────────────────────────────────────────────────

  static void _validateInput(String email, String password) {
    _validateEmail(email);
    if (password.length < 6) {
      throw ArgumentError('Password must be at least 6 characters');
    }
  }

  static void _validateEmail(String email) {
    if (email.isEmpty || !email.contains('@')) {
      throw ArgumentError('Please enter a valid email address');
    }
  }

  /// Converts a Firebase auth exception into a user-friendly message.
  static String errorMessage(Exception e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('weak-password')) return 'Password should be at least 6 characters';
    if (msg.contains('email-already-in-use')) return 'This email is already registered';
    if (msg.contains('invalid-email')) return 'Please enter a valid email address';
    if (msg.contains('user-not-found')) return 'No account found with this email';
    if (msg.contains('wrong-password')) return 'Incorrect password';
    if (msg.contains('invalid-credential') || msg.contains('user-disabled')) {
      return 'This account has been disabled';
    }
    if (msg.contains('too-many-requests')) return 'Too many attempts. Please try again later';
    if (msg.contains('network-request-failed')) return 'Network error. Check your connection';
    return 'Authentication failed. Please try again';
  }
}
