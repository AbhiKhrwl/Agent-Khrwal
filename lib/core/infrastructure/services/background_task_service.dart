import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(FirstTaskHandler());
}

class FirstTaskHandler extends TaskHandler {
  @override
  Future<void> onDestroy(DateTime timestamp) async {
    debugPrint('🔱 [BackgroundTask] Background service destroyed.');
  }

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter taskStarter) async {
    debugPrint('🔱 [BackgroundTask] Background service started.');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Keep-alive heartbeat
  }
}

/// 🔱 Background Task Service
///
/// Wraps the flutter_foreground_task package to manage the Android Foreground Service
/// as a WakeLock during high-computation local inference or agent tool operations.
class BackgroundTaskService {
  static bool _initialized = false;

  /// Setup the default notification and engine configurations
  static Future<void> init() async {
    if (_initialized) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'apex_engine_channel',
        channelName: 'Agent Kharwal Engine',
        channelDescription: 'Keeps the local intelligence and agent engine running in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    _initialized = true;
  }

  /// Request permissions if they are not already granted
  static Future<void> requestPermissions() async {
    try {
      // 1. Request Notification Permission (Required for Android 13+)
      final notificationPermission = await FlutterForegroundTask.checkNotificationPermission();
      if (notificationPermission != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }

      // 2. Request Battery Optimization Bypass
      final isIgnoringBattery = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (!isIgnoringBattery) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (e) {
      debugPrint('🔱 [BackgroundTaskService] Error requesting permissions: $e');
    }
  }

  /// Start the persistent foreground service with high priority
  static Future<void> start() async {
    try {
      await init();
      await requestPermissions();

      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Agent Kharwal Engine 🔱',
          notificationText: 'Active reasoning and tool execution in progress...',
        );
      } else {
        await FlutterForegroundTask.startService(
          notificationTitle: 'Agent Kharwal Engine 🔱',
          notificationText: 'Active reasoning and tool execution in progress...',
          callback: startCallback,
        );
      }
      debugPrint('🔱 [BackgroundTaskService] Foreground Service started successfully.');
    } catch (e) {
      debugPrint('🔱 [BackgroundTaskService] Failed to start foreground service: $e');
    }
  }

  /// Stop the foreground service cleanly to preserve battery life
  static Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
        debugPrint('🔱 [BackgroundTaskService] Foreground Service stopped cleanly.');
      }
    } catch (e) {
      debugPrint('🔱 [BackgroundTaskService] Failed to stop foreground service: $e');
    }
  }
}
