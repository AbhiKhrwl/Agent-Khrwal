import 'dart:async';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:apex_lite/core/infrastructure/heartbeat/aether_core.dart';
import 'package:apex_lite/core/infrastructure/handshake/cipher_protocol.dart';
import 'package:apex_lite/core/infrastructure/router/agent_router.dart';
import 'package:apex_lite/core/infrastructure/security/sentry_purity.dart';
import 'package:apex_lite/core/infrastructure/tools/spectral_ops.dart';
import 'package:apex_lite/core/infrastructure/tools/bash_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/directory_briefing_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/file_read_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/file_write_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/notification_agent_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/data_injector_tool.dart';
import 'package:apex_lite/core/infrastructure/tools/voice_munshi_tool.dart';
import 'package:apex_lite/core/infrastructure/services/local_inference_service.dart';
import 'package:apex_lite/core/infrastructure/services/session_manager.dart';
import 'package:apex_lite/core/domain/entities/message.dart';
import 'package:apex_lite/core/domain/entities/protocol_mode.dart';
import 'package:apex_lite/ui/faces/gajraj/gajraj_scaffold.dart';
import 'package:apex_lite/ui/faces/model_picker_screen.dart';
import 'package:apex_lite/ui/theme/divine_palette.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize FlutterGemma engine (required for Gemma 4)
  await gemma.FlutterGemma.initialize(
    huggingFaceToken: const String.fromEnvironment('HUGGINGFACE_TOKEN'),
    maxDownloadRetries: 10,
    webStorageMode: gemma.WebStorageMode.cacheApi,
  );

  // 1. Setup Sandbox
  final docsDir = await getApplicationDocumentsDirectory();
  final sandboxPath = '${docsDir.path}/apex_sandbox';
  final sandboxDir = Directory(sandboxPath);
  if (!await sandboxDir.exists()) {
    await sandboxDir.create(recursive: true);
  }

  // 2. Initialize Session Manager
  // 🔱 MASSIVE UPGRADE: WhatsApp-style session persistence.
  // Load the most recent session on startup instead of creating a new one.
  // Old chats are preserved across app restarts.
  final sessionManager = SessionManager();
  await sessionManager.initialize();
  final existingSessions = await sessionManager.listSessions();
  if (existingSessions.isNotEmpty) {
    // Sort by updatedAt (most recent first) and load the last used session
    existingSessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await sessionManager.loadSession(existingSessions.first.id);
  } else {
    // First-ever launch — create a fresh session
    await sessionManager.createSession(title: 'Getting Started');
  }

  // 3. Initialize Infrastructure
  final validator = SentryPurity(workingDirectory: sandboxPath);
  final router = AgentRouter(validator: validator);
  final protocol = CipherProtocol();

  final spectral = SpectralOps(workingDirectory: sandboxPath);

  // 4. Register ALL Tools
  router.registerTool(BashTool(spectral));
  router.registerTool(DirectoryBriefingTool(sandboxPath));
  router.registerTool(FileReadTool(sandboxPath));
  router.registerTool(FileWriteTool(sandboxPath));
  router.registerTool(DataInjectorTool(spectral));
  router.registerTool(NotificationAgentTool());
  router.registerTool(VoiceMunshiTool());

  final core = AetherCore(router: router, protocol: protocol);

  final inference = LocalInferenceService();

  runApp(ApexLiteApp(
    core: core,
    inference: inference,
    sessionManager: sessionManager,
    sandboxPath: sandboxPath,
    spectralOps: spectral,
  ));
}

class ApexLiteApp extends StatelessWidget {
  final AetherCore core;
  final LocalInferenceService inference;
  final SessionManager sessionManager;
  final String sandboxPath;
  final SpectralOps spectralOps;

  const ApexLiteApp({
    super.key,
    required this.core,
    required this.inference,
    required this.sessionManager,
    required this.sandboxPath,
    required this.spectralOps,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Agent Kharwal',
      theme: DivineTheme.dark,
      debugShowCheckedModeBanner: false,
      home: BootSplash(
        core: core,
        inference: inference,
        sessionManager: sessionManager,
        sandboxPath: sandboxPath,
        spectralOps: spectralOps,
      ),
    );
  }
}

/// Boot screen: initializes engine, then routes to model picker or chat
class BootSplash extends StatefulWidget {
  final AetherCore core;
  final LocalInferenceService inference;
  final SessionManager sessionManager;
  final String sandboxPath;
  final SpectralOps spectralOps;

  const BootSplash({
    super.key,
    required this.core,
    required this.inference,
    required this.sessionManager,
    required this.sandboxPath,
    required this.spectralOps,
  });

  @override
  State<BootSplash> createState() => _BootSplashState();
}

class _BootSplashState extends State<BootSplash>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  String _statusText = 'Initializing engine...';

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
    requestStoragePermission();
    _initEngine();
  }

  Future<void> _initEngine() async {
    final ready = await widget.inference.initialize();
    if (mounted) {
      setState(() {
        _statusText = ready
            ? 'Engine ready.'
            : 'Engine init failed. You can still pick a model.';
      });
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) {
        Navigator.pushReplacement(
          context,
          PageRouteBuilder(
            pageBuilder: (_, a1, a2) => ModelPickerScreen(
              inference: widget.inference,
              core: widget.core,
              sessionManager: widget.sessionManager,
              onModelReady: (ctx) => _goToChat(ctx),
            ),
            transitionDuration: const Duration(milliseconds: 500),
            transitionsBuilder: (_, anim, a2, child) {
              return FadeTransition(
                opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
                child: child,
              );
            },
          ),
        );
      }
    }
  }

  void _goToChat(BuildContext ctx) {
    Navigator.pushReplacement(
      ctx,
      PageRouteBuilder(
        pageBuilder: (_, a1, a2) => _InferenceWrapper(
          core: widget.core,
          inference: widget.inference,
          sessionManager: widget.sessionManager,
          sandboxPath: widget.sandboxPath,
          spectralOps: widget.spectralOps,
        ),
        transitionDuration: const Duration(milliseconds: 500),
        transitionsBuilder: (_, anim, a2, child) {
          return FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0.05, 0),
                end: Offset.zero,
              ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
              child: child,
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 🔱 Supreme double-ring pulsing orb
            AnimatedBuilder(
              animation: _pulseController,
              builder: (_, child) {
                final pulse = _pulseController.value;
                return Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: DivinePalette.neonCyan.withAlpha(20 + (pulse * 30).toInt()),
                      width: 1.5,
                    ),
                  ),
                  child: Center(
                    child: Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            DivinePalette.neonCyan.withAlpha(15 + (pulse * 25).toInt()),
                            DivinePalette.neonCyan.withAlpha(3),
                          ],
                        ),
                        border: Border.all(color: DivinePalette.neonCyan.withAlpha(50), width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: DivinePalette.neonCyan.withAlpha(15 + (pulse * 20).toInt()),
                            blurRadius: 20,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.psychology_alt_rounded,
                        color: DivinePalette.neonCyan,
                        size: 28,
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 28),
            const Text(
              'AGENT KHARWAL',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: 3,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Your AI. Your Device. Your Privacy.',
              style: TextStyle(
                color: DivinePalette.neonCyan.withAlpha(120),
                fontSize: 12,
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 24),
            // Status indicator
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 12, height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: DivinePalette.neonCyan.withAlpha(100),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _statusText,
                  style: TextStyle(
                    color: Colors.white.withAlpha(80),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InferenceWrapper extends StatefulWidget {
  final AetherCore core;
  final LocalInferenceService inference;
  final SessionManager sessionManager;
  final String sandboxPath;
  final SpectralOps spectralOps;
  const _InferenceWrapper({
    required this.core,
    required this.inference,
    required this.sessionManager,
    required this.sandboxPath,
    required this.spectralOps,
  });

  @override
  State<_InferenceWrapper> createState() => _InferenceWrapperState();
}

class _InferenceWrapperState extends State<_InferenceWrapper> {
  StreamSubscription<Map<String, dynamic>>? _eventSubscription;

  @override
  void initState() {
    super.initState();
    _eventSubscription = widget.core.eventStream.listen((event) {
      if (event['type'] == 'performance' &&
          event['metric'] == 'total_latency') {
        final latency = event['value'] as int;
        if (latency > 10000 && widget.inference.maxTokens > 128) {
          widget.inference.maxTokens =
              (widget.inference.maxTokens * 0.7).toInt();
          debugPrint(
            'PERFORMANCE AUDIT: Latency ${latency}ms is high. Reduced maxTokens to ${widget.inference.maxTokens}',
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    widget.inference.stopGeneration();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GajrajOracleScaffold(
      core: widget.core,
      callModel: (List<Message> history) {
        if (widget.core.chatMode == ChatMode.letsDo) {
          final toolMaps = widget.core.router.getToolDefinitionsFlat();
          return widget.inference.getResponseStream(
            history,
            maps: toolMaps,
          );
        }
        return widget.inference.getResponseStream(history);
      },
      sessionManager: widget.sessionManager,
      sandboxPath: widget.sandboxPath,
      spectralOps: widget.spectralOps,
    );
  }
}

Future<void> requestStoragePermission() async {
  if (Platform.isAndroid) {
    final androidInfo = await DeviceInfoPlugin().androidInfo;

    if (androidInfo.version.sdkInt >= 33) {
      Map<Permission, PermissionStatus> statuses = await [
        Permission.photos,
        Permission.videos,
        Permission.audio,
      ].request();

      if (statuses[Permission.photos]!.isGranted) {
        debugPrint('Android 13+ Storage Access Granted');
      }
    } else if (androidInfo.version.sdkInt >= 30) {
      var status = await Permission.manageExternalStorage.request();
      if (status.isGranted) {
        debugPrint('Manage Storage Granted');
      }
    } else {
      var status = await Permission.storage.request();
      if (status.isGranted) {
        debugPrint('Storage Granted');
      }
    }
  }
}