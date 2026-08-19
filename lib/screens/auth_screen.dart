import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../theme/theme.dart';

/// Auth screen with Login and Signup tabs.
/// Provides email/password authentication with passwordless email link support.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmPassCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;
  String? _errorMessage;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _confirmPassCtrl.dispose();
    super.dispose();
  }

  Future<void> _handleSignup() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      await AuthService().signUp(
        email: _emailCtrl.text.trim(),
        password: _passCtrl.text,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Account created! Check your email to verify.'),
            backgroundColor: OneDarkColors.green,
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = AuthService.errorMessage(e as Exception));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      await AuthService().signIn(
        email: _emailCtrl.text.trim(),
        password: _passCtrl.text,
      );
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = AuthService.errorMessage(e as Exception));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleForgotPassword() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter your email address first'), backgroundColor: OneDarkColors.red),
      );
      return;
    }
    setState(() { _isLoading = true; _errorMessage = null; });
    try {
      await AuthService().sendPasswordResetEmail(email);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Password reset email sent!'), backgroundColor: OneDarkColors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = AuthService.errorMessage(e as Exception));
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: OneDarkColors.bg,
      appBar: AppBar(
        title: const Text('Sign In', style: TextStyle(color: OneDarkColors.fg)),
        backgroundColor: OneDarkColors.bgDark,
        foregroundColor: OneDarkColors.fg,
        iconTheme: const IconThemeData(color: OneDarkColors.fg),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: OneDarkColors.cyan,
          labelColor: OneDarkColors.cyan,
          unselectedLabelColor: OneDarkColors.fgDim,
          tabs: const [
            Tab(text: 'Sign In'),
            Tab(text: 'Sign Up'),
          ],
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Error message
                if (_errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: OneDarkColors.red.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(_errorMessage!, style: const TextStyle(color: OneDarkColors.red)),
                  ),

                // Email field
                TextFormField(
                  controller: _emailCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    labelStyle: TextStyle(color: OneDarkColors.fgDim),
                    prefixIcon: Icon(Icons.email, color: OneDarkColors.cyan),
                    border: OutlineInputBorder(),
                    enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: OneDarkColors.dim)),
                    focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: OneDarkColors.cyan)),
                  ),
                  style: const TextStyle(color: OneDarkColors.fg),
                  keyboardType: TextInputType.emailAddress,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Enter your email';
                    if (!v.contains('@')) return 'Enter a valid email';
                    return null;
                  },
                ),
                const SizedBox(height: 16),

                // Password field
                TextFormField(
                  controller: _passCtrl,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    labelStyle: const TextStyle(color: OneDarkColors.fgDim),
                    prefixIcon: const Icon(Icons.lock, color: OneDarkColors.cyan),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword ? Icons.visibility_off : Icons.visibility,
                        color: OneDarkColors.fgDim,
                      ),
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                    border: const OutlineInputBorder(),
                    enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: OneDarkColors.dim)),
                    focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: OneDarkColors.cyan)),
                  ),
                  style: const TextStyle(color: OneDarkColors.fg),
                  obscureText: _obscurePassword,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  validator: (v) {
                    if (v == null || v.length < 6) return 'Password must be 6+ characters';
                    return null;
                  },
                ),

                // Confirm password (signup only)
                if (_tabController.index == 1) ...[
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _confirmPassCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Confirm Password',
                      labelStyle: TextStyle(color: OneDarkColors.fgDim),
                      prefixIcon: Icon(Icons.lock_outline, color: OneDarkColors.cyan),
                      border: OutlineInputBorder(),
                      enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: OneDarkColors.dim)),
                      focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: OneDarkColors.cyan)),
                    ),
                    style: const TextStyle(color: OneDarkColors.fg),
                    obscureText: true,
                    validator: (v) {
                      if (v != _passCtrl.text) return 'Passwords do not match';
                      return null;
                    },
                  ),
                ],

                const SizedBox(height: 24),

                // Submit button
                FilledButton(
                  onPressed: _isLoading ? null : (_tabController.index == 0 ? _handleLogin : _handleSignup),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
                  child: _isLoading
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_tabController.index == 0 ? 'Sign In' : 'Create Account'),
                ),

                const SizedBox(height: 16),

                // Forgot password (signin only)
                if (_tabController.index == 0)
                  TextButton(
                    onPressed: _isLoading ? null : _handleForgotPassword,
                    child: const Text('Forgot Password?', style: TextStyle(color: OneDarkColors.cyan)),
                  ),

                const Spacer(),

                // Info text
                Text(
                  'Your data stays on device.\nAuth enables cloud sync and premium features.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: OneDarkColors.fgDim, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
