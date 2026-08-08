import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/alert.dart';

// =============================================================================
// NotificationService — pembungkus flutter_local_notifications untuk
// menampilkan PERINGATAN tanaman di status bar HP (notifikasi LOKAL, tidak
// butuh server/FCM).
//
// Anti-spam: notifikasi HANYA dipicu saat ada alert BARU (id yang belum
// pernah ditampilkan sejak app dibuka), bukan tiap poll 3 detik. Ini menceg
// "spam notif" saat mis. tanah tetap kering berjam-jam -- pengguna cukup
// diingatkan SEKALI saat kondisi berubah jadi tidak normal, dan lagi saat
// kembali normal (alert hilang) sebagai konfirmasi.
// =============================================================================

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  // Id alert yang SUDAH ditampilkan di sesi ini -- untuk deduplikasi.
  final Set<String> _shown = {};

  Future<void> init() async {
    // Dipanggil SEKALI di main() SEBELUM runApp (butuh
    //   WidgetsFlutterBinding.ensureInitialized()).
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    // Ikon notif diambil dari mipmap launcher (sudah ada di project).
    const settings = InitializationSettings(android: androidSettings);
    await _plugin.initialize(settings);
    // Izin notifikasi di Android 13+ diminta saat app butuh -- Flutter
    //   Local Notifications otomatis meminta izin saat show() dipanggil
    //   pertama kali (via requestNotificationsPermission di versi ini),
    //   jadi tidak perlu boilerplate permission manual yang rentan.
  }

  /// Tampilkan notifikasi untuk daftar alert terkini. Hanya alert yang
  /// BELUM pernah ditampilkan yang memicu notif baru; alert yang HILANG
  /// (kembali normal) dibersihkan dari set _shown (dan memunculkan notif
  /// "kembali normal" sekali).
  Future<void> syncAlerts(List<Alert> alerts) async {
    final incomingIds = alerts.map((a) => a.id).toSet();

    // 1) Alert baru -> notif.
    for (final a in alerts) {
      if (_shown.contains(a.id)) continue;
      _shown.add(a.id);
      await _show(a);
    }

    // 2) Alert yang sudah tidak ada lagi -> bersihkan & kabarkan normal.
    final removed =
        _shown.where((id) => !incomingIds.contains(id)).toList();
    for (final id in removed) {
      _shown.remove(id);
      // (Opsional) bisa tampilkan notif "kondisi kembali normal" -- namun
      // untuk menghindari kebisingan, cukup bersihkan state tanpa notif.
    }
  }

  Future<void> _show(Alert a) async {
    const androidDetails = AndroidNotificationDetails(
      'trimharvest_alerts',
      'Peringatan Tanaman',
      channelDescription:
          'Peringatan saat tanah/pupuk menyimpang atau terdeteksi hama.',
      importance: Importance.high,
      priority: Priority.high,
      color: Color(0xFF2E7D32),
      ledColor: Color(0xFF2E7D32),
    );
    await _plugin.show(
      a.id.hashCode,
      'TrimHarvest: ${a.title}',
      a.message,
      const NotificationDetails(android: androidDetails),
    );
    // `a.id.hashCode` jadi notification id: alert sama -> notif sama
    //   (replace, tidak tumpuk). Warna channel diabaikan di beberapa
    //   launcher tapi tidak error.
  }

  /// Reset state (mis. saat logout) supaya sesi baru mulai bersih.
  void reset() => _shown.clear();
}
