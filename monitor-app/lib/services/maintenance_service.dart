import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ============================================================================
// maintenance_service.dart — Jurnal pemeliharaan per-modul (sensor/gateway).
//
// TAB "PIN / JURNAL PEMELIHARAAN" di dashboard menyimpan catatan ringan
// tentang kondisi fisik alat, mis. "sensor TDS rusak, ganti 12 Aug",
// "gateway mati lampu indikator, cek kabel". Tujuannya memudahkan
// pemeliharaan sistem di lapangan (sawah/rumah) tanpa harus ingat di
// kepala.
//
// Penyimpanan: shared_preferences (bukan secure storage) -- ini catatan
// OPERASIONAL LOKAL, bukan rahasia (bandingkan dengan token/login di
// SecureStorageService). Konsisten dengan ThemeController yang juga pakai
// shared_preferences untuk preferensi non-rahasia.
// ============================================================================

// Modul yang bisa dicatat. `deviceId` opsional: kalau null berarti catatan
// umum (mis. "gudang alat"), kalau diisi berarti spesifik untuk satu
// device/gateway terdaftar.
enum MaintenanceModule {
  umum('umum', 'Umum', Icons.info_outline),
  node('node', 'Node Sawah', Icons.sensors_outlined),
  gateway('gateway', 'Gateway Rumah', Icons.router_outlined),
  tds('tds', 'Sensor TDS', Icons.opacity_outlined),
  fork('fork', 'Sensor Fork', Icons.grass_outlined),
  cap('cap', 'Sensor Kapasitif', Icons.water_drop_outlined),
  pir('pir', 'Sensor Gerak (PIR)', Icons.vibration_outlined),
  baterai('baterai', 'Baterai', Icons.battery_full_outlined);

  const MaintenanceModule(this.id, this.label, this.icon);
  final String id;
  final String label;
  final IconData icon;

  static MaintenanceModule fromId(String id) =>
      values.firstWhere((m) => m.id == id, orElse: () => umum);
}

// Satu entri jurnal. IMMUTABLE (final semua field) -- konsisten dengan
// model Device/Reading di app ini: kalau perlu ubah, buat entri baru.
class MaintenanceEntry {
  final String id;
  final String moduleId;
  final String? deviceId; // null = catatan umum
  final String? deviceLabel;
  final String note;
  final DateTime createdAt;
  // `pinned` = entri yang di-mark "penting" (pin) supaya menonjol di
  //   atas daftar & lebih gampang ditemukan saat alat rusak mendadak.
  final bool pinned;

  const MaintenanceEntry({
    required this.id,
    required this.moduleId,
    this.deviceId,
    this.deviceLabel,
    required this.note,
    required this.createdAt,
    this.pinned = false,
  });

  factory MaintenanceEntry.fromJson(Map<String, dynamic> json) {
    final created = json['createdAt'] as String?;
    return MaintenanceEntry(
      id: json['id'] as String? ?? '',
      moduleId: json['moduleId'] as String? ?? 'umum',
      deviceId: json['deviceId'] as String?,
      deviceLabel: json['deviceLabel'] as String?,
      note: json['note'] as String? ?? '',
      createdAt:
          created != null ? DateTime.tryParse(created) ?? DateTime.now() : DateTime.now(),
      pinned: json['pinned'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'moduleId': moduleId,
        'deviceId': deviceId,
        'deviceLabel': deviceLabel,
        'note': note,
        'createdAt': createdAt.toIso8601String(),
        'pinned': pinned,
      };

  MaintenanceEntry copyWith({
    String? note,
    bool? pinned,
    String? deviceLabel,
  }) =>
      MaintenanceEntry(
        id: id,
        moduleId: moduleId,
        deviceId: deviceId,
        deviceLabel: deviceLabel ?? this.deviceLabel,
        note: note ?? this.note,
        createdAt: createdAt,
        pinned: pinned ?? this.pinned,
      );
}

class MaintenanceService {
  MaintenanceService._();
  static final MaintenanceService instance = MaintenanceService._();

  static const _prefKey = 'maintenance_entries_v1';

  // ValueNotifier supaya tab jurnal langsung REFRESH saat ada entri
  // ditambah/diubah/dihapus (tanpa perlu state management ekstra), sejauh
  // widget membungkus dirinya dengan ValueListenableBuilder.
  final ValueNotifier<List<MaintenanceEntry>> entries =
      ValueNotifier<List<MaintenanceEntry>>([]);

  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        // Urutkan: yang di-pin di atas, lalu terbaru di atas.
        final parsed = list
            .map((e) => MaintenanceEntry.fromJson(e as Map<String, dynamic>))
            .toList();
        _sort(parsed);
        entries.value = parsed;
      } catch (_) {
        // Kalau JSON rusak, mulai dari kosong (jangan crash).
        entries.value = [];
      }
    }
    _loaded = true;
  }

  void _sort(List<MaintenanceEntry> list) {
    list.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.createdAt.compareTo(a.createdAt);
    });
  }

  Future<void> _persist(List<MaintenanceEntry> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefKey, jsonEncode(list.map((e) => e.toJson()).toList()));
    entries.value = List<MaintenanceEntry>.from(list);
  }

  Future<void> saveEntry(MaintenanceEntry entry) async {
    // Update kalau id sudah ada, atau tambah baru.
    final existing = entries.value.indexWhere((e) => e.id == entry.id);
    final list = List<MaintenanceEntry>.from(entries.value);
    if (existing >= 0) {
      list[existing] = entry;
    } else {
      list.add(entry);
    }
    _sort(list);
    await _persist(list);
  }

  Future<void> togglePin(MaintenanceEntry entry) async {
    final list = entries.value.map((e) {
      if (e.id == entry.id) return e.copyWith(pinned: !e.pinned);
      return e;
    }).toList();
    _sort(list);
    await _persist(list);
  }

  Future<void> deleteEntry(String id) async {
    final list = entries.value.where((e) => e.id != id).toList();
    await _persist(list);
  }
}
