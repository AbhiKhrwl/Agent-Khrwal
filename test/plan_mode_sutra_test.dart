import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:apex_lite/core/infrastructure/services/plan_mode_coordinator.dart';
import 'package:apex_lite/core/infrastructure/tools/plan_mode_tools.dart';
import 'package:apex_lite/core/infrastructure/router/agent_router.dart';
import 'package:apex_lite/core/infrastructure/security/sentry_purity.dart';
import 'package:apex_lite/core/domain/entities/tool_entities.dart';
import 'package:apex_lite/core/domain/interfaces/i_tool.dart';

// A mock non-readonly tool to test plan mode block constraints
class MockWriteTool implements ITool {
  @override
  String get name => 'mock_write';

  @override
  String get description => 'A mock tool that performs writing/editing operations.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {},
        'required': [],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    return ToolResult(toolUseId: '', content: 'Mock write succeeded!');
  }
}

void main() {
  late PlanModeCoordinator coordinator;
  late AgentRouter router;
  late String testDir;

  setUp(() {
    testDir = './apex_sandbox_test_${DateTime.now().millisecondsSinceEpoch}';
    Directory(testDir).createSync(recursive: true);

    coordinator = PlanModeCoordinator.custom(
      plansDirectory: '$testDir/plans',
      mailboxDirectory: '$testDir/mailboxes',
      transcriptFilePath: '$testDir/transcript.jsonl',
    );

    // Swap the singleton instance properties or create a test environment
    router = AgentRouter(validator: SentryPurity(workingDirectory: testDir));
    router.registerTool(MockWriteTool());
    router.registerTool(EnterPlanModeTool());
    router.registerTool(ExitPlanModeTool());

    // Reset coordinator state
    coordinator.exitPlanMode();
    coordinator.state.awaitingLeaderApproval = false;
    coordinator.state.activeRequestId = null;
  });

  tearDown(() {
    try {
      final dir = Directory(testDir);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    } catch (_) {}
  });

  group('Plan Mode State & Restrictions', () {
    test('Should enter and exit plan mode correctly', () {
      expect(coordinator.isPlanModeActive, isFalse);

      coordinator.enterPlanMode('test_session');
      expect(coordinator.isPlanModeActive, isTrue);
      expect(coordinator.state.planSlug, equals('test_session'));
      expect(coordinator.state.planFilePath, contains('test_session.md'));

      coordinator.exitPlanMode();
      expect(coordinator.isPlanModeActive, isFalse);
    });

    test('Should block non-readonly tools under plan mode in router', () async {
      // Direct execute should succeed when plan mode is off
      PlanModeManager.isPlanModeActive = false;
      final request = ToolRequest(id: 'r1', name: 'mock_write', params: {});
      final resultBefore = await router.executeSingleTool(request);
      expect(resultBefore.isError, isFalse);
      expect(resultBefore.content, equals('Mock write succeeded!'));

      // Enter Plan Mode - should block MockWriteTool
      PlanModeManager.isPlanModeActive = true;
      final resultAfter = await router.executeSingleTool(request);
      expect(resultAfter.isError, isTrue);
      expect(resultAfter.content, contains('Plan Mode Error'));

      // Exit Plan Mode - should succeed again
      PlanModeManager.isPlanModeActive = false;
      final resultFinal = await router.executeSingleTool(request);
      expect(resultFinal.isError, isFalse);
      expect(resultFinal.content, equals('Mock write succeeded!'));
    });
  });

  group('Advanced Blueprint Powers', () {
    test('Dynamic Model Escalation (Auto-Escalation)', () {
      coordinator.exitPlanMode();
      final modelNormal = coordinator.getRuntimeModel(mainLoopModel: 'lite', exceeds200kTokens: false);
      expect(modelNormal, equals('lite'));

      coordinator.enterPlanMode('test_session');
      final modelPlan = coordinator.getRuntimeModel(mainLoopModel: 'lite', exceeds200kTokens: false);
      expect(modelPlan, equals('gemini-2.5-flash')); // Escalates to reasoning model

      final modelUltra = coordinator.getRuntimeModel(mainLoopModel: 'lite', exceeds200kTokens: true);
      expect(modelUltra, equals('moonshotai/kimi-k2-instruct-0905')); // High capacity model
    });

    test('Compaction Plan-Retention Anchors', () {
      coordinator.exitPlanMode();
      expect(coordinator.buildCompactionReminder('agent-01'), isNull);

      coordinator.enterPlanMode('test_session');
      final reminder = coordinator.buildCompactionReminder('agent-01');
      expect(reminder, isNotNull);
      expect(reminder!['subtype'], equals('plan_mode'));
      expect(reminder['agentId'], equals('agent-01'));
    });

    test('Swarm Mailbox Approval Loops', () async {
      coordinator.enterPlanMode('test_session');
      
      const planContent = '# My Implementation Plan\n1. Write files.';
      await coordinator.submitPlanForApproval(agentName: 'teammate-01', planContent: planContent);

      expect(coordinator.state.awaitingLeaderApproval, isTrue);
      expect(coordinator.state.activeRequestId, isNotNull);

      // Verify lead mailbox contains request
      final mailboxFile = File('${coordinator.mailboxDirectory}/team-lead.json');
      expect(mailboxFile.existsSync(), isTrue);
      final json = jsonDecode(mailboxFile.readAsStringSync());
      expect(json['requestId'], equals(coordinator.state.activeRequestId));
      expect(json['from'], equals('teammate-01'));
      expect(json['planContent'], equals(planContent));

      // Simulate team lead writing approval response
      final responseFile = File('${coordinator.mailboxDirectory}/teammate-01.json');
      responseFile.writeAsStringSync(jsonEncode({
        'type': 'plan_approval_response',
        'requestId': coordinator.state.activeRequestId,
        'status': 'approved',
      }));

      // Poll mailbox
      final approved = coordinator.pollMailboxForApproval('teammate-01');
      expect(approved, isTrue);
      expect(coordinator.state.awaitingLeaderApproval, isFalse);
      expect(coordinator.isPlanModeActive, isFalse); // Restrictions lifted
    });

    test('File Snapshot Backup & Recovery', () async {
      coordinator.enterPlanMode('test_session');
      const planContent = '# Safe Plan Snapshot\n- Test recovery.';
      final file = File(coordinator.state.planFilePath!);
      file.writeAsStringSync(planContent);
      await coordinator.snapshotPlan(planContent);

      // Wipe plans directory
      expect(file.existsSync(), isTrue);
      file.deleteSync();
      expect(file.existsSync(), isFalse);

      // Trigger recovery
      final recovered = await coordinator.recoverPlanFromTranscript('test_session');
      expect(recovered, isTrue);
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), equals(planContent));
    });
  });
}
