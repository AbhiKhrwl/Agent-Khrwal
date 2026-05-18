import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:archive/archive.dart';
import '../theme/divine_palette.dart';

/// 🔱 Vault — Sandbox File Explorer.
/// Shows as a modal bottom sheet. Lets users browse, preview, download,
/// create folders, and set the active project directory.
class SandboxExplorer extends StatefulWidget {
  final String sandboxRoot;
  final String currentWorkingDir;
  final void Function(String newPath) onProjectChanged;

  const SandboxExplorer({
    super.key,
    required this.sandboxRoot,
    required this.currentWorkingDir,
    required this.onProjectChanged,
  });

  /// Show the Vault as a modal bottom sheet.
  static Future<void> show(
    BuildContext context, {
    required String sandboxRoot,
    required String currentWorkingDir,
    required void Function(String newPath) onProjectChanged,
  }) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SandboxExplorer(
        sandboxRoot: sandboxRoot,
        currentWorkingDir: currentWorkingDir,
        onProjectChanged: onProjectChanged,
      ),
    );
  }

  @override
  State<SandboxExplorer> createState() => _SandboxExplorerState();
}

class _SandboxExplorerState extends State<SandboxExplorer> {
  late String _currentPath;
  List<FileSystemEntity> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.sandboxRoot;
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final dir = Directory(_currentPath);
      if (!dir.existsSync()) {
        _entries = [];
      } else {
        final items = dir.listSync();
        items.sort((a, b) {
          if (a is Directory && b is File) return -1;
          if (a is File && b is Directory) return 1;
          return p.basename(a.path).compareTo(p.basename(b.path));
        });
        _entries = items.where((e) => !p.basename(e.path).startsWith('.')).toList();
      }
    } catch (_) {
      _entries = [];
    }
    if (mounted) setState(() => _loading = false);
  }

  void _navigateTo(String path) {
    setState(() => _currentPath = path);
    _refresh();
  }

  List<String> get _breadcrumbs {
    final rel = p.relative(_currentPath, from: widget.sandboxRoot);
    if (rel == '.' || rel.isEmpty) return ['Sandbox'];
    return ['Sandbox', ...rel.split(Platform.pathSeparator)];
  }

  String _breadcrumbPath(int index) {
    if (index == 0) return widget.sandboxRoot;
    final parts = p.relative(_currentPath, from: widget.sandboxRoot).split(Platform.pathSeparator);
    return p.joinAll([widget.sandboxRoot, ...parts.sublist(0, index)]);
  }

  bool get _isAtRoot => _currentPath == widget.sandboxRoot;
  bool get _isActiveProject => _currentPath == widget.currentWorkingDir;

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.3,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0B0E13),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(top: BorderSide(color: Color(0xFF1A1D23), width: 1)),
        ),
        child: Column(
          children: [
            _buildHandle(),
            _buildHeader(),
            _buildBreadcrumbs(),
            const Divider(color: Color(0xFF1A1D23), height: 1),
            _buildToolbar(),
            const Divider(color: Color(0xFF1A1D23), height: 1),
            Expanded(child: _buildFileList(scrollCtrl)),
          ],
        ),
      ),
    );
  }

  Widget _buildHandle() {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Container(
        width: 36, height: 4,
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final fileCount = _entries.whereType<File>().length;
    final folderCount = _entries.whereType<Directory>().length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [DivinePalette.celestialGold.withAlpha(150), DivinePalette.neonCyan.withAlpha(80)],
              ),
            ),
            child: const Center(child: Icon(Icons.folder_special_rounded, color: Colors.black, size: 16)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Vault', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
                Text('$folderCount folders · $fileCount files',
                  style: TextStyle(color: Colors.white.withAlpha(80), fontSize: 11)),
              ],
            ),
          ),
          if (_isActiveProject)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: DivinePalette.matrixGreen.withAlpha(20),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: DivinePalette.matrixGreen.withAlpha(60)),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bolt, size: 12, color: DivinePalette.matrixGreen),
                  SizedBox(width: 3),
                  Text('Active', style: TextStyle(color: DivinePalette.matrixGreen, fontSize: 10, fontWeight: FontWeight.w700)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumbs() {
    final crumbs = _breadcrumbs;
    return SizedBox(
      height: 28,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: crumbs.length,
        separatorBuilder: (_, i) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Icon(Icons.chevron_right, size: 14, color: Colors.white.withAlpha(40)),
        ),
        itemBuilder: (_, i) {
          final isLast = i == crumbs.length - 1;
          return GestureDetector(
            onTap: isLast ? null : () => _navigateTo(_breadcrumbPath(i)),
            child: Center(
              child: Text(
                crumbs[i],
                style: TextStyle(
                  color: isLast ? DivinePalette.neonCyan : Colors.white.withAlpha(80),
                  fontSize: 12, fontFamily: 'monospace',
                  fontWeight: isLast ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          _ToolBtn(icon: Icons.home_rounded, label: 'Root', color: Colors.white54,
            onTap: _isAtRoot ? null : () => _navigateTo(widget.sandboxRoot)),
          _ToolBtn(icon: Icons.create_new_folder_rounded, label: 'New', color: DivinePalette.celestialGold,
            onTap: _showNewFolderDialog),
          _ToolBtn(icon: Icons.bolt_rounded,
            label: _isActiveProject ? 'Active' : 'Set Project',
            color: _isActiveProject ? DivinePalette.matrixGreen : DivinePalette.neonCyan,
            onTap: _isActiveProject ? null : () {
              widget.onProjectChanged(_currentPath);
              setState(() {});
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text('Project set: ${p.basename(_currentPath)}'),
                  backgroundColor: DivinePalette.matrixGreen.withAlpha(180),
                  duration: const Duration(seconds: 2),
                ));
              }
            }),
          _ToolBtn(icon: Icons.refresh_rounded, label: 'Refresh', color: Colors.white54,
            onTap: _refresh),
        ],
      ),
    );
  }

  Widget _buildFileList(ScrollController ctrl) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: DivinePalette.neonCyan, strokeWidth: 2));
    }
    if (_entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open, size: 48, color: Colors.white.withAlpha(20)),
            const SizedBox(height: 8),
            Text('Empty folder', style: TextStyle(color: Colors.white.withAlpha(60), fontSize: 14)),
            const SizedBox(height: 4),
            Text('Agent will create files here', style: TextStyle(color: Colors.white.withAlpha(30), fontSize: 12)),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: ctrl,
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: _entries.length,
      itemBuilder: (_, i) => _FileEntryTile(
        entity: _entries[i],
        sandboxRoot: widget.sandboxRoot,
        onTapFolder: (path) => _navigateTo(path),
        onTapFile: (file) => _showFilePreview(file),
        onDelete: (entity) => _confirmDelete(entity),
        onShare: (entity) => _shareEntity(entity),
      ),
    );
  }

  // ── Actions ──

  void _showNewFolderDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF12161C),
        title: const Text('New Folder', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
          decoration: InputDecoration(
            hintText: 'folder_name',
            hintStyle: TextStyle(color: Colors.white.withAlpha(40)),
            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: DivinePalette.neonCyan.withAlpha(60))),
            focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: DivinePalette.neonCyan)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isNotEmpty && !name.contains('..') && !name.contains('/')) {
                Directory(p.join(_currentPath, name)).createSync(recursive: true);
                Navigator.pop(ctx);
                _refresh();
              }
            },
            child: const Text('Create', style: TextStyle(color: DivinePalette.neonCyan)),
          ),
        ],
      ),
    );
  }

  void _showFilePreview(File file) {
    final name = p.basename(file.path);
    final size = file.lengthSync();
    final sizeStr = _formatSize(size);
    String? content;
    try {
      if (size < 100000) content = file.readAsStringSync();
    } catch (_) {}

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.7, minChildSize: 0.3, maxChildSize: 0.95,
        builder: (_, ctrl) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFF0D1117),
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(_fileIcon(name), color: DivinePalette.neonCyan, size: 20),
                    const SizedBox(width: 10),
                    Expanded(child: Text(name, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600, fontFamily: 'monospace'), overflow: TextOverflow.ellipsis)),
                    Text(sizeStr, style: TextStyle(color: Colors.white.withAlpha(60), fontSize: 11)),
                    const SizedBox(width: 8),
                    IconButton(icon: const Icon(Icons.share_rounded, size: 18, color: DivinePalette.celestialGold), onPressed: () => _shareEntity(file)),
                  ],
                ),
              ),
              const Divider(color: Color(0xFF1A1D23), height: 1),
              Expanded(
                child: content != null
                  ? SingleChildScrollView(
                      controller: ctrl,
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(content, style: const TextStyle(color: Colors.white70, fontSize: 12, fontFamily: 'monospace', height: 1.5)),
                    )
                  : Center(child: Text('Binary file ($sizeStr)', style: TextStyle(color: Colors.white.withAlpha(60)))),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(FileSystemEntity entity) async {
    final name = p.basename(entity.path);
    final isDir = entity is Directory;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF12161C),
        title: Text('Delete $name?', style: const TextStyle(color: Colors.white, fontSize: 15)),
        content: Text(
          isDir ? 'This will delete the folder and ALL its contents.' : 'This file will be permanently deleted.',
          style: TextStyle(color: Colors.white.withAlpha(120), fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      try {
        entity.deleteSync(recursive: true);
        _refresh();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
        }
      }
    }
  }

  Future<void> _shareEntity(FileSystemEntity entity) async {
    try {
      if (entity is File) {
        await Share.shareXFiles([XFile(entity.path)]);
      } else if (entity is Directory) {
        // ZIP the folder then share
        final archive = Archive();
        final dirName = p.basename(entity.path);
        await _addDirToArchive(archive, entity, dirName);
        final zipData = ZipEncoder().encode(archive);

        final tmpZip = File('${Directory.systemTemp.path}/$dirName.zip');
        tmpZip.writeAsBytesSync(zipData);
        await Share.shareXFiles([XFile(tmpZip.path)]);
        try { tmpZip.deleteSync(); } catch (_) {}
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Share failed: $e')));
      }
    }
  }

  Future<void> _addDirToArchive(Archive archive, Directory dir, String prefix) async {
    for (final entity in dir.listSync()) {
      final name = '$prefix/${p.basename(entity.path)}';
      if (entity is File) {
        final bytes = entity.readAsBytesSync();
        archive.addFile(ArchiveFile(name, bytes.length, bytes));
      } else if (entity is Directory) {
        await _addDirToArchive(archive, entity, name);
      }
    }
  }

  // ── Helpers ──

  static String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static IconData _fileIcon(String name) {
    final ext = p.extension(name).toLowerCase();
    switch (ext) {
      case '.txt': return Icons.description_outlined;
      case '.json': return Icons.data_object;
      case '.py': return Icons.code;
      case '.dart': return Icons.code;
      case '.js': return Icons.javascript;
      case '.md': return Icons.article_outlined;
      case '.csv': return Icons.table_chart_outlined;
      case '.log': return Icons.receipt_long;
      case '.sh': return Icons.terminal;
      default: return Icons.insert_drive_file_outlined;
    }
  }
}

// ── Toolbar Button ──

class _ToolBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;
  const _ToolBtn({required this.icon, required this.label, required this.color, this.onTap});

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: disabled ? 0.35 : 1.0,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 3),
            padding: const EdgeInsets.symmetric(vertical: 6),
            decoration: BoxDecoration(
              color: color.withAlpha(8),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withAlpha(25)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── File/Folder Entry Tile ──

class _FileEntryTile extends StatelessWidget {
  final FileSystemEntity entity;
  final String sandboxRoot;
  final void Function(String) onTapFolder;
  final void Function(File) onTapFile;
  final void Function(FileSystemEntity) onDelete;
  final void Function(FileSystemEntity) onShare;

  const _FileEntryTile({
    required this.entity,
    required this.sandboxRoot,
    required this.onTapFolder,
    required this.onTapFile,
    required this.onDelete,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final name = p.basename(entity.path);
    final isDir = entity is Directory;

    int? fileSize;
    int childCount = 0;
    if (entity is File) {
      try { fileSize = (entity as File).lengthSync(); } catch (_) {}
    } else if (entity is Directory) {
      try { childCount = (entity as Directory).listSync().length; } catch (_) {}
    }

    return InkWell(
      onTap: () {
        if (isDir) {
          onTapFolder(entity.path);
        } else {
          onTapFile(entity as File);
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // Icon
            Container(
              width: 34, height: 34,
              decoration: BoxDecoration(
                color: isDir
                    ? DivinePalette.celestialGold.withAlpha(12)
                    : DivinePalette.neonCyan.withAlpha(8),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Center(
                child: Icon(
                  isDir ? Icons.folder_rounded : _getFileIcon(name),
                  size: 18,
                  color: isDir ? DivinePalette.celestialGold : DivinePalette.neonCyan,
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Name + meta
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: TextStyle(
                    color: Colors.white.withAlpha(220), fontSize: 13,
                    fontFamily: 'monospace', fontWeight: FontWeight.w500,
                  ), overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 2),
                  Text(
                    isDir ? '$childCount items' : _getFormattedSize(fileSize ?? 0),
                    style: TextStyle(color: Colors.white.withAlpha(50), fontSize: 10),
                  ),
                ],
              ),
            ),
            // Share button
            IconButton(
              icon: Icon(Icons.share_rounded, size: 16, color: Colors.white.withAlpha(50)),
              onPressed: () => onShare(entity),
              splashRadius: 16,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
            ),
            // Delete button
            IconButton(
              icon: Icon(Icons.delete_outline_rounded, size: 16, color: Colors.redAccent.withAlpha(80)),
              onPressed: () => onDelete(entity),
              splashRadius: 16,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              padding: EdgeInsets.zero,
            ),
            // Chevron for folders
            if (isDir)
              Icon(Icons.chevron_right, size: 16, color: Colors.white.withAlpha(30)),
          ],
        ),
      ),
    );
  }
}

IconData _getFileIcon(String name) {
  final ext = p.extension(name).toLowerCase();
  switch (ext) {
    case '.txt': return Icons.description_outlined;
    case '.json': return Icons.data_object;
    case '.py': return Icons.code;
    case '.dart': return Icons.code;
    case '.js': return Icons.javascript;
    case '.md': return Icons.article_outlined;
    case '.csv': return Icons.table_chart_outlined;
    case '.log': return Icons.receipt_long;
    case '.sh': return Icons.terminal;
    default: return Icons.insert_drive_file_outlined;
  }
}

String _getFormattedSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
