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

class DecimalThousandsSeparatorInputFormatter extends TextInputFormatter {
  const DecimalThousandsSeparatorInputFormatter({this.maxDecimalPlaces = 4});

  final int maxDecimalPlaces;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final formatted = formatDecimalInputText(
      newValue.text,
      maxDecimalPlaces: maxDecimalPlaces,
    );
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

String formatDecimalInputText(Object? value, {int maxDecimalPlaces = 4}) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return '';

  final negative = text.startsWith('-');
  final cleaned = text.replaceAll(',', '');
  final parts = cleaned.split('.');
  final digits = parts.first.replaceAll(RegExp(r'[^0-9]'), '');
  final decimalDigits = parts.length > 1
      ? parts.sublist(1).join().replaceAll(RegExp(r'[^0-9]'), '')
      : '';

  final normalizedWhole =
      digits.isEmpty ? '0' : digits.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  final grouped = _groupDigits(normalizedWhole);
  final decimalEnd = decimalDigits.length < maxDecimalPlaces
      ? decimalDigits.length
      : maxDecimalPlaces;
  final suffix =
      cleaned.contains('.') ? '.${decimalDigits.substring(0, decimalEnd)}' : '';
  return '${negative ? '-' : ''}$grouped$suffix';
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
