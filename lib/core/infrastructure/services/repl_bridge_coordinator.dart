import 'dart:async';
import 'dart:math';

class RegistrationResult {
  final String environmentId;
  final String environmentSecret;

  RegistrationResult({required this.environmentId, required this.environmentSecret});
}

class SessionSyncBridge {
  final String baseUrl;
  final String dir;
  final String machineName;
  
  String? _environmentId;
  // ignore: unused_field
  String? _environmentSecret;
  String? _currentSessionId;
  int _lastTransportSequenceNum = 0;
  bool _isConnecting = false;

  // Polling Backoff Constants
  static const int initialDelayMs = 2000;
  static const int maxDelayMs = 60000;
  static const int giveUpMs = 15 * 60 * 1000; // 15 Minutes

  SessionSyncBridge({
    required this.baseUrl,
    required this.dir,
    required this.machineName,
  });

  String? get environmentId => _environmentId;
  String? get sessionId => _currentSessionId;
  int get lastSequenceNum => _lastTransportSequenceNum;

  /// Simulates registering the local environment with the server gateway.
  Future<RegistrationResult> registerEnvironment({String? reuseId}) async {
    await Future.delayed(const Duration(milliseconds: 600));
    final envId = reuseId ?? 'env_${Random().nextInt(100000)}';
    final envSecret = 'sec_${Random().nextInt(100000)}';
    
    _environmentId = envId;
    _environmentSecret = envSecret;
    
    return RegistrationResult(environmentId: envId, environmentSecret: envSecret);
  }

  /// Simulates spawning a remote control session.
  Future<String> createSession(String envId, String title) async {
    await Future.delayed(const Duration(milliseconds: 500));
    final sessId = 'sess_${Random().nextInt(100000)}';
    _currentSessionId = sessId;
    
    _lastTransportSequenceNum = 0;
    return sessId;
  }

  /// Simulates reconnecting an existing session in-place.
  Future<bool> tryReconnectSession(String envId, String sessId) async {
    await Future.delayed(const Duration(milliseconds: 400));
    final success = Random().nextDouble() > 0.2;
    if (success) {
      _currentSessionId = sessId;
    }
    return success;
  }

  /// Starts the background poll loop with exponential backoff for error recovery.
  Future<void> startWorkPollLoop(void Function(Map<String, dynamic> workItem) onWorkReceived) async {
    if (_isConnecting) return;
    _isConnecting = true;

    int currentDelayMs = initialDelayMs;
    final stopwatch = Stopwatch()..start();

    // Run in a separate background microtask/future loop
    unawaited(() async {
      while (_isConnecting) {
        try {
          // Simulate a poll request
          final result = await _simulatePollRequest();
          
          if (result['status'] == 'success') {
            currentDelayMs = initialDelayMs;
            stopwatch.reset();
            
            if (result.containsKey('work')) {
              final work = result['work'] as Map<String, dynamic>;
              onWorkReceived(work);
              
              if (work.containsKey('sequenceNum')) {
                _lastTransportSequenceNum = work['sequenceNum'] as int;
              }
            }
          } else {
            throw Exception('Server returned error response');
          }
        } catch (e) {
          if (stopwatch.elapsedMilliseconds > giveUpMs) {
            _isConnecting = false;
            break;
          }
          await Future.delayed(Duration(milliseconds: currentDelayMs));
          currentDelayMs = min(currentDelayMs * 2, maxDelayMs);
        }
        
        await Future.delayed(const Duration(seconds: 10));
      }
    }());
  }

  /// Stop the background polling loop.
  void stop() {
    _isConnecting = false;
  }

  Future<Map<String, dynamic>> _simulatePollRequest() async {
    await Future.delayed(const Duration(milliseconds: 300));
    
    if (Random().nextDouble() < 0.05) {
      throw Exception('Connection timeout');
    }

    if (Random().nextDouble() < 0.1) {
      return {
        'status': 'success',
        'work': {
          'workId': 'work_${Random().nextInt(1000)}',
          'ingressToken': 'jwt_token_sample',
          'sequenceNum': _lastTransportSequenceNum + 1,
          'message': 'ping'
        }
      };
    }

    return {'status': 'success'};
  }
}
