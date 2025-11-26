import 'package:flutter/material.dart';
import 'dart:convert';
import '../services/api_logger.dart';

class DebugOverlay extends StatelessWidget {
  final Widget child;
  final bool enabled;
  final GlobalKey<NavigatorState> navigatorKey;

  const DebugOverlay({
    super.key,
    required this.child,
    required this.navigatorKey,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;

    return Stack(
      children: [
        child,
        Positioned(
          right: 16,
          bottom: 36,
          child: Material(
            color: Colors.transparent,
            child: FloatingActionButton(
              mini: true,
              heroTag: 'debug_fab',
              backgroundColor: const Color(0xFF8B5CF6),
              onPressed: () => _showDebugLog(),
              child: const Icon(Icons.bug_report, color: Colors.white, size: 20),
            ),
          ),
        ),
      ],
    );
  }

  void _showDebugLog() {
    navigatorKey.currentState?.push(
      MaterialPageRoute(
        builder: (context) => const DebugLogScreen(),
      ),
    );
  }
}

class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  final ApiLogger _logger = ApiLogger();

  @override
  void initState() {
    super.initState();
    _logger.addListener(_onLogUpdate);
  }

  @override
  void dispose() {
    _logger.removeListener(_onLogUpdate);
    super.dispose();
  }

  void _onLogUpdate() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F0F1E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1E2D),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'Debug Log',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.grey),
            onPressed: () {
              _logger.clearLogs();
            },
          ),
        ],
      ),
      body: _logger.logs.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.inbox_outlined,
                    size: 64,
                    color: Colors.grey.shade600,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No data',
                    style: TextStyle(
                      color: Colors.grey.shade500,
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Server communication logs will appear here',
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _logger.logs.length,
              itemBuilder: (context, index) {
                final log = _logger.logs[index];
                return _LogEntryCard(entry: log);
              },
            ),
    );
  }
}

class _LogEntryCard extends StatefulWidget {
  final ApiLogEntry entry;

  const _LogEntryCard({required this.entry});

  @override
  State<_LogEntryCard> createState() => _LogEntryCardState();
}

class _LogEntryCardState extends State<_LogEntryCard> {
  bool _isExpanded = false;

  Color get _typeColor {
    switch (widget.entry.type) {
      case LogType.request:
        return const Color(0xFF3B82F6); // Blue
      case LogType.response:
        return const Color(0xFF10B981); // Green
      case LogType.error:
        return const Color(0xFFEF4444); // Red
    }
  }

  String _formatJson(dynamic data) {
    if (data == null) return 'null';
    try {
      if (data is String) {
        final parsed = jsonDecode(data);
        return const JsonEncoder.withIndent('  ').convert(parsed);
      }
      return const JsonEncoder.withIndent('  ').convert(data);
    } catch (e) {
      return data.toString();
    }
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}.'
        '${time.millisecond.toString().padLeft(3, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A3C),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _typeColor.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _typeColor.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      widget.entry.typeLabel,
                      style: TextStyle(
                        color: _typeColor,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade700,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      widget.entry.method,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (widget.entry.statusCode != null) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: widget.entry.statusCode! >= 200 && widget.entry.statusCode! < 300
                            ? Colors.green.withOpacity(0.2)
                            : Colors.red.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        widget.entry.statusCode.toString(),
                        style: TextStyle(
                          color: widget.entry.statusCode! >= 200 && widget.entry.statusCode! < 300
                              ? Colors.green
                              : Colors.red,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    _formatTime(widget.entry.timestamp),
                    style: TextStyle(
                      color: Colors.grey.shade500,
                      fontSize: 11,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _isExpanded ? Icons.expand_less : Icons.expand_more,
                    color: Colors.grey.shade500,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          // Endpoint
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              widget.entry.endpoint,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
              ),
              maxLines: _isExpanded ? null : 1,
              overflow: _isExpanded ? null : TextOverflow.ellipsis,
            ),
          ),
          // Expanded content
          if (_isExpanded) ...[
            const SizedBox(height: 12),
            const Divider(color: Colors.grey, height: 1),
            if (widget.entry.headers != null) ...[
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Headers',
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E2D),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _formatJson(widget.entry.headers),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (widget.entry.body != null) ...[
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Body',
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E2D),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _formatJson(widget.entry.body),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
