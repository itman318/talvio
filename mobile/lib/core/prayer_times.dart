import 'dart:math' as math;

/// Prayer times, Qibla direction and Hijri date — computed on the phone (no internet needed).
/// Astronomy follows the well-known PrayTimes.org method.

enum CalcMethod { karachi, mwl, makkah, isna, egypt }

const calcMethodNames = {
  CalcMethod.karachi: 'University of Islamic Sciences, Karachi',
  CalcMethod.mwl: 'Muslim World League',
  CalcMethod.makkah: 'Umm al-Qura, Makkah',
  CalcMethod.isna: 'ISNA (North America)',
  CalcMethod.egypt: 'Egyptian General Authority',
};

class PrayerDay {
  PrayerDay(this.date, this.fajr, this.sunrise, this.dhuhr, this.asr, this.maghrib, this.isha);
  final DateTime date;
  final DateTime fajr;
  final DateTime sunrise;
  final DateTime dhuhr;
  final DateTime asr;
  final DateTime maghrib;
  final DateTime isha;

  /// (name, time) of the five prayers plus sunrise, in order.
  List<(String, DateTime)> get all => [
        ('Fajr', fajr),
        ('Sunrise', sunrise),
        ('Dhuhr', dhuhr),
        ('Asr', asr),
        ('Maghrib', maghrib),
        ('Isha', isha),
      ];

  List<(String, DateTime)> get prayers => all.where((p) => p.$1 != 'Sunrise').toList();
}

double _rad(double d) => d * math.pi / 180;
double _deg(double r) => r * 180 / math.pi;
double _sin(double d) => math.sin(_rad(d));
double _cos(double d) => math.cos(_rad(d));
double _tan(double d) => math.tan(_rad(d));
double _asin(double x) => _deg(math.asin(x));
double _acos(double x) => _deg(math.acos(x.clamp(-1.0, 1.0)));
double _atan2(double y, double x) => _deg(math.atan2(y, x));
double _acot(double x) => _deg(math.atan(1 / x));
double _fixAngle(double a) => a - 360 * (a / 360).floorToDouble();
double _fixHour(double a) => a - 24 * (a / 24).floorToDouble();

double _julian(int y, int m, int d) {
  if (m <= 2) {
    y -= 1;
    m += 12;
  }
  final a = (y / 100).floor();
  final b = 2 - a + (a / 4).floor();
  return (365.25 * (y + 4716)).floor() + (30.6001 * (m + 1)).floor() + d + b - 1524.5;
}

/// Sun declination and equation of time for a Julian date.
(double, double) _sunPosition(double jd) {
  final d = jd - 2451545.0;
  final g = _fixAngle(357.529 + 0.98560028 * d);
  final q = _fixAngle(280.459 + 0.98564736 * d);
  final l = _fixAngle(q + 1.915 * _sin(g) + 0.020 * _sin(2 * g));
  final e = 23.439 - 0.00000036 * d;
  final ra = _atan2(_cos(e) * _sin(l), _cos(l)) / 15;
  final eqt = q / 15 - _fixHour(ra);
  final decl = _asin(_sin(e) * _sin(l));
  return (decl, eqt);
}

PrayerDay prayerTimes(
  DateTime day, {
  required double lat,
  required double lng,
  CalcMethod method = CalcMethod.karachi,
  bool hanafiAsr = true,
}) {
  final local = DateTime(day.year, day.month, day.day, 12);
  final tz = local.timeZoneOffset.inMinutes / 60.0;
  final jd = _julian(day.year, day.month, day.day) - lng / (15 * 24);
  final (fajrAngle, ishaAngle, ishaMinutes) = switch (method) {
    CalcMethod.karachi => (18.0, 18.0, 0),
    CalcMethod.mwl => (18.0, 17.0, 0),
    CalcMethod.makkah => (18.5, 0.0, 90),
    CalcMethod.isna => (15.0, 15.0, 0),
    CalcMethod.egypt => (19.5, 17.5, 0),
  };

  double midDay(double t) => _fixHour(12 - _sunPosition(jd + t).$2);
  double sunAngleTime(double angle, double t, {bool ccw = false}) {
    final decl = _sunPosition(jd + t).$1;
    final noon = midDay(t);
    final x = (-_sin(angle) - _sin(decl) * _sin(lat)) / (_cos(decl) * _cos(lat));
    final h = _acos(x) / 15;
    return noon + (ccw ? -h : h);
  }

  double asrTime(double factor, double t) {
    final decl = _sunPosition(jd + t).$1;
    final angle = -_acot(factor + _tan((lat - decl).abs()));
    return sunAngleTime(angle, t);
  }

  // two passes: the second uses the first pass's times for a better sun position
  var times = [5.0, 6.0, 12.0, 13.0, 18.0, 18.0];
  for (var pass = 0; pass < 2; pass++) {
    final t = times.map((h) => h / 24).toList();
    times = [
      sunAngleTime(fajrAngle, t[0], ccw: true),
      sunAngleTime(0.833, t[1], ccw: true),
      midDay(t[2]),
      asrTime(hanafiAsr ? 2 : 1, t[3]),
      sunAngleTime(0.833, t[4]),
      ishaMinutes > 0 ? 0 : sunAngleTime(ishaAngle, t[5]),
    ];
  }
  final shift = tz - lng / 15;
  DateTime at(double hours, {int plusMinutes = 0}) {
    final h = _fixHour(hours + shift);
    final minutes = (h * 60).round() + plusMinutes;
    return DateTime(day.year, day.month, day.day).add(Duration(minutes: minutes));
  }

  final maghrib = at(times[4], plusMinutes: 1); // a minute of safety after sunset
  return PrayerDay(
    DateTime(day.year, day.month, day.day),
    at(times[0]),
    at(times[1]),
    at(times[2], plusMinutes: 1),
    at(times[3]),
    maghrib,
    ishaMinutes > 0 ? maghrib.add(Duration(minutes: ishaMinutes)) : at(times[5]),
  );
}

/// Direction of the Kaaba from here, in degrees clockwise from true north.
double qiblaBearing(double lat, double lng) {
  const kLat = 21.4225;
  const kLng = 39.8262;
  final dLng = _rad(kLng - lng);
  final y = math.sin(dLng);
  final x = math.cos(_rad(lat)) * math.tan(_rad(kLat)) - math.sin(_rad(lat)) * math.cos(dLng);
  return _fixAngle(_deg(math.atan2(y, x)));
}

/// Distance to the Kaaba in km (great circle).
double distanceToKaabaKm(double lat, double lng) {
  const r = 6371.0;
  final dLat = _rad(21.4225 - lat);
  final dLng = _rad(39.8262 - lng);
  final a = math.pow(math.sin(dLat / 2), 2) + math.cos(_rad(lat)) * math.cos(_rad(21.4225)) * math.pow(math.sin(dLng / 2), 2);
  return 2 * r * math.asin(math.sqrt(a.toDouble()));
}

class HijriDate {
  HijriDate(this.year, this.month, this.day);
  final int year;
  final int month;
  final int day;

  static const months = [
    'Muharram', 'Safar', 'Rabi al-Awwal', 'Rabi al-Thani', 'Jumada al-Ula', 'Jumada al-Thani',
    'Rajab', 'Shaban', 'Ramadan', 'Shawwal', 'Dhul Qadah', 'Dhul Hijjah',
  ];

  String get monthName => months[(month - 1).clamp(0, 11)];
  bool get isRamadan => month == 9;
  @override
  String toString() => '$day $monthName $year AH';
}

/// Tabular (arithmetical) Islamic calendar; [adjustDays] lets the user match the local moon sighting.
HijriDate hijriFor(DateTime date, {int adjustDays = 0}) {
  final d = DateTime(date.year, date.month, date.day).add(Duration(days: adjustDays));
  final jd = _julian(d.year, d.month, d.day).floor() + 1; // civil JDN
  var l = jd - 1948440 + 10632;
  final n = ((l - 1) / 10631).floor();
  l = l - 10631 * n + 354;
  final j = (((10985 - l) / 5316).floor()) * (((50 * l) / 17719).floor()) + ((l / 5670).floor()) * (((43 * l) / 15238).floor());
  l = l - (((30 - j) / 15).floor()) * (((17719 * j) / 50).floor()) - ((j / 16).floor()) * (((15238 * j) / 43).floor()) + 29;
  final month = ((24 * l) / 709).floor();
  final day = l - ((709 * month) / 24).floor();
  final year = 30 * n + j - 30;
  return HijriDate(year, month, day);
}

/// Major cities for people who don't want to share GPS.
const prayerCities = <(String, double, double)>[
  ('Makkah', 21.4225, 39.8262),
  ('Madinah', 24.4672, 39.6111),
  ('Riyadh', 24.7136, 46.6753),
  ('Jeddah', 21.4858, 39.1925),
  ('Dubai', 25.2048, 55.2708),
  ('Abu Dhabi', 24.4539, 54.3773),
  ('Doha', 25.2854, 51.5310),
  ('Kuwait City', 29.3759, 47.9774),
  ('Muscat', 23.5880, 58.3829),
  ('Istanbul', 41.0082, 28.9784),
  ('Cairo', 30.0444, 31.2357),
  ('Karachi', 24.8607, 67.0011),
  ('Lahore', 31.5204, 74.3587),
  ('Islamabad', 33.6844, 73.0479),
  ('Multan', 30.1575, 71.5249),
  ('Peshawar', 34.0151, 71.5249),
  ('Kot Addu', 30.4697, 70.9669),
  ('Delhi', 28.6139, 77.2090),
  ('Mumbai', 19.0760, 72.8777),
  ('Dhaka', 23.8103, 90.4125),
  ('Kuala Lumpur', 3.1390, 101.6869),
  ('Jakarta', -6.2088, 106.8456),
  ('London', 51.5074, -0.1278),
  ('Paris', 48.8566, 2.3522),
  ('Berlin', 52.5200, 13.4050),
  ('New York', 40.7128, -74.0060),
  ('Toronto', 43.6532, -79.3832),
  ('Chicago', 41.8781, -87.6298),
  ('Sydney', -33.8688, 151.2093),
];
