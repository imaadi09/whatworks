import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../models/rating.dart';
import '../../models/user.dart';
import '../../utils/constants.dart';

class RatingsDetailScreen extends StatefulWidget {
  final String title;
  final List<int> ratings; // All ratings for this task/person
  final List<Map<String, dynamic>>
  ratingDetails; // Full rating details with comments
  final Map<String, List<int>>? criteriaRatings; // Criteria breakdown
  final VoidCallback? onAddRating; // Optional "add/update rating" action

  const RatingsDetailScreen({
    super.key,
    required this.title,
    required this.ratings,
    required this.ratingDetails,
    this.criteriaRatings,
    this.onAddRating,
  });

  @override
  State<RatingsDetailScreen> createState() => _RatingsDetailScreenState();
}

class _RatingsDetailScreenState extends State<RatingsDetailScreen> {
  late RatingStats _stats;
  bool _showAllRatings = false;

  @override
  void initState() {
    super.initState();
    _stats = RatingStats.calculate(
      widget.ratings,
      criteriaRatings: widget.criteriaRatings,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.chatCanvas(context),
      appBar: AppBar(
        backgroundColor: AppTheme.headerGreen,
        foregroundColor: Colors.white,
        title: Text(widget.title),
      ),
      floatingActionButton: widget.onAddRating == null
          ? null
          : FloatingActionButton.extended(
              onPressed: widget.onAddRating,
              icon: const Icon(Icons.star, color: Colors.white),
              label: const Text(
                'Rate',
                style: TextStyle(color: Colors.white),
              ),
              backgroundColor: AppTheme.headerGreen,
            ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Summary card
          _buildSummaryCard(),

          const SizedBox(height: 24),

          // Rating distribution
          _buildDistributionSection(),

          if (_stats.criteriaAverages != null &&
              _stats.criteriaAverages!.isNotEmpty) ...[
            const SizedBox(height: 24),
            _buildCriteriaSection(),
          ],

          const SizedBox(height: 24),

          // Individual ratings
          _buildRatingsList(),
        ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [AppTheme.headerGreen, AppTheme.primaryGreen],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primaryGreen.withOpacity(0.3),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // Big rating number
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _stats.totalRatings > 0
                    ? _stats.averageRating.toStringAsFixed(1)
                    : '—',
                style: const TextStyle(
                  fontSize: 56,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _getStarsDisplay(_stats.averageRating),
                    style: const TextStyle(fontSize: 20, color: Colors.white),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_stats.totalRatings} rating${_stats.totalRatings != 1 ? 's' : ''}',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.white.withOpacity(0.8),
                    ),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Rating message
          Text(
            _stats.totalRatings > 0
                ? _getRatingMessage(_stats.averageRating)
                : 'No ratings yet',
            style: TextStyle(
              fontSize: 14,
              color: Colors.white.withOpacity(0.9),
              fontStyle: FontStyle.italic,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildDistributionSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Rating Distribution',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: AppTheme.primaryText,
          ),
        ),
        const SizedBox(height: 12),
        ...List.generate(5, (index) {
          final stars = 5 - index;
          final count = _stats.ratingDistribution[stars] ?? 0;
          final percentage = _stats.totalRatings > 0
              ? (count / _stats.totalRatings * 100).toInt()
              : 0;

          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Text(
                  '$stars',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.secondaryText,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.star, size: 14, color: Colors.amber),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: percentage / 100,
                      minHeight: 8,
                      backgroundColor: AppTheme.lightGrey,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        percentage > 50
                            ? AppTheme.primaryGreen
                            : percentage > 20
                            ? Colors.orange
                            : Colors.red,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 30,
                  child: Text(
                    '$count',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryText,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildCriteriaSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Criteria Breakdown',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: AppTheme.primaryText,
          ),
        ),
        const SizedBox(height: 12),
        ..._stats.criteriaAverages!.entries.map(
          (entry) => _buildCriteriaBar(entry.key, entry.value),
        ),
      ],
    );
  }

  Widget _buildCriteriaBar(String criteria, double average) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                criteria,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.primaryText,
                ),
              ),
              Text(
                average.toStringAsFixed(1),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.headerGreen,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: average / 5,
              minHeight: 6,
              backgroundColor: AppTheme.lightGrey,
              valueColor: AlwaysStoppedAnimation<Color>(
                average >= 4
                    ? AppTheme.primaryGreen
                    : average >= 3
                    ? Colors.orange
                    : Colors.red,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRatingsList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Individual Ratings',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppTheme.primaryText,
              ),
            ),
            if (widget.ratingDetails.length > 3)
              TextButton(
                onPressed: () {
                  setState(() {
                    _showAllRatings = !_showAllRatings;
                  });
                },
                child: Text(_showAllRatings ? 'Show Less' : 'Show All'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        ...(widget.ratingDetails.take(
          _showAllRatings ? widget.ratingDetails.length : 3,
        )).map((detail) => _buildRatingCard(detail)),
      ],
    );
  }

  Widget _buildRatingCard(Map<String, dynamic> detail) {
    final rating = detail['rating'] as int;
    final comment = detail['comment'] as String?;
    final ratedBy = detail['ratedBy'] as String?;
    final ratedAt = detail['ratedAt'] as DateTime?;
    final criteriaRatings = detail['criteriaRatings'] as Map<String, int>?;

    // Find the user who gave the rating
    UserModel? rater;
    if (ratedBy != null) {
      // Rater name is stored directly in ratedBy if it's a display name
      // (UID-based lookup would require Firestore query)
      rater = ratedBy.length < 30
          ? UserModel(
              uid: ratedBy,
              name: ratedBy,
              email: '',
              phone: '',
              createdAt: DateTime.now(),
            )
          : null;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.lightGrey),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with rater info
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: AppTheme.headerGreen.withOpacity(0.2),
                child: Text(
                  rater?.name.substring(0, 1).toUpperCase() ?? '?',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.headerGreen,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rater?.name ?? 'Unknown',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.primaryText,
                      ),
                    ),
                    if (ratedAt != null)
                      Text(
                        DateFormat('dd MMM yyyy, HH:mm').format(ratedAt),
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.lightText,
                        ),
                      ),
                  ],
                ),
              ),
              // Stars
              Row(
                children: List.generate(5, (index) {
                  return Icon(
                    index < rating ? Icons.star : Icons.star_border,
                    size: 16,
                    color: index < rating ? Colors.amber : Colors.grey.shade300,
                  );
                }),
              ),
            ],
          ),

          // Comment
          if (comment != null && comment.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppTheme.lightGrey,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                comment,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppTheme.secondaryText,
                ),
              ),
            ),
          ],

          // Criteria ratings
          if (criteriaRatings != null && criteriaRatings.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: criteriaRatings.entries.map((entry) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.headerGreen.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppTheme.headerGreen.withOpacity(0.3),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        entry.key,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.headerGreen,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.star,
                        size: 12,
                        color: entry.value >= 4
                            ? Colors.amber
                            : entry.value >= 3
                            ? Colors.orange
                            : Colors.red,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '${entry.value}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.primaryText,
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  String _getStarsDisplay(double rating) {
    if (rating == 0) return '☆☆☆☆☆';
    final filled = rating.round();
    return '★' * filled + '☆' * (5 - filled);
  }

  String _getRatingMessage(double rating) {
    if (rating >= 4.5) return 'Outstanding performance!';
    if (rating >= 4.0) return 'Excellent work!';
    if (rating >= 3.5) return 'Very good performance';
    if (rating >= 3.0) return 'Good, meets expectations';
    if (rating >= 2.5) return 'Fair, room for improvement';
    if (rating >= 2.0) return 'Below expectations';
    return 'Needs significant improvement';
  }
}
