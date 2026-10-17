import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/message.dart';
import '../../providers/auth_provider.dart';
import '../../utils/constants.dart';
import '../../utils/export_service.dart';
import '../../utils/paywall_constants.dart';

/// Shared "3-dot" chat capabilities for detail screens: conversation search
/// (with in-document deep search), screenshot share, and full-transcript export.
///
/// Extracted verbatim from the task detail screen (the base module) so that the
/// task and sales/CRM detail screens offer the SAME chat menu. The base
/// screen's behaviour and UI are unchanged — its code moved here as-is and the
/// host now delegates through a handful of lightweight hooks (the message list,
/// scroll-to-message, sender-name and title lookups). Search-result highlight
/// rendering is already provided by [DetailChatBubblesMixin] via the
/// `chatIsCurrentSearchResult` / `chatSearchInsideDocument` hooks, which this
/// mixin implements against its own search state.
mixin DetailChatMenuMixin<T extends StatefulWidget> on State<T> {
  // ---- Host hooks the adopting screen must provide ----

  /// Chronological message list the conversation search iterates over.
  List<MessageModel> get chatSearchMessages;

  /// Message source for the export transcript. Defaults to [chatSearchMessages];
  /// the task screen overrides this to prefer the fuller `_allMessages` cache.
  List<MessageModel> get chatExportMessages => chatSearchMessages;

  /// Scroll the chat list to reveal the message with [messageId].
  void chatScrollToMessageById(String messageId);

  /// Resolve a sender id to a display name (used by the export rows).
  String chatSenderNameFor(String senderId);

  /// Human title for the conversation, used for the export file name and the
  /// share sheet text (e.g. the task or enquiry title).
  String get chatExportTitle;

  /// Noun prefix for the share-sheet text ("Task", "Enquiry", ...).
  String get chatShareSubjectLabel;

  /// File-name prefix for the captured screenshot PNG.
  String get chatScreenshotFilePrefix => 'chat_screenshot';

  // ---- Owned state ----
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchCategory =
      'All'; // All, Messages, Media, Files, Documents, Links
  List<String> _searchResultMessageIds = [];
  int _currentSearchIndex = 0;
  String? _currentSnippet; // Snippet from inside document search

  /// RepaintBoundary key the host must wrap its chat body with so
  /// [shareChatScreenshot] can capture it.
  final GlobalKey chatScreenshotKey = GlobalKey();

  // ---- Public surface the host screen wires into its build / menu ----

  /// Whether the conversation search bar is currently shown.
  bool get isChatSearching => _isSearching;

  /// True when [messageId] is one of the active search matches (drives the
  /// bubble highlight supplied by [DetailChatBubblesMixin]).
  bool chatIsSearchMatch(String messageId) =>
      _isSearching && _searchResultMessageIds.contains(messageId);

  void toggleChatSearch() {
    setState(() {
      _isSearching = !_isSearching;
      if (!_isSearching) {
        _searchController.clear();
        _searchResultMessageIds = [];
        _currentSearchIndex = 0;
        _searchCategory = 'All';
      }
    });
    if (_isSearching) {
      // Focus search field after frame
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          FocusScope.of(context).requestFocus(FocusNode());
        }
      });
    }
  }

  void _performSearch(String query) {
    if (query.isEmpty) {
      setState(() {
        _searchResultMessageIds = [];
        _currentSearchIndex = 0;
      });
      return;
    }

    final q = query.toLowerCase();
    final results = <String>[];
    String? snippet;

    final messages = chatSearchMessages;
    for (int i = 0; i < messages.length; i++) {
      final msg = messages[i];
      if (msg.type == MessageType.system) continue;

      bool matches = false;

      switch (_searchCategory) {
        case 'Messages':
          matches =
              msg.type == MessageType.text &&
              msg.text.toLowerCase().contains(q);
          break;
        case 'Media':
          matches = msg.type == MessageType.image;
          break;
        case 'Files':
          matches =
              msg.type == MessageType.file &&
              (msg.fileName?.toLowerCase().contains(q) ?? false);
          break;
        case 'Documents':
          // Search INSIDE document content (PDF extracted text)
          if (msg.type == MessageType.file &&
              msg.searchableContent != null &&
              msg.searchableContent!.toLowerCase().contains(q)) {
            matches = true;
            // Extract snippet around the match
            snippet = _extractSnippet(msg.searchableContent!, query);
          }
          break;
        case 'Links':
          matches =
              msg.text.toLowerCase().contains('http') ||
              (msg.fileUrl?.toLowerCase().contains('http') ?? false);
          break;
        case 'All':
        default:
          matches =
              msg.text.toLowerCase().contains(q) ||
              (msg.fileName?.toLowerCase().contains(q) ?? false) ||
              (msg.type == MessageType.image) ||
              (msg.type == MessageType.file) ||
              (msg.type == MessageType.voice);
          // Also search inside document content
          if (!matches &&
              msg.type == MessageType.file &&
              msg.searchableContent != null &&
              msg.searchableContent!.toLowerCase().contains(q)) {
            matches = true;
            snippet = _extractSnippet(msg.searchableContent!, query);
          }
          break;
      }

      if (matches) results.add(messages[i].id);
    }

    setState(() {
      _searchResultMessageIds = results;
      _currentSearchIndex = results.isNotEmpty ? 0 : 0;
      _currentSnippet = snippet;
    });

    // Scroll to first result
    if (results.isNotEmpty) {
      chatScrollToMessageById(results.first);
    }
  }

  // Extract a snippet of text around the search match
  String _extractSnippet(String content, String query) {
    final lowerContent = content.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final index = lowerContent.indexOf(lowerQuery);
    if (index == -1) return '';

    const snippetLength = 80;
    final start = (index - snippetLength ~/ 2).clamp(0, content.length);
    final end = (index + query.length + snippetLength ~/ 2).clamp(
      0,
      content.length,
    );

    String snippet = content.substring(start, end).trim();
    if (start > 0) snippet = '...$snippet';
    if (end < content.length) snippet = '$snippet...';
    return snippet;
  }

  // Get highlighted snippet with RichText
  Widget _buildHighlightedSnippet(String snippet, String query) {
    final lowerSnippet = snippet.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final spans = <TextSpan>[];
    int pos = 0;

    while (pos < snippet.length) {
      final matchStart = lowerSnippet.indexOf(lowerQuery, pos);
      if (matchStart == -1) {
        spans.add(TextSpan(text: snippet.substring(pos)));
        break;
      }
      if (matchStart > pos) {
        spans.add(TextSpan(text: snippet.substring(pos, matchStart)));
      }
      spans.add(
        TextSpan(
          text: snippet.substring(matchStart, matchStart + query.length),
          style: const TextStyle(
            backgroundColor: Colors.yellow,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      pos = matchStart + query.length;
    }

    return RichText(
      text: TextSpan(
        style: const TextStyle(
          fontSize: 12,
          color: AppTheme.secondaryText,
          height: 1.3,
        ),
        children: spans,
      ),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }

  void _nextResult() {
    if (_searchResultMessageIds.isEmpty) return;
    setState(() {
      _currentSearchIndex =
          (_currentSearchIndex + 1) % _searchResultMessageIds.length;
    });
    chatScrollToMessageById(_searchResultMessageIds[_currentSearchIndex]);
  }

  void _previousResult() {
    if (_searchResultMessageIds.isEmpty) return;
    setState(() {
      _currentSearchIndex =
          (_currentSearchIndex - 1 + _searchResultMessageIds.length) %
          _searchResultMessageIds.length;
    });
    chatScrollToMessageById(_searchResultMessageIds[_currentSearchIndex]);
  }

  Widget buildChatSearchBar() {
    final categories = [
      'All',
      'Messages',
      'Media',
      'Files',
      'Documents',
      'Links',
    ];
    return Container(
      color: Colors.white,
      child: Column(
        children: [
          // Search input row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                // Back button
                IconButton(
                  icon: const Icon(
                    Icons.arrow_back,
                    color: AppTheme.headerGreen,
                  ),
                  onPressed: toggleChatSearch,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 40,
                    minHeight: 40,
                  ),
                ),
                // Search field
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    autofocus: true,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      hintText: 'Search in conversation...',
                      hintStyle: const TextStyle(
                        color: AppTheme.lightText,
                        fontSize: 15,
                      ),
                      border: InputBorder.none,
                      suffixIcon: _searchController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 20),
                              onPressed: () {
                                _searchController.clear();
                                _performSearch('');
                              },
                            )
                          : null,
                    ),
                    onChanged: _performSearch,
                  ),
                ),
                // Navigation arrows
                if (_searchResultMessageIds.isNotEmpty) ...[
                  Text(
                    '${_currentSearchIndex + 1}/${_searchResultMessageIds.length}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.secondaryText,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_up, size: 20),
                    onPressed: _previousResult,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                    onPressed: _nextResult,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Category tabs
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: categories.map((cat) {
                final isSelected = _searchCategory == cat;
                // Count results per category
                final count = _countCategoryResults(cat);
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(cat),
                        if (count > 0 && _searchController.text.isNotEmpty) ...[
                          const SizedBox(width: 4),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? AppTheme.headerGreen
                                  : AppTheme.lightText.withOpacity(0.3),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '$count',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: isSelected
                                    ? Colors.white
                                    : AppTheme.secondaryText,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    selected: isSelected,
                    onSelected: (_) {
                      setState(() {
                        _searchCategory = cat;
                      });
                      _performSearch(_searchController.text);
                    },
                    selectedColor: AppTheme.lightGreen,
                    backgroundColor: AppTheme.lightGrey,
                    labelStyle: TextStyle(
                      fontSize: 13,
                      color: isSelected
                          ? AppTheme.headerGreen
                          : AppTheme.secondaryText,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                    showCheckmark: false,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 4),
          // Snippet display for document search results
          if (_currentSnippet != null && _searchController.text.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: Colors.yellow.withOpacity(0.08),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.article,
                    size: 18,
                    color: AppTheme.headerGreen,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Found inside document',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.headerGreen,
                          ),
                        ),
                        const SizedBox(height: 2),
                        _buildHighlightedSnippet(
                          _currentSnippet!,
                          _searchController.text,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
          // Divider
          Container(height: 1, color: AppTheme.dividerColor),
        ],
      ),
    );
  }

  int _countCategoryResults(String category) {
    final q = _searchController.text.toLowerCase();
    int count = 0;
    for (final msg in chatSearchMessages) {
      if (msg.type == MessageType.system) continue;
      switch (category) {
        case 'Messages':
          if (msg.type == MessageType.text &&
              msg.text.toLowerCase().contains(q))
            count++;
          break;
        case 'Media':
          if (msg.type == MessageType.image) count++;
          break;
        case 'Files':
          if (msg.type == MessageType.file &&
              (msg.fileName?.toLowerCase().contains(q) ?? false))
            count++;
          break;
        case 'Documents':
          if (msg.type == MessageType.file &&
              msg.searchableContent != null &&
              msg.searchableContent!.toLowerCase().contains(q))
            count++;
          break;
        case 'Links':
          if (msg.text.toLowerCase().contains('http') ||
              (msg.fileUrl?.toLowerCase().contains('http') ?? false))
            count++;
          break;
        case 'All':
          if (msg.text.toLowerCase().contains(q) ||
              (msg.fileName?.toLowerCase().contains(q) ?? false) ||
              msg.type == MessageType.image ||
              msg.type == MessageType.file ||
              msg.type == MessageType.voice ||
              (msg.searchableContent?.toLowerCase().contains(q) ?? false))
            count++;
          break;
      }
    }
    return count;
  }

  // ---- Bubbles-mixin hooks (implemented against this mixin's search state) ----

  /// True when [messageId] is the currently-focused search result (bubbles
  /// highlight it more strongly than the other matches).
  bool chatIsCurrentSearchResult(String messageId) =>
      _searchResultMessageIds.indexOf(messageId) == _currentSearchIndex;

  /// Hook the bubbles layer uses to offer "Search inside document" on file
  /// messages that carry extracted text.
  void Function(MessageModel message)? get chatSearchInsideDocument =>
      searchInsideDocument;

  // ---- Share (chat screenshot) ----

  Future<void> shareChatScreenshot() async {
    try {
      // Show loading indicator
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Capturing screenshot...'),
          duration: Duration(seconds: 1),
        ),
      );

      // Wait for UI to settle
      await Future.delayed(const Duration(milliseconds: 300));

      final boundary =
          chatScreenshotKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Failed to capture screenshot'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final pngBytes = byteData.buffer.asUint8List();
      final tempDir = await getTemporaryDirectory();
      final file = await File(
        '${tempDir.path}/${chatScreenshotFilePrefix}_${DateTime.now().millisecondsSinceEpoch}.png',
      ).create();
      await file.writeAsBytes(pngBytes);

      if (!mounted) return;
      await Share.shareXFiles([
        XFile(file.path),
      ], text: '$chatShareSubjectLabel: $chatExportTitle');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error capturing screenshot: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // ---- Export (full transcript: messages, actions, edits) ----

  /// Export the full chat transcript — all messages, actions, edits and
  /// system events in chronological order — to CSV / Excel / PDF.
  void exportChat() {
    final planType = context.read<AuthProvider>().effectivePlanType;
    if (!PaywallLimits.canExport(planType)) {
      showPaywallDialog(
        context,
        feature: 'Export is a Premium feature.',
        detail:
            'Upgrade to Premium to export the full chat to CSV, Excel and PDF.',
      );
      return;
    }

    final msgs = List<MessageModel>.from(chatExportMessages)..sort(
      (a, b) => a.createdAt.compareTo(b.createdAt),
    );

    if (msgs.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No messages to export')));
      return;
    }

    String typeLabel(MessageModel m) {
      if (m.type == MessageType.system) {
        switch (m.systemType) {
          case SystemMessageType.reminder:
            return 'Reminder';
          case SystemMessageType.warning:
            return 'Warning';
          case SystemMessageType.query:
            return 'Query';
          case SystemMessageType.followUp:
            return 'Follow-up';
          case SystemMessageType.call:
            return 'Scheduled Call';
          case SystemMessageType.statusChange:
            return 'Status Change';
          case SystemMessageType.assigneeChange:
            return 'Assignee Change';
          case SystemMessageType.progressChange:
            return 'Progress Change';
          case SystemMessageType.blocker:
            return 'Blocker';
          case SystemMessageType.approval:
            return 'Request';
          case SystemMessageType.extension:
            return 'Extension Request';
          case SystemMessageType.progressReport:
            return 'Progress Report';
          case SystemMessageType.regular:
            return 'Action';
        }
      }
      switch (m.type) {
        case MessageType.image:
          return 'Image';
        case MessageType.file:
          return 'File';
        case MessageType.voice:
          return 'Voice';
        default:
          return 'Message';
      }
    }

    String content(MessageModel m) {
      var text = m.text;
      if ((m.type == MessageType.image || m.type == MessageType.file) &&
          (m.fileName?.isNotEmpty ?? false)) {
        text = text.isEmpty ? '[${m.fileName}]' : '$text [${m.fileName}]';
      } else if (m.type == MessageType.voice) {
        final dur = m.duration != null ? ' ${m.duration}s' : '';
        text = text.isEmpty ? '[Voice note$dur]' : text;
      }
      if (m.deleted) text = '[deleted]';
      if (m.replyToMessageText != null && m.replyToMessageText!.isNotEmpty) {
        text = 'Re: "${m.replyToMessageText}" — $text';
      }
      if (m.queryReply != null && m.queryReply!.isNotEmpty) {
        text = '$text | Reply: ${m.queryReply}';
      }
      if (m.isEdited) text = '$text (edited)';
      return text;
    }

    final headers = ['#', 'Date & Time', 'Sender', 'Type', 'Message'];
    final df = DateFormat('dd/MM/yyyy hh:mm a');
    var i = 1;
    final rows = msgs
        .map(
          (m) => [
            '${i++}',
            df.format(m.createdAt),
            chatSenderNameFor(m.senderId),
            typeLabel(m),
            content(m),
          ],
        )
        .toList();

    ExportService.showExportDialog(
      context: context,
      headers: headers,
      rows: rows,
      title: 'Chat_$chatExportTitle',
      filterLabel: 'Full',
    );
  }

  // ---- In-document deep search ----

  void searchInsideDocument(MessageModel message) {
    final docContent = message.searchableContent ?? '';
    final searchCtrl = TextEditingController();
    List<int> matchPositions = [];
    int currentMatch = 0;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            void doSearch(String query) {
              if (query.isEmpty) {
                setModalState(() {
                  matchPositions = [];
                  currentMatch = 0;
                });
                return;
              }
              final q = query.toLowerCase();
              final content = docContent.toLowerCase();
              final positions = <int>[];
              int idx = 0;
              while (true) {
                idx = content.indexOf(q, idx);
                if (idx == -1) break;
                positions.add(idx);
                idx += q.length;
              }
              setModalState(() {
                matchPositions = positions;
                currentMatch = 0;
              });
            }

            return Container(
              height: MediaQuery.of(context).size.height * 0.75,
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Column(
                children: [
                  // Header
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: const BoxDecoration(
                      color: AppTheme.headerGreen,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(16),
                      ),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.article, color: Colors.white),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                message.fileName ?? 'Document',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const Text(
                                'Search & view document content',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),
                  // Search bar
                  Container(
                    padding: const EdgeInsets.all(12),
                    color: Colors.white,
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: searchCtrl,
                            decoration: InputDecoration(
                              hintText: 'Search inside ${message.fileName}...',
                              hintStyle: const TextStyle(
                                fontSize: 14,
                                color: AppTheme.lightText,
                              ),
                              prefixIcon: const Icon(
                                Icons.search,
                                size: 20,
                                color: AppTheme.headerGreen,
                              ),
                              filled: true,
                              fillColor: AppTheme.lightGrey,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(24),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10,
                              ),
                              isDense: true,
                            ),
                            onChanged: doSearch,
                          ),
                        ),
                        if (matchPositions.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(
                            '${currentMatch + 1}/${matchPositions.length}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.headerGreen,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.keyboard_arrow_up,
                              color: AppTheme.headerGreen,
                            ),
                            onPressed: () {
                              setModalState(() {
                                currentMatch =
                                    (currentMatch - 1 + matchPositions.length) %
                                    matchPositions.length;
                              });
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.keyboard_arrow_down,
                              color: AppTheme.headerGreen,
                            ),
                            onPressed: () {
                              setModalState(() {
                                currentMatch =
                                    (currentMatch + 1) % matchPositions.length;
                              });
                            },
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 32,
                              minHeight: 32,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  // Match count info
                  if (searchCtrl.text.isNotEmpty && matchPositions.isEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      color: Colors.red.withOpacity(0.05),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.info_outline,
                            size: 16,
                            color: Colors.red,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'No matches found for "${searchCtrl.text}"',
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.red,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (matchPositions.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      color: Colors.yellow.withOpacity(0.08),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.check_circle,
                            size: 16,
                            color: AppTheme.headerGreen,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${matchPositions.length} match${matchPositions.length > 1 ? 'es' : ''} found',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.headerGreen,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Document content with highlights
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child:
                          searchCtrl.text.isNotEmpty &&
                              matchPositions.isNotEmpty
                          ? _buildDocumentContentWithHighlights(
                              docContent,
                              searchCtrl.text,
                              matchPositions,
                              currentMatch,
                            )
                          : SelectableText(
                              docContent,
                              style: const TextStyle(
                                fontSize: 14,
                                color: AppTheme.primaryText,
                                height: 1.6,
                              ),
                            ),
                    ),
                  ),
                  // Bottom bar with document stats
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.lightGrey,
                      border: Border(
                        top: BorderSide(color: AppTheme.dividerColor),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _buildDocStat(
                          Icons.text_fields,
                          '${docContent.length} chars',
                        ),
                        _buildDocStat(
                          Icons.wrap_text,
                          '${docContent.split('\n').length} lines',
                        ),
                        _buildDocStat(
                          Icons.short_text,
                          '${docContent.split(RegExp(r'\s+')).length} words',
                        ),
                        if (matchPositions.isNotEmpty)
                          _buildDocStat(
                            Icons.search,
                            '${matchPositions.length} matches',
                            isHighlight: true,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDocStat(
    IconData icon,
    String label, {
    bool isHighlight = false,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 14,
          color: isHighlight ? AppTheme.headerGreen : AppTheme.lightText,
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: isHighlight ? AppTheme.headerGreen : AppTheme.lightText,
            fontWeight: isHighlight ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    );
  }

  Widget _buildDocumentContentWithHighlights(
    String content,
    String query,
    List<int> matchPositions,
    int currentMatch,
  ) {
    final spans = <TextSpan>[];
    int pos = 0;
    final lowerContent = content.toLowerCase();
    final lowerQuery = query.toLowerCase();

    int matchIdx = 0;
    while (pos < content.length) {
      final matchStart = lowerContent.indexOf(lowerQuery, pos);
      if (matchStart == -1) {
        spans.add(TextSpan(text: content.substring(pos)));
        break;
      }
      if (matchStart > pos) {
        spans.add(TextSpan(text: content.substring(pos, matchStart)));
      }
      final isCurrentMatch = matchIdx == currentMatch;
      spans.add(
        TextSpan(
          text: content.substring(matchStart, matchStart + query.length),
          style: TextStyle(
            backgroundColor: isCurrentMatch
                ? Colors.orange.withOpacity(0.5)
                : Colors.yellow.withOpacity(0.4),
            fontWeight: isCurrentMatch ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      );
      pos = matchStart + query.length;
      matchIdx++;
    }

    return RichText(
      text: TextSpan(
        style: const TextStyle(
          fontSize: 14,
          color: AppTheme.primaryText,
          height: 1.6,
        ),
        children: spans,
      ),
    );
  }

  /// Tear down menu-owned resources. Hosts call this from their `dispose()`.
  void disposeDetailChatMenu() {
    _searchController.dispose();
  }
}
