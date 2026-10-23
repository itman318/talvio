import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../core/prayer_reminders.dart';
import '../core/prayer_times.dart';
import '../core/prefs.dart';
import '../theme/brand.dart';
import '../utils/format.dart';

String _hm(DateTime t) => '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';

String _left(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '${h}h ${m.toString().padLeft(2, '0')}m' : '${m}m ${s.toString().padLeft(2, '0')}s';
}

/// Settings → Prayer times: today's prayer times, next-prayer countdown, Sehri/Iftar, Hijri date, Qibla.
class PrayerScreen extends StatefulWidget {
  const PrayerScreen({super.key});

  @override
  State<PrayerScreen> createState() => _PrayerScreenState();
}

class _PrayerScreenState extends State<PrayerScreen> {
  Timer? _tick;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _useGps() async {
    final prefs = context.read<AppPrefs>();
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) throw 'Turn on location (GPS) first';
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) throw 'Location permission is needed — or pick a city instead';
      final pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.low));
      // nearest known city just for the label
      var label = 'My location';
      var best = 40.0;
      for (final (name, lat, lng) in prayerCities) {
        final d = Geolocator.distanceBetween(pos.latitude, pos.longitude, lat, lng) / 1000;
        if (d < best) {
          best = d;
          label = name;
        }
      }
      prefs.setPrayerPlace(label, pos.latitude, pos.longitude);
      await PrayerReminders.reschedule(prefs);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _pickCity() async {
    final prefs = context.read<AppPrefs>();
    final picked = await showModalBottomSheet<(String, double, double)>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (ctx, sc) => ListView(controller: sc, children: [
          const ListTile(title: Text('Choose city', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18))),
          ListTile(
            leading: const Icon(Icons.my_location),
            title: const Text('Use my current location'),
            onTap: () => Navigator.pop(ctx, ('__gps__', 0.0, 0.0)),
          ),
          const Divider(height: 1),
          for (final c in prayerCities)
            ListTile(
              leading: const Icon(Icons.location_city_outlined),
              title: Text(c.$1),
              trailing: prefs.prayerPlace == c.$1 ? Icon(Icons.check, color: Brand.primary) : null,
              onTap: () => Navigator.pop(ctx, c),
            ),
        ]),
      ),
    );
    if (picked == null) return;
    if (picked.$1 == '__gps__') return _useGps();
    prefs.setPrayerPlace(picked.$1, picked.$2, picked.$3);
    await PrayerReminders.reschedule(prefs);
  }

  Future<void> _settings() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const PrayerSettingsScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<AppPrefs>();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final lat = prefs.prayerLat;
    final lng = prefs.prayerLng;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prayer times'),
        actions: [IconButton(tooltip: 'Prayer settings', icon: const Icon(Icons.tune), onPressed: _settings)],
      ),
      body: lat == null || lng == null
          ? _empty()
          : _content(prefs, lat, lng, dark),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(color: Brand.primary.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: Icon(Icons.mosque_outlined, size: 44, color: Brand.primary),
            ),
            const SizedBox(height: 20),
            const Text('Set your location', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            const Text('Prayer times are calculated on your phone — your location is never sent anywhere.', textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _locating ? null : _useGps,
              icon: _locating ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.my_location),
              label: const Text('Use my location'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(onPressed: _pickCity, icon: const Icon(Icons.location_city_outlined), label: const Text('Choose a city')),
          ]),
        ),
      );

  Widget _content(AppPrefs prefs, double lat, double lng, bool dark) {
    final now = DateTime.now();
    final method = CalcMethod.values[prefs.prayerMethod];
    final today = prayerTimes(now, lat: lat, lng: lng, method: method, hanafiAsr: prefs.hanafiAsr);
    final tomorrow = prayerTimes(now.add(const Duration(days: 1)), lat: lat, lng: lng, method: method, hanafiAsr: prefs.hanafiAsr);
    // next prayer (sunrise is shown but not counted as a prayer)
    (String, DateTime)? next;
    for (final p in today.prayers) {
      if (p.$2.isAfter(now)) {
        next = p;
        break;
      }
    }
    next ??= ('Fajr', tomorrow.fajr);
    String? current;
    for (final p in today.all) {
      if (!p.$2.isAfter(now)) current = p.$1;
    }
    final hijri = hijriFor(now, adjustDays: prefs.hijriAdjust);
    // after Maghrib the Islamic day has already started
    final hijriTonight = now.isAfter(today.maghrib) ? hijriFor(now.add(const Duration(days: 1)), adjustDays: prefs.hijriAdjust) : null;
    final sehri = now.isAfter(today.fajr) ? tomorrow.fajr : today.fajr;
    final iftar = now.isAfter(today.maghrib) ? tomorrow.maghrib : today.maghrib;

    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
      // hero: next prayer
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Brand.ink, Brand.inkSoft]),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.place_outlined, color: Colors.white70, size: 16),
            const SizedBox(width: 4),
            Expanded(
              child: InkWell(
                onTap: _pickCity,
                child: Text('${prefs.prayerPlace.isEmpty ? 'My location' : prefs.prayerPlace}  ▾',
                    style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
              ),
            ),
            Text(hijri.toString(), style: const TextStyle(color: Brand.premium, fontWeight: FontWeight.w600, fontSize: 13)),
          ]),
          const SizedBox(height: 18),
          Text('Next: ${next.$1}', style: const TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 2),
          Text(_hm(next.$2), style: const TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w800, height: 1.1)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(color: Brand.primary, borderRadius: BorderRadius.circular(20)),
            child: Text('in ${_left(next.$2.difference(now))}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13)),
          ),
          if (hijriTonight != null) ...[
            const SizedBox(height: 10),
            Text('Tonight: ${hijriTonight.day} ${hijriTonight.monthName}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ]),
      ),
      const SizedBox(height: 14),
      // Sehri / Iftar
      Row(children: [
        Expanded(child: _miniCard(Icons.nightlight_outlined, 'Suhoor ends', _hm(sehri), Brand.accent, dark)),
        const SizedBox(width: 12),
        Expanded(child: _miniCard(Icons.wb_twilight, 'Iftar', _hm(iftar), Brand.amber, dark)),
      ]),
      if (hijri.isRamadan || (hijriTonight?.isRamadan ?? false))
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text('Ramadan Mubarak 🌙', textAlign: TextAlign.center, style: TextStyle(color: Brand.premium, fontWeight: FontWeight.w700)),
        ),
      const SizedBox(height: 14),
      // today's list
      Card(
        margin: EdgeInsets.zero,
        child: Column(children: [
          for (final (name, time) in today.all)
            ListTile(
              dense: true,
              leading: Icon(_icon(name), color: name == current ? Brand.primary : Theme.of(context).hintColor),
              title: Text(name, style: TextStyle(fontWeight: name == current ? FontWeight.w800 : FontWeight.w500, fontSize: 15)),
              trailing: Text(_hm(time),
                  style: TextStyle(fontWeight: name == current ? FontWeight.w800 : FontWeight.w600, fontSize: 15, color: name == current ? Brand.primary : null)),
              tileColor: name == current ? Brand.primary.withValues(alpha: 0.08) : null,
            ),
        ]),
      ),
      const SizedBox(height: 8),
      Text('${calcMethodNames[method]} · Asr ${prefs.hanafiAsr ? 'Hanafi' : 'Shafi‘i'}',
          textAlign: TextAlign.center, style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12)),
      const SizedBox(height: 18),
      // reminders
      Card(
        margin: EdgeInsets.zero,
        child: Column(children: [
          SwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: const Text('Prayer reminders'),
            subtitle: const Text('A notification at each prayer time'),
            value: prefs.prayerReminders,
            onChanged: (v) => _setReminders(prefs, reminders: v),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.restaurant_outlined),
            title: const Text('Suhoor & Iftar alerts'),
            subtitle: const Text('In Ramadan: 30 min before Suhoor ends, and at Iftar'),
            value: prefs.ramadanReminders,
            onChanged: (v) => _setReminders(prefs, ramadan: v),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      FilledButton.tonalIcon(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => QiblaScreen(lat: lat, lng: lng))),
        icon: const Icon(Icons.explore_outlined),
        label: Text('Qibla direction · ${qiblaBearing(lat, lng).round()}°'),
      ),
    ]);
  }

  Future<void> _setReminders(AppPrefs prefs, {bool? reminders, bool? ramadan}) async {
    if (reminders == true || ramadan == true) {
      final ok = await PrayerReminders.requestPermission();
      if (!ok) {
        if (mounted) showInfo(context, 'Allow notifications for Talvio to get reminders');
        return;
      }
    }
    prefs.setPrayerOptions(reminders: reminders, ramadan: ramadan);
    await PrayerReminders.reschedule(prefs);
    if (mounted && (reminders == true || ramadan == true)) showInfo(context, 'Reminders set for the next 7 days');
  }

  Widget _miniCard(IconData icon, String label, String time, Color color, bool dark) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: dark ? 0.16 : 0.12),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
              Text(time, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            ]),
          ),
        ]),
      );

  IconData _icon(String name) => switch (name) {
        'Fajr' => Icons.brightness_3_outlined,
        'Sunrise' => Icons.wb_sunny_outlined,
        'Dhuhr' => Icons.light_mode_outlined,
        'Asr' => Icons.wb_cloudy_outlined,
        'Maghrib' => Icons.wb_twilight,
        _ => Icons.nights_stay_outlined,
      };
}

class PrayerSettingsScreen extends StatelessWidget {
  const PrayerSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<AppPrefs>();
    void changed() => PrayerReminders.reschedule(prefs);
    return Scaffold(
      appBar: AppBar(title: const Text('Prayer settings')),
      body: ListView(children: [
        const ListTile(dense: true, title: Text('CALCULATION METHOD', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.6))),
        RadioGroupList<int>(
          value: prefs.prayerMethod,
          items: [for (final m in CalcMethod.values) (m.index, calcMethodNames[m]!)],
          onChanged: (v) {
            prefs.setPrayerOptions(method: v);
            changed();
          },
        ),
        const Divider(),
        const ListTile(dense: true, title: Text('ASR', style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.6))),
        RadioGroupList<bool>(
          value: prefs.hanafiAsr,
          items: const [(true, 'Hanafi (later Asr)'), (false, 'Shafi‘i, Maliki, Hanbali')],
          onChanged: (v) {
            prefs.setPrayerOptions(hanafi: v);
            changed();
          },
        ),
        const Divider(),
        ListTile(
          title: const Text('Hijri date adjustment'),
          subtitle: Text('${hijriFor(DateTime.now(), adjustDays: prefs.hijriAdjust)} — match your local moon sighting'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              onPressed: prefs.hijriAdjust <= -2 ? null : () {
                prefs.setPrayerOptions(hijri: prefs.hijriAdjust - 1);
                changed();
              },
            ),
            Text(prefs.hijriAdjust > 0 ? '+${prefs.hijriAdjust}' : '${prefs.hijriAdjust}', style: const TextStyle(fontWeight: FontWeight.w700)),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              onPressed: prefs.hijriAdjust >= 2 ? null : () {
                prefs.setPrayerOptions(hijri: prefs.hijriAdjust + 1);
                changed();
              },
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Simple list of radio rows (avoids the deprecated RadioListTile groupValue API).
class RadioGroupList<T> extends StatelessWidget {
  const RadioGroupList({super.key, required this.value, required this.items, required this.onChanged});
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Column(children: [
        for (final (v, label) in items)
          ListTile(
            title: Text(label),
            trailing: v == value ? Icon(Icons.check_circle, color: Brand.primary) : const Icon(Icons.circle_outlined),
            onTap: () => onChanged(v),
          ),
      ]);
}

/// Qibla compass: phone heading from the magnetometer + accelerometer, arrow points to the Kaaba.
class QiblaScreen extends StatefulWidget {
  const QiblaScreen({super.key, required this.lat, required this.lng});
  final double lat;
  final double lng;

  @override
  State<QiblaScreen> createState() => _QiblaScreenState();
}

class _QiblaScreenState extends State<QiblaScreen> {
  StreamSubscription? _acc;
  StreamSubscription? _mag;
  List<double>? _g;
  double? _heading; // degrees from magnetic north
  bool _noSensor = false;

  @override
  void initState() {
    super.initState();
    try {
      _acc = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen((e) {
        final g = [e.x, e.y, e.z];
        _g = _g == null ? g : [for (var i = 0; i < 3; i++) _g![i] * 0.8 + g[i] * 0.2];
      }, onError: (_) => setState(() => _noSensor = true));
      _mag = magnetometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen(_onMag, onError: (_) => setState(() => _noSensor = true));
    } catch (_) {
      _noSensor = true;
    }
  }

  void _onMag(MagnetometerEvent m) {
    final a = _g;
    if (a == null || !mounted) return;
    // same maths as Android's SensorManager.getRotationMatrix → azimuth
    final hx = m.y * a[2] - m.z * a[1];
    final hy = m.z * a[0] - m.x * a[2];
    final hz = m.x * a[1] - m.y * a[0];
    final normH = math.sqrt(hx * hx + hy * hy + hz * hz);
    if (normH < 0.1) return;
    final normA = math.sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
    final ax = a[0] / normA, az = a[2] / normA;
    final hxn = hx / normH, hyn = hy / normH, hzn = hz / normH;
    final my = az * hxn - ax * hzn;
    var az0 = math.atan2(hyn, my) * 180 / math.pi;
    az0 = (az0 + 360) % 360;
    // smooth across the 0/360 boundary
    final prev = _heading;
    if (prev != null) {
      var diff = az0 - prev;
      if (diff > 180) diff -= 360;
      if (diff < -180) diff += 360;
      az0 = (prev + diff * 0.25 + 360) % 360;
    }
    setState(() => _heading = az0);
  }

  @override
  void dispose() {
    _acc?.cancel();
    _mag?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final qibla = qiblaBearing(widget.lat, widget.lng);
    final heading = _heading;
    final turn = heading == null ? qibla : (qibla - heading + 360) % 360;
    final facing = heading != null && (turn < 5 || turn > 355);
    final km = distanceToKaabaKm(widget.lat, widget.lng);
    return Scaffold(
      appBar: AppBar(title: const Text('Qibla')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('${qibla.toStringAsFixed(0)}° from North', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('Kaaba is ${km.round()} km away', style: TextStyle(color: Theme.of(context).hintColor)),
            const SizedBox(height: 28),
            SizedBox(
              width: 280,
              height: 280,
              child: Stack(alignment: Alignment.center, children: [
                // dial rotates so that N points to real north
                Transform.rotate(
                  angle: -(heading ?? 0) * math.pi / 180,
                  child: CustomPaint(size: const Size(280, 280), painter: _DialPainter(Theme.of(context).brightness == Brightness.dark)),
                ),
                Transform.rotate(
                  angle: turn * math.pi / 180,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(color: facing ? Brand.accent : Brand.ink, borderRadius: BorderRadius.circular(10)),
                      child: const Icon(Icons.mosque, color: Colors.white, size: 26),
                    ),
                    Container(width: 4, height: 80, color: facing ? Brand.accent : Brand.primary),
                    const SizedBox(height: 124),
                  ]),
                ),
                Container(width: 14, height: 14, decoration: const BoxDecoration(color: Brand.primary, shape: BoxShape.circle)),
              ]),
            ),
            const SizedBox(height: 24),
            if (_noSensor)
              const Text('This phone has no compass sensor. Use the angle above with a compass.', textAlign: TextAlign.center)
            else if (heading == null)
              const Text('Hold the phone flat…')
            else
              Text(facing ? 'You are facing the Qibla ✓' : 'Turn until the arrow points straight up',
                  style: TextStyle(fontWeight: FontWeight.w700, color: facing ? Brand.accent : null)),
            const SizedBox(height: 10),
            Text('Keep the phone flat and away from metal or magnets. If it looks wrong, move the phone in a figure‑8 to calibrate.',
                textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
          ]),
        ),
      ),
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter(this.dark);
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    canvas.drawCircle(c, r, Paint()..color = dark ? Brand.inkSoft : Colors.white);
    canvas.drawCircle(c, r - 1, Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Brand.faint.withValues(alpha: 0.5));
    final tick = Paint()..color = Brand.muted;
    for (var i = 0; i < 72; i++) {
      final a = i * 5 * math.pi / 180;
      final long = i % 18 == 0;
      final len = long ? 14.0 : (i % 2 == 0 ? 8.0 : 4.0);
      tick.strokeWidth = long ? 2.5 : 1;
      final dir = Offset(math.sin(a), -math.cos(a));
      canvas.drawLine(c + dir * (r - 4), c + dir * (r - 4 - len), tick);
    }
    const labels = ['N', 'E', 'S', 'W'];
    for (var i = 0; i < 4; i++) {
      final a = i * math.pi / 2;
      final tp = TextPainter(
        text: TextSpan(
          text: labels[i],
          style: TextStyle(fontFamily: 'Jakarta', fontWeight: FontWeight.w800, fontSize: 18, color: i == 0 ? Brand.primary : (dark ? Colors.white : Brand.ink)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final p = c + Offset(math.sin(a), -math.cos(a)) * (r - 34);
      tp.paint(canvas, p - Offset(tp.width / 2, tp.height / 2));
    }
  }

  @override
  bool shouldRepaint(covariant _DialPainter old) => old.dark != dark;
}
