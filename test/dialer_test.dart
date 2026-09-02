import 'package:flutter_test/flutter_test.dart';
import 'package:loc_360/data/dialer.dart';

void main() {
  group('sanitiseForDialling', () {
    test('keeps a bare 10-digit number as-is', () {
      // What a tracked person carries: `mobile_no`, no country code. Prefixing +91 here would
      // be a guess, and the wrong one outside India.
      expect(sanitiseForDialling('8764597659'), '8764597659');
    });

    test('strips the spaces an emergency contact was typed with', () {
      expect(sanitiseForDialling('+91 8764597659'), '+918764597659');
    });

    test('drops dial-unsafe punctuation but keeps the leading plus', () {
      expect(sanitiseForDialling('+91 (876) 459-7659'), '+918764597659');
      expect(sanitiseForDialling(' 087-645 97659 '), '08764597659');
    });

    test('a plus that is not leading is punctuation, not a country code', () {
      expect(sanitiseForDialling('876+459+7659'), '8764597659');
    });

    test('returns empty for nothing dialable, so the caller can say so', () {
      expect(sanitiseForDialling(''), '');
      expect(sanitiseForDialling('   '), '');
      expect(sanitiseForDialling('not a number'), '');
      expect(sanitiseForDialling('+'), '');
    });
  });
}
