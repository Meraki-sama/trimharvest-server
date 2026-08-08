import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Preferensi tampilan (terang/gelap/ikuti sistem) -- BUKAN data sensitif
// seperti token/kredensial (yang tetap wajib lewat flutter_secure_storage,
// lihat secure_storage_service.dart), jadi shared_preferences biasa cukup
// dan sesuai di sini.
class ThemeController {
  ThemeController._();
  static final ThemeController instance = ThemeController._();
  // Pola singleton yang SAMA dengan SecureStorageService -- satu
  //   instance global untuk preferensi tema di seluruh app.

  static const _prefKey = 'theme_mode';

  // ValueNotifier supaya widget manapun (mis. tombol di AppBar dashboard)
  // bisa memicu ganti tema tanpa perlu state management tambahan (Provider/
  // Riverpod dll) -- cukup untuk kebutuhan satu preferensi global ini.
  final ValueNotifier<ThemeMode> mode = ValueNotifier(ThemeMode.system);
  // `ValueNotifier<T>` adalah kelas bawaan Flutter yang MENGGABUNGKAN
  //   "menyimpan satu nilai" dengan "memberi tahu pendengar (listener)
  //   setiap kali nilainya berubah" -- widget yang dibungkus
  //   `ValueListenableBuilder` (lihat main.dart) otomatis REBUILD setiap
  //   kali `mode.value` berubah, TANPA butuh library state management
  //   pihak ketiga (Provider/Riverpod/Bloc) -- pilihan yang PROPORSIONAL:
  //   untuk SATU preferensi global sesederhana tema, `ValueNotifier`
  //   bawaan sudah cukup, tidak perlu menambah dependency & kompleksitas
  //   ekstra.

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    // `SharedPreferences.getInstance()` -- API async karena di balik
    //   layar perlu membaca file/database kecil di disk (walau biasanya
    //   sangat cepat).
    final stored = prefs.getString(_prefKey);
    switch (stored) {
      case 'light':
        mode.value = ThemeMode.light;
        break;
      case 'dark':
        mode.value = ThemeMode.dark;
        break;
      default:
        mode.value = ThemeMode.system;
        // Default MENCAKUP baik kasus `stored == null` (belum pernah
        //   diatur, pengguna baru) MAUPUN kasus string yang tidak
        //   dikenal (data rusak/versi lama) -- keduanya jatuh ke pilihan
        //   PALING AMAN & netral: ikuti pengaturan sistem operasi.
    }
  }

  Future<void> setMode(ThemeMode newMode) async {
    mode.value = newMode;
    // Update nilai `ValueNotifier` DULU -- UI langsung merespons
    //   SEKETIKA (tidak menunggu penyimpanan ke disk selesai), baru
    //   SETELAHNYA disimpan ke SharedPreferences di bawah -- prioritas
    //   RESPONSIVITAS UI di atas urutan penyimpanan (perbedaan latensi
    //   antara keduanya sangat kecil dalam praktik, tapi urutan ini tetap
    //   praktik yang baik: UI merespons secepat mungkin, persistensi
    //   menyusul).
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, newMode.name);
    // `newMode.name` -- fitur Dart untuk enum yang memberikan
    //   representasi STRING dari nama konstanta enum (mis.
    //   `ThemeMode.dark.name` menghasilkan string `"dark"`) -- otomatis
    //   cocok dengan string yang dicek di `load()` di atas (`case
    //   'dark':`), tanpa perlu mapping manual.
  }

  // Toggle sederhana terang<->gelap dipakai tombol cepat di AppBar. Kalau
  // sedang "system", dianggap mulai dari terang (asumsi paling umum) lalu
  // toggle ke gelap.
  Future<void> toggleQuick() async {
    final isDark = isDarkNow;
    // Pakai helper `isDarkNow` (sama persis dengan yang dipakai widget
    //   lain, mis. ikon tema di dashboard) supaya logika "apakah sedang
    //   tampil gelap" TIDAK diduplikasi di banyak tempat.
    await setMode(isDark ? ThemeMode.light : ThemeMode.dark);
    // Toggle SEDERHANA: kalau saat ini gelap -> pindah ke terang
    //   eksplisit; kalau saat ini terang (termasuk kasus "system" yang
    //   kebetulan terang) -> pindah ke gelap eksplisit. CATATAN: tombol
    //   cepat ini HANYA berpindah antara `light` <-> `dark`, TIDAK PERNAH
    //   kembali ke `system` lagi lewat toggle ini (untuk kembali ke
    //   `system`, pengguna perlu mekanisme lain, mis. menu pengaturan
    //   yang lebih lengkap kalau ada) -- ini SESUAI namanya "Quick" (cepat/
    //   pintasan), bukan menu pengaturan tema yang lengkap.
  }

  /// Getter yang mengembalikan `true` kalau tampilan SAAT INI sedang gelap
  /// (baik karena mode eksplisit `dark`, maupun `system` + OS sedang
  /// gelap). Dipakai baik oleh `toggleQuick()` di sini maupun widget ikon
  /// tema di dashboard -- SATU sumber kebenaran, tidak ada duplikasi logika.
  bool get isDarkNow {
    return mode.value == ThemeMode.dark ||
        (mode.value == ThemeMode.system &&
            WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark);
  }
}
