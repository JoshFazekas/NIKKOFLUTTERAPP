import 'dart:async';
import 'package:flutter/material.dart';
import '../widgets/debug_overlay.dart';
import '../services/provisioning_service.dart';

class MenuScreen extends StatelessWidget {
  const MenuScreen({super.key});

  void _openDebugLog(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const DebugLogScreen(),
      ),
    );
  }

  void _openActivityLog(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => const ActivityLogScreen(),
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
        child: SafeArea(
          child: Column(
            children: [
              // App Bar with back button
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back, color: Colors.white, size: 28),
                      tooltip: 'Back',
                    ),
                    const SizedBox(width: 8),
                    Image.asset('assets/images/nikko.png', height: 32),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Menu',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              
              const SizedBox(height: 24),
              
              // Menu items
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    // Debug Log Button
                    _MenuButton(
                      icon: Icons.bug_report_outlined,
                      title: 'Debug Log',
                      subtitle: 'View API requests and responses',
                      onTap: () => _openDebugLog(context),
                    ),
                    
                    const SizedBox(height: 16),
                    
                    // Activity Log Button
                    _MenuButton(
                      icon: Icons.history,
                      title: 'Activity Log',
                      subtitle: 'View provisioning history',
                      onTap: () => _openActivityLog(context),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _MenuButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E2D),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF8B5CF6).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  icon,
                  color: const Color(0xFF8B5CF6),
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: Colors.white.withOpacity(0.5),
                size: 24,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ActivityLogScreen extends StatefulWidget {
  const ActivityLogScreen({super.key});

  @override
  State<ActivityLogScreen> createState() => _ActivityLogScreenState();
}

class _ActivityLogScreenState extends State<ActivityLogScreen> {
  final _provisioningService = ProvisioningService();
  List<String> _logMessages = [];
  final ScrollController _scrollController = ScrollController();
  StreamSubscription<String>? _messageSubscription;

  @override
  void initState() {
    super.initState();
    // Load existing log messages from the provisioning service
    _logMessages = List.from(_provisioningService.logMessages);
    _setupListener();
    
    // Scroll to bottom after initial load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients && _logMessages.isNotEmpty) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _messageSubscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _setupListener() {
    // Listen for new messages that come in while this screen is open
    _messageSubscription = _provisioningService.messageStream.listen((message) {
      if (mounted) {
        // Refresh from the service's stored messages to stay in sync
        setState(() {
          _logMessages = List.from(_provisioningService.logMessages);
        });
        // Auto-scroll to bottom
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          }
        });
      }
    });
  }

  void _clearLog() {
    _provisioningService.clearLogMessages();
    setState(() {
      _logMessages.clear();
    });
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
        child: SafeArea(
          child: Column(
            children: [
              // App Bar with back button
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back, color: Colors.white, size: 28),
                      tooltip: 'Back',
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Activity Log',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    if (_logMessages.isNotEmpty)
                      IconButton(
                        onPressed: _clearLog,
                        icon: Icon(
                          Icons.delete_outline,
                          color: Colors.white.withOpacity(0.7),
                          size: 24,
                        ),
                        tooltip: 'Clear Log',
                      ),
                  ],
                ),
              ),
              
              // Activity log content
              Expanded(
                child: _logMessages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.terminal_rounded,
                              size: 64,
                              color: Colors.white.withOpacity(0.3),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'No activity yet',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.6),
                                fontSize: 18,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'TX/RX data will appear here during provisioning',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.4),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      )
                    : Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1E2D),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.1),
                          ),
                        ),
                        child: ListView.builder(
                          controller: _scrollController,
                          itemCount: _logMessages.length,
                          itemBuilder: (context, index) {
                            final message = _logMessages[index];
                            Color textColor = Colors.white.withOpacity(0.7);
                            FontWeight fontWeight = FontWeight.normal;
                            
                            // Highlight TX/RX messages
                            if (message.contains('[TX→]')) {
                              textColor = const Color(0xFF22C55E); // Green for TX
                              fontWeight = FontWeight.w500;
                            } else if (message.contains('[←RX]')) {
                              textColor = const Color(0xFF3B82F6); // Blue for RX
                              fontWeight = FontWeight.w500;
                            } else if (message.contains('Error') || message.contains('ERROR')) {
                              textColor = const Color(0xFFEF4444); // Red for errors
                            } else if (message.contains('✓')) {
                              textColor = const Color(0xFF22C55E); // Green for success
                            } else if (message.contains('---')) {
                              textColor = Colors.white.withOpacity(0.3);
                            }
                            
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Text(
                                message,
                                style: TextStyle(
                                  color: textColor,
                                  fontSize: 11,
                                  fontWeight: fontWeight,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
              
              // Legend at bottom
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildLegendItem('TX', const Color(0xFF22C55E)),
                    const SizedBox(width: 24),
                    _buildLegendItem('RX', const Color(0xFF3B82F6)),
                    const SizedBox(width: 24),
                    _buildLegendItem('Error', const Color(0xFFEF4444)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLegendItem(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withOpacity(0.6),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}
