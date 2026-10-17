import 'package:cloud_firestore/cloud_firestore.dart';

/// Firebase Database Seeder
/// Run this once to initialize Firestore with initial data
/// Collections will be created automatically on first write

class FirebaseSeeder {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Seed the database with initial data
  /// Call this once when app first launches with Firebase
  Future<void> seedDatabase() async {
    try {
      print('🌱 Starting Firebase database seeding...');

      // 1. Create users
      await _seedUsers();

      // 2. Create tasks
      await _seedTasks();

      // 3. Create messages
      await _seedMessages();

      print('✅ Database seeding completed successfully!');
    } catch (e) {
      print('❌ Error seeding database: $e');
      rethrow;
    }
  }

  /// Seed users collection
  Future<void> _seedUsers() async {
    print('📁 Creating users collection...');

    final users = [
      {
        'uid': 'user_001',
        'name': 'Aditya Sharma',
        'email': 'aditya@whatworks.com',
        'phone': '9876543210',
        'avatarUrl': null,
        'organization': 'Sharma Enterprises',
        'createdAt': Timestamp.now(),
        'isOnApp': true,
      },
      {
        'uid': 'user_002',
        'name': 'Shalu Gupta',
        'email': 'shalu@whatworks.com',
        'phone': '9876543211',
        'avatarUrl': null,
        'organization': 'Sharma Enterprises',
        'createdAt': Timestamp.now(),
        'isOnApp': true,
      },
      {
        'uid': 'user_003',
        'name': 'Rahul Verma',
        'email': 'rahul@whatworks.com',
        'phone': '9876543212',
        'avatarUrl': null,
        'organization': 'Sharma Enterprises',
        'createdAt': Timestamp.now(),
        'isOnApp': false, // Field agent
      },
      {
        'uid': 'user_004',
        'name': 'Priya Singh',
        'email': 'priya@whatworks.com',
        'phone': '9876543213',
        'avatarUrl': null,
        'organization': 'Sharma Enterprises',
        'createdAt': Timestamp.now(),
        'isOnApp': true,
      },
      {
        'uid': 'user_005',
        'name': 'Amit Rao',
        'email': 'amit@whatworks.com',
        'phone': '9876543214',
        'avatarUrl': null,
        'organization': 'Sharma Enterprises',
        'createdAt': Timestamp.now(),
        'isOnApp': true,
      },
    ];

    for (final userData in users) {
      await _firestore
          .collection('users')
          .doc(userData['uid'] as String)
          .set(userData);
      print('  ✅ Created user: ${userData['name']}');
    }

    print('  📊 Total users created: ${users.length}');
  }

  /// Seed tasks collection
  Future<void> _seedTasks() async {
    print('📁 Creating tasks collection...');

    final tasks = [
      {
        'id': 'task_001',
        'title': 'Q3 Sales Report',
        'description': 'Prepare comprehensive sales report for Q3 2026',
        'createdBy': 'user_001', // Aditya Sharma
        'assignedTo': 'Shalu Gupta',
        'priority': 3,
        'progress': 0.75,
        'status': 'in_progress',
        'deadline': Timestamp.fromDate(
          DateTime.now().add(const Duration(days: 5)),
        ),
        'createdAt': Timestamp.now(),
        'updatedAt': Timestamp.now(),
        'tags': ['report', 'sales', 'quarterly'],
        'reminderCount': 0,
        'warningCount': 0,
        'statusRequestCount': 0,
      },
      {
        'id': 'task_002',
        'title': 'Website Update',
        'description': 'Update company website with new product listings',
        'createdBy': 'user_005', // Amit Rao
        'assignedTo': 'Aditya Sharma',
        'priority': 2,
        'progress': 0.50,
        'status': 'in_progress',
        'deadline': Timestamp.fromDate(
          DateTime.now().add(const Duration(days: 2)),
        ),
        'createdAt': Timestamp.now(),
        'updatedAt': Timestamp.now(),
        'tags': ['website', 'update'],
        'reminderCount': 1,
        'warningCount': 0,
        'statusRequestCount': 0,
      },
      {
        'id': 'task_003',
        'title': 'Customer Delivery',
        'description': 'Deliver products to customer in Mumbai',
        'createdBy': 'user_001', // Aditya Sharma
        'assignedTo': 'Rahul Verma',
        'priority': 1,
        'progress': 0.25,
        'status': 'pending',
        'deadline': Timestamp.fromDate(
          DateTime.now().subtract(const Duration(days: 3)),
        ),
        'createdAt': Timestamp.now(),
        'updatedAt': Timestamp.now(),
        'tags': ['delivery', 'customer'],
        'reminderCount': 2,
        'warningCount': 1,
        'statusRequestCount': 1,
      },
      {
        'id': 'task_004',
        'title': 'Budget Report',
        'description': 'Prepare annual budget report for review',
        'createdBy': 'user_001', // Aditya Sharma
        'assignedTo': 'Priya Gupta',
        'priority': 2,
        'progress': 0.0,
        'status': 'not_started',
        'deadline': Timestamp.fromDate(
          DateTime.now().add(const Duration(days: 7)),
        ),
        'createdAt': Timestamp.now(),
        'updatedAt': Timestamp.now(),
        'tags': ['budget', 'finance'],
        'reminderCount': 0,
        'warningCount': 0,
        'statusRequestCount': 0,
      },
      {
        'id': 'task_005',
        'title': 'Inventory Check',
        'description': 'Complete monthly inventory audit',
        'createdBy': 'user_004', // Priya Singh
        'assignedTo': 'Aditya Sharma',
        'priority': 3,
        'progress': 0.60,
        'status': 'in_progress',
        'deadline': Timestamp.fromDate(
          DateTime.now().add(const Duration(days: 1)),
        ),
        'createdAt': Timestamp.now(),
        'updatedAt': Timestamp.now(),
        'tags': ['inventory', 'audit'],
        'reminderCount': 1,
        'warningCount': 0,
        'statusRequestCount': 0,
      },
    ];

    for (final taskData in tasks) {
      await _firestore
          .collection('tasks')
          .doc(taskData['id'] as String)
          .set(taskData);
      print('  ✅ Created task: ${taskData['title']}');
    }

    print('  📊 Total tasks created: ${tasks.length}');
  }

  /// Seed messages for tasks
  Future<void> _seedMessages() async {
    print('📁 Creating messages in tasks...');

    // Messages for task_001 (Q3 Sales Report)
    final task1Messages = [
      {
        'id': 'msg_001',
        'taskId': 'task_001',
        'senderId': 'user_001',
        'text': 'Please prioritize the Q3 numbers section',
        'type': 'text',
        'createdAt': Timestamp.fromDate(
          DateTime.now().subtract(const Duration(hours: 24)),
        ),
        'deliveryMethod': 'in-app',
      },
      {
        'id': 'msg_002',
        'taskId': 'task_001',
        'senderId': 'user_002',
        'text': 'Working on it now. Will share draft by tomorrow.',
        'type': 'text',
        'createdAt': Timestamp.fromDate(
          DateTime.now().subtract(const Duration(hours: 20)),
        ),
        'deliveryMethod': 'in-app',
      },
      {
        'id': 'msg_003',
        'taskId': 'task_001',
        'senderId': 'system',
        'text': '📅 Reminder scheduled for 10/02/2026',
        'type': 'system',
        'createdAt': Timestamp.fromDate(
          DateTime.now().subtract(const Duration(hours: 18)),
        ),
        'deliveryMethod': 'in-app',
      },
    ];

    await _addMessagesToTask('task_001', task1Messages);

    // Messages for task_002 (Website Update)
    final task2Messages = [
      {
        'id': 'msg_004',
        'taskId': 'task_002',
        'senderId': 'user_005',
        'text': 'Can you update the product images as well?',
        'type': 'text',
        'createdAt': Timestamp.fromDate(
          DateTime.now().subtract(const Duration(hours: 48)),
        ),
        'deliveryMethod': 'in-app',
      },
      {
        'id': 'msg_005',
        'taskId': 'task_002',
        'senderId': 'system',
        'text':
            '⏰ Amit Rao sent a reminder to Aditya Sharma\n📅 Follow-up date: 12/02/2026\n💬 "Please complete by Friday"',
        'type': 'system',
        'createdAt': Timestamp.fromDate(
          DateTime.now().subtract(const Duration(hours: 36)),
        ),
        'deliveryMethod': 'in-app',
      },
    ];

    await _addMessagesToTask('task_002', task2Messages);

    // Messages for task_003 (Customer Delivery)
    final task3Messages = [
      {
        'id': 'msg_006',
        'taskId': 'task_003',
        'senderId': 'user_001',
        'text': 'This is overdue. Please update status immediately.',
        'type': 'text',
        'createdAt': Timestamp.fromDate(
          DateTime.now().subtract(const Duration(hours: 12)),
        ),
        'deliveryMethod': 'in-app',
      },
      {
        'id': 'msg_007',
        'taskId': 'task_003',
        'senderId': 'system',
        'text': '⚠️ WARNING issued to Rahul Verma by Aditya Sharma',
        'type': 'system',
        'createdAt': Timestamp.fromDate(
          DateTime.now().subtract(const Duration(hours: 6)),
        ),
        'deliveryMethod': 'in-app',
      },
    ];

    await _addMessagesToTask('task_003', task3Messages);

    print('  ✅ Messages created for 3 tasks');
  }

  /// Helper to add messages to a task
  Future<void> _addMessagesToTask(
    String taskId,
    List<Map<String, dynamic>> messages,
  ) async {
    for (final msgData in messages) {
      await _firestore
          .collection('tasks')
          .doc(taskId)
          .collection('messages')
          .doc(msgData['id'] as String)
          .set(msgData);
    }
    print('    📝 Added ${messages.length} messages to task $taskId');
  }
}
