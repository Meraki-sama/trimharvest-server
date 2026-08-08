import 'package:flutter/material.dart';

import 'services/api_client.dart';
import 'services/secure_storage_service.dart';
import 'services/theme_controller.dart';
import 'services/notification_service.dart';
import 'services/notif_history_service.dart';
import 'services/maintenance_service.dart';
import 'theme.dart';
import 'screens/server_setup_screen.dart';
import 'screens/login_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/splash_screen.dart';

void main() async {
  // `main()` di sini bertipe `async` -- BERBEDA dari template default
  //   Flutter (`void main() { runApp(...); }` biasa, TANPA async) --
  //   dibutuhkan karena ada `await` di bawah SEBELUM `runApp()` dipanggil.
  WidgetsFlutterBinding.ensureInitialized();
  // WAJIB dipanggil SEBELUM kode async apa pun yang menyentuh plugin
  //   platform (mis. shared_preferences di bawah) dijalankan SEBELUM
  //   `runApp()` -- fungsi ini menyiapkan "jembatan" komunikasi antara
  //   Flutter framework dengan kode platform native (Android/iOS) yang
  //   biasanya baru diinisialisasi otomatis saat `runApp()` dipanggil --
  //   tanpa baris ini, memanggil plugin platform SEBELUM `runApp()` bisa
  //   melempar error runtime.
  await ThemeController.instance.load();
  // MEMUAT preferensi tema TERSIMPAN SEBELUM `runApp()` -- supaya app
  //   langsung tampil dengan tema yang BENAR sejak frame PERTAMA (tidak
  //   ada "kedipan" sekilas memakai tema default lalu berganti ke tema
  //   tersimpan sesaat kemudian).
  await NotificationService.instance.init();
  // Inisialisasi channel notifikasi lokal (peringatan tanaman) -- harus
  //   SETELAH ensureInitialized() & SEBELUM runApp().
  await NotifHistoryService.instance.load();
  // Muat RIWAYAT peringatan tersimpan (tab Notifikasi di home) supaya
  //   entri lama langsung tampil sejak app dibuka, tanpa menunggu poll.
  await MaintenanceService.instance.load();
  // Muat JURNAL PEMELIHARAAN tersimpan (tab Jurnal/Pin) supaya catatan
  //   per-modul langsung tampil tanpa perlu baca storage lagi saat tab
  //   dibuka.
  runApp(const TrimHarvestApp());
}

class TrimHarvestApp extends StatelessWidget {
  const TrimHarvestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance.mode,
      // MEMBUNGKUS SELURUH `MaterialApp` dengan `ValueListenableBuilder`
      //   -- setiap kali `ThemeController.instance.mode` berubah
      //   (dipicu `toggleQuick()` dari dashboard_screen.dart),
      //   `MaterialApp` di bawah REBUILD dengan `themeMode` yang baru --
      //   inilah mekanisme yang membuat perubahan tema LANGSUNG
      //   TERLIHAT di seluruh app secara real-time tanpa perlu restart
      //   app.
      builder: (context, themeMode, _) {
        return MaterialApp(
          title: 'TrimHarvest',
          debugShowCheckedModeBanner: false,
          // Menyembunyikan pita/banner "DEBUG" merah di pojok kanan
          //   atas yang MUNCUL SECARA DEFAULT saat menjalankan app dalam
          //   mode debug -- murni kosmetik, tidak memengaruhi
          //   fungsionalitas.
          themeMode: themeMode,
          // Tema "Pertanian Hipnotis" terpusat di lib/theme.dart -- palet
          // psikologi warna + spacing/tipografi golden-ratio.
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          // `theme` & `darkTheme` DIDEFINISIKAN TERPISAH -- Flutter
          //   OTOMATIS memilih salah satunya berdasarkan `themeMode`
          //   (ThemeMode.light/dark/system) yang di-set di atas -- app
          //   TIDAK PERLU logika manual "kalau gelap pakai tema ini,
          //   kalau terang pakai tema itu", `MaterialApp` menanganinya
          //   sendiri berdasarkan kedua properti ini.
          home: const AppGate(),
        );
      },
    );
  }
}

// Gerbang awal app: cek apakah server sudah diatur, lalu apakah operator
// sudah login -- lihat /PROTOCOL.md bagian 3.
class AppGate extends StatefulWidget {
  // "Gate" (gerbang) -- widget KHUSUS yang tugasnya HANYA memutuskan
  //   LAYAR AWAL mana yang harus ditampilkan berdasarkan STATE
  //   TERSIMPAN (bukan konten aplikasi itu sendiri) -- pola umum untuk
  //   menangani "routing awal" berdasarkan kondisi async (baca dari
  //   secure storage) yang tidak bisa diketahui SEKETIKA saat app baru
  //   dibuka.
  const AppGate({super.key});

  @override
  State<AppGate> createState() => _AppGateState();
}

enum _GateStatus { loading, needsServerSetup, needsLogin, ready }
// Status URUTAN LOGIS: loading -> needsServerSetup (server BELUM diatur)
//   -> needsLogin (belum login) -> ready.

class _AppGateState extends State<AppGate> {
  _GateStatus _status = _GateStatus.loading;

  @override
  void initState() {
    super.initState();
    _resolveStatus();
  }

  Future<void> _resolveStatus() async {
    final serverUrl = await SecureStorageService.instance.readServerBaseUrl();
    if (serverUrl == null || serverUrl.isEmpty) {
      setState(() => _status = _GateStatus.needsServerSetup);
      return;
    }
    final loggedIn = await ApiClient.instance.isLoggedIn();
    // Cek ADA token tersimpan (murah, lokal). Kalau TIDAK ada, langsung
    //   ke login (tidak perlu nembak jaringan).
    if (!loggedIn) {
      setState(() => _status = _GateStatus.needsLogin);
      return;
    }
    // Token ADA -- tapi bisa jadi SUDAH KEDALUWARSA (access token hanya
    //   valid 15 menit). Validasi SUNGGUHAN ke server supaya app tidak
    //   langsung nyasar ke dashboard yang cuma menampilkan error "Tidak
    //   bisa terhubung" kalau tokennya ternyata mati. Kalau server
    //   menolak (401) -> bersihkan & ke login. Kalau GAGAL JARINGAN ->
    //   tetap dianggap login (dashboard yang retry), supaya WiFi flaky
    //   tidak salah lempar ke login.
    final stillValid = await ApiClient.instance.isTokenStillValid();
    setState(() => _status = stillValid ? _GateStatus.ready : _GateStatus.needsLogin);
  }

  @override
  Widget build(BuildContext context) {
    switch (_status) {
      case _GateStatus.loading:
        return const SplashScreen();
        // Spinner SINGKAT saat pemeriksaan async berlangsung -- karena
        //   `readServerBaseUrl()`/`isLoggedIn()` cuma baca dari secure
        //   storage LOKAL (bukan request jaringan), status ini BIASANYA
        //   hanya terlihat SEKILAS (milidetik) saat app pertama dibuka.
      case _GateStatus.needsServerSetup:
        return ServerSetupScreen(onDone: _resolveStatus);
        // `onDone: _resolveStatus` -- callback yang DIBERIKAN adalah
        //   METHOD `_resolveStatus` ITU SENDIRI (bukan closure baru) --
        //   setelah ServerSetupScreen selesai menyimpan URL, ia
        //   memanggil `widget.onDone()` yang SAMA DENGAN memanggil
        //   `_resolveStatus()` LAGI di sini -- yang akan MENGECEK ULANG
        //   status (kali ini serverUrl SUDAH ada) dan otomatis
        //   berpindah ke `needsLogin` atau `ready` sesuai kondisi login
        //   saat itu.
      case _GateStatus.needsLogin:
        return LoginScreen(onLoggedIn: _resolveStatus);
        // Pola IDENTIK: setelah login berhasil, `_resolveStatus()`
        //   dipanggil lagi, kali ini `isLoggedIn()` akan `true`,
        //   sehingga status berubah jadi `ready`.
      case _GateStatus.ready:
        return DashboardScreen(onLoggedOut: _resolveStatus);
        // Dan sebaliknya: setelah LOGOUT, `_resolveStatus()` dipanggil
        //   lagi, `isLoggedIn()` kini `false`, status kembali ke
        //   `needsLogin` -- SATU METHOD (`_resolveStatus`) MENANGANI
        //   SELURUH SIKLUS transisi antar-status app, dipakai berulang
        //   sebagai callback di KETIGA cabang non-loading.
    }
  }
}
