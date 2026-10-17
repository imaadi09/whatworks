class TaskRating {
  final String taskId;
  final String ratedBy; // User who gave the rating
  final int rating; // 1-5 stars
  final String? comment;
  final DateTime ratedAt;
  final Map<String, int>?
  criteriaRatings; // e.g., {'quality': 4, 'timeliness': 5, 'communication': 3}

  TaskRating({
    required this.taskId,
    required this.ratedBy,
    required this.rating,
    this.comment,
    required this.ratedAt,
    this.criteriaRatings,
  });

  Map<String, dynamic> toMap() {
    return {
      'taskId': taskId,
      'ratedBy': ratedBy,
      'rating': rating,
      'comment': comment,
      'ratedAt': ratedAt.toUtc(),
      'criteriaRatings': criteriaRatings,
    };
  }

  factory TaskRating.fromMap(Map<String, dynamic> map) {
    return TaskRating(
      taskId: map['taskId'] ?? '',
      ratedBy: map['ratedBy'] ?? '',
      rating: (map['rating'] ?? 5).clamp(1, 5),
      comment: map['comment'],
      ratedAt: (map['ratedAt'] as DateTime?) ?? DateTime.now(),
      criteriaRatings: map['criteriaRatings'] != null
          ? Map<String, int>.from(map['criteriaRatings'])
          : null,
    );
  }
}

class PersonRating {
  final String personId;
  final String ratedBy;
  final int rating; // 1-5 stars
  final String? comment;
  final DateTime ratedAt;
  final String? taskId; // Optional: rating linked to a specific task
  final Map<String, int>?
  criteriaRatings; // e.g., {'quality': 4, 'reliability': 5, 'teamwork': 4}

  PersonRating({
    required this.personId,
    required this.ratedBy,
    required this.rating,
    this.comment,
    required this.ratedAt,
    this.taskId,
    this.criteriaRatings,
  });

  Map<String, dynamic> toMap() {
    return {
      'personId': personId,
      'ratedBy': ratedBy,
      'rating': rating,
      'comment': comment,
      'ratedAt': ratedAt.toUtc(),
      'taskId': taskId,
      'criteriaRatings': criteriaRatings,
    };
  }

  factory PersonRating.fromMap(Map<String, dynamic> map) {
    return PersonRating(
      personId: map['personId'] ?? '',
      ratedBy: map['ratedBy'] ?? '',
      rating: (map['rating'] ?? 5).clamp(1, 5),
      comment: map['comment'],
      ratedAt: (map['ratedAt'] as DateTime?) ?? DateTime.now(),
      taskId: map['taskId'],
      criteriaRatings: map['criteriaRatings'] != null
          ? Map<String, int>.from(map['criteriaRatings'])
          : null,
    );
  }
}

class RatingStats {
  final double averageRating;
  final int totalRatings;
  final Map<int, int>
  ratingDistribution; // e.g., {5: 10, 4: 5, 3: 2, 2: 1, 1: 0}
  final Map<String, double>? criteriaAverages;

  RatingStats({
    required this.averageRating,
    required this.totalRatings,
    required this.ratingDistribution,
    this.criteriaAverages,
  });

  factory RatingStats.empty() {
    return RatingStats(
      averageRating: 0.0,
      totalRatings: 0,
      ratingDistribution: {5: 0, 4: 0, 3: 0, 2: 0, 1: 0},
    );
  }

  factory RatingStats.calculate(
    List<int> ratings, {
    Map<String, List<int>>? criteriaRatings,
  }) {
    if (ratings.isEmpty) {
      return RatingStats.empty();
    }

    final sum = ratings.fold(0, (a, b) => a + b);
    final average = sum / ratings.length;

    final distribution = {5: 0, 4: 0, 3: 0, 2: 0, 1: 0};
    for (final rating in ratings) {
      distribution[rating] = (distribution[rating] ?? 0) + 1;
    }

    Map<String, double>? criteriaAverages;
    if (criteriaRatings != null) {
      criteriaAverages = {};
      criteriaRatings.forEach((criteria, values) {
        if (values.isNotEmpty) {
          final criteriaSum = values.fold(0, (a, b) => a + b);
          criteriaAverages![criteria] = criteriaSum / values.length;
        }
      });
    }

    return RatingStats(
      averageRating: average,
      totalRatings: ratings.length,
      ratingDistribution: distribution,
      criteriaAverages: criteriaAverages,
    );
  }
}
