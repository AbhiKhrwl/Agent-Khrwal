import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import '../services/id_service.dart';
import '../security/path_jailer.dart';
import 'agent_tool.dart'; // To interface with active subagents registry

/// Helper class for accessing shared task records in the sandbox.
class TaskStoreHelper {
  static Map<String, Map<String, dynamic>> readTasks(String sandboxRoot) {
    try {
      final file = File(p.join(sandboxRoot, '.apex_tasks.json'));
      if (!file.existsSync()) return {};
      final text = file.readAsStringSync();
      if (text.isEmpty) return {};
      return Map<String, Map<String, dynamic>>.from(jsonDecode(text));
    } catch (_) {
      return {};
    }
  }

  static void writeTasks(String sandboxRoot, Map<String, Map<String, dynamic>> tasks) {
    try {
      final file = File(p.join(sandboxRoot, '.apex_tasks.json'));
      file.writeAsStringSync(jsonEncode(tasks), flush: true);
    } catch (_) {}
  }
}

/// CRUD Tool: Creates a background/loop task.
class TaskCreateTool implements ITool {
  final String sandboxRoot;

  TaskCreateTool(this.sandboxRoot);

  @override
  String get name => 'task_create';

  @override
  String get description => 'Creates a new structured session/background task profile.';

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'title': {'type': 'string', 'description': 'Task title.'},
          'description': {'type': 'string', 'description': 'Detailed task description.'},
          'status': {
            'type': 'string',
            'description': 'Initial status: "todo", "in_progress", or "done".'
          },
          'priority': {
            'type': 'string',
            'description': 'Task priority: "high", "medium", or "low".'
          },
        },
        'required': ['title'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final title = params['title'] as String? ?? '';
      if (title.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "title" is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final description = params['description'] as String? ?? '';
      final status = params['status'] as String? ?? 'todo';
      final priority = params['priority'] as String? ?? 'medium';

      final taskId = 'task_${IdService.generate().substring(0, 8)}';
      final tasks = TaskStoreHelper.readTasks(sandboxRoot);

      final taskMeta = {
        'agentId': taskId,
        'name': title,
        'description': description,
        'prompt': description,
        'subagent_type': 'task',
        'status': status,
        'priority': priority,
        'outputFile': '.apex_task_$taskId.txt',
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      };

      tasks[taskId] = taskMeta;
      TaskStoreHelper.writeTasks(sandboxRoot, tasks);

      // Initialize status output file
      final file = File(p.join(sandboxRoot, '.apex_task_$taskId.txt'));
      await file.writeAsString(
          'Task: $title\n'
          'Status: ${status.toUpperCase()}\n'
          'Priority: ${priority.toUpperCase()}\n'
          'Description: $description\n',
          flush: true);

      return ToolResult(
        toolUseId: '',
        content: jsonEncode({
          'taskId': taskId,
          'title': title,
          'status': status,
        }),
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'TaskCreate Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}

/// CRUD Tool: Retrieves a specific task details.
class TaskGetTool implements ITool {
  final String sandboxRoot;

  TaskGetTool(this.sandboxRoot);

  @override
  String get name => 'task_get';

  @override
  String get description => 'Retrieves status and metadata details of a specific task.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'taskId': {'type': 'string', 'description': 'The unique ID of the task to fetch.'},
        },
        'required': ['taskId'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final taskId = params['taskId'] as String? ?? '';
      if (taskId.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "taskId" is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final tasks = TaskStoreHelper.readTasks(sandboxRoot);
      final task = tasks[taskId];

      if (task == null) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Task "$taskId" not found.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      return ToolResult(
        toolUseId: '',
        content: jsonEncode({'task': task}),
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'TaskGet Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}

/// CRUD Tool: Updates task status and metadata.
class TaskUpdateTool implements ITool {
  final String sandboxRoot;

  TaskUpdateTool(this.sandboxRoot);

  @override
  String get name => 'task_update';

  @override
  String get description => 'Updates the status, description, or priority of a task.';

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'taskId': {'type': 'string', 'description': 'Unique task ID.'},
          'title': {'type': 'string', 'description': 'Updated title.'},
          'description': {'type': 'string', 'description': 'Updated description.'},
          'status': {'type': 'string', 'description': 'New status: "todo", "in_progress", or "done".'},
          'priority': {'type': 'string', 'description': 'New priority: "high", "medium", or "low".'},
        },
        'required': ['taskId'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final taskId = params['taskId'] as String? ?? '';
      if (taskId.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "taskId" is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final tasks = TaskStoreHelper.readTasks(sandboxRoot);
      final task = tasks[taskId];

      if (task == null) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Task "$taskId" not found.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      if (params.containsKey('title')) task['name'] = params['title'];
      if (params.containsKey('description')) task['description'] = params['description'];
      if (params.containsKey('status')) task['status'] = params['status'];
      if (params.containsKey('priority')) task['priority'] = params['priority'];

      task['updated_at'] = DateTime.now().toIso8601String();
      tasks[taskId] = task;
      TaskStoreHelper.writeTasks(sandboxRoot, tasks);

      // Append status update to task log file
      final file = File(p.join(sandboxRoot, '.apex_task_$taskId.txt'));
      if (file.existsSync()) {
        await file.writeAsString(
            '\n---\nUpdate Time: ${task['updated_at']}\nStatus Changed: ${task['status']?.toString().toUpperCase()}\n',
            mode: FileMode.append,
            flush: true);
      }

      return ToolResult(
        toolUseId: '',
        content: 'Task "$taskId" updated successfully.',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'TaskUpdate Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}

/// CRUD Tool: Lists session tasks with filters.
class TaskListTool implements ITool {
  final String sandboxRoot;

  TaskListTool(this.sandboxRoot);

  @override
  String get name => 'task_list';

  @override
  String get description => 'Lists all tasks inside the session with filters for status or priority.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'status': {'type': 'string', 'description': 'Filter by status ("todo", "in_progress", "done").'},
          'priority': {'type': 'string', 'description': 'Filter by priority ("high", "medium", "low").'},
        },
        'required': [],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final filterStatus = params['status'] as String? ?? '';
      final filterPriority = params['priority'] as String? ?? '';

      final tasks = TaskStoreHelper.readTasks(sandboxRoot);
      final List<Map<String, dynamic>> matchingTasks = [];

      for (final t in tasks.values) {
        if (filterStatus.isNotEmpty && t['status']?.toString() != filterStatus) continue;
        if (filterPriority.isNotEmpty && t['priority']?.toString() != filterPriority) continue;
        matchingTasks.add(t);
      }

      return ToolResult(
        toolUseId: '',
        content: jsonEncode({
          'tasks': matchingTasks,
          'total': matchingTasks.length,
        }),
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'TaskList Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}

/// CRUD Tool: Stops/Kills a background running agent/task.
class TaskStopTool implements ITool {
  final String sandboxRoot;

  TaskStopTool(this.sandboxRoot);

  @override
  String get name => 'task_stop';

  @override
  String get description => 'Stops or terminates a currently running background agent task.';

  @override
  bool get isConcurrencySafe => false;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'taskId': {'type': 'string', 'description': 'The target task/agent ID to stop.'},
        },
        'required': ['taskId'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final taskId = params['taskId'] as String? ?? '';
      if (taskId.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "taskId" is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final tasks = TaskStoreHelper.readTasks(sandboxRoot);
      final task = tasks[taskId];

      if (task == null) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Task "$taskId" not found.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      task['status'] = 'stopped';
      task['updated_at'] = DateTime.now().toIso8601String();
      tasks[taskId] = task;
      TaskStoreHelper.writeTasks(sandboxRoot, tasks);

      // Stop active sub-agent logic if registered in registry
      SubAgentRegistry.activeAgents[taskId]?['status'] = 'stopped';

      // Cascade cancellation to the active subagent supervisor cancellation token!
      final supervisor = AgentTool.supervisors[taskId];
      if (supervisor != null) {
        supervisor.cancellationToken.cancel();
      }

      // Log the stop event
      final file = File(p.join(sandboxRoot, '.apex_task_$taskId.txt'));
      if (file.existsSync()) {
        await file.writeAsString(
            '\n---\nTerminated Time: ${task['updated_at']}\nStatus: STOPPED (Manually terminated by coordinator).\n',
            mode: FileMode.append,
            flush: true);
      }

      return ToolResult(
        toolUseId: '',
        content: 'Task "$taskId" has been successfully stopped.',
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'TaskStop Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}

/// CRUD Tool: Reads current output of a background task.
class TaskOutputTool implements ITool {
  final String sandboxRoot;
  final PathJailer _jailer;

  TaskOutputTool(this.sandboxRoot) : _jailer = PathJailer(sandboxRoot: sandboxRoot);

  @override
  String get name => 'task_output';

  @override
  String get description => 'Reads the current generated log/output file content of a background task.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'taskId': {'type': 'string', 'description': 'The target task/agent ID.'},
        },
        'required': ['taskId'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    try {
      final taskId = params['taskId'] as String? ?? '';
      if (taskId.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "taskId" is required.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final tasks = TaskStoreHelper.readTasks(sandboxRoot);
      final task = tasks[taskId];

      if (task == null) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Task "$taskId" not found.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }

      final relPath = task['outputFile'] as String? ?? '.apex_task_$taskId.txt';
      if (!_jailer.isPathSafe(relPath)) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: Task output path escapes sandbox.',
          isError: true,
          errorType: ToolErrorType.security,
        );
      }

      final fullPath = p.join(sandboxRoot, relPath);
      final file = File(fullPath);
      if (!file.existsSync()) {
        return ToolResult(
          toolUseId: '',
          content: 'Task output file does not exist yet.',
        );
      }

      final logText = await file.readAsString();

      final supervisor = AgentTool.supervisors[taskId];
      final Map<String, dynamic> responsePayload = {
        'content': logText,
        'status': task['status'],
      };
      if (supervisor != null) {
        responsePayload['supervisor'] = supervisor.toJson();
      }

      return ToolResult(
        toolUseId: '',
        content: jsonEncode(responsePayload),
      );
    } catch (e) {
      return ToolResult(
        toolUseId: '',
        content: 'TaskOutput Error: $e',
        isError: true,
        errorType: ToolErrorType.execution,
      );
    }
  }
}
