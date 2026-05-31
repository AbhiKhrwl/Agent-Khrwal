import 'dart:convert';
import 'dart:io';
import 'dart:math';

enum PermissionMode {
  defaultMode,
  plan,
  acceptEdits,
  bypassPermissions
}

class SemanticPermission {
  final String tool;
  final String prompt;

  SemanticPermission({required this.tool, required this.prompt});
}

class PlanApprovalRequest {
  final String requestId;
  final String fromAgent;
  final String planFilePath;
  final String planContent;
  final String timestamp;

  PlanApprovalRequest({
    required this.requestId,
    required this.fromAgent,
    required this.planFilePath,
    required this.planContent,
    required this.timestamp,
  });

  String toJsonString() {
    return jsonEncode({
      'type': 'plan_approval_request',
      'requestId': requestId,
      'from': fromAgent,
      'planFilePath': planFilePath,
      'planContent': planContent,
      'timestamp': timestamp,
    });
  }
}

class PlanModeState {
  PermissionMode mode;
  PermissionMode? prePlanMode;
  String? planSlug;
  String? planFilePath;
  bool awaitingLeaderApproval = false;
  String? activeRequestId;
  final List<SemanticPermission> allowedPrompts = [];

  PlanModeState({this.mode = PermissionMode.defaultMode});
}

class PlanModeCoordinator {
  final String plansDirectory;
  final String mailboxDirectory;
  final String transcriptFilePath;
  final PlanModeState state = PlanModeState();

  static final PlanModeCoordinator instance = PlanModeCoordinator._internal();

  factory PlanModeCoordinator() {
    return instance;
  }

  PlanModeCoordinator._internal()
      : plansDirectory = './apex_sandbox/plans',
        mailboxDirectory = './apex_sandbox/mailboxes',
        transcriptFilePath = './apex_sandbox/transcript.jsonl' {
    _initDirs();
  }

  PlanModeCoordinator.custom({
    required this.plansDirectory,
    required this.mailboxDirectory,
    required this.transcriptFilePath,
  }) {
    _initDirs();
  }

  void _initDirs() {
    Directory(plansDirectory).createSync(recursive: true);
    Directory(mailboxDirectory).createSync(recursive: true);
    final transcriptFile = File(transcriptFilePath);
    if (!transcriptFile.existsSync()) {
      try {
        transcriptFile.createSync(recursive: true);
      } catch (_) {}
    }
  }

  // ==========================================
  // 1. Dynamic Model Selector (Auto-Escalation)
  // ==========================================

  /// Resolves the optimal runtime model based on permission mode, token sizes, and provider type.
  String getRuntimeModel({
    required String mainLoopModel,
    required bool exceeds200kTokens,
    String? providerType,
  }) {
    if (state.mode == PermissionMode.plan) {
      // 🔱 SMART EFFICIENCY & FREE-FIRST POLICY:
      // If the user's active model contains "free", "8b", "9b", or "gemma2",
      // it means they are intentionally running a highly cost-efficient or free model.
      // We MUST respect their choice and NEVER force-escalate to massive paid/heavy models.
      final lowerModel = mainLoopModel.toLowerCase();
      if (lowerModel.contains('free') || 
          lowerModel.contains('8b') || 
          lowerModel.contains('9b') || 
          lowerModel.contains('gemma-2') || 
          lowerModel.contains('gemma2')) {
        
        final pType = providerType?.toLowerCase() ?? '';
        if (pType == 'openrouter') {
          // If on OpenRouter, return an outstanding free-tier reasoning model
          return exceeds200kTokens 
              ? 'google/gemma-2-27b-it:free' 
              : 'google/gemma-2-9b-it:free';
        }
        // For other providers, respect the exact selected model
        return mainLoopModel;
      }

      final pType = providerType?.toLowerCase() ?? 'gemini'; // Default to gemini for backward-compatibility with tests
      if (pType == 'gemini') {
        if (exceeds200kTokens) {
          return 'moonshotai/kimi-k2-instruct-0905'; // Escalated standard backup model
        }
        return 'gemini-2.5-flash'; // High capability reasoning model
      } else if (pType == 'groq') {
        return 'llama-3.1-8b-instant'; // Ultra fast and cheap 8B model instead of heavy 70B
      } else if (pType == 'nvidia') {
        return exceeds200kTokens ? 'meta/llama-3.1-70b-instruct' : 'meta/llama-3.1-8b-instruct'; // Use highly optimized 8B/70B instead of extremely slow 405B
      } else if (pType == 'openrouter') {
        return exceeds200kTokens ? 'moonshotai/kimi-k2-instruct-0905' : 'google/gemini-2.5-flash';
      } else {
        // For local Ollama or Custom providers, do not auto-escalate to avoid pulling/calling non-existent models.
        return mainLoopModel;
      }
    }
    return mainLoopModel; // Revert to standard model for implementation
  }

  // ==========================================
  // 2. Compaction Plan-Retention Anchors
  // ==========================================

  /// Generates a plan_mode compaction reminder if currently in plan mode.
  /// Re-injects the metadata so the agent stays in plan mode after memory compaction.
  Map<String, dynamic>? buildCompactionReminder(String agentId) {
    if (state.mode != PermissionMode.plan) return null;

    final hasPlanFile = state.planFilePath != null && File(state.planFilePath!).existsSync();

    return {
      'type': 'attachment',
      'subtype': 'plan_mode',
      'reminderType': 'full',
      'planFilePath': state.planFilePath,
      'planExists': hasPlanFile,
      'agentId': agentId,
      'timestamp': DateTime.now().toIso8601String(),
    };
  }

  // ==========================================
  // 3. Swarm-Level Mailbox Approval Loops
  // ==========================================

  /// Submits the plan to the team leader's mailbox and pauses local execution.
  Future<void> submitPlanForApproval({
    required String agentName,
    required String planContent,
  }) async {
    if (state.planFilePath == null) return;

    // Serialize and write plan to local disk first
    File(state.planFilePath!).writeAsStringSync(planContent);
    await snapshotPlan(planContent);

    final requestId = 'req_plan_${Random().nextInt(100000)}';
    final request = PlanApprovalRequest(
      requestId: requestId,
      fromAgent: agentName,
      planFilePath: state.planFilePath!,
      planContent: planContent,
      timestamp: DateTime.now().toIso8601String(),
    );

    // Write to leader's mailbox file
    final mailboxFile = File('$mailboxDirectory/team-lead.json');
    mailboxFile.writeAsStringSync(request.toJsonString());

    state.awaitingLeaderApproval = true;
    state.activeRequestId = requestId;

    print('[Swarm] Submitted plan approval request $requestId to team-lead.');
  }

  /// Polls the mailbox for a decision from the team leader.
  /// If approved, transitions the permission mode and lifts write blocks.
  bool pollMailboxForApproval(String agentName) {
    if (!state.awaitingLeaderApproval) return false;

    final approvalFile = File('$mailboxDirectory/$agentName.json');
    if (!approvalFile.existsSync()) return false;

    try {
      final payload = jsonDecode(approvalFile.readAsStringSync());
      if (payload['type'] == 'plan_approval_response' &&
          payload['requestId'] == state.activeRequestId &&
          payload['status'] == 'approved') {
        
        // Lift restrictions and transition mode
        state.mode = state.prePlanMode ?? PermissionMode.defaultMode;
        state.prePlanMode = null;
        state.awaitingLeaderApproval = false;
        state.activeRequestId = null;

        // Clean mailbox file
        approvalFile.deleteSync();

        print('[Swarm] Plan approved by leader! Transitioned to ${state.mode}. Restrictions lifted.');
        return true;
      }
    } catch (e) {
      print('[Swarm] Error parsing mailbox approval: $e');
    }

    return false;
  }

  // ==========================================
  // 4. File Snapshot Backup & Recovery
  // ==========================================

  /// Writes a file snapshot transaction to the session log transcript.
  Future<void> snapshotPlan(String planContent) async {
    if (state.planFilePath == null) return;

    final snapshotEntry = {
      'type': 'system',
      'subtype': 'file_snapshot',
      'timestamp': DateTime.now().toIso8601String(),
      'snapshotFiles': [
        {
          'key': 'plan',
          'path': state.planFilePath,
          'content': planContent,
          'timestamp': DateTime.now().toIso8601String(),
        }
      ]
    };

    final file = File(transcriptFilePath);
    await file.writeAsString('${jsonEncode(snapshotEntry)}\n', mode: FileMode.append);
    print('[Snapshot] Serialized plan snapshot to transcript.');
  }

  /// Recovers the plan file from log transcripts on session resume.
  Future<bool> recoverPlanFromTranscript(String sessionId) async {
    final file = File(transcriptFilePath);
    if (!file.existsSync()) return false;

    try {
      final lines = await file.readAsLines();
      
      // Scan backward to locate the latest snapshot
      for (int i = lines.length - 1; i >= 0; i--) {
        try {
          final entry = jsonDecode(lines[i]);
          if (entry['type'] == 'system' && entry['subtype'] == 'file_snapshot') {
            final files = entry['snapshotFiles'] as List<dynamic>;
            for (final f in files) {
              if (f['key'] == 'plan') {
                final content = f['content'] as String;
                final path = f['path'] as String;
                
                state.planSlug = sessionId;
                state.planFilePath = path;
                File(path).writeAsStringSync(content);
                
                print('[Recovery] Restored plan file from transcript snapshot.');
                return true;
              }
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
    return false;
  }

  // ==========================================
  // Helper State Initializers
  // ==========================================

  void enterPlanMode(String sessionId) {
    state.prePlanMode = state.mode;
    state.mode = PermissionMode.plan;
    
    state.planSlug = sessionId;
    state.planFilePath = '$plansDirectory/$sessionId.md';
    print('[PlanMode] Enter. Mode = ${state.mode}');
  }

  void exitPlanMode() {
    state.mode = PermissionMode.defaultMode;
    state.prePlanMode = null;
    print('[PlanMode] Exit. Mode = ${state.mode}');
  }

  bool get isPlanModeActive => state.mode == PermissionMode.plan;
}
