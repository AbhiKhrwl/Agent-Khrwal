import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;
import 'atomic_write_engine.dart';

enum SkillState { active, stale, archived }

class SkillRecord {
  final String name;
  final DateTime createdAt;
  final DateTime lastActivityAt;
  final SkillState state;
  final bool isPinned;

  SkillRecord({
    required this.name,
    required this.createdAt,
    required this.lastActivityAt,
    required this.state,
    required this.isPinned,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'created_at': createdAt.toIso8601String(),
        'last_activity_at': lastActivityAt.toIso8601String(),
        'state': state.name,
        'pinned': isPinned,
      };

  factory SkillRecord.fromJson(Map<String, dynamic> json) {
    return SkillRecord(
      name: json['name'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      lastActivityAt: DateTime.parse(json['last_activity_at'] as String),
      state: SkillState.values.byName(json['state'] as String? ?? 'active'),
      isPinned: json['pinned'] as bool? ?? false,
    );
  }
}

class ApexCuratorEngine {
  final String sandboxRoot;
  final Directory skillsDir;
  final File stateFile;
  final File telemetryFile;

  final Duration runInterval = const Duration(days: 7);
  final Duration staleCutoff = const Duration(days: 30);
  final Duration archiveCutoff = const Duration(days: 90);

  ApexCuratorEngine({required this.sandboxRoot})
      : skillsDir = Directory(p.join(sandboxRoot, 'skills')),
        stateFile = File(p.join(sandboxRoot, 'skills', '.curator_state')),
        telemetryFile = File(p.join(sandboxRoot, 'skills', '.telemetry.json')) {
    if (!skillsDir.existsSync()) {
      skillsDir.createSync(recursive: true);
    }
  }

  /// Stateful time-gated check: Should the curator run its sweep now?
  bool shouldRunNow() {
    if (!stateFile.existsSync()) {
      _seedFirstRun();
      return true; // Run on first check
    }

    try {
      final text = stateFile.readAsStringSync();
      final stateData = jsonDecode(text) as Map<String, dynamic>;
      final lastRun = DateTime.parse(stateData['last_run_at'] as String);
      final elapsed = DateTime.now().difference(lastRun);
      return elapsed >= runInterval;
    } catch (_) {
      return false;
    }
  }

  void _seedFirstRun() {
    final state = {
      'last_run_at': DateTime.now().toIso8601String(),
      'run_count': 0,
    };
    try {
      AtomicWriteEngine.writeAtomicallySync(stateFile, jsonEncode(state));
    } catch (_) {}
  }

  /// Automatically updates skill activity telemetry (called whenever a skill loads/runs).
  /// Implements automatic Reactivation (reactivates stale skills if used).
  Future<void> trackSkillActivity(String skillName) async {
    final telemetry = await _readTelemetry();
    final now = DateTime.now();

    if (telemetry.containsKey(skillName)) {
      final record = SkillRecord.fromJson(telemetry[skillName] as Map<String, dynamic>);
      final updated = SkillRecord(
        name: record.name,
        createdAt: record.createdAt,
        lastActivityAt: now,
        state: record.state == SkillState.stale ? SkillState.active : record.state,
        isPinned: record.isPinned,
      );
      telemetry[skillName] = updated.toJson();
    } else {
      final newRecord = SkillRecord(
        name: skillName,
        createdAt: now,
        lastActivityAt: now,
        state: SkillState.active,
        isPinned: false,
      );
      telemetry[skillName] = newRecord.toJson();
    }

    await _writeTelemetry(telemetry);
  }

  /// Pins/Unpins a specific skill.
  Future<bool> setPinStatus(String skillName, bool pinned) async {
    final telemetry = await _readTelemetry();
    if (!telemetry.containsKey(skillName)) return false;

    final record = SkillRecord.fromJson(telemetry[skillName] as Map<String, dynamic>);
    final updated = SkillRecord(
      name: record.name,
      createdAt: record.createdAt,
      lastActivityAt: record.lastActivityAt,
      state: record.state,
      isPinned: pinned,
    );
    telemetry[skillName] = updated.toJson();
    await _writeTelemetry(telemetry);
    return true;
  }

  /// Executes automatic state-transitions and archives stale skills.
  Future<Map<String, int>> executeStateTransitions() async {
    final report = {
      'marked_stale': 0,
      'archived': 0,
      'reactivated': 0,
      'consolidated_absorbed': 0,
      'consolidated_umbrellas': 0,
    };
    final telemetry = await _readTelemetry();
    final now = DateTime.now();

    // Verify existing skills folder and auto-discover files not yet tracked in telemetry
    await _autoDiscoverSkills(telemetry);

    for (final entry in telemetry.entries) {
      final record = SkillRecord.fromJson(entry.value as Map<String, dynamic>);
      if (record.isPinned) continue; // Pinned skills are completely protected

      final inactiveDuration = now.difference(record.lastActivityAt);

      if (inactiveDuration >= archiveCutoff) {
        if (record.state != SkillState.archived) {
          final success = await _archiveSkillFolder(record.name);
          if (success) {
            _updateTelemetryState(record.name, SkillState.archived, telemetry);
            report['archived'] = report['archived']! + 1;
          }
        }
      } else if (inactiveDuration >= staleCutoff) {
        if (record.state == SkillState.active) {
          _updateTelemetryState(record.name, SkillState.stale, telemetry);
          report['marked_stale'] = report['marked_stale']! + 1;
        }
      } else if (inactiveDuration < staleCutoff) {
        if (record.state == SkillState.stale) {
          _updateTelemetryState(record.name, SkillState.active, telemetry);
          report['reactivated'] = report['reactivated']! + 1;
        }
      }
    }

    await _writeTelemetry(telemetry);

    // Run autonomous skill consolidation strategies
    try {
      final consolidationReport = await consolidateSkills();
      report['consolidated_absorbed'] = consolidationReport['absorbed'] ?? 0;
      report['consolidated_umbrellas'] = consolidationReport['new_umbrellas'] ?? 0;
    } catch (_) {}

    // Save run time state
    try {
      final state = {
        'last_run_at': now.toIso8601String(),
      };
      await AtomicWriteEngine.writeAtomically(stateFile, jsonEncode(state));
    } catch (_) {}

    return report;
  }

  /// Scans active/stale skills, groups them by prefix clusters, and performs consolidation
  /// using the three strategies described in the research paper.
  Future<Map<String, int>> consolidateSkills() async {
    final report = {'absorbed': 0, 'new_umbrellas': 0, 'demoted': 0};
    final telemetry = await _readTelemetry();

    // 1. Discover all skills first
    await _autoDiscoverSkills(telemetry);

    // 2. Identify active or stale skills (we don't cluster archived ones)
    final activeSkills = telemetry.entries
        .where((e) {
          final record = SkillRecord.fromJson(e.value as Map<String, dynamic>);
          return record.state != SkillState.archived;
        })
        .map((e) => e.key)
        .toList();

    // 3. Find prefix clusters
    // We group skills by their prefix.
    // The prefix is extracted by splitting the skill name by '-' or '_'.
    // If the skill has at least one hyphen/underscore, the prefix is the first token.
    final clusters = <String, List<String>>{};
    for (final skill in activeSkills) {
      final parts = skill.split(RegExp(r'[-_]'));
      if (parts.length > 1) {
        final prefix = parts.first.toLowerCase();
        clusters.putIfAbsent(prefix, () => []).add(skill);
      }
    }

    // Filter to retain clusters with 2 or more skills
    clusters.removeWhere((prefix, list) => list.length < 2);

    for (final entry in clusters.entries) {
      final prefix = entry.key;
      final siblings = entry.value;

      // Determine if there is an exact match for prefix itself among active skills
      // or if one already exists in the folder
      final umbrellaDir = Directory(p.join(skillsDir.path, prefix));
      final umbrellaExists = activeSkills.contains(prefix) ||
          File(p.join(umbrellaDir.path, 'SKILL.md')).existsSync();

      if (umbrellaExists) {
        // Strategy 1: Absorb into Umbrella
        final success = await _absorbIntoUmbrella(prefix, siblings, telemetry);
        if (success) {
          report['absorbed'] = report['absorbed']! + siblings.length;
        }
      } else {
        // Strategy 2: Create New Umbrella
        final success = await _createNewUmbrella(prefix, siblings, telemetry);
        if (success) {
          report['new_umbrellas'] = report['new_umbrellas']! + 1;
          report['absorbed'] = report['absorbed']! + siblings.length;
        }
      }
    }

    await _writeTelemetry(telemetry);
    return report;
  }

  Future<bool> _absorbIntoUmbrella(
    String umbrellaName,
    List<String> siblings,
    Map<String, dynamic> telemetry,
  ) async {
    final umbrellaPath = p.join(skillsDir.path, umbrellaName);
    final umbrellaMdFile = File(p.join(umbrellaPath, 'SKILL.md'));
    if (!umbrellaMdFile.existsSync()) {
      await _writeDefaultUmbrellaMd(umbrellaMdFile, umbrellaName);
    }

    String umbrellaContent = await umbrellaMdFile.readAsString();
    final combinedTriggers = <String>{umbrellaName};

    // Parse existing triggers of the umbrella
    combinedTriggers.addAll(_extractTriggersFromContent(umbrellaContent));

    for (final sibling in siblings) {
      if (sibling == umbrellaName) continue; // Don't absorb oneself

      final siblingPath = p.join(skillsDir.path, sibling);
      final siblingMdFile = File(p.join(siblingPath, 'SKILL.md'));
      if (!siblingMdFile.existsSync()) continue;

      final siblingContent = await siblingMdFile.readAsString();
      final siblingTriggers = _extractTriggersFromContent(siblingContent);
      combinedTriggers.addAll(siblingTriggers);

      // Parse sibling metadata
      final title = _extractMetaFromContent(siblingContent, 'Title') ?? sibling;
      final description = _extractMetaFromContent(siblingContent, 'Description') ?? '';

      // Extract the core body of sibling markdown (removing frontmatter/triggers/metadata)
      final coreInstructions = _extractCoreInstructions(siblingContent);

      // Strategy 3: Demote to support if it's very small or specific, otherwise append as H2
      final isNarrow = coreInstructions.trim().length < 300 || _hasSpecificCodeOnly(coreInstructions);
      if (isNarrow) {
        // Demote to support reference file
        final refsDir = Directory(p.join(umbrellaPath, 'references'));
        if (!refsDir.existsSync()) refsDir.createSync(recursive: true);
        final refFile = File(p.join(refsDir.path, '$sibling.md'));
        await AtomicWriteEngine.writeAtomically(refFile, siblingContent);
      } else {
        // Append as a labeled subsection under umbrella
        umbrellaContent += '\n\n## Consolidated Workflow: $title\n';
        if (description.isNotEmpty) {
          umbrellaContent += '*$description*\n\n';
        }
        umbrellaContent += '$coreInstructions\n';
      }

      // Re-home sibling support directories (templates, scripts)
      await _mergeSupportFolders(siblingPath, umbrellaPath);

      // Archive sibling
      final success = await _archiveSkillFolder(sibling);
      if (success) {
        _updateTelemetryState(sibling, SkillState.archived, telemetry);
      }
    }

    // Update umbrella triggers and content
    umbrellaContent = _updateTriggersInContent(umbrellaContent, combinedTriggers.toList());
    await AtomicWriteEngine.writeAtomically(umbrellaMdFile, umbrellaContent);

    // Ensure umbrella is tracked in telemetry as active
    _updateTelemetryState(umbrellaName, SkillState.active, telemetry);
    final now = DateTime.now();
    if (!telemetry.containsKey(umbrellaName)) {
      final record = SkillRecord(
        name: umbrellaName,
        createdAt: now,
        lastActivityAt: now,
        state: SkillState.active,
        isPinned: false,
      );
      telemetry[umbrellaName] = record.toJson();
    } else {
      final record = SkillRecord.fromJson(telemetry[umbrellaName] as Map<String, dynamic>);
      final updated = SkillRecord(
        name: record.name,
        createdAt: record.createdAt,
        lastActivityAt: now,
        state: SkillState.active,
        isPinned: record.isPinned,
      );
      telemetry[umbrellaName] = updated.toJson();
    }

    return true;
  }

  Future<bool> _createNewUmbrella(
    String umbrellaName,
    List<String> siblings,
    Map<String, dynamic> telemetry,
  ) async {
    final umbrellaPath = p.join(skillsDir.path, umbrellaName);
    final umbrellaDir = Directory(umbrellaPath);
    if (!umbrellaDir.existsSync()) {
      umbrellaDir.createSync(recursive: true);
    }

    final umbrellaMdFile = File(p.join(umbrellaPath, 'SKILL.md'));
    await _writeDefaultUmbrellaMd(umbrellaMdFile, umbrellaName);

    return await _absorbIntoUmbrella(umbrellaName, siblings, telemetry);
  }

  Future<void> _writeDefaultUmbrellaMd(File file, String name) async {
    final defaultContent = '''
Title: $name Umbrella Skill
Description: Autonomous consolidated master skill for all workflows starting with "$name".
Triggers: ["$name"]

# $name Consolidation Dashboard
This skill orchestrates multiple specialized sub-workflows related to $name.
''';
    await AtomicWriteEngine.writeAtomically(file, defaultContent);
  }

  List<String> _extractTriggersFromContent(String content) {
    final reg = RegExp(r'Triggers:\s*\[(.*)\]');
    final match = reg.firstMatch(content);
    if (match == null) return [];
    return match.group(1)!
        .split(',')
        .map((e) => e.trim().replaceAll('"', '').replaceAll("'", ''))
        .where((e) => e.isNotEmpty)
        .toList();
  }

  String? _extractMetaFromContent(String content, String tag) {
    final reg = RegExp('$tag:\\s*(.*)');
    final match = reg.firstMatch(content);
    return match?.group(1)?.trim();
  }

  String _extractCoreInstructions(String content) {
    final lines = content.split('\n');
    final coreLines = lines.where((line) {
      final lower = line.toLowerCase();
      return !lower.startsWith('title:') &&
          !lower.startsWith('description:') &&
          !lower.startsWith('triggers:');
    });
    return coreLines.join('\n').trim();
  }

  bool _hasSpecificCodeOnly(String instructions) {
    final trimmed = instructions.trim();
    return trimmed.contains('```') && trimmed.length < 500;
  }

  String _updateTriggersInContent(String content, List<String> triggers) {
    final uniqTriggers = triggers.toSet().toList();
    final triggersStr = 'Triggers: [${uniqTriggers.map((t) => '"$t"').join(', ')}]';
    if (content.contains('Triggers: [')) {
      return content.replaceAll(RegExp(r'Triggers:\s*\[.*\]'), triggersStr);
    } else {
      return 'Title: Consolidated Skill\n$triggersStr\n\n$content';
    }
  }

  Future<void> _mergeSupportFolders(String siblingPath, String umbrellaPath) async {
    final subfolders = ['references', 'templates', 'scripts'];
    for (final folder in subfolders) {
      final source = Directory(p.join(siblingPath, folder));
      if (source.existsSync()) {
        final target = Directory(p.join(umbrellaPath, folder));
        if (!target.existsSync()) {
          target.createSync(recursive: true);
        }
        final files = source.listSync(recursive: true);
        for (final file in files) {
          if (file is File) {
            final relative = p.relative(file.path, from: source.path);
            final dest = File(p.join(target.path, relative));
            if (!dest.parent.existsSync()) {
              dest.parent.createSync(recursive: true);
            }
            if (dest.existsSync()) {
              await dest.delete();
            }
            await file.rename(dest.path);
          }
        }
      }
    }
  }

  /// Manually archives a skill directory.
  Future<bool> manuallyArchiveSkill(String skillName) async {
    final telemetry = await _readTelemetry();
    final success = await _archiveSkillFolder(skillName);
    if (success) {
      _updateTelemetryState(skillName, SkillState.archived, telemetry);
      await _writeTelemetry(telemetry);
    }
    return success;
  }

  // ── Internal Helpers ──────────────────────────────────────────────────

  Future<Map<String, dynamic>> _readTelemetry() async {
    if (!telemetryFile.existsSync()) return {};
    try {
      final text = await telemetryFile.readAsString();
      return Map<String, dynamic>.from(jsonDecode(text) as Map<dynamic, dynamic>);
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeTelemetry(Map<String, dynamic> telemetry) async {
    await AtomicWriteEngine.writeAtomically(telemetryFile, jsonEncode(telemetry));
  }

  Future<void> _autoDiscoverSkills(Map<String, dynamic> telemetry) async {
    if (!skillsDir.existsSync()) return;
    final now = DateTime.now();

    final children = skillsDir.listSync();
    for (final child in children) {
      if (child is Directory) {
        final name = p.basename(child.path);
        if (name.startsWith('.') || name == 'skills') continue;

        final skillMd = File(p.join(child.path, 'SKILL.md'));
        if (skillMd.existsSync() && !telemetry.containsKey(name)) {
          final record = SkillRecord(
            name: name,
            createdAt: now,
            lastActivityAt: now,
            state: SkillState.active,
            isPinned: false,
          );
          telemetry[name] = record.toJson();
        }
      }
    }
  }

  Future<bool> _archiveSkillFolder(String skillName) async {
    final sourceDir = Directory(p.join(skillsDir.path, skillName));
    final archiveDir = Directory(p.join(skillsDir.path, '.archive', skillName));

    if (sourceDir.existsSync()) {
      try {
        if (!archiveDir.parent.existsSync()) {
          archiveDir.parent.createSync(recursive: true);
        }
        if (archiveDir.existsSync()) {
          await archiveDir.delete(recursive: true);
        }
        await sourceDir.rename(archiveDir.path);
        return true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }

  void _updateTelemetryState(String name, SkillState newState, Map<String, dynamic> telemetry) {
    if (!telemetry.containsKey(name)) return;
    final record = SkillRecord.fromJson(telemetry[name] as Map<String, dynamic>);
    final updated = SkillRecord(
      name: record.name,
      createdAt: record.createdAt,
      lastActivityAt: record.lastActivityAt,
      state: newState,
      isPinned: record.isPinned,
    );
    telemetry[name] = updated.toJson();
  }
}
