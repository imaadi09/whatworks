import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/message.dart';
import '../utils/constants.dart';
import '../utils/helpers.dart';

/// Hooks that connect the shared media gallery to the host chat screen.
///
/// The gallery is 100% presentation + selection; every data access and
/// mutation goes through these callbacks so Task and Sales/CRM detail
/// screens can share one implementation.
class MediaGalleryConfig {
  /// Live media messages of the conversation (re-read on every rebuild,
  /// so deletes/forwards reflect instantly).
  final List<MessageModel> Function() messages;
  final Color themeColor;
  final String currentUserId;
  final String Function(String senderId) senderName;

  /// Resolve the cached local file path for a message (null = not cached).
  final Future<String?> Function(MessageModel) localPathFor;

  /// Open actions
  final void Function(MessageModel) openImage;
  final void Function(MessageModel) openDocument;

  /// Close the gallery and scroll the chat to this message.
  final void Function(MessageModel) openInChat;

  /// Message actions (hosts already implement these with confirmations)
  final void Function(MessageModel) forward;
  final void Function(MessageModel) deleteForMe;
  final void Function(MessageModel) deleteForEveryone;
  final bool Function(MessageModel) canDeleteForEveryone;

  const MediaGalleryConfig({
    required this.messages,
    required this.themeColor,
    required this.currentUserId,
    required this.senderName,
    required this.localPathFor,
    required this.openImage,
    required this.openDocument,
    required this.openInChat,
    required this.forward,
    required this.deleteForMe,
    required this.deleteForEveryone,
    required this.canDeleteForEveryone,
  });
}

enum _MediaFilter { all, photos, documents, voice }

/// Open the WhatsApp-style media gallery bottom sheet.
void showChatMediaGallery(BuildContext context, MediaGalleryConfig config) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _MediaGallerySheet(config: config),
  );
}

class _MediaGallerySheet extends StatefulWidget {
  final MediaGalleryConfig config;
  const _MediaGallerySheet({required this.config});

  @override
  State<_MediaGallerySheet> createState() => _MediaGallerySheetState();
}

class _MediaGallerySheetState extends State<_MediaGallerySheet> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  _MediaFilter _filter = _MediaFilter.all;
  bool _isSelecting = false;
  final Set<String> _selectedIds = {};

  // Metadata caches: message id -> local file size / pdf page count.
  final Map<String, int> _sizes = {};
  final Map<String, int?> _pdfPages = {};

  MediaGalleryConfig get _cfg => widget.config;

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  List<MessageModel> get _allMedia => _cfg.messages();

  bool _matches(MessageModel m, String q) {
    if (q.isEmpty) return true;
    final name = (m.fileName ?? '').toLowerCase();
    final sender = _cfg.senderName(m.senderId).toLowerCase();
    return name.contains(q) || sender.contains(q);
  }

  List<MessageModel> _filtered(String query) {
    return _allMedia.where((m) {
      if (!_matches(m, query)) return false;
      switch (_filter) {
        case _MediaFilter.photos:
          return m.type == MessageType.image;
        case _MediaFilter.documents:
          return m.type == MessageType.file;
        case _MediaFilter.voice:
          return m.type == MessageType.voice;
        case _MediaFilter.all:
          return true;
      }
    }).toList();
  }

  // ─── Metadata (size / pages) ─────────────────────────────────────────────

  void _loadMetadata(MessageModel m) {
    if (m.fileName == null) return;
    if (_sizes.containsKey(m.id) && _pdfPages.containsKey(m.id)) return;
    () async {
      try {
        final path = await _cfg.localPathFor(m);
        if (path == null) return;
        final file = File(path);
        if (!await file.exists()) return;
        final size = await file.length();
        int? pages;
        if (m.type == MessageType.file &&
            m.fileName!.toLowerCase().endsWith('.pdf')) {
          pages = await _countPdfPages(file);
        }
        if (!mounted) return;
        setState(() {
          _sizes[m.id] = size;
          if (pages != null) _pdfPages[m.id] = pages;
        });
      } catch (_) {}
    }();
  }

  /// Lightweight page count: counts "/Type /Page" objects in the file bytes.
  /// Best-effort only — never blocks the UI and fails silently.
  Future<int?> _countPdfPages(File file) async {
    try {
      if (await file.length() > 50 * 1024 * 1024)
        return null; // skip huge files
      final bytes = await file.readAsBytes();
      final content = String.fromCharCodes(
        bytes.take(bytes.length.clamp(0, 8 * 1024 * 1024)),
      );
      final matches = RegExp(r'/Type\s*/Page[^s]').allMatches(content);
      return matches.isEmpty ? null : matches.length;
    } catch (_) {
      return null;
    }
  }

  String _metaLine(MessageModel m) {
    final parts = <String>[_cfg.senderName(m.senderId)];
    if (m.type == MessageType.voice) {
      parts.add(Helpers.formatDuration(m.duration ?? 0));
    }
    final size = _sizes[m.id];
    if (size != null) parts.add(Helpers.formatFileSize(size));
    final pages = _pdfPages[m.id];
    if (pages != null) parts.add('$pages page${pages == 1 ? '' : 's'}');
    parts.add(Helpers.getRelativeTime(m.createdAt));
    return parts.join(' · ');
  }

  // ─── Selection mode ──────────────────────────────────────────────────────

  void _toggleSelection(MessageModel m) {
    setState(() {
      if (_selectedIds.contains(m.id)) {
        _selectedIds.remove(m.id);
        if (_selectedIds.isEmpty) _isSelecting = false;
      } else {
        _selectedIds.add(m.id);
      }
    });
  }

  void _startSelection(MessageModel m) {
    setState(() {
      _isSelecting = true;
      _selectedIds.add(m.id);
    });
  }

  void _exitSelection() {
    setState(() {
      _isSelecting = false;
      _selectedIds.clear();
    });
  }

  List<MessageModel> get _selectedMessages =>
      _allMedia.where((m) => _selectedIds.contains(m.id)).toList();

  void _bulkForward() {
    final selected = _selectedMessages;
    _exitSelection();
    Navigator.pop(context); // close gallery, forward flow shows target picker
    for (final m in selected) {
      _cfg.forward(m);
    }
  }

  void _bulkShare() async {
    final selected = _selectedMessages;
    final paths = <String>[];
    for (final m in selected) {
      final path = await _cfg.localPathFor(m);
      if (path != null && await File(path).exists()) paths.add(path);
    }
    if (!mounted) return;
    if (paths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Open the files once first so they can be shared'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    await Share.shareXFiles(paths.map((p) => XFile(p)).toList());
    if (mounted) _exitSelection();
  }

  void _bulkDelete() {
    final selected = _selectedMessages;
    final allOwn = selected.every((m) => _cfg.canDeleteForEveryone(m));
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text('Delete for Me (${selected.length})'),
              onTap: () {
                Navigator.pop(ctx);
                _exitSelection();
                Navigator.pop(context); // close gallery
                for (final m in selected) {
                  _cfg.deleteForMe(m);
                }
              },
            ),
            if (allOwn)
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: Text('Delete for Everyone (${selected.length})'),
                onTap: () {
                  Navigator.pop(ctx);
                  _exitSelection();
                  Navigator.pop(context); // close gallery
                  for (final m in selected) {
                    _cfg.deleteForEveryone(m);
                  }
                },
              ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Cancel'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Per-item menu ───────────────────────────────────────────────────────

  void _showItemMenu(MessageModel m) {
    final canShare = _sizes[m.id] != null; // local copy available
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new_outlined),
              title: const Text('Open'),
              onTap: () {
                Navigator.pop(ctx);
                _openItem(m);
              },
            ),
            ListTile(
              leading: Icon(Icons.chat_bubble_outline, color: _cfg.themeColor),
              title: const Text('Open in Chat'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.pop(context); // close gallery
                _cfg.openInChat(m);
              },
            ),
            ListTile(
              leading: const Icon(Icons.forward),
              title: const Text('Forward'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.pop(context); // close gallery
                _cfg.forward(m);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.share,
                color: canShare ? _cfg.themeColor : AppTheme.lightText,
              ),
              title: const Text('Share'),
              subtitle: canShare
                  ? null
                  : const Text(
                      'Open the file once to enable sharing',
                      style: TextStyle(fontSize: 11, color: AppTheme.lightText),
                    ),
              onTap: canShare
                  ? () async {
                      Navigator.pop(ctx);
                      final path = await _cfg.localPathFor(m);
                      if (path != null && await File(path).exists()) {
                        await Share.shareXFiles([XFile(path)]);
                      }
                    }
                  : null,
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('Delete for Me'),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.pop(context); // close gallery
                _cfg.deleteForMe(m);
              },
            ),
            if (_cfg.canDeleteForEveryone(m))
              ListTile(
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text('Delete for Everyone'),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.pop(context); // close gallery
                  _cfg.deleteForEveryone(m);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _openItem(MessageModel m) {
    if (m.type == MessageType.image) {
      _cfg.openImage(m);
    } else if (m.type == MessageType.file) {
      _cfg.openDocument(m);
    }
  }

  // ─── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final all = _allMedia;
    final media = _filtered(query);

    final images = media.where((m) => m.type == MessageType.image).toList();
    final files = media.where((m) => m.type == MessageType.file).toList();
    final voices = media.where((m) => m.type == MessageType.voice).toList();

    // Kick off metadata loads for visible items (cached, runs once per item).
    for (final m in media) {
      _loadMetadata(m);
    }

    final totalSize = _sizes.values.fold<int>(0, (a, b) => a + b);

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => _isSelecting
          ? _buildSelectionLayout(
              scrollController,
              media,
              images,
              files,
              voices,
            )
          : _buildNormalLayout(
              scrollController,
              all,
              media,
              images,
              files,
              voices,
              query,
              totalSize,
            ),
    );
  }

  Widget _buildNormalLayout(
    ScrollController scrollController,
    List<MessageModel> all,
    List<MessageModel> media,
    List<MessageModel> images,
    List<MessageModel> files,
    List<MessageModel> voices,
    String query,
    int totalSize,
  ) {
    return Column(
      children: [
        Container(
          width: 40,
          height: 4,
          margin: const EdgeInsets.only(top: 12, bottom: 12),
          decoration: BoxDecoration(
            color: AppTheme.lightText.withOpacity(0.3),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Text(
                'Media, Links & Docs',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: _cfg.themeColor,
                ),
              ),
              const Spacer(),
              Text(
                '${all.length} items'
                '${totalSize > 0 ? ' · ${Helpers.formatFileSize(totalSize)}' : ''}',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.secondaryText,
                ),
              ),
            ],
          ),
        ),
        // Search
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search by file name or sender',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: query.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {});
                      },
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.lightGrey),
              ),
            ),
            onChanged: (value) => setState(() {}),
          ),
        ),
        // Filter chips
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              _filterChip(_MediaFilter.all, 'All (${all.length})'),
              _filterChip(
                _MediaFilter.photos,
                'Photos (${all.where((m) => m.type == MessageType.image).length})',
              ),
              _filterChip(
                _MediaFilter.documents,
                'Documents (${all.where((m) => m.type == MessageType.file).length})',
              ),
              _filterChip(
                _MediaFilter.voice,
                'Voice (${all.where((m) => m.type == MessageType.voice).length})',
              ),
            ],
          ),
        ),
        Expanded(
          child: media.isEmpty
              ? Center(
                  child: Text(
                    query.isNotEmpty
                        ? 'No attachments match "$query"'
                        : 'No attachments yet',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppTheme.lightText,
                    ),
                  ),
                )
              : ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  children: [
                    if (images.isNotEmpty) ...[
                      _sectionHeader('Photos', images.length),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 3,
                              mainAxisSpacing: 3,
                            ),
                        itemCount: images.length,
                        itemBuilder: (context, i) => _imageTile(images[i]),
                      ),
                    ],
                    if (files.isNotEmpty) ...[
                      _sectionHeader('Documents', files.length),
                      ...files.map(_documentTile),
                    ],
                    if (voices.isNotEmpty) ...[
                      _sectionHeader('Voice Notes', voices.length),
                      ...voices.map(_voiceTile),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildSelectionLayout(
    ScrollController scrollController,
    List<MessageModel> media,
    List<MessageModel> images,
    List<MessageModel> files,
    List<MessageModel> voices,
  ) {
    return Column(
      children: [
        // Selection AppBar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          color: _cfg.themeColor,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: _exitSelection,
              ),
              Text(
                '${_selectedIds.length} selected',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.share, color: Colors.white),
                tooltip: 'Share',
                onPressed: _bulkShare,
              ),
              IconButton(
                icon: const Icon(Icons.forward, color: Colors.white),
                tooltip: 'Forward',
                onPressed: _bulkForward,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, color: Colors.white),
                tooltip: 'Delete',
                onPressed: _bulkDelete,
              ),
            ],
          ),
        ),
        Expanded(
          child: media.isEmpty
              ? const Center(
                  child: Text(
                    'No attachments',
                    style: TextStyle(fontSize: 13, color: AppTheme.lightText),
                  ),
                )
              : ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    if (images.isNotEmpty) ...[
                      _sectionHeader('Photos', images.length),
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 3,
                              mainAxisSpacing: 3,
                            ),
                        itemCount: images.length,
                        itemBuilder: (context, i) => _imageTile(images[i]),
                      ),
                    ],
                    if (files.isNotEmpty) ...[
                      _sectionHeader('Documents', files.length),
                      ...files.map(_documentTile),
                    ],
                    if (voices.isNotEmpty) ...[
                      _sectionHeader('Voice Notes', voices.length),
                      ...voices.map(_voiceTile),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  // ─── Tiles ───────────────────────────────────────────────────────────────

  Widget _filterChip(_MediaFilter filter, String label) {
    final active = _filter == filter;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: active ? Colors.white : AppTheme.secondaryText,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        selected: active,
        selectedColor: _cfg.themeColor,
        backgroundColor: AppTheme.lightGrey,
        onSelected: (_) => setState(() => _filter = filter),
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  Widget _sectionHeader(String title, int count) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        '$title ($count)',
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: AppTheme.secondaryText,
        ),
      ),
    );
  }

  bool _isSelected(MessageModel m) => _selectedIds.contains(m.id);

  Widget _selectionBadge(MessageModel m) {
    final selected = _isSelected(m);
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? _cfg.themeColor : Colors.white.withOpacity(0.85),
        border: Border.all(
          color: selected ? _cfg.themeColor : Colors.grey.shade400,
          width: 1.5,
        ),
      ),
      child: selected
          ? const Icon(Icons.check, size: 14, color: Colors.white)
          : null,
    );
  }

  void _handleTap(MessageModel m) {
    if (_isSelecting) {
      _toggleSelection(m);
    } else {
      _openItem(m);
    }
  }

  Widget _imageTile(MessageModel m) {
    final selected = _isSelected(m);
    return GestureDetector(
      onTap: () => _handleTap(m),
      onLongPress: () =>
          _isSelecting ? _toggleSelection(m) : _startSelection(m),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: CachedNetworkImage(
              imageUrl: m.fileUrl ?? '',
              fit: BoxFit.cover,
              placeholder: (_, __) => Container(color: AppTheme.lightGrey),
              errorWidget: (_, __, ___) => Container(
                color: AppTheme.lightGrey,
                child: const Icon(Icons.broken_image),
              ),
            ),
          ),
          if (selected)
            Container(
              decoration: BoxDecoration(
                color: _cfg.themeColor.withOpacity(0.3),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _cfg.themeColor, width: 2),
              ),
            ),
          Positioned(
            top: 4,
            left: 4,
            child: Visibility(
              visible: _isSelecting || selected,
              child: _selectionBadge(m),
            ),
          ),
          if (_sizes[m.id] != null)
            Positioned(
              bottom: 2,
              right: 4,
              child: Text(
                Helpers.formatFileSize(_sizes[m.id]!),
                style: const TextStyle(
                  fontSize: 9,
                  color: Colors.white,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 2)],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _documentTile(MessageModel m) {
    final selected = _isSelected(m);
    final info = _fileTypeInfo(m.fileName ?? '');
    return InkWell(
      onTap: () => _handleTap(m),
      onLongPress: () =>
          _isSelecting ? _toggleSelection(m) : _startSelection(m),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _cfg.themeColor.withOpacity(0.08) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? _cfg.themeColor
                : AppTheme.lightGrey.withOpacity(0.8),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            if (_isSelecting) ...[
              _selectionBadge(m),
              const SizedBox(width: 10),
            ],
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: info.color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(info.icon, color: info.color, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.fileName ?? 'Unknown',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryText,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _metaLine(m),
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.secondaryText,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.more_vert, size: 20, color: AppTheme.lightText),
              onPressed: () => _showItemMenu(m),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          ],
        ),
      ),
    );
  }

  Widget _voiceTile(MessageModel m) {
    final selected = _isSelected(m);
    return InkWell(
      onTap: () => _handleTap(m),
      onLongPress: () =>
          _isSelecting ? _toggleSelection(m) : _startSelection(m),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _cfg.themeColor.withOpacity(0.08) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected
                ? _cfg.themeColor
                : AppTheme.lightGrey.withOpacity(0.8),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            if (_isSelecting) ...[
              _selectionBadge(m),
              const SizedBox(width: 10),
            ],
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: AppTheme.primaryGreen.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.mic,
                color: AppTheme.primaryGreen,
                size: 22,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Voice message',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryText,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _metaLine(m),
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.secondaryText,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.more_vert, size: 20, color: AppTheme.lightText),
              onPressed: () => _showItemMenu(m),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            ),
          ],
        ),
      ),
    );
  }

  /// Icon + color per file extension.
  ({IconData icon, Color color}) _fileTypeInfo(String fileName) {
    final ext = fileName.toLowerCase().split('.').last;
    switch (ext) {
      case 'pdf':
        return (icon: Icons.picture_as_pdf, color: const Color(0xFFE53935));
      case 'doc':
      case 'docx':
        return (icon: Icons.description, color: const Color(0xFF1565C0));
      case 'xls':
      case 'xlsx':
      case 'csv':
        return (icon: Icons.table_chart, color: const Color(0xFF2E7D32));
      case 'ppt':
      case 'pptx':
        return (icon: Icons.slideshow, color: const Color(0xFFEF6C00));
      case 'zip':
      case 'rar':
      case '7z':
        return (icon: Icons.folder_zip, color: const Color(0xFF6D4C41));
      case 'txt':
        return (icon: Icons.article, color: const Color(0xFF546E7A));
      default:
        return (icon: Icons.insert_drive_file, color: const Color(0xFF1971C2));
    }
  }
}
