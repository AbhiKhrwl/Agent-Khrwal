import 'package:flutter_test/flutter_test.dart';
import 'package:apex_lite/core/infrastructure/tools/spectral_ops.dart';
import 'package:apex_lite/core/infrastructure/tools/bash_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/directory_briefing_tool.dart';
import 'dart:io';

void main() {
  late String sandboxPath;
  late SpectralOps spectral;
  late BashTool bashTool;
  late DirectoryBriefingTool briefingTool;

  setUp(() {
    sandboxPath = '${Directory.systemTemp.path}/apex_test_sandbox';
    final dir = Directory(sandboxPath);
    if (dir.existsSync()) dir.deleteSync(recursive: true);
    dir.createSync(recursive: true);

    spectral = SpectralOps(workingDirectory: sandboxPath);
    bashTool = BashTool(spectral);
    briefingTool = DirectoryBriefingTool(sandboxPath);
  });

  test('Scenario A: Shopkeeper Sale Entry', () async {
    // Simulate AI sending a command to record a sale
    final result = await bashTool.run({
      'command': 'echo "2026-05-06, Rice, 500" >> sales.csv'
    });

    expect(result.isError, false);
    
    final file = File('$sandboxPath/sales.csv');
    expect(file.existsSync(), true);
    final content = file.readAsStringSync();
    expect(content.contains('Rice, 500'), true);
  });

  test('Scenario B: Directory Briefing', () async {
    // Create some dummy files
    File('$sandboxPath/notes.txt').createSync();
    Directory('$sandboxPath/project').createSync();
    File('$sandboxPath/project/main.dart').createSync();

    final result = await briefingTool.run({'depth': 3});
    
    expect(result.isError, false);
    expect(result.content.contains('notes.txt'), true);
    expect(result.content.contains('project/'), true);
    expect(result.content.contains('main.dart'), true);
  });
}
