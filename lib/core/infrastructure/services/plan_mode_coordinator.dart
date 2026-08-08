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
  static String? customSandboxDir;

  String plansDirectory;
  String mailboxDirectory;
  String transcriptFilePath;
  final PlanModeState state = PlanModeState();
  bool _dirsInitialized = false;

  static final PlanModeCoordinator instance = PlanModeCoordinator._internal();

  factory PlanModeCoordinator() {
    return instance;
  }

  PlanModeCoordinator._internal()
      : plansDirectory = '',
        mailboxDirectory = '',
        transcriptFilePath = '';

  PlanModeCoordinator.custom({
    required this.plansDirectory,
    required this.mailboxDirectory,
    required this.transcriptFilePath,
  }) {
    _initDirsSync();
  }

  /// 🔱 Platform-safe lazy init: resolves writable base path on first use.
  /// On Android/iOS, `./` is READ-ONLY — we must use getApplicationDocumentsDirectory.
  /// On desktop/CLI, the relative path works fine.
  Future<void> ensureInitialized() async {
    if (_dirsInitialized) return;

    final basePath = customSandboxDir ?? './apex_sandbox';

    plansDirectory = '$basePath/plans';
    mailboxDirectory = '$basePath/mailboxes';
    transcriptFilePath = '$basePath/transcript.jsonl';

    _initDirsSync();
    _dirsInitialized = true;
  }

  void _initDirsSync() {
    try {
      Directory(plansDirectory).createSync(recursive: true);
      Directory(mailboxDirectory).createSync(recursive: true);
      final transcriptFile = File(transcriptFilePath);
      if (!transcriptFile.existsSync()) {
        transcriptFile.createSync(recursive: true);
      }
    } catch (e) {
      // 🔱 Safety: Don't crash the entire app if sandbox dirs fail.
      // Plan mode features will degrade gracefully.
      print('[PlanModeCoordinator] Warning: Could not init dirs: $e');
    }
  }

  // ==========================================
  // 1. Dynamic Model Selector (Auto-Escalation)
  // ==========================================

  // 🔱 2026 Active and Fallback Models per Provider
  static const List<String> nvidiaModels = [
    'nvidia/llama-3.1-nemotron-70b-instruct',
    'nvidia/llama-3.1-nemotron-51b-instruct',
    'deepseek-ai/deepseek-v4-pro',
    'deepseek-ai/deepseek-v4-flash',
    'qwen/qwen3-coder-480b-a35b-instruct',
    'qwen/qwen3.5-397b-a17b',
    'qwen/qwen3.5-122b-a10b',
    'qwen/qwen3-next-80b-a3b-instruct',
    'google/gemma-4-31b-it',
  ];

  static const List<String> openRouterModels = [
    'google/gemma-4-26b-a4b-it:free',
    'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free',
    'nvidia/nemotron-3-super-120b-a12b:free',
    'nvidia/nemotron-3-nano-30b-a3b:free',
    'google/gemma-4-31b-it:free',
    'deepseek/deepseek-v4-flash:free',
    'qwen/qwen3-coder:free',
    'qwen/qwen3-next-80b-a3b-instruct:free',
  ];

  static const List<String> geminiModels = [
    'gemini-3.1-flash-lite',
    'gemini-3-flash-preview',
    'gemini-2.5-flash',
    'gemini-2.5-flash-lite',
    'gemini-2.0-flash',
    'gemini-2.0-flash-001',
    'gemini-2.0-flash-lite',
    'gemini-2.0-flash-lite-001',
  ];

  static const List<String> groqModels = [
    'llama-3.3-70b-versatile',
    'openai/gpt-oss-120b',
    'qwen/qwen3-32b',
  ];

  static List<String> getProviderModels(String type) {
    switch (type.toLowerCase()) {
      case 'nvidia':
        return nvidiaModels;
      case 'openrouter':
        return openRouterModels;
      case 'gemini':
        return geminiModels;
      case 'groq':
        return groqModels;
      case 'ollama':
        return ['gemma4:e2b', 'gemma:2b', 'llama3', 'mistral'];
      case 'custom':
        return ['custom-model-1', 'custom-model-2'];
      default:
        return [];
    }
  }

  /// Resolves the ordered list of runtime models based on permission mode, token sizes, and provider type.
  List<String> getRuntimeModelList({
    required String mainLoopModel,
    required bool exceeds200kTokens,
    String? providerType,
  }) {
    final pType = providerType?.toLowerCase() ?? 'gemini';

    final List<String> rawCandidates = [];

    if (state.mode == PermissionMode.plan) {
      if (pType == 'nvidia') {
        if (exceeds200kTokens) {
          rawCandidates.addAll([
            'nvidia/llama-3.1-nemotron-70b-instruct',
            ...nvidiaModels.where((m) => m != 'nvidia/llama-3.1-nemotron-70b-instruct'),
          ]);
        } else {
          rawCandidates.addAll(nvidiaModels);
        }
      } else if (pType == 'openrouter') {
        if (exceeds200kTokens) {
          rawCandidates.addAll([
            'nvidia/nemotron-3-super-120b-a12b:free',
            ...openRouterModels.where((m) => m != 'nvidia/nemotron-3-super-120b-a12b:free'),
          ]);
        } else {
          rawCandidates.addAll(openRouterModels);
        }
      } else if (pType == 'gemini') {
        if (exceeds200kTokens) {
          rawCandidates.addAll(['moonshotai/kimi-k2-instruct-0905', ...geminiModels]);
        } else {
          rawCandidates.addAll(geminiModels);
        }
      } else if (pType == 'groq') {
        rawCandidates.addAll(groqModels);
      } else {
        // Ollama or custom: respect the user's main loop model strictly to avoid blind cloud failures
        rawCandidates.add(mainLoopModel);
      }
    } else {
      // In standard mode, start with the configured mainLoopModel,
      // and provide the provider-specific models as robust fallback candidates.
      if (mainLoopModel.trim().isNotEmpty) {
        rawCandidates.add(mainLoopModel);
      }
      List<String> providerList = [];

      if (pType == 'nvidia') {
        providerList = nvidiaModels;
      } else if (pType == 'openrouter') {
        providerList = openRouterModels;
      } else if (pType == 'gemini') {
        providerList = geminiModels;
      } else if (pType == 'groq') {
        providerList = groqModels;
      }

      for (final model in providerList) {
        rawCandidates.add(model);
      }
    }

    // Sanitize candidates list: remove duplicates, trim strings, filter empty names.
    final List<String> sanitizedCandidates = [];
    for (final candidate in rawCandidates) {
      final trimmed = candidate.trim();
      if (trimmed.isNotEmpty && !sanitizedCandidates.contains(trimmed)) {
        sanitizedCandidates.add(trimmed);
      }
    }

    return sanitizedCandidates;
  }

  /// Resolves the optimal runtime model based on permission mode, token sizes, and provider type.
  String getRuntimeModel({
    required String mainLoopModel,
    required bool exceeds200kTokens,
    String? providerType,
  }) {
    final list = getRuntimeModelList(
      mainLoopModel: mainLoopModel,
      exceeds200kTokens: exceeds200kTokens,
      providerType: providerType,
    );
    return list.isNotEmpty ? list.first : mainLoopModel;
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
