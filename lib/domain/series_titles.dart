import 'discovery.dart';

final _season = RegExp(r'第\s*([零〇一二三四五六七八九十百千两\d]+)\s*(季|部|卷|篇|剧)');
String _normalize(String value) => value.toLowerCase().replaceAll(
  RegExp(r'[\s：:，,。.!！?？·\-—_《》【】\[\]（）()]'),
  '',
);

int? seasonNumber(String value) {
  final numeric = int.tryParse(value);
  if (numeric != null) return numeric > 0 ? numeric : null;
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  const units = {'十': 10, '百': 100, '千': 1000};
  if (!value.split('').any(units.containsKey)) {
    final decimal = value
        .split('')
        .map((char) => digits[char]?.toString() ?? '')
        .join();
    final result = int.tryParse(decimal);
    return result != null && result > 0 ? result : null;
  }
  var total = 0, digit = 0;
  for (final char in value.split('')) {
    if (digits.containsKey(char)) {
      digit = digits[char]!;
    } else if (units.containsKey(char)) {
      total += (digit == 0 ? 1 : digit) * units[char]!;
      digit = 0;
    } else {
      return null;
    }
  }
  return total + digit > 0 ? total + digit : null;
}

String chineseSeason(int number) {
  if (number <= 0 || number > 9999) return '$number';
  const digits = '零一二三四五六七八九';
  final result = StringBuffer();
  var zero = false;
  for (final part in [(1000, '千'), (100, '百'), (10, '十'), (1, '')]) {
    final digit = number ~/ part.$1 % 10;
    if (digit == 0) {
      if (result.isNotEmpty) zero = true;
      continue;
    }
    if (zero) result.write('零');
    if (!(part.$1 == 10 && digit == 1 && result.isEmpty)) {
      result.write(digits[digit]);
    }
    result.write(part.$2);
    zero = false;
  }
  return result.toString();
}

class SeriesTitle {
  SeriesTitle(String title) {
    this.extra = title.contains('番外');
    final match = _season.firstMatch(title);
    final extra = title.indexOf('番外');
    tail = match == null ? '' : title.substring(match.end).trim();
    base =
        (match != null
                ? title.substring(0, match.start)
                : extra >= 0
                ? title.substring(0, extra)
                : title)
            .trim();
    number = match == null ? 1 : seasonNumber(match[1]!) ?? 1;
    unit = match?[2] ?? '季';
  }
  late final String base, unit, tail;
  late final int number;
  late final bool extra;
  List<String> get queries => base.isEmpty
      ? []
      : {
          '$base第${chineseSeason(number + 1)}$unit',
          '$base第${number + 1}$unit',
          '$base番外',
        }.toList();
  bool matches(String title) =>
      _normalize(SeriesTitle(title).base) == _normalize(base);
  bool isNextOrExtra(String title) =>
      matches(title) &&
      (SeriesTitle(title).number == number + 1 ||
          _normalize(title).startsWith('${_normalize(base)}番外'));
  bool isNextSeason(String title) =>
      !extra &&
      base.isNotEmpty &&
      matches(title) &&
      _season.hasMatch(title) &&
      !title.contains('番外') &&
      SeriesTitle(title).unit == unit &&
      _normalize(SeriesTitle(title).tail) == _normalize(tail) &&
      SeriesTitle(title).number == number + 1;
}

List<DramaSummary> mergeRelated(
  String currentId,
  Iterable<DramaSummary> manual,
  Iterable<DramaSummary> recommended,
) {
  final seen = <String>{currentId};
  return [...manual, ...recommended].where((row) => seen.add(row.id)).toList();
}
