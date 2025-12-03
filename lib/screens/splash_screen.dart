import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/auth_state.dart';
import 'home_screen.dart';
import 'sign_in_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  final AuthState _authState = AuthState();
  final AuthService _authService = AuthService();

  @override
  void initState() {
    super.initState();
    _checkAuthStatus();
  }

  Future<void> _checkAuthStatus() async {
    // Small delay to show splash screen
    await Future.delayed(const Duration(milliseconds: 500));

    // Check if we have stored credentials
    final hasCredentials = await _authState.loadStoredCredentials();

    if (!hasCredentials) {
      // No stored credentials, go to sign in
      _navigateToSignIn();
      return;
    }

    // We have stored credentials, validate the token
    final token = _authState.token;
    if (token != null) {
      final isValid = await _authService.validateToken(token);

      if (isValid) {
        // Token is still valid, go to home
        _navigateToHome();
      } else {
        // Token expired, try to re-authenticate with stored credentials
        await _tryReAuthenticate();
      }
    } else {
      _navigateToSignIn();
    }
  }

  Future<void> _tryReAuthenticate() async {
    final email = _authState.email;
    final password = _authState.password;

    if (email == null || password == null) {
      _navigateToSignIn();
      return;
    }

    try {
      // Try to get a new token with stored credentials
      final result = await _authService.authenticate(email, password);

      final token = result['token'] as String;
      final refreshToken = result['refreshToken'] as String;
      final userId = result['id'] as int;

      // Update the token
      await _authState.updateToken(
        token: token,
        refreshToken: refreshToken,
        userId: userId,
      );

      _navigateToHome();
    } catch (e) {
      // Re-authentication failed, show session expired dialog
      if (mounted) {
        _showSessionExpiredDialog();
      }
    }
  }

  void _navigateToSignIn() {
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const SignInScreen()),
      );
    }
  }

  void _navigateToHome() {
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const HomeScreen()),
      );
    }
  }

  void _showSessionExpiredDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2D),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.timer_off_outlined, color: Color(0xFFEF4444), size: 28),
            SizedBox(width: 12),
            Text(
              'Session Timed Out',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Text(
          'Please sign in again to restore your session.',
          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              // Clear stored credentials and navigate to sign in
              await _authState.logout();
              if (mounted) {
                Navigator.of(context).pop();
                _navigateToSignIn();
              }
            },
            style: TextButton.styleFrom(
              backgroundColor: const Color(0xFF8B5CF6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            child: const Text(
              'Sign Out',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF1A1A2E), Color(0xFF0F0F1E), Color(0xFF0A0A14)],
          ),
        ),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // App logo/icon
              Image(
                image: AssetImage('assets/images/nikko.png'),
                width: 80,
                height: 80,
              ),
              SizedBox(height: 24),
              Text(
                'Nikko App',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 48),
              CircularProgressIndicator(color: Color(0xFF8B5CF6)),
            ],
          ),
        ),
      ),
    );
  }
}
