import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

/// Application-wide constants
class AppConstants {
  /// Standard length for mobile numbers across the application
  static const int mobileNumberLength = 10;
}

/// Extension for general Object nullability checks
extension ObjectNullCheck on Object? {
  bool get isNull => this == null;
}

/// Extension for String validation and masking
extension StringValidation on String? {
  /// Checks if string is not null, not literally "null", and not empty spaces
  ///
  /// Usage:
  /// ```dart
  /// if (username.isValid) { ... }
  /// ```
  bool get isValid =>
      this != null && this!.toLowerCase() != 'null' && this!.trim().isNotEmpty;

  /// Checks if string is a valid mobile number of the exact required length
  ///
  /// Usage:
  /// ```dart
  /// if (phone.isValidMobile) { ... }
  /// ```
  bool get isValidMobile =>
      isValid &&
      this!.trim().length == AppConstants.mobileNumberLength &&
      int.tryParse(this!.trim()) != null;
}

extension StringMasking on String {
  /// Masks the string, keeping the first 4 characters visible and starring the rest
  ///
  /// Usage:
  /// ```dart
  /// 'password123'.mask(); // Returns: 'pass*******'
  /// ```
  String mask() {
    if (isEmpty) return '';
    if (length <= 4) return '*' * length;
    return substring(0, 4) + '*' * (length - 4);
  }
}

/// Extension for Color HEX conversions
extension ColorConversion on String {
  /// Converts a Hex String (e.g. #FF0000) to a Flutter Color object
  ///
  /// Usage:
  /// ```dart
  /// Color red = '#FF0000'.toColor();
  /// ```
  Color toColor() {
    String hex = replaceAll('#', '');
    if (hex.length == 6) {
      hex = 'FF$hex';
    }
    return Color(int.parse('0x$hex'));
  }
}

extension ColorHexString on Color {
  /// Converts a Flutter Color object to a Hex String
  ///
  /// Usage:
  /// ```dart
  /// String hex = Colors.red.toHexString(); // Returns: '#FFFF0000'
  /// ```
  String toHexString() =>
      '#${toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
}

/// Extension on BuildContext for quick UI operations (Toasts/Snackbars/Keyboard)
///
/// Usage:
/// ```dart
/// context.showShortSnackBar('Item saved');
/// context.showAlertDialog(message: 'Are you sure?', onPositiveClick: () {});
/// context.hideKeyboard();
/// double width = context.screenWidth;
/// ```
extension ContextUIExt on BuildContext {
  /// Hides the soft keyboard
  void hideKeyboard() {
    FocusScope.of(this).unfocus();
  }

  /// Shows a short Snackbar (equivalent to Short Toast/Snackbar in Android)
  void showShortSnackBar(String message) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  /// Shows a long Snackbar
  void showLongSnackBar(String message) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  /// Shows a Snackbar with an Action button
  void showSnackBarWithAction({
    required String message,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(label: actionLabel, onPressed: onAction),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  /// Shows a simple Alert Dialog
  void showAlert(String message, {String title = 'Alert'}) {
    showDialog(
      context: this,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  /// Shows a customizable Alert Dialog with positive and optional negative actions
  void showAlertDialog({
    String? title,
    required String message,
    String? posBtnText,
    String? negBtnText,
    bool showNegBtn = true,
    required VoidCallback onPositiveClick,
  }) {
    showDialog(
      context: this,
      builder: (context) => AlertDialog(
        title: Text(title ?? 'Alert'),
        content: Text(message),
        actions: [
          if (showNegBtn)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(negBtnText ?? 'No'),
            ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              onPositiveClick();
            },
            child: Text(posBtnText ?? 'Yes'),
          ),
        ],
      ),
    );
  }

  /// Shows an API response dialog (Translated from Kotlin apiAlertDialog)
  void showApiAlertDialog({
    required bool isError,
    required String title,
    required String subTitle,
    required VoidCallback action,
  }) {
    showDialog(
      context: this,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        contentPadding: const EdgeInsets.all(24),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              color: isError
                  ? Theme.of(context).colorScheme.error
                  : Colors.green,
              size: 64,
            ),
            const SizedBox(height: 16),
            if (title.isNotEmpty) ...[
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
            ],
            if (subTitle.isNotEmpty)
              Text(
                subTitle,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  Navigator.of(context).pop();
                  action();
                },
                child: const Text('Close'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Shows a simplified API error dialog
  void showApiErrorDialog(String errMsg) {
    showDialog(
      context: this,
      builder: (context) => AlertDialog(
        title: const Text('Error'),
        content: Text(errMsg),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Copies text to clipboard and shows a toast
  Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      showShortSnackBar('Copied to clipboard!');
    }
  }

  /// Opens the Date Chooser
  Future<DateTime?> openDateChooser({
    DateTime? initialDate,
    DateTime? firstDate,
    DateTime? lastDate,
  }) async {
    final now = DateTime.now();
    return await showDatePicker(
      context: this,
      initialDate: initialDate ?? now,
      firstDate: firstDate ?? DateTime(now.year - 100),
      lastDate: lastDate ?? DateTime(now.year + 100),
    );
  }

  /// Opens the Time Picker
  Future<TimeOfDay?> openTimePicker({TimeOfDay? initialTime}) async {
    return await showTimePicker(
      context: this,
      initialTime: initialTime ?? TimeOfDay.now(),
    );
  }

  /// Theme Utilities
  bool get isDarkMode => Theme.of(this).brightness == Brightness.dark;

  /// Screen dimension utilities
  double get screenWidth => MediaQuery.of(this).size.width;
  double get screenHeight => MediaQuery.of(this).size.height;
}

/// Debouncer utility for handling rapid clicks (Throttled/Debouncer Kotlin util equivalent)
///
/// Usage:
/// ```dart
/// final debouncer = Debouncer(milliseconds: 500);
///
/// ElevatedButton(
///   onPressed: () => debouncer.run(() => submitForm()),
///   child: const Text('Submit'),
/// )
/// ```
class Debouncer {
  final int milliseconds;
  Timer? _timer;

  Debouncer({required this.milliseconds});

  void run(VoidCallback action) {
    if (_timer?.isActive ?? false) {
      return; // Ignore rapid clicks
    }
    action();
    _timer = Timer(Duration(milliseconds: milliseconds), () {});
  }
}

/// Date and Time Formatting Utilities
///
/// Usage:
/// ```dart
/// String formatted = DateUtilsExt.formatDateTime(
///   formatFrom: 'dd/MM/yyyy',
///   formatTo: 'dd-MMM-yyyy',
///   value: '14/02/2026'
/// ); // Returns: '14-Feb-2026'
/// ```
class DateUtilsExt {
  /// Formats a date from one format to another (equivalent to formatDateTime Kotlin)
  static String formatDateTime({
    required String formatFrom,
    required String formatTo,
    required String value,
  }) {
    try {
      final parsedDate = DateFormat(formatFrom).parse(value);
      return DateFormat(formatTo).format(parsedDate);
    } catch (e) {
      return value; // Return original on error
    }
  }

  /// Gets a specific date before the current date (equivalent to getBeforeDate Kotlin)
  ///
  /// Usage:
  /// ```dart
  /// String fiveDaysAgo = DateUtilsExt.getBeforeDate(day: true, count: 5);
  /// ```
  static String getBeforeDate({
    bool day = false,
    bool month = false,
    bool year = false,
    int count = 0,
    String format = 'dd-MMM-yyyy',
  }) {
    DateTime now = DateTime.now();
    if (day) {
      now = DateTime(now.year, now.month, now.day - count);
    } else if (month) {
      now = DateTime(now.year, now.month - count, now.day);
    } else if (year) {
      now = DateTime(now.year - count, now.month, now.day);
    }
    return DateFormat(format).format(now);
  }
}
