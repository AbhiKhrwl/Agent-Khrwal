import 'dart:async';
import 'dart:collection';

class SubagentActivity {
  final String toolName;
  final String description;
  final DateTime timestamp;

  SubagentActivity({
    required this.toolName,
    required this.description,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'toolName': toolName,
        'description': description,
        'timestamp': timestamp.toIso8601String(),
      };
}

class SubagentProgress {
  int toolUseCount = 0;
  int latestInputTokens = 0;
  int cumulativeOutputTokens = 0;
  final Queue<SubagentActivity> recentActivities = Queue<SubagentActivity>();

  int get totalTokens => latestInputTokens + cumulativeOutputTokens;

  /// Adds a tool invocation to the activity queue (capped at 5)
  void logActivity(String toolName, String description) {
    toolUseCount++;
    recentActivities.addLast(SubagentActivity(
      toolName: toolName,
      description: description,
      timestamp: DateTime.now(),
    ));

    if (recentActivities.length > 5) {
      recentActivities.removeFirst();
    }
  }

  /// Updates turn token metrics safely using stateless prefix-caching
  void updateTokens(int input, int output) {
    // Input is cumulative, store latest
    latestInputTokens = input;
    // Output is discrete addition, sum up
    cumulativeOutputTokens += output;
  }

  Map<String, dynamic> toJson() => {
        'toolUseCount': toolUseCount,
        'latestInputTokens': latestInputTokens,
        'cumulativeOutputTokens': cumulativeOutputTokens,
        'totalTokens': totalTokens,
        'recentActivities': recentActivities.map((a) => a.toJson()).toList(),
      };
}

class SwarmCancellationToken {
  final _cancelController = StreamController<void>.broadcast();
  bool _isCancelled = false;

  bool get isCancelled => _isCancelled;
  Stream<void> get onCancelled => _cancelController.stream;

  /// Propagates the cancel state
  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _cancelController.add(null);
    _cancelController.close();
  }

  /// Binds this token as a child. If parent cancels, this token cancels.
  void bindToParent(SwarmCancellationToken parent) {
    if (parent.isCancelled) {
      cancel();
      return;
    }
    parent.onCancelled.listen((_) => cancel());
  }
}

class SubagentTaskSupervisor {
  final String taskId;
  final String description;
  final String agentType;
  final SwarmCancellationToken cancellationToken;
  final SubagentProgress progress = SubagentProgress();
  
  String status = 'running';

  SubagentTaskSupervisor({
    required this.taskId,
    required this.description,
    required this.agentType,
    required this.cancellationToken,
  }) {
    cancellationToken.onCancelled.listen((_) => _handleAbort());
  }

  /// Record turn in the subagent loop and update its progress/telemetry
  void runTurn(String toolName, String toolDesc, int inputTok, int outputTok) {
    if (cancellationToken.isCancelled) return;
    progress.logActivity(toolName, toolDesc);
    progress.updateTokens(inputTok, outputTok);
  }

  void _handleAbort() {
    status = 'killed';
  }

  void complete() {
    if (status == 'running') {
      status = 'completed';
    }
  }

  Map<String, dynamic> toJson() => {
        'taskId': taskId,
        'description': description,
        'agentType': agentType,
        'status': status,
        'progress': progress.toJson(),
      };
}
