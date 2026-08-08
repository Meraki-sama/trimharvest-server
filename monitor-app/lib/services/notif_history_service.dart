import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/alert.dart';

// =============================================================================
// NotifHistoryService — RIWAYAT peringatan tanaman DI DALAM app.
//
// Beda dari NotificationService (yang cuma memunculkan popup di status bar HP
// lalu HILANG): service ini MENYIMPAN setiap peringatan (dengan waktu & nama
// device) secara PERSISTEN di SharedPreferences, supaya pengguna bisa membuka
// tab "Notifikasi" di home dan melihat KEMBALI kondisi tanaman yang pernah
// menyimpang dari threshold — walau app sudah ditutup & dibuka ulang.
//
// Anti-spam: satu peringatan (id sama, device sama) hanya DICATAT SEKALI per
// "episode". Saat kondisi kembali normal (alert hilang) lalu menyimpang lagi
// nanti, itu dicatat sebagai entri baru. Logika episode ini disinkronkan dari
// NotificationService.syncAlerts.
// =============================================================================

// Satu entri riwayat peringatan.
class NotifRecord {
  final String alertId; // id stabil alert, mis. "tds_high"
  final String deviceId;
  final String deviceLabel;
  final AlertLevel level;
  final String title;
  final String message;
  final DateTime time;
  bool read;

  NotifRecord({
    required this.alertId,
    required this.deviceId,
    required this.deviceLabel,
    required this.level,
    required this.title,
    required this.message,
    required this.time,
    this.read = false,
  });

  Map<String, dynamic> toJson() => {
        'alertId': alertId,
        'deviceId': deviceId,
        'deviceLabel': deviceLabel,
        'level': level.name,
        'title': title,
        'message': message,
        'time': time.toIso8601String(),
        'read': read,
      };

  factory NotifRecord.fromJson(Map<String, dynamic> j) => NotifRecord(
        alertId: j['alertId'] as String? ?? '',
        deviceId: j['deviceId'] as String? ?? '',
        deviceLabel: j['deviceLabel'] as String? ?? 'Perangkat',
        level: AlertLevel.values.firstWhere(
          (e) => e.name == (j['level'] as String? ?? 'warning'),
          orElse: () => AlertLevel.warning,
        ),
        title: j['title'] as String? ?? '',
        message: j['message'] as String? ?? '',
        time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.now(),
        read: j['read'] as bool? ?? false,
      );
}

class NotifHistoryService {
  NotifHistoryService._();
  static final NotifHistoryService instance = NotifHistoryService._();

  static const _key = 'notif_history_v1';
  static const _maxRecords = 200;
  // Batasi jumlah riwayat tersimpan (buang yang paling lama kalau lewat)
  //   supaya penyimpanan tidak membengkak tanpa batas.

  // Daftar riwayat (terbaru di indeks 0). ValueNotifier supaya UI (tab
  // Notifikasi & badge unread) rebuild OTOMATIS saat ada entri baru.
  final ValueNotifier<List<NotifRecord>> records =
      ValueNotifier<List<NotifRecord>>([]);

  // Kunci episode alert yang SEDANG aktif ("$deviceId::$alertId") supaya satu
  // episode tidak dicatat berulang tiap poll 3 detik.
  final Set<String> _activeEpisodes = {};

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = (jsonDecode(raw) as List)
            .map((e) => NotifRecord.fromJson(e as Map<String, dynamic>))
            .toList();
        records.value = list;
      } catch (_) {
        records.value = [];
      }
    }
    _loaded = true;
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final data = jsonEncode(records.value.map((r) => r.toJson()).toList());
    await prefs.setString(_key, data);
  }

  int get unreadCount => records.value.where((r) => !r.read).length;

  /// Sinkronkan riwayat dengan alert terkini SATU device. Alert baru (episode
  /// yang belum aktif) DICATAT sebagai entri riwayat; alert yang sudah hilang
  /// menandai episodenya selesai supaya kejadian berikutnya dicatat lagi.
  Future<void> syncAlerts(
    String deviceId,
    String deviceLabel,
    List<Alert> alerts,
  ) async {
    if (!_loaded) await load();
    final incoming = alerts.map((a) => '$deviceId::${a.id}').toSet();
    var changed = false;

    // 1) Alert baru untuk device ini -> catat entri.
    for (final a in alerts) {
      final ep = '$deviceId::${a.id}';
      if (_activeEpisodes.contains(ep)) continue;
      _activeEpisodes.add(ep);
      records.value = [
        NotifRecord(
          alertId: a.id,
          deviceId: deviceId,
          deviceLabel: deviceLabel,
          level: a.level,
          title: a.title,
          message: a.message,
          time: DateTime.now(),
        ),
        ...records.value,
      ];
      changed = true;
    }

    // 2) Episode yang tidak lagi aktif untuk device ini -> tutup (boleh dicatat
    //    lagi kalau kambuh nanti).
    _activeEpisodes.removeWhere(
        (ep) => ep.startsWith('$deviceId::') && !incoming.contains(ep));

    // Trim ke batas maksimum.
    if (records.value.length > _maxRecords) {
      records.value = records.value.sublist(0, _maxRecords);
      changed = true;
    }

    if (changed) await _persist();
  }

  Future<void> markAllRead() async {
    if (!_loaded) await load();
    for (final r in records.value) {
      r.read = true;
    }
    records.value = List.of(records.value);
    await _persist();
  }

  Future<void> clearAll() async {
    records.value = [];
    _activeEpisodes.clear();
    await _persist();
  }

  /// Reset (mis. saat logout) — riwayat tetap tersimpan, tapi episode aktif
  /// dibersihkan supaya sesi baru mencatat ulang bila kondisi masih menyimpang.
  void resetEpisodes() => _activeEpisodes.clear();
}
