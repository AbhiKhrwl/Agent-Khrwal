import 'dart:io';
import '../tools/bash_tool.dart';
import '../tools/directory_briefing_tool.dart';
import '../tools/file_read_tool.dart';
import '../tools/file_write_tool.dart';
import '../tools/data_injector_tool.dart';
import '../tools/notification_agent_tool.dart';
import '../tools/voice_munshi_tool.dart';
import '../tools/file_edit_tool.dart';
import '../tools/glob_tool.dart';
import '../tools/grep_tool.dart';
import '../tools/web_search_tool.dart';
import '../tools/web_fetch_tool.dart';
import '../tools/agent_tool.dart';
import '../tools/todo_write_tool.dart';
import '../tools/task_tools.dart';
import '../tools/send_message_tool.dart';
import '../tools/brief_tool.dart';
import '../tools/plan_mode_tools.dart';
import '../tools/ask_user_question_tool.dart';
import '../tools/mcp_tools.dart';
import '../tools/worktree_tools.dart';
import '../tools/cron_tools.dart';
import '../tools/team_tools.dart';
import '../tools/notebook_edit_tool.dart';
import '../tools/skill_tool.dart';
import '../tools/lsp_tool.dart';
import '../tools/config_tool.dart';
import '../tools/sleep_tool.dart';
import '../tools/tool_search_tool.dart';
import '../tools/tool_describe_tool.dart';
import '../tools/tool_call_tool.dart';
import '../tools/rollback_tool.dart';
import '../tools/spectral_ops.dart';
import '../tools/git_tools.dart';
import '../tools/verify_project_tool.dart';
import '../tools/project_mapper_tool.dart';
import '../tools/smart_context_gather_tool.dart';
import '../tools/search_memory_tool.dart';
import 'agent_router.dart';



/// 🔱 Centralized Tool Registry — Single source of truth for all tool registrations.
///
/// Eliminates the DRY violation between `bin/kharwal_cli.dart` and `lib/main.dart`
/// where identical tool registration blocks were copy-pasted.
class ToolRegistry {
  /// Registers ALL native tools into the given [router].
  ///
  /// [sandboxPath] is the working directory for sandboxed file/shell operations.
  /// [spectral] is the SpectralOps instance for shell execution.
  /// [isCli] controls platform-specific tool registration (e.g., DataInjector is macOS-only in CLI).
  static void registerAll(
    AgentRouter router, {
    required String sandboxPath,
    required SpectralOps spectral,
    bool isCli = false,
  }) {
    // ── Core File & Shell Tools ──
    router.registerTool(BashTool(spectral));
    router.registerTool(DirectoryBriefingTool(sandboxPath));
    router.registerTool(FileReadTool(sandboxPath));
    router.registerTool(FileWriteTool(sandboxPath));
    router.registerTool(FileEditTool(sandboxPath));
    router.registerTool(GlobTool(sandboxPath));
    router.registerTool(GrepTool(sandboxPath));

    // DataInjector: macOS-only in CLI, always available in mobile (Flutter handles it)
    if (isCli) {
      if (Platform.isMacOS) {
        router.registerTool(DataInjectorTool(spectral));
      }
    } else {
      router.registerTool(DataInjectorTool(spectral));
    }

    // ── Communication & Notification Tools ──
    router.registerTool(NotificationAgentTool());
    router.registerTool(VoiceMunshiTool());
    router.registerTool(SendMessageTool(sandboxPath));
    router.registerTool(AskUserQuestionTool());

    // ── Web Tools ──
    router.registerTool(WebSearchTool());
    router.registerTool(WebFetchTool());

    // ── Agent & Task Orchestration Tools ──
    router.registerTool(AgentTool(sandboxPath));
    router.registerTool(TodoWriteTool(sandboxPath));
    router.registerTool(TaskCreateTool(sandboxPath));
    router.registerTool(TaskGetTool(sandboxPath));
    router.registerTool(TaskUpdateTool(sandboxPath));
    router.registerTool(TaskListTool(sandboxPath));
    router.registerTool(TaskStopTool(sandboxPath));
    router.registerTool(TaskOutputTool(sandboxPath));
    router.registerTool(BriefTool());

    // ── Plan Mode Tools ──
    router.registerTool(EnterPlanModeTool());
    router.registerTool(ExitPlanModeTool());

    // ── MCP Protocol Tools ──
    router.registerTool(ListMcpResourcesTool());
    router.registerTool(ReadMcpResourceTool());

    // ── Git Worktree Tools ──
    router.registerTool(EnterWorktreeTool(spectral));
    router.registerTool(ExitWorktreeTool(spectral));

    // ── Cron Scheduling Tools ──
    router.registerTool(ScheduleCronTool());
    router.registerTool(CronCreateTool());
    router.registerTool(CronDeleteTool());
    router.registerTool(CronListTool());

    // ── Team / Swarm Tools ──
    router.registerTool(TeamCreateTool(sandboxPath));
    router.registerTool(TeamDeleteTool(sandboxPath));
    router.registerTool(TeamJoinTool(sandboxPath));

    // ── Specialized Tools ──
    router.registerTool(NotebookEditTool(sandboxPath));
    router.registerTool(SkillTool(sandboxPath));
    router.registerTool(LSPTool(sandboxPath));
    router.registerTool(ConfigTool(sandboxPath));
    router.registerTool(SleepTool());
    router.registerTool(SpectralRollbackTool(sandboxPath));

    // ── Progressive Tool Disclosure Bridge Tools ──
    router.registerTool(ToolSearchTool(() => router.registeredTools));
    router.registerTool(ToolDescribeTool(() => router.registeredTools));
    router.registerTool(ToolCallTool((req) => router.executeSingleTool(req)));

    // ── 🔱 MASSIVE UPGRADE: Git-Native Tools ──
    router.registerTool(GitStatusTool(sandboxPath));
    router.registerTool(GitDiffTool(sandboxPath));
    router.registerTool(GitCommitTool(sandboxPath));
    router.registerTool(GitLogTool(sandboxPath));
    router.registerTool(GitCheckoutTool(sandboxPath));

    // ── 🔱 MASSIVE UPGRADE: Auto Verification Tool ──
    router.registerTool(VerifyProjectTool(sandboxPath));

    // ── 🔱 MASSIVE UPGRADE: Codebase Structural Mapper ──
    router.registerTool(ProjectMapperTool(sandboxPath));

    // ── 🔱 MASSIVE UPGRADE: Smart Context Gatherer ──
    router.registerTool(SmartContextGatherTool(sandboxPath));

    // ── 🔱 MASSIVE UPGRADE: Long-Term Memory Searcher ──
    router.registerTool(SearchMemoryTool(sandboxPath));



    // ── Dynamic MCP Tools from Registry ──
    for (final toolDef in McpRegistry.mcpTools.values) {
      router.registerTool(McpToolAdapter(toolDef));
    }
  }
}
