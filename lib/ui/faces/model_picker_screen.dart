import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_gemma/flutter_gemma.dart' as gemma;
import '../../core/infrastructure/services/local_inference_service.dart';
import '../../core/infrastructure/services/session_manager.dart';
import '../../core/infrastructure/heartbeat/aether_core.dart';
import '../theme/divine_palette.dart';

/// Premium model selection screen.
/// Users can either pick a locally stored model file or download one.
class ModelPickerScreen extends StatefulWidget {
  final LocalInferenceService inference;
  final AetherCore core;
  final SessionManager sessionManager;
  final void Function(BuildContext context) onModelReady;

  const ModelPickerScreen({
    super.key,
    required this.inference,
    required this.core,
    required this.sessionManager,
    required this.onModelReady,
  });

  @override
  State<ModelPickerScreen> createState() => _ModelPickerScreenState();
}

class _ModelPickerScreenState extends State<ModelPickerScreen>
    with SingleTickerProviderStateMixin {
  ModelType _selectedModelType = ModelType.gemma4;
  gemma.PreferredBackend _selectedBackend = gemma.PreferredBackend.gpu;
  bool _isDownloading = false;
  int _downloadProgress = 0;
  String? _statusMessage;
  late AnimationController _pulseController;

  static const _accent = DivinePalette.neonCyan;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<bool> _isValidTfliteModel(String filePath) async {
    try {
      final file = File(filePath);
      // Check if file exists and is large enough to be a valid model
      if (!file.existsSync()) return false;
      if (file.lengthSync() < 1000000) return false; // Minimum size check

      final raf = await file.open(mode: FileMode.read);
      final bytes = await raf.read(8);
      await raf.close();
      if (bytes.length < 8) return false;
      final magic = String.fromCharCodes(bytes.sublist(4, 8));
      // Accept both TFL3 (standard) and potentially other valid TFLite formats
      return magic == 'TFL3' || magic == 'TFL4' || magic == 'LITE';
    } catch (e) {
      // If validation fails, don't block the model loading
      // Some valid models might not pass the magic byte check
      final file = File(filePath);
      return file.existsSync() && file.lengthSync() > 1000000;
    }
  }

  Future<void> _pickModelFile() async {
    try {
      // Request storage permissions before picking a file
      if (Platform.isAndroid) {
        bool hasPermission = await widget.inference.requestStoragePermissions();
        if (!hasPermission) {
          if (mounted) {
            setState(() {
              _statusMessage = '❌ Error: Storage permissions not granted.';
            });
          }
          return;
        }
      }

      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        dialogTitle: 'Select Gemma 4 (.litertlm) model file',
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.path == null) return;

      final cachedFile = File(file.path!);
      if (!cachedFile.existsSync()) {
        if (mounted) {
          setState(
            () => _statusMessage = '❌ Error: Picked file does not exist.',
          );
        }
        return;
      }

      // Check for file truncation (Android cache limit issue)
      if (cachedFile.lengthSync() != file.size) {
        if (mounted) {
          setState(
            () => _statusMessage =
                '❌ Error: File truncated! Ensure enough device storage.',
          );
        }
        return;
      }

      // Pre-validate TFLite magic bytes to prevent MediaPipe RET_CHECK crashes
      final isValid = await _isValidTfliteModel(file.path!);
      if (!isValid) {
        if (mounted) {
          setState(
            () => _statusMessage =
                '❌ Error: Not a valid .litertlm/TFLite model (Missing TFL3 magic bytes).',
          );
        }
        return;
      }

      setState(() {
        _statusMessage = 'Loading model from: ${file.name}';
      });

      final success = await widget.inference.loadModelFromFile(
        modelType: _selectedModelType,
        filePath: file.path!,
        fileName: file.name,
      );

      if (success && mounted) {
        setState(() => _statusMessage = 'Model ready: ${file.name}');
        // Don't auto-navigate, let user manually navigate
        // await Future.delayed(const Duration(milliseconds: 600));
        // if (mounted) widget.onModelReady(context);
      } else if (mounted) {
        setState(() {
          _statusMessage =
              '❌ ${widget.inference.errorMessage ?? "Failed to load model"}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _statusMessage = '❌ Error: $e');
      }
    }
  }

  Future<void> _downloadModel() async {
    setState(() {
      _isDownloading = true;
      _downloadProgress = 0;
      _statusMessage = 'Downloading ${_modelTypeName(_selectedModelType)}...';
    });

    final success = await widget.inference.downloadModel(
      modelType: _selectedModelType,
      onProgress: (progress) {
        if (mounted) {
          setState(() => _downloadProgress = progress);
        }
      },
    );

    if (success && mounted) {
      setState(() {
        _isDownloading = false;
        _statusMessage = '✅ Model ready!';
      });
      // Don't auto-navigate, let user manually navigate
      // await Future.delayed(const Duration(milliseconds: 500));
      // if (mounted) widget.onModelReady(context);
    } else if (mounted) {
      setState(() {
        _isDownloading = false;
        _statusMessage =
            '❌ ${widget.inference.errorMessage ?? "Download failed"}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _buildHeader(),
                const SizedBox(height: 40),
                _buildModelTypeSelector(),
                const SizedBox(height: 24),
                _buildBackendToggle(),
                const SizedBox(height: 32),
                _buildDropZone(),
                const SizedBox(height: 20),
                _buildDivider(),
                const SizedBox(height: 20),
                _buildDownloadButton(),
                if (_isDownloading) ...[
                  const SizedBox(height: 20),
                  _buildProgressBar(),
                ],
                if (_statusMessage != null) ...[
                  const SizedBox(height: 20),
                  _buildStatusMessage(),
                ],
                // Add manual navigation button when model is ready
                if (_statusMessage != null &&
                    (_statusMessage!.contains('Model ready') ||
                        _statusMessage!.contains('✅ Model ready'))) ...[
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () => widget.onModelReady(context),
                      icon: const Icon(Icons.arrow_forward, size: 18),
                      label: const Text(
                        'GO TO CHAT',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: DivinePalette.neonCyan,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        // 🔱 Supreme pulsing orb with double rings
        AnimatedBuilder(
          animation: _pulseController,
          builder: (_, child) {
            final pulse = _pulseController.value;
            return Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: _accent.withAlpha(30 + (pulse * 40).toInt()),
                  width: 1.5,
                ),
              ),
              child: Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        _accent.withAlpha(20 + (pulse * 20).toInt()),
                        _accent.withAlpha(5),
                      ],
                    ),
                    border: Border.all(color: _accent.withAlpha(60), width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: _accent.withAlpha(20 + (pulse * 30).toInt()),
                        blurRadius: 24,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.psychology_alt_rounded, color: _accent, size: 32),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 24),
        const Text(
          'AGENT KHARWAL',
          style: TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: 3,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'On-device AI powered by Gemma 4',
          style: TextStyle(
            color: Colors.white.withAlpha(120),
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 14),
        // 🔱 Feature badges
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _featureBadge('🔒', 'Local-First', DivinePalette.matrixGreen),
            const SizedBox(width: 8),
            _featureBadge('💰', 'Zero Cost', DivinePalette.celestialGold),
            const SizedBox(width: 8),
            _featureBadge('🛡️', 'Private', _accent),
          ],
        ),
      ],
    );
  }

  Widget _buildModelTypeSelector() {
    // Only show Gemma 4 option
    final types = [ModelType.gemma4];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('MODEL ARCHITECTURE'),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: types.map((type) {
            final selected = _selectedModelType == type;
            return GestureDetector(
              onTap: _isDownloading
                  ? null
                  : () => setState(() => _selectedModelType = type),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? _accent.withAlpha(25)
                      : Colors.white.withAlpha(8),
                  border: Border.all(
                    color: selected ? _accent : Colors.white.withAlpha(30),
                    width: selected ? 1.5 : 1,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _modelTypeName(type),
                  style: TextStyle(
                    color: selected ? _accent : Colors.white.withAlpha(120),
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildBackendToggle() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('INFERENCE BACKEND'),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withAlpha(20)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              _backendOption(gemma.PreferredBackend.gpu, 'GPU', Icons.memory),
              Container(
                width: 1,
                height: 40,
                color: Colors.white.withAlpha(20),
              ),
              _backendOption(gemma.PreferredBackend.cpu, 'CPU', Icons.settings),
            ],
          ),
        ),
      ],
    );
  }

  Widget _backendOption(
    gemma.PreferredBackend backend,
    String label,
    IconData icon,
  ) {
    final selected = _selectedBackend == backend;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _selectedBackend = backend);
          widget.inference.setBackend(backend);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected ? _accent.withAlpha(20) : Colors.transparent,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: selected ? _accent : Colors.white38, size: 16),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: selected ? _accent : Colors.white38,
                  fontFamily: 'monospace',
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDropZone() {
    final isDragOver = ValueNotifier<bool>(false);

    return ValueListenableBuilder<bool>(
      valueListenable: isDragOver,
      builder: (context, hovered, _) {
        return GestureDetector(
          onTap: _isDownloading ? null : _pickModelFile,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
            decoration: BoxDecoration(
              border: Border.all(
                color: hovered ? _accent : Colors.white.withAlpha(25),
                width: hovered ? 2 : 1,
              ),
              borderRadius: BorderRadius.circular(12),
              color: hovered
                  ? _accent.withAlpha(10)
                  : Colors.white.withAlpha(5),
            ),
            child: Column(
              children: [
                Icon(
                  hovered ? Icons.cloud_upload : Icons.folder_open,
                  color: hovered ? _accent : Colors.white38,
                  size: 40,
                ),
                const SizedBox(height: 12),
                Text(
                  hovered ? 'DROP MODEL FILE HERE' : 'PICK MODEL FROM FILE',
                  style: TextStyle(
                    color: hovered ? _accent : Colors.white54,
                    fontFamily: 'monospace',
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Select a pre-downloaded .litertlm model file',
                  style: TextStyle(
                    color: Colors.white.withAlpha(50),
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDivider() {
    return Row(
      children: [
        Expanded(
          child: Container(height: 1, color: Colors.white.withAlpha(15)),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'OR DOWNLOAD',
            style: TextStyle(
              color: Colors.white.withAlpha(40),
              fontSize: 10,
              fontFamily: 'monospace',
              letterSpacing: 2,
            ),
          ),
        ),
        Expanded(
          child: Container(height: 1, color: Colors.white.withAlpha(15)),
        ),
      ],
    );
  }

  Widget _buildDownloadButton() {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        onPressed: _isDownloading ? null : _downloadModel,
        icon: _isDownloading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.black,
                ),
              )
            : const Icon(Icons.download, size: 18),
        label: Text(
          _isDownloading
              ? 'DOWNLOADING...'
              : 'DOWNLOAD ${_modelTypeName(_selectedModelType)}',
          style: const TextStyle(
            fontFamily: 'monospace',
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: _accent,
          foregroundColor: Colors.black,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          disabledBackgroundColor: _accent.withAlpha(80),
        ),
      ),
    );
  }

  Widget _buildProgressBar() {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: _downloadProgress / 100,
            backgroundColor: Colors.white.withAlpha(15),
            valueColor: const AlwaysStoppedAnimation(_accent),
            minHeight: 6,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '$_downloadProgress%',
          style: TextStyle(
            color: Colors.white.withAlpha(100),
            fontFamily: 'monospace',
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _buildStatusMessage() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            _statusMessage?.startsWith('❌') == true
                ? Icons.error_outline
                : Icons.info_outline,
            color: _statusMessage?.startsWith('❌') == true
                ? Colors.redAccent
                : _accent,
            size: 16,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _statusMessage ?? '',
              style: TextStyle(
                color: Colors.white.withAlpha(180),
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _featureBadge(String emoji, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withAlpha(12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(emoji, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(
            color: color.withAlpha(200),
            fontSize: 10,
            fontWeight: FontWeight.w600,
          )),
        ],
      ),
    );
  }

  Widget _sectionLabel(String label) {
    return Text(
      label,
      style: TextStyle(
        color: Colors.white.withAlpha(80),
        fontSize: 10,
        fontFamily: 'monospace',
        letterSpacing: 2,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  String _modelTypeName(ModelType type) {
    switch (type) {
      case ModelType.gemma4:
        return 'GEMMA 4 E2B';
    }
  }
}
