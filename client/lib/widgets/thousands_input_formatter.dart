import 'package:flutter/services.dart';

class ThousandsSeparatorInputFormatter extends TextInputFormatter {
  const ThousandsSeparatorInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final formatted = formatIntegerInputText(newValue.text);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}

String removeNumberGrouping(String value) {
  return value.replaceAll(',', '').trim();
}

String formatIntegerInputText(Object? value) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return '';

  final negative = text.startsWith('-');
  final whole = text.split('.').first;
  final digits = whole.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return negative ? '-' : '';

  final normalized = digits.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  final grouped = _groupDigits(normalized);
  return negative ? '-$grouped' : grouped;
}

String _groupDigits(String digits) {
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final remaining = digits.length - i;
    buffer.write(digits[i]);
    if (remaining > 1 && remaining % 3 == 1) {
      buffer.write(',');
    }
  }
  return buffer.toString();
}
