/// Validation utilities for the WhatWorks app
class AppValidator {
  // Character limits
  static const int maxTitleLength = 100;
  static const int maxDescriptionLength = 1000;
  static const int maxMessageLength = 2000;
  static const int maxCommentLength = 500;
  static const int maxFileNameLength = 255;
  static const int maxTagLength = 30;
  static const int maxTagsPerTask = 10;

  // File size limits (in bytes)
  static const int maxImageSize = 5 * 1024 * 1024; // 5 MB
  static const int maxDocumentSize = 100 * 1024 * 1024; // 100 MB
  static const int maxVoiceNoteSize = 10 * 1024 * 1024; // 10 MB (10 min audio)
  static const int maxFileSize = 100 * 1024 * 1024; // 100 MB (absolute max)

  // Allowed file types
  static const List<String> allowedImageExtensions = [
    'jpg',
    'jpeg',
    'png',
    'gif',
    'webp',
  ];
  static const List<String> allowedDocumentExtensions = [
    'pdf',
    'doc',
    'docx',
    'xls',
    'xlsx',
    'ppt',
    'pptx',
    'txt',
  ];
  static const List<String> allowedAudioExtensions = [
    'mp3',
    'wav',
    'm4a',
    'aac',
    'ogg',
  ];

  // Validation methods

  /// Validate user name
  static String? validateName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Name is required';
    }
    if (value.trim().length < 2) {
      return 'Name must be at least 2 characters';
    }
    if (value.length > 100) {
      return 'Name must be less than 100 characters';
    }
    return null;
  }

  /// Validate email
  static String? validateEmail(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Email is required';
    }
    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(value.trim())) {
      return 'Please enter a valid email';
    }
    return null;
  }

  /// Validate password
  static String? validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Password is required';
    }
    if (value.length < 6) {
      return 'Password must be at least 6 characters';
    }
    if (value.length > 128) {
      return 'Password must be less than 128 characters';
    }
    return null;
  }

  /// Validate confirm password
  static String? validateConfirmPassword(String? value, String password) {
    if (value == null || value.isEmpty) {
      return 'Please confirm your password';
    }
    if (value != password) {
      return 'Passwords do not match';
    }
    return null;
  }

  /// Validate phone number
  static String? validatePhoneNumber(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null; // Phone is optional
    }
    final phoneRegex = RegExp(r'^\+?[0-9]{10,15}$');
    if (!phoneRegex.hasMatch(value.trim())) {
      return 'Please enter a valid phone number';
    }
    return null;
  }

  /// Validate task title
  static ValidationResult validateTitle(String title) {
    if (title.trim().isEmpty) {
      return ValidationResult(isValid: false, error: 'Title is required');
    }
    if (title.length > maxTitleLength) {
      return ValidationResult(
        isValid: false,
        error: 'Title must be less than $maxTitleLength characters',
      );
    }
    if (title.trim().length < 3) {
      return ValidationResult(
        isValid: false,
        error: 'Title must be at least 3 characters',
      );
    }
    return ValidationResult(isValid: true);
  }

  /// Validate task description
  static ValidationResult validateDescription(String description) {
    if (description.isEmpty) {
      return ValidationResult(isValid: true); // Description is optional
    }
    if (description.length > maxDescriptionLength) {
      return ValidationResult(
        isValid: false,
        error: 'Description must be less than $maxDescriptionLength characters',
      );
    }
    return ValidationResult(isValid: true);
  }

  /// Validate message text
  static ValidationResult validateMessage(String message) {
    if (message.trim().isEmpty) {
      return ValidationResult(isValid: false, error: 'Message cannot be empty');
    }
    if (message.length > maxMessageLength) {
      return ValidationResult(
        isValid: false,
        error: 'Message must be less than $maxMessageLength characters',
      );
    }
    return ValidationResult(isValid: true);
  }

  /// Validate comment (for ratings)
  static ValidationResult validateComment(String comment) {
    if (comment.isEmpty) {
      return ValidationResult(isValid: true); // Comment is optional
    }
    if (comment.length > maxCommentLength) {
      return ValidationResult(
        isValid: false,
        error: 'Comment must be less than $maxCommentLength characters',
      );
    }
    return ValidationResult(isValid: true);
  }

  /// Validate file size
  static ValidationResult validateFileSize(int sizeInBytes, String fileType) {
    int maxSize;
    switch (fileType.toLowerCase()) {
      case 'image':
        maxSize = maxImageSize;
        break;
      case 'document':
        maxSize = maxDocumentSize;
        break;
      case 'audio':
        maxSize = maxVoiceNoteSize;
        break;
      default:
        maxSize = maxFileSize;
    }

    if (sizeInBytes > maxSize) {
      final sizeInMB = (sizeInBytes / (1024 * 1024)).toStringAsFixed(2);
      final maxInMB = (maxSize / (1024 * 1024)).toStringAsFixed(0);
      return ValidationResult(
        isValid: false,
        error:
            'File size ($sizeInMB MB) exceeds maximum allowed size ($maxInMB MB)',
      );
    }
    if (sizeInBytes == 0) {
      return ValidationResult(isValid: false, error: 'File is empty');
    }
    return ValidationResult(isValid: true);
  }

  /// Validate file extension
  static ValidationResult validateFileExtension(
    String fileName,
    String fileType,
  ) {
    final extension = fileName.split('.').last.toLowerCase();

    List<String> allowedExtensions;
    switch (fileType.toLowerCase()) {
      case 'image':
        allowedExtensions = allowedImageExtensions;
        break;
      case 'document':
        allowedExtensions = allowedDocumentExtensions;
        break;
      case 'audio':
        allowedExtensions = allowedAudioExtensions;
        break;
      default:
        allowedExtensions = [
          ...allowedImageExtensions,
          ...allowedDocumentExtensions,
          ...allowedAudioExtensions,
        ];
    }

    if (!allowedExtensions.contains(extension)) {
      return ValidationResult(
        isValid: false,
        error:
            'File type .$extension is not allowed. Allowed: ${allowedExtensions.join(', ')}',
      );
    }

    if (fileName.length > maxFileNameLength) {
      return ValidationResult(
        isValid: false,
        error: 'File name must be less than $maxFileNameLength characters',
      );
    }

    return ValidationResult(isValid: true);
  }

  /// Validate tag
  static ValidationResult validateTag(String tag) {
    if (tag.trim().isEmpty) {
      return ValidationResult(isValid: false, error: 'Tag cannot be empty');
    }
    if (tag.length > maxTagLength) {
      return ValidationResult(
        isValid: false,
        error: 'Tag must be less than $maxTagLength characters',
      );
    }
    final invalidChars = RegExp(r'[<>"&]');
    if (tag.contains(invalidChars)) {
      return ValidationResult(
        isValid: false,
        error: 'Tag contains invalid characters',
      );
    }
    return ValidationResult(isValid: true);
  }

  /// Validate phone number (simple)
  static String? validateSimplePhoneNumber(String? value) {
    if (value == null || value.trim().isEmpty) {
      return null; // Phone is optional
    }
    final phoneRegex = RegExp(r'^\+?[0-9]{10,15}$');
    if (!phoneRegex.hasMatch(value.trim())) {
      return 'Please enter a valid phone number';
    }
    return null;
  }

  /// Validate participant count
  static ValidationResult validateParticipants(List<String> participants) {
    const maxParticipants = 50; // WhatsApp group limit

    if (participants.isEmpty) {
      return ValidationResult(
        isValid: false,
        error: 'At least one participant is required',
      );
    }
    if (participants.length > maxParticipants) {
      return ValidationResult(
        isValid: false,
        error: 'Maximum $maxParticipants participants allowed',
      );
    }
    return ValidationResult(isValid: true);
  }

  /// Validate date
  static ValidationResult validateDeadline(DateTime? deadline) {
    if (deadline == null) {
      return ValidationResult(isValid: true); // Deadline is optional
    }

    final now = DateTime.now();
    final maxFutureDate = now.add(const Duration(days: 365 * 5)); // 5 years max

    if (deadline.isBefore(now.subtract(const Duration(days: 1)))) {
      return ValidationResult(
        isValid: false,
        error: 'Deadline cannot be in the past',
      );
    }
    if (deadline.isAfter(maxFutureDate)) {
      return ValidationResult(
        isValid: false,
        error: 'Deadline cannot be more than 5 years in the future',
      );
    }
    return ValidationResult(isValid: true);
  }

  /// Validate priority
  static ValidationResult validatePriority(int priority) {
    if (priority < 1 || priority > 3) {
      return ValidationResult(
        isValid: false,
        error: 'Priority must be between 1 (Low) and 3 (High)',
      );
    }
    return ValidationResult(isValid: true);
  }

  /// Sanitize text input (remove potentially harmful characters)
  static String sanitizeInput(String input) {
    return input
        .trim()
        .replaceAll(RegExp(r'<[^>]*>'), '') // Remove HTML tags
        .replaceAll(
          RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'),
          '',
        ); // Remove control characters
  }

  /// Get file type from extension
  static String getFileType(String fileName) {
    final extension = fileName.split('.').last.toLowerCase();
    if (allowedImageExtensions.contains(extension)) return 'image';
    if (allowedDocumentExtensions.contains(extension)) return 'document';
    if (allowedAudioExtensions.contains(extension)) return 'audio';
    return 'unknown';
  }

  /// Format file size for display
  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  /// Check if file is too large before upload
  static bool isFileTooLarge(int bytes, String? fileType) {
    if (fileType == null) return bytes > maxFileSize;

    switch (fileType.toLowerCase()) {
      case 'image':
        return bytes > maxImageSize;
      case 'document':
        return bytes > maxDocumentSize;
      case 'audio':
        return bytes > maxVoiceNoteSize;
      default:
        return bytes > maxFileSize;
    }
  }
}

/// Result of a validation check
class ValidationResult {
  final bool isValid;
  final String? error;

  ValidationResult({required this.isValid, this.error});

  @override
  String toString() {
    return isValid ? 'Valid' : 'Invalid: $error';
  }
}
