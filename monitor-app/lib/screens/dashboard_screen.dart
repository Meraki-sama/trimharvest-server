import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../models/device.dart';
import '../models/alert.dart';
import '../models/thresholds.dart';
import '../services/api_client.dart';
import '../services/theme_controller.dart';
import '../services/secure_storage_service.dart';
// Dipakai tombol "Pengaturan Server" di AppBar untuk membaca URL server
//   saat ini sebelum membuka ServerSetupScreen.
import '../theme.dart';
import '../widgets/reading_card.dart';
import '../route_transitions.dart';
import '../services/notification_service.dart';
import '../services/notif_history_service.dart';
import 'device_detail_screen.dart';
import 'add_device_screen.dart';
import 'change_password_screen.dart';
import 'splash_screen.dart';
import 'notification_history_screen.dart';
import 'maintenance_log_screen.dart';
import 'user_guide_screen.dart';
import 'server_setup_screen.dart';
// Layar pengaturan server (URL API) -- bisa dibuka SETELAH login lewat
//   tombol AppBar di bawah, bukan cuma sebelum login (main.dart).

class DashboardScreen extends StatefulWidget {
  final VoidCallback onLoggedOut;
  // Sama seperti `onLoggedIn`/`onDone` di layar-layar lain -- Dashboard
  //   TIDAK menentukan sendiri "harus pindah ke layar login" saat logout,
  //   cukup memberi tahu pemanggilnya (main.dart) lewat callback ini.
  const DashboardScreen({super.key, required this.onLoggedOut});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  List<Device>? _devices;
  // NULLABLE (`List<Device>?`, bukan `List<Device>`) -- membedakan TIGA
  //   kondisi berbeda secara EKSPLISIT: `null` = "belum pernah berhasil
  //   fetch sama sekali" (tampilkan loading spinner), list KOSONG `[]` =
  //   "berhasil fetch, memang belum ada device", list BERISI = "ada
  //   device untuk ditampilkan" -- lihat _buildBody() di bawah yang
  //   memakai perbedaan ini.
  String? _error;
  Timer? _pollTimer;
  int _tabIndex = 0;
  // 0 = tab Perangkat (daftar device), 1 = tab Notifikasi (riwayat
  //   peringatan), 2 = tab Jurnal Pemeliharaan (catatan per modul),
  //   3 = tab Buku Panduan (manual penggunaan app).
  //   Dikendalikan bottom navigation di bawah.

  @override
  void initState() {
    super.initState();
    _load();
    // Polling sederhana tiap 8 detik -- cukup responsif untuk data yang
    // dikirim node tiap >=5 detik (lihat /PROTOCOL.md), tanpa perlu
    // infrastruktur push notification/websocket tambahan.
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _load(silent: true));
    // POLLING 3 detik (dari sebelumnya 8) -- node mengirim data tiap
    //   >=5 detik, jadi 3 detik memberi update YANG LEBIH RESPONSIF
    //   (latensi maksimal ~3 detik, bukan 8) tanpa membebani server
    //   berlebihan. Tetap polling (bukan WebSocket) demi kesederhanaan
    //   deploy, cukup untuk monitoring pertanian.
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    // WAJIB membatalkan Timer saat widget dihancurkan -- kalau
    //   dilupakan, Timer akan TERUS BERJALAN di latar belakang &
    //   memanggil `_load()` yang MEMANGGIL `setState()` pada widget yang
    //   SUDAH TIDAK ADA lagi -- akan memicu ERROR/memory leak (mirip
    //   masalah `mounted` yang dibahas di login_screen.dart, tapi di
    //   sini pencegahannya lewat membatalkan Timer-nya SENDIRI, bukan
    //   cuma cek `mounted`).
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    // Parameter `silent` -- membedakan TIPE PEMANGGILAN: `silent:
    //   false` (default, dipakai saat load AWAL & saat pengguna menekan
    //   "Coba Lagi"/pull-to-refresh) MERESET `_error` ke null SEBELUM
    //   fetch (memberi kesan "mencoba ulang dari awal"); `silent: true`
    //   (dipakai POLLING BERKALA di initState di atas) TIDAK mereset
    //   error/state APA PUN sebelum fetch -- supaya polling di latar
    //   belakang TIDAK membuat UI "berkedip" (mis. menghapus data lama
    //   sesaat) tiap 8 detik walau requestnya kebetulan gagal sesaat.
    if (!silent) setState(() => _error = null);
    try {
      final devices = await ApiClient.instance.fetchDevices();
      if (!mounted) return;
      // Cek `mounted` SETELAH `await` -- pola yang konsisten dengan
      //   login_screen.dart, mencegah setState pada widget yang sudah
      //   di-dispose (PENTING di sini karena `_load` dipanggil
      //   BERULANG oleh Timer, jauh lebih sering daripada submit form
      //   biasa, jadi risiko "widget sudah hilang saat request masih
      //   berjalan" lebih besar).
      setState(() {
        _devices = devices;
        _error = null;
        // Reset error ke null juga di SINI (bukan cuma di awal
        //   fungsi) -- penting untuk kasus SILENT polling: kalau
        //   percobaan SEBELUMNYA gagal (ada _error tersimpan) tapi
        //   percobaan SEKARANG BERHASIL, error lama ini perlu
        //   dibersihkan supaya tidak nyangkut ditampilkan padahal data
        //   terbaru sudah berhasil didapat.
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 401) {
        // PENANGANAN KHUSUS untuk 401 (token tidak valid/kedaluwarsa):
        //   CATATAN PENTING -- di titik ini, ApiClient._authorizedRequest()
        //   SUDAH MENCOBA auto-refresh token SATU KALI (lihat
        //   api_client.dart) SEBELUM exception 401 ini benar-benar
        //   sampai ke sini -- jadi kalau 401 MASIH terjadi di level UI
        //   ini, artinya refresh token JUGA sudah tidak valid/kedaluwarsa
        //   (bukan cuma access token biasa yang expired) -- keputusan
        //   yang tepat di titik ini memang LOGOUT PAKSA & kembali ke
        //   layar login, karena TIDAK ADA cara lain memulihkan sesi
        //   tanpa password ulang.
        await ApiClient.instance.logout();
        widget.onLoggedOut();
        return;
      }
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Tidak bisa terhubung ke server.');
      // Pesan GENERIK (tidak menyertakan detail exception mentah
      //   seperti di login_screen.dart) -- kemungkinan karena di
      //   dashboard ini, error tak terduga LEBIH SERING terjadi akibat
      //   polling berkala menemui masalah jaringan sesaat (bukan
      //   kesalahan konfigurasi yang perlu detail teknis untuk
      //   di-debug pengguna), jadi pesan singkat & tidak menakutkan
      //   dianggap lebih sesuai di sini.
    }
  }

  Future<void> _logout() async {
    await ApiClient.instance.logout();
    widget.onLoggedOut();
    // Logout MANUAL (tombol di AppBar) -- BEDA dari logout OTOMATIS
    //   akibat 401 di `_load()` di atas: di sini TIDAK ADA pengecekan
    //   status code apa pun, pengguna memang SENGAJA menekan tombol
    //   keluar.
  }

  // Buka layar Pengaturan Server. Dipisah jadi method sendiri supaya
  // penggunaan `context` di dalamnya TIDAK melintasi async gap (linter
  // use_build_context_synchronously tidak berkelakar) -- `context` dipakai
  // langsung di sini tanpa `await` di antaranya.
  Future<bool?> _pushServerSetup(String? currentUrl) {
    return AppRoute.push<bool>(
      context,
      ServerSetupScreen(
        initialUrl: currentUrl,
        onDone: () {
          // pemanggil lama (main/login) pakai ini; di sini kita cukup
          // andalkan nilai kembalian `true` di pemanggil.
        },
      ),
    );
  }

  // Dipanggil SETELAH kembali dari layar Pengaturan Server (push selesai,
  // secara synchronous di dalam method ini) -- aman pakai `context` karena
  // TIDAK ada await di sini, sehingga linter use_build_context_synchronously
  // tidak berkelakar.
  void _notifyServerChangedAndLogout() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Server diubah. Silakan login kembali.')),
    );
    _logout();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TrimHarvest'),
        actions: [
          ValueListenableBuilder<ThemeMode>(
            valueListenable: ThemeController.instance.mode,
            // `ValueListenableBuilder` -- widget yang REBUILD OTOMATIS
            //   HANYA bagian kecil ini (bukan seluruh Scaffold) setiap
            //   kali `ThemeController.instance.mode` berubah -- efisien:
            //   mengganti tema TIDAK memicu rebuild seluruh dashboard,
            //   cukup ikon tombol ini yang perlu berubah.
            builder: (context, mode, _) {
              final isDark = ThemeController.instance.isDarkNow;
              // Satu sumber kebenaran (helper `isDarkNow` di
              //   ThemeController) -- tidak menduplikasi logika penentuan
              //   "sedang gelap" yang juga dipakai `toggleQuick()`.
              return IconButton(
                tooltip: isDark ? 'Mode Terang' : 'Mode Gelap',
                icon: AnimatedSwitcher(
                  // FIX kekakuan: sebelumnya ikon berganti SEKETIKA saat
                  //   toggle ditekan -- kini berputar+fade halus (rotasi
                  //   kecil terasa lebih "hidup" untuk aksi ganti tema).
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (child, anim) => RotationTransition(
                    turns: Tween<double>(begin: 0.75, end: 1).animate(anim),
                    child: FadeTransition(opacity: anim, child: child),
                  ),
                  child: Icon(
                    isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                    key: ValueKey(isDark),
                  ),
                ),
                // Ikon MENUNJUKKAN AKSI yang akan terjadi kalau ditekan
                //   (bukan status SAAT INI) -- kalau SEDANG gelap,
                //   tampilkan ikon MATAHARI (mengajak pindah ke terang);
                //   konvensi ikon toggle yang umum di banyak aplikasi.
                onPressed: () {
                  HapticFeedback.selectionClick();
                  ThemeController.instance.toggleQuick();
                },
              );
            },
          ),
          IconButton(
            tooltip: 'Buku Panduan',
            icon: const Icon(Icons.menu_book_outlined),
            onPressed: () => AppRoute.push(context, const UserGuideScreen()),
            // Buka buku panduan (manual penggunaan app) kapan saja sebagai
            //   pengganti tutorial interaktif. Tidak mengubah flag
            //   onboarding_done.
          ),
          IconButton(
            tooltip: 'Ganti Password',
            icon: const Icon(Icons.lock_outline),
            onPressed: () => AppRoute.push(context, const ChangePasswordScreen()),
          ),
          IconButton(
            tooltip: 'Pengaturan Server',
            icon: const Icon(Icons.dns_outlined),
            // Buka layar pengaturan URL server SETELAH login -- berguna
            //   kalau server pindah host (mis. Railway -> deploy sendiri).
            //   Setelah simpan URL baru, app otomatis LOGOUT (token milik
            //   server lama) dan kembali ke login dengan server baru.
            onPressed: () async {
              final currentUrl = await SecureStorageService.instance.readServerBaseUrl();
              // Baca URL server SAAT INI supaya ditampilkan di field
              //   (user bisa langsung Simpan tanpa mengetik ulang).
              final changed = await _pushServerSetup(currentUrl);
              if (changed == true) _notifyServerChangedAndLogout();
            },
          ),
          IconButton(
            tooltip: 'Keluar',
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      floatingActionButton: _tabIndex == 0
          ? FloatingActionButton.extended(
              onPressed: () async {
                final added = await AppRoute.push<bool>(context, const AddDeviceScreen());
                if (added == true) _load();
              },
              icon: const Icon(Icons.add),
              label: const Text('Tambah Device'),
            )
          : null,
      // Tombol "Tambah Device" HANYA muncul di tab Perangkat (index 0),
      //   tidak relevan di tab Notifikasi/Jurnal/Buku Panduan.
      body: IndexedStack(
        // IndexedStack (bukan sekadar switch) -- menjaga STATE keempat tab
        //   tetap hidup saat berpindah (daftar device tidak perlu fetch
        //   ulang tiap buka tab, polling tetap jalan di belakang).
        index: _tabIndex,
        children: [
          RefreshIndicator(
            onRefresh: () => _load(),
            child: _buildBody(),
          ),
          const NotificationHistoryView(),
          const MaintenanceLogScreen(),
          const UserGuideScreen(),
        ],
      ),
      bottomNavigationBar: ValueListenableBuilder<List<NotifRecord>>(
        valueListenable: NotifHistoryService.instance.records,
        // Rebuild badge angka "belum dibaca" tiap ada peringatan baru.
        builder: (context, records, _) {
          final unread =
              records.where((r) => !r.read).length;
          return NavigationBar(
            selectedIndex: _tabIndex,
            onDestinationSelected: (i) {
              setState(() => _tabIndex = i);
              // Buka tab Notifikasi -> tandai semua terbaca (badge hilang).
              if (i == 1) NotifHistoryService.instance.markAllRead();
            },
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard),
                label: 'Perangkat',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: unread > 0,
                  label: Text('$unread'),
                  child: const Icon(Icons.notifications_outlined),
                ),
                selectedIcon: Badge(
                  isLabelVisible: unread > 0,
                  label: Text('$unread'),
                  child: const Icon(Icons.notifications),
                ),
                label: 'Notifikasi',
              ),
              const NavigationDestination(
                icon: Icon(Icons.push_pin_outlined),
                selectedIcon: Icon(Icons.push_pin),
                label: 'Jurnal',
              ),
              const NavigationDestination(
                icon: Icon(Icons.menu_book_outlined),
                selectedIcon: Icon(Icons.menu_book),
                label: 'Panduan',
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBody() {
    // Method TERPISAH yang menangani LOGIKA TAMPILAN BERCABANG
    //   berdasarkan state (`_devices`/`_error`) -- memisahkan build()
    //   utama (struktur Scaffold/AppBar) dari logika "apa yang
    //   ditampilkan di body" membuat kode lebih mudah dibaca.
    if (_devices == null && _error == null) {
      // KEADAAN AWAL: belum pernah berhasil fetch DAN belum pernah
      //   gagal (baru saja initState, request pertama masih berjalan)
      //   -- tampilkan layar pembuka bermerek (bukan spinner polos).
      return const SplashScreen();
    }
    if (_error != null && _devices == null) {
      // KEADAAN GAGAL TOTAL: sudah PERNAH mencoba tapi GAGAL, dan
      //   BELUM PERNAH punya data devices sama sekali sebelumnya --\n      //   tampilkan pesan error + tombol coba lagi PENUH LAYAR (bukan
      //   sekadar notifikasi kecil), karena TIDAK ADA data apa pun yang
      //   bisa ditampilkan sebagai gantinya.
      return ListView(
        // `ListView` (bukan `Column` biasa) dipakai di sini WALAU
        //   isinya cuma beberapa widget statis -- alasannya: `ListView`
        //   otomatis MENDUKUNG scroll & bekerja dengan baik di dalam
        //   `RefreshIndicator` (yang butuh widget scrollable sebagai
        //   child agar gestur tarik-ke-bawah berfungsi) -- kalau
        //   memakai `Column` biasa, pull-to-refresh TIDAK akan berfungsi
        //   dalam keadaan error ini.
        children: [
          const SizedBox(height: AppSpacing.xxl),
          Icon(Icons.cloud_off,
              size: AppSpacing.xl + 16,
              color: Theme.of(context).colorScheme.error.withValues(alpha: 0.55)),
          const SizedBox(height: AppSpacing.md),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Text(_error!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AppColors.inkMuted)),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Center(
            child: FilledButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh),
              label: const Text('Coba Lagi'),
            ),
          ),
        ],
      );
    }
    final devices = _devices ?? [];
    // Di titik INI, kondisi di atas sudah menyingkirkan kemungkinan
    //   `_devices == null DAN _error == null` maupun `_error != null
    //   DAN _devices == null` -- jadi SATU-SATUNYA kemungkinan
    //   `_devices` masih null di sini adalah kasus yang TIDAK mungkin
    //   secara logika (fallback `?? []` di sini murni pengaman tipe
    //   data Dart, bukan jalur yang benar-benar diharapkan tereksekusi).
    if (devices.isEmpty) {
      // KEADAAN BERHASIL TAPI KOSONG: fetch SUKSES, memang belum ada
      //   device terdaftar sama sekali (pengguna BARU, belum pernah
      //   provisioning apa pun) -- pesan yang RAMAH & MENGARAHKAN
      //   (bukan sekadar "tidak ada data"), memberi tahu APA yang harus
      //   dilakukan (tekan tombol tambah).
      return ListView(
        children: [
          const SizedBox(height: AppSpacing.xxl),
          Icon(Icons.spa_outlined,
              size: AppSpacing.xl + 16,
              color: AppColors.leaf.withValues(alpha: 0.55)),
          const SizedBox(height: AppSpacing.md),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Text(
                'Belum ada alat yang dipantau.\nTekan tombol "Tambah Device" di kanan bawah untuk mulai.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: AppColors.inkMuted),
              ),
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      // `ListView.builder` (bukan `ListView` biasa dengan `children`
      //   statis) -- membangun widget item HANYA untuk yang SEDANG
      //   TERLIHAT di layar (lazy building) -- lebih efisien kalau
      //   jumlah device banyak (walau untuk skala proyek ini yang
      //   biasanya hanya beberapa device, perbedaannya tidak terlalu
      //   terasa, tapi tetap praktik yang baik/scalable).
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xxl),
      // Padding BAWAH jauh lebih besar (xxl) daripada sisi lain --
      //   memberi RUANG supaya item PALING BAWAH dalam daftar tidak
      //   tertutup oleh `FloatingActionButton` yang MENGAMBANG di pojok
      //   kanan bawah layar.
      itemCount: devices.length,
      itemBuilder: (context, index) => _FadeInItem(
        // FIX kekakuan: sebelumnya daftar device muncul SEKETIKA saat
        //   load pertama (langsung "nongol" penuh) -- kini tiap kartu
        //   fade+geser naik tipis secara bertahap (delay makin besar per
        //   index), memberi kesan daftar "mengalir masuk" alih-alih
        //   melompat ke layar. Hanya berjalan SEKALI saat kartu pertama
        //   kali dibangun (key per device id), TIDAK terulang tiap poll
        //   3 detik karena ListView.builder mendaur ulang widget yang
        //   sudah ada untuk index yang sama.
        key: ValueKey(devices[index].deviceId),
        index: index,
        child: _DeviceCard(device: devices[index]),
      ),
    );
  }
}

// Pembungkus animasi masuk (fade + geser naik tipis) untuk tiap item daftar
// device -- lihat pemakaian di _buildBody() di atas. StatefulWidget karena
// butuh AnimationController yang berjalan SEKALI saat widget pertama kali
// dipasang (initState), bukan tiap kali build() dipanggil ulang oleh polling.
class _FadeInItem extends StatefulWidget {
  final int index;
  final Widget child;
  const _FadeInItem({super.key, required this.index, required this.child});

  @override
  State<_FadeInItem> createState() => _FadeInItemState();
}

class _FadeInItemState extends State<_FadeInItem> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 380));
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _slide = Tween<Offset>(begin: const Offset(0, 0.06), end: Offset.zero)
        .animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    // Delay bertahap per index (dibatasi 6 item pertama saja supaya daftar
    // panjang tidak terasa lambat) -- efek "mengalir" satu-per-satu.
    final delay = Duration(milliseconds: 40 * widget.index.clamp(0, 6));
    Future.delayed(delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final Device device;
  const _DeviceCard({required this.device});
  // Constructor TANPA `super.key` -- karena ini widget PRIVAT (prefix
  //   underscore) yang tidak dipakai/diakses lintas file, kebiasaan
  //   menambahkan `key` sedikit lebih longgar dibanding widget publik
  //   (walau tetap praktik lebih baik untuk selalu menyertakannya).

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final onlineColor = device.isOnline ? AppColors.leaf : cs.onSurface.withValues(alpha: 0.4);
    // Hanya tampilkan readings "core" (bukan "raw"/kalibrasi) di ringkasan
    // dashboard -- lihat /PROTOCOL.md bagian 4, raw hanya relevan di layar
    // Kalibrasi.
    final coreReadings =
        (device.lastReading?.readings ?? const []).where((r) => r.unit != 'raw').toList();
    // `device.lastReading?.readings ?? const []` -- kalau device
    //   belum pernah kirim data sama sekali (`lastReading` null),
    //   fallback ke list KOSONG -- kombinasi dengan `.where(...)` di
    //   belakangnya memfilter SEMUA reading dengan unit "raw" (data
    //   kalibrasi mentah yang HANYA relevan di calibration_screen.dart,
    //   TIDAK perlu ditampilkan di ringkasan dashboard yang seharusnya
    //   fokus pada data yang bermakna langsung bagi pengguna).

    // Evaluasi threshold "standar industri" -- hasilnya dipakai untuk
    // banner peringatan, badge tiap kartu sensor, & notifikasi lokal.
    final alerts = evaluateReadings(coreReadings);
    final alertsByReadingId = <String, Alert>{};
    for (final a in alerts) {
      // Ambil id sensor dari alert id (format: "<id_sensor>_low" dll).
      // Map kasar: cocokkan alert ke reading berdasar prefix sebelum '_'.
      final sensorId = a.id.contains('_') ? a.id.split('_').first : a.id;
      alertsByReadingId.putIfAbsent(sensorId, () => a);
    }
    // Untuk hama (motion) id-nya "motion" persis -> sudah cocok.
    // Notifikasi lokal: panggil tiap build (aman, anti-spam via set id).
    if (alerts.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        NotificationService.instance.syncAlerts(alerts);
      });
    }
    // Catat ke RIWAYAT peringatan (tab Notifikasi) — per device, dengan
    // deduplikasi episode di dalam service. Dipanggil tiap build (aman:
    // service hanya mencatat episode BARU, bukan tiap poll).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotifHistoryService.instance.syncAlerts(device.deviceId, device.label, alerts);
    });

    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: InkWell(
        // `InkWell` -- widget yang MEMBERI EFEK RIAK VISUAL (ripple)
        //   saat disentuh, SEKALIGUS mendeteksi tap -- dipakai
        //   MEMBUNGKUS seluruh isi Card supaya SELURUH AREA kartu bisa
        //   ditekan (bukan cuma tombol kecil di dalamnya) untuk membuka
        //   detail device.
        onTap: () {
          HapticFeedback.selectionClick();
          // Getar sentuhan ringan saat kartu ditekan -- feedback fisik
          //   kecil yang membuat tap terasa "diterima" seketika, sebelum
          //   transisi halaman (280ms) selesai -- detail kecil yang
          //   membuat interaksi terasa hidup, bukan datar/kaku.
          AppRoute.push(
            context,
            DeviceDetailScreen(deviceId: device.deviceId, label: device.label),
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Ikon perangkat dalam lingkaran lembut -- memberi
                  // "berat" visual di header kartu (hierarchy lebih jelas).
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: onlineColor.withValues(alpha: 0.14),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      device.isOnline ? Icons.router : Icons.router_outlined,
                      size: 22,
                      color: onlineColor,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(device.label,
                        style: Theme.of(context).textTheme.titleLarge,
                        overflow: TextOverflow.ellipsis),
                        // `overflow: TextOverflow.ellipsis` -- kalau
                        //   label device TERLALU PANJANG untuk muat di
                        //   satu baris, dipotong dengan "..." di akhir
                        //   (bukan meluber/membuat layout rusak) --
                        //   `Expanded` di sekitarnya WAJIB ada supaya
                        //   Text ini tahu BATAS lebar maksimumnya
                        //   sebelum memutuskan kapan harus memotong.
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: onlineColor.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                    ),
                    child: Text(
                      device.isOnline ? 'Online' : 'Offline',
                      style: TextStyle(
                        color: onlineColor,
                        fontSize: AppText.caption,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (!device.isOnline)
                Container(
                  margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  // padding dinaikkan -> badge setinggi ~36dp + teks 14pt,
                  //   cukup besar & kontras supaya status "putus" langsung
                  //   terlihat dari jarak jauh (info paling kritis bagi
                  //   petani yang cek HP sekilas).
                  decoration: BoxDecoration(
                    color: cs.error,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'OFFLINE',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5),
                  ),
                ),
              if (device.gatewayPowerSave)
                Container(
                  margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.sun,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'HEMAT GW',
                    style: TextStyle(
                        color: AppColors.inkStrong,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5),
                  ),
                ),
              if (device.nodePowerSave)
                Container(
                  margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppColors.leaf,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'HEMAT',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5),
                  ),
                ),
              if (alerts.isNotEmpty)
                _AlertBanner(alerts: alerts),
              if (coreReadings.isEmpty)
                Text('Belum ada data.', style: TextStyle(color: cs.onSurface.withValues(alpha: 0.4)))
              else
                LayoutBuilder(
                  // LayoutBuilder -- kasih akses ke `constraints.maxWidth`
                  //   (lebar kartu yg TERSISA setelah padding) supaya lebar
                  //   tiap item dihitung DINAMIS dari lebar layar nyata,
                  //   BUKAN asumsi fixed. Ini krusial di layar sempit:
                  //   GridView.count dgn childAspectRatio memaksa tinggi sel
                  //   = lebar/aspectRatio, dan kalau lebar sel kecil (layar
                  //   sempit, 3 kolom) tinggi sel jadi terlalu pendek ->
                  //   "BOTTOM OVERFLOWED BY X PIXELS" (spt terlihat di HP lu).
                  builder: (context, constraints) {
                    const cols = 3;
                    const gap = AppSpacing.xs;
                    final itemWidth = (constraints.maxWidth - (cols - 1) * gap) / cols;
                    // Lebar tiap item = (lebar penuh - total spasi antar
                    //   kolom) / 3 -- dibagi rata persis supaya 3 kolom
                    //   rapi tanpa sisa.
                    return Wrap(
                      // Wrap (bukan GridView) -- TIDAK memaksa tinggi
                      //   seragam per sel, tiap ReadingCard mengambil TINGGI
                      //   NATURALNYA SENDIRI (Card + isi) -> TIDAK AKAN
                      //   overflow ke bawah walaupun layar sempit.
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final reading in coreReadings)
                          SizedBox(
                            width: itemWidth,
                            child: ReadingCard(
                              reading: reading,
                              alert: alertsByReadingId[reading.id],
                            ),
                          ),
                        // `SizedBox(width: itemWidth)` membatasi LEBAR saja
                        //   (tinggi bebas) -- kombinasi dg Wrap di atas =
                        //   anti-overflow di segala ukuran layar.
                      ],
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// Banner peringatan "standar industri" di dalam kartu device -- merangkum
// semua alert aktif (tanah kering/basah, pupuk kurang/pekato, hama) dalam
// satu kartu ringkas berwarna sesuai level tertinggi.
class _AlertBanner extends StatelessWidget {
  final List<Alert> alerts;
  const _AlertBanner({required this.alerts});

  @override
  Widget build(BuildContext context) {
    // Level tertinggi menentukan warna banner (critical = merah, else amber).
    final hasCritical = alerts.any((a) => a.level == AlertLevel.critical);
    final bg = hasCritical
        ? (Theme.of(context).colorScheme.errorContainer)
        : const Color(0xFFFFF3E0); // amber pucat
    final fg = hasCritical
        ? (Theme.of(context).colorScheme.onErrorContainer)
        : const Color(0xFF5D4037); // cokelat tua, kontras di amber

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(hasCritical ? Icons.warning_amber_rounded : Icons.info_outline,
                  size: 16, color: fg),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  alerts.length == 1
                      ? alerts.first.title
                      : '${alerts.length} peringatan tanaman',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: AppText.caption,
                      color: fg),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ...alerts.map((a) => Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text('• ${a.message}',
                    style: TextStyle(
                        fontSize: AppText.caption,
                        height: 1.4,
                        color: fg),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              )),
        ],
      ),
    );
  }
}
