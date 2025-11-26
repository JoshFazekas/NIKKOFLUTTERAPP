import 'package:flutter/material.dart';
import 'screens/sign_in_screen.dart';
import 'widgets/debug_overlay.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // Set to false to hide debug button in production
  static const bool showDebugButton = true;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nikko App',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8B5CF6),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0F0F1E),
      ),
      builder: (context, child) {
        return DebugOverlay(
          enabled: showDebugButton,
          navigatorKey: navigatorKey,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const SignInScreen(),
    );
  }
}
