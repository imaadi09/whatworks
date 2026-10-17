import 'package:flutter/material.dart';
import '../../utils/constants.dart';

class RatingDialog extends StatefulWidget {
  final String title;
  final ValueChanged<int> onRatingSubmitted;
  final Map<String, int>? initialCriteriaRatings;

  const RatingDialog({
    super.key,
    required this.title,
    required this.onRatingSubmitted,
    this.initialCriteriaRatings,
  });

  @override
  State<RatingDialog> createState() => _RatingDialogState();
}

class _RatingDialogState extends State<RatingDialog> {
  int _selectedRating = 0;
  final TextEditingController _commentController = TextEditingController();

  // Criteria ratings
  final Map<String, int> _criteriaRatings = {
    'Quality': 0,
    'Timeliness': 0,
    'Communication': 0,
  };

  bool _showCriteria = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialCriteriaRatings != null) {
      _criteriaRatings.addAll(widget.initialCriteriaRatings!);
    }
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 400),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Title
            Text(
              widget.title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: AppTheme.headerGreen,
              ),
            ),
            const SizedBox(height: 20),

            // Star rating
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(5, (index) {
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedRating = index + 1;
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(
                      index < _selectedRating ? Icons.star : Icons.star_border,
                      size: 40,
                      color: index < _selectedRating
                          ? Colors.amber
                          : Colors.grey.shade300,
                    ),
                  ),
                );
              }),
            ),

            if (_selectedRating > 0) ...[
              const SizedBox(height: 8),
              Text(
                _getRatingText(_selectedRating),
                style: const TextStyle(
                  fontSize: 14,
                  color: AppTheme.secondaryText,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],

            const SizedBox(height: 20),

            // Comment field
            TextField(
              controller: _commentController,
              decoration: InputDecoration(
                hintText: 'Add a comment (optional)...',
                hintStyle: const TextStyle(fontSize: 13),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                isDense: true,
              ),
              maxLines: 3,
            ),

            const SizedBox(height: 12),

            // Show criteria breakdown toggle
            InkWell(
              onTap: () {
                setState(() {
                  _showCriteria = !_showCriteria;
                });
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _showCriteria ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: AppTheme.headerGreen,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Rate specific criteria',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.headerGreen,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),

            // Criteria ratings
            if (_showCriteria) ...[
              const SizedBox(height: 12),
              ..._criteriaRatings.entries.map(
                (entry) => _buildCriteriaRow(entry.key, entry.value, (value) {
                  setState(() {
                    _criteriaRatings[entry.key] = value;
                  });
                }),
              ),
            ],

            const SizedBox(height: 20),

            // Buttons
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _selectedRating > 0
                        ? () {
                            widget.onRatingSubmitted(_selectedRating);
                            // In a real app, you'd also save comment and criteriaRatings
                          }
                        : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.headerGreen,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Submit'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCriteriaRow(
    String criteria,
    int value,
    ValueChanged<int> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              criteria,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Row(
              children: List.generate(5, (index) {
                return Expanded(
                  child: GestureDetector(
                    onTap: () => onChanged(index + 1),
                    child: Container(
                      height: 30,
                      margin: const EdgeInsets.symmetric(horizontal: 2),
                      decoration: BoxDecoration(
                        color: index < value
                            ? AppTheme.headerGreen
                            : AppTheme.lightGrey,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: index < value
                              ? AppTheme.headerGreen
                              : AppTheme.lightText.withOpacity(0.3),
                        ),
                      ),
                      child: Center(
                        child: Text(
                          '${index + 1}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: index < value
                                ? Colors.white
                                : AppTheme.secondaryText,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  String _getRatingText(int rating) {
    switch (rating) {
      case 1:
        return 'Poor - Needs significant improvement';
      case 2:
        return 'Fair - Below expectations';
      case 3:
        return 'Good - Meets expectations';
      case 4:
        return 'Very Good - Above expectations';
      case 5:
        return 'Excellent - Outstanding performance!';
      default:
        return '';
    }
  }
}
