import 'package:flutter/material.dart';
import '../services/business_vocabulary.dart';
import '../utils/constants.dart';

/// Sector ("business type") chooser — the SINGLE picker implementation shared
/// by the Settings → Preferences tile and the drawer's top-level "Sector" item,
/// so the two entry points can never drift apart.
///
/// Changing the sector re-labels module vocabularies (e.g. "Task" → "Job") and
/// re-seeds milestone TEMPLATES, so only NEW items pick them up; existing items
/// keep their setup. That makes it always safe to change — exactly what the
/// onboarding picker does, just re-entered later.
///
/// Returns the id of the newly-applied sector when the user actually changed
/// it, or null when the dialog was cancelled or the selection was unchanged.
/// Callers use that to decide whether a label refresh / module rebuild is
/// warranted (the [BusinessVocabulary] getters read an in-memory cache
/// synchronously, so already-built widgets need an explicit rebuild to
/// re-resolve).
Future<String?> showSectorPicker(BuildContext context) async {
  final currentId = BusinessVocabulary.current?.id ?? 'general';
  var selectedId = currentId;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (context, setSheetState) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Business type'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Names items and pre-fills tracking steps to match how you '
                  'work. Applies to new items — existing ones stay unchanged.',
                  style: TextStyle(fontSize: 13, color: AppTheme.secondaryText),
                ),
                const SizedBox(height: 8),
                // Grouped by front-door module (Option A), matching the
                // onboarding picker so the two surfaces stay in parity.
                for (final group in SectorTemplates.pickerGroups) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.title.toUpperCase(),
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                            color: AppTheme.headerGreen,
                          ),
                        ),
                        if (group.subtitle.isNotEmpty)
                          Text(
                            group.subtitle,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: AppTheme.secondaryText,
                            ),
                          ),
                      ],
                    ),
                  ),
                  for (final sector in group.sectors)
                    RadioListTile<String>(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 4,
                      ),
                      title: Text(
                        sector.label,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: sector.examples.isEmpty
                          ? Text(
                              sector.blurb,
                              style: const TextStyle(fontSize: 12),
                            )
                          : Text(
                              '${sector.blurb}\n${sector.examples}',
                              style: const TextStyle(
                                fontSize: 12,
                                height: 1.3,
                              ),
                            ),
                      value: sector.id,
                      groupValue: selectedId,
                      activeColor: AppTheme.headerGreen,
                      onChanged: (v) =>
                          setSheetState(() => selectedId = v ?? selectedId),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryGreen,
              foregroundColor: Colors.white,
            ),
            child: const Text('Apply'),
          ),
        ],
      ),
    ),
  );

  if (confirmed != true) return null;
  if (selectedId == currentId) return null;

  await BusinessVocabulary.set(selectedId);
  return selectedId;
}
