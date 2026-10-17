import 'package:flutter/material.dart';
import '../../../utils/constants.dart';

/// Skeleton home screen for Vendor / Purchase module.
/// To be implemented with procurement and vendor management features.
class VendorHomeScreen extends StatelessWidget {
  const VendorHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.chatCanvas(context),
      appBar: AppBar(
        backgroundColor: const Color(0xFF7048E8),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Vendor / Purchase',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: const Color(0xFF7048E8).withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(
                Icons.local_shipping_outlined,
                size: 40,
                color: Color(0xFF7048E8),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Vendor / Purchase Module',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: AppTheme.primaryText,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Procurement & vendor management',
              style: TextStyle(
                fontSize: 14,
                color: AppTheme.secondaryText,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Coming soon',
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.lightText,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
