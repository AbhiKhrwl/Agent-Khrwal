import 'dart:async';
import 'dart:convert';
import '../../domain/interfaces/i_tool.dart';
import '../../domain/entities/tool_entities.dart';
import 'spectral_ops.dart';

class CronJob {
  final String id;
  final String schedule;
  final String command;
  final String description;
  final DateTime createdAt;

  CronJob({
    required this.id,
    required this.schedule,
    required this.command,
    required this.description,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'schedule': schedule,
        'command': command,
        'description': description,
        'createdAt': createdAt.toIso8601String(),
      };
}

class CronRegistry {
  static final List<CronJob> _jobs = [];
  static SpectralOps? _spectral;
  static Timer? _timer;

  static void init(SpectralOps spectral) {
    _spectral = spectral;
    _timer?.cancel();
    
    // Check cron jobs once a minute
    _timer = Timer.periodic(const Duration(minutes: 1), (timer) {
      final now = DateTime.now();
      for (final job in _jobs) {
        if (_matches(now, job.schedule)) {
          _executeJob(job);
        }
      }
    });
  }

  static void addJob(CronJob job) {
    _jobs.add(job);
  }

  static bool removeJob(String id) {
    final before = _jobs.length;
    _jobs.removeWhere((job) => job.id == id);
    return _jobs.length < before;
  }

  static List<CronJob> get jobs => List.unmodifiable(_jobs);

  static bool _matchesField(String field, int currentValue) {
    if (field == '*') return true;
    final parts = field.split(',');
    for (final part in parts) {
      if (part.contains('/')) {
        final subparts = part.split('/');
        final step = int.tryParse(subparts[1]) ?? 1;
        if (subparts[0] == '*' || subparts[0] == '') {
          if (currentValue % step == 0) return true;
        } else {
          final start = int.tryParse(subparts[0]) ?? 0;
          if (currentValue >= start && (currentValue - start) % step == 0) return true;
        }
      } else if (part.contains('-')) {
        final subparts = part.split('-');
        final start = int.tryParse(subparts[0]) ?? 0;
        final end = int.tryParse(subparts[1]) ?? 0;
        if (currentValue >= start && currentValue <= end) return true;
      } else {
        final val = int.tryParse(part);
        if (val == currentValue) return true;
      }
    }
    return false;
  }

  static bool _matches(DateTime time, String cronExpr) {
    final fields = cronExpr.trim().split(RegExp(r'\s+'));
    if (fields.length < 5) return false;

    final m = _matchesField(fields[0], time.minute);
    final h = _matchesField(fields[1], time.hour);
    final dom = _matchesField(fields[2], time.day);
    final mon = _matchesField(fields[3], time.month);
    
    // Dart: weekday is 1 (Mon) - 7 (Sun). Cron: 0 (Sun) - 6 (Sat)
    final cronDow = time.weekday == 7 ? 0 : time.weekday;
    final dow = _matchesField(fields[4], cronDow);

    return m && h && dom && mon && dow;
  }

  static void _executeJob(CronJob job) async {
    if (_spectral == null) return;
    print('[CRON TRIGGERED] Running job ${job.id}: ${job.command}');
    try {
      final result = await _spectral!.execute(job.command);
      print('[CRON COMPLETED] Job ${job.id} exited with code ${result.exitCode}. Result length: ${result.content.length}');
    } catch (e) {
      print('[CRON ERROR] Job ${job.id} failed: $e');
    }
  }
}

/// Generic ScheduleCronTool to coordinate general cron actions
class ScheduleCronTool implements ITool {
  @override
  String get name => 'schedule_cron';

  @override
  String get description =>
      'Coordinates general cron scheduled tasks. Use this or specific cron_create, cron_delete, cron_list tools.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'description': 'Action to perform: create, delete, or list',
          },
          'cronId': {
            'type': 'string',
            'description': 'Required for delete action.',
          },
          'schedule': {
            'type': 'string',
            'description': 'Required for create action (e.g. */5 * * * *).',
          },
          'command': {
            'type': 'string',
            'description': 'Required for create action (e.g. ls).',
          },
          'description': {
            'type': 'string',
            'description': 'Optional for create action.',
          },
        },
        'required': ['action'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    final action = params['action'] as String? ?? '';
    if (action == 'create') {
      final schedule = params['schedule'] as String? ?? '';
      final command = params['command'] as String? ?? '';
      final desc = params['description'] as String? ?? '';
      if (schedule.isEmpty || command.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "schedule" and "command" are required to create a cron job.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }
      final jobId = 'cron_${DateTime.now().millisecondsSinceEpoch}';
      final job = CronJob(
        id: jobId,
        schedule: schedule,
        command: command,
        description: desc,
        createdAt: DateTime.now(),
      );
      CronRegistry.addJob(job);
      return ToolResult(
        toolUseId: '',
        content: 'Created cron job $jobId scheduled as "$schedule" running command "$command".',
      );
    } else if (action == 'delete') {
      final cronId = params['cronId'] as String? ?? '';
      if (cronId.isEmpty) {
        return ToolResult(
          toolUseId: '',
          content: 'Error: "cronId" is required to delete a cron job.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }
      final removed = CronRegistry.removeJob(cronId);
      if (removed) {
        return ToolResult(
          toolUseId: '',
          content: 'Deleted cron job $cronId.',
        );
      } else {
        return ToolResult(
          toolUseId: '',
          content: 'Cron job $cronId not found.',
          isError: true,
          errorType: ToolErrorType.validation,
        );
      }
    } else if (action == 'list') {
      final list = CronRegistry.jobs.map((j) => j.toJson()).toList();
      return ToolResult(
        toolUseId: '',
        content: jsonEncode({'crons': list}),
      );
    } else {
      return ToolResult(
        toolUseId: '',
        content: 'Error: Invalid action "$action". Must be "create", "delete", or "list".',
        isError: true,
        errorType: ToolErrorType.validation,
      );
    }
  }
}

/// Specific tool to create a cron job
class CronCreateTool implements ITool {
  @override
  String get name => 'cron_create';

  @override
  String get description => 'Creates a new cron task schedule.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'schedule': {
            'type': 'string',
            'description': 'Cron expression (e.g. "*/5 * * * *" for every 5 mins).',
          },
          'command': {
            'type': 'string',
            'description': 'The command / prompt to execute when triggered.',
          },
          'description': {
            'type': 'string',
            'description': 'Optional human-readable description of the cron job.',
          },
        },
        'required': ['schedule', 'command'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    final schedule = params['schedule'] as String? ?? params['cron'] as String? ?? '';
    final command = params['command'] as String? ?? (params['params'] as Map?)?['command'] as String? ?? '';
    final desc = params['description'] as String? ?? '';

    if (schedule.isEmpty || command.isEmpty) {
      return ToolResult(
        toolUseId: '',
        content: 'Error: "schedule" and "command" are required.',
        isError: true,
        errorType: ToolErrorType.validation,
      );
    }

    final jobId = params['id'] as String? ?? 'cron_${DateTime.now().millisecondsSinceEpoch}';
    final job = CronJob(
      id: jobId,
      schedule: schedule,
      command: command,
      description: desc,
      createdAt: DateTime.now(),
    );
    CronRegistry.addJob(job);

    return ToolResult(
      toolUseId: '',
      content: 'Successfully created cron job $jobId with schedule "$schedule".',
    );
  }
}

/// Specific tool to delete a cron job
class CronDeleteTool implements ITool {
  @override
  String get name => 'cron_delete';

  @override
  String get description => 'Deletes a cron task by its ID.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => false;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {
          'cronId': {
            'type': 'string',
            'description': 'The ID of the cron job to delete.',
          },
        },
        'required': ['cronId'],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    final cronId = params['cronId'] as String? ?? params['id'] as String? ?? '';
    if (cronId.isEmpty) {
      return ToolResult(
        toolUseId: '',
        content: 'Error: "cronId" or "id" is required.',
        isError: true,
        errorType: ToolErrorType.validation,
      );
    }

    final success = CronRegistry.removeJob(cronId);
    if (success) {
      return ToolResult(
        toolUseId: '',
        content: 'Successfully deleted cron job $cronId.',
      );
    } else {
      return ToolResult(
        toolUseId: '',
        content: 'Cron job $cronId not found.',
        isError: true,
        errorType: ToolErrorType.validation,
      );
    }
  }
}

/// Specific tool to list all cron jobs
class CronListTool implements ITool {
  @override
  String get name => 'cron_list';

  @override
  String get description => 'Lists all currently registered cron tasks.';

  @override
  bool get isConcurrencySafe => true;

  @override
  bool get isReadOnly => true;

  @override
  Map<String, dynamic> get parameterSchema => {
        'type': 'object',
        'properties': {},
        'required': [],
      };

  @override
  Future<ToolResult> run(Map<String, dynamic> params) async {
    final list = CronRegistry.jobs.map((j) => j.toJson()).toList();
    return ToolResult(
      toolUseId: '',
      content: jsonEncode({'crons': list}),
    );
  }
}
