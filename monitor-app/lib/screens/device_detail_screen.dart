import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import '../theme.dart';
// `show Clipboard, ClipboardData` -- import SELEKTIF, hanya mengambil
//   DUA nama ini dari package `flutter/services.dart` (yang isinya jauh
//   lebih banyak) -- mempersempit apa yang "terlihat" di file ini,
//   sedikit dokumentasi implisit tentang APA yang sebenarnya dipakai
//   dari import ini.

import '../models/reading.dart';
import '../models/alert.dart';
import '../models/thresholds.dart';
import '../services/api_client.dart';
import '../services/secure_storage_service.dart';
import '../widgets/reading_card.dart';
import '../widgets/sparkline.dart';
import '../route_transitions.dart';
import 'calibration_screen.dart';

class DeviceDetailScreen extends StatefulWidget {
  final String deviceId;
  final String label;
  const DeviceDetailScreen({super.key, required this.deviceId, required this.label});
  // Menerima `label` LANGSUNG dari layar sebelumnya (dashboard_screen.dart
  //   meneruskan `device.label` saat navigasi) -- supaya AppBar bisa
  //   LANGSUNG menampilkan judul yang benar SEKETIKA, tanpa harus
  //   menunggu fetch data device ini selesai dulu (data histori/reading
  //   memang perlu di-fetch async, tapi label sudah tersedia lebih awal).

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  List<ReadingSnapshot> _history = [];
  // BERBEDA dari `_devices` di dashboard_screen.dart yang NULLABLE --
  //   di sini `_history` langsung diinisialisasi list KOSONG (bukan
  //   null) -- konsekuensinya: layar ini TIDAK PUNYA state "loading
  //   awal" yang terpisah secara eksplisit (lihat build(): kondisi
  //   "coreReadings.isEmpty" dipakai untuk menampilkan pesan "belum ada
  //   data", yang SECARA VISUAL sama antara "masih loading" dan "memang
  //   kosong" -- perbedaan kecil dari pola di dashboard_screen.dart yang
  //   membedakan ketiganya secara eksplisit).
  String? _error;
  Timer? _pollTimer;
  bool _sendingCommand = false;
  // Flag TUNGGAL untuk menandakan "SEDANG mengirim SATU perintah
  //   apa pun" -- dipakai menonaktifkan SEMUA tombol kontrol sekaligus
  //   (lihat build(): banyak `onPressed: _sendingCommand ? null :
  //   ...`), mencegah pengguna menekan BEBERAPA perintah SEKALIGUS
  //   secara bersamaan yang bisa membingungkan urutan eksekusinya.

  @override
  void initState() {
    super.initState();
    // Panggil _load() SEKALI saja, lalu (di .then) ambil ID reading untuk
    // memuat threshold tersimpan -- menghindari double network call & race
    // (lihat bug #1: pemanggilan _load() ganda di initState sebelumnya).
    _load().then((_) {
      if (!mounted) return;
      final ids = _history
          .where((s) => s.type == 'sensor')
          .expand((s) => s.readings)
          .where((r) => r.unit != 'bool' && r.value != null)
          .map((r) => r.id)
          .toSet()
          .toList();
      _loadThresholds(ids);
    });
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _load(silent: true));
    // Polling 3 detik (dari 8) -- konsisten dengan dashboard_screen,
    //   memberi update grafik/ringkasan lebih responsif (latensi maksimal
    //   ~3 detik) mengikuti node yg kirim tiap >=5 detik.
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    // Bebaskan semua TextEditingController patokan (cegah memory leak tiap
    // navigasi keluar dari layar detail -- lihat bug #2).
    for (final c in _thresholdControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final history = await ApiClient.instance.fetchReadings(widget.deviceId, limit: 100);
      // `limit: 100` -- LEBIH KECIL dari default `fetchReadings` (200,
      //   lihat api_client.dart) -- kemungkinan cukup untuk grafik
      //   Sparkline yang ditampilkan (tidak butuh RIBUAN titik data,
      //   yang justru akan membuat grafik terlalu padat/tidak terbaca),
      //   sekaligus mempercepat waktu muat layar ini.
      if (!mounted) return;
      setState(() {
        _history = history;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      // Perbaikan: konsisten dengan cabang `catch` di bawah -- pesan
      // error HANYA ditampilkan kalau BUKAN polling diam-diam (`!silent`).
      // Sebelumnya polling latar belakang yang gagal (mis. sesi
      // kedaluwarsa) tetap memunculkan error yang mengganggu, padahal
      // niat `silent: true` adalah jangan mengganggu kalau sekadar gagal
      // sesaat. Error jenis ApiException sekarang dihormati flag silent.
      if (!silent) setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      if (!silent) setState(() => _error = 'Tidak bisa memuat data.');
      // Di CABANG INI (exception umum/jaringan), baru benar-benar
      //   MENGHORMATI flag `silent` -- error HANYA ditampilkan kalau
      //   BUKAN polling diam-diam (`!silent`) -- inkonsistensi kecil
      //   dibanding cabang ApiException di atas yang disebutkan
      //   sebelumnya.
    }
  }

  ReadingSnapshot? get _latestCore {
    // Getter yang mencari snapshot "core" TERBARU dari seluruh
    //   `_history` -- diperlukan karena `_history` berisi CAMPURAN
    //   snapshot (sensor "core", sensor "calib", heartbeat) yang datang
    //   BERURUTAN secara kronologis, dan layar ini HANYA butuh yang
    //   PALING BARU dari jenis "core" untuk menampilkan kartu ringkasan
    //   di atas.
    for (final snap in _history.reversed) {
      // `.reversed` -- iterasi dari BELAKANG (data TERBARU, karena
      //   server/api_client.dart mengembalikan histori dalam urutan
      //   KRONOLOGIS lama->baru, lihat server/src/routes/devices.js:
      //   `.reverse()` di sana) -- mencari dari belakang berarti
      //   menemukan yang TERBARU LEBIH DULU, dan `return` langsung
      //   berhenti di situ (tidak perlu memindai SELURUH list kalau
      //   yang dicari sudah ketemu di dekat akhir).
      if (snap.type == 'sensor' && snap.nodeMsgType == 'core') return snap;
    }
    return null;
    // Null kalau device BELUM PERNAH mengirim body tipe "core" sama
    //   sekali (mis. device benar-benar baru) -- ditangani di build()
    //   lewat operator `?.`/`??`.
  }

  List<double> _historyFor(String readingId) {
    // Ekstrak SERI NILAI historis untuk SATU `readingId` tertentu
    //   (mis. semua nilai "tds" dari waktu ke waktu) dari `_history` --
    //   dipakai untuk menyusun data yang ditampilkan Sparkline.
    final values = <double>[];
    for (final snap in _history) {
      if (snap.type != 'sensor') continue;
      // Lewati snapshot HEARTBEAT (tidak punya reading sensor sama
      //   sekali, lihat routes/ingest.js yang tidak menyimpan `readings`
      //   untuk heartbeat) -- hanya snapshot bertipe "sensor" yang
      //   relevan di sini.
      final r = snap.byId(readingId);
      if (r?.value != null) values.add(r!.value!.toDouble());
      // CATATAN: snapshot tipe "sensor" TAPI nodeMsgType "calib" JUGA
      //   IKUT DIPERIKSA di sini (TIDAK difilter seperti `_latestCore`
      //   di atas yang eksplisit mensyaratkan nodeMsgType == 'core') --
      //   ini AMAN & BENAR karena `snap.byId(readingId)` cuma akan
      //   MENGEMBALIKAN NILAI kalau `readingId` yang dicari MEMANG ADA
      //   di snapshot tersebut (mis. mencari "tds" tidak akan
      //   menemukan apa pun di snapshot "calib" yang isinya "tds_raw",
      //   ID YANG BERBEDA) -- jadi secara PRAKTIK snapshot "calib" tetap
      //   diperiksa tapi TIDAK PERNAH cocok untuk ID sensor "core"
      //   biasa, hasilnya tetap benar walau tidak difilter eksplisit.
      //   `r!.value!` -- DUA null-assertion berturutan: `r!` aman
      //   karena sudah dicek `r?.value != null` di kondisi if (yang
      //   secara implisit juga membuktikan `r` sendiri bukan null), dan
      //   `.value!` aman karena kondisi if yang sama sudah memastikan
      //   `value` bukan null.
    }
    return values;
  }

  Future<void> _sendCommand(Map<String, dynamic> command, {String? successMessage}) async {
    // Helper TERPUSAT untuk mengirim SEMUA jenis perintah (dipakai
    //   oleh banyak tombol di build() di bawah) -- menyatukan pola
    //   loading state + feedback SnackBar sukses/gagal di SATU tempat.
    setState(() => _sendingCommand = true);
    try {
      await ApiClient.instance.sendCommand(widget.deviceId, command);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(successMessage ?? 'Perintah terkirim, akan diproses gateway.')),
        // `successMessage` OPSIONAL -- kebanyakan pemanggilan cukup
        //   pakai pesan DEFAULT yang generik, tapi untuk perintah yang
        //   butuh penjelasan lebih spesifik (mis. wifi_update, lihat
        //   _promptWifiUpdate di bawah) bisa diberi pesan kustom yang
        //   lebih informatif.
      );
      // CATATAN PENTING soal MAKNA "terkirim" di sini: SnackBar ini
      //   muncul begitu server MENGONFIRMASI menerima & MENGANTRE
      //   perintah (lihat server/src/routes/devices.js POST /commands:
      //   `arrayUnion` ke `pendingCommands`), BUKAN berarti perintah
      //   SUDAH BENAR-BENAR DITERAPKAN di gateway/node -- itulah kenapa
      //   pesan defaultnya berbunyi "akan diproses gateway" (future
      //   tense), bukan "berhasil diterapkan" (past tense) -- perintah
      //   BARU benar-benar sampai ke perangkat fisik saat gateway
      //   melakukan ingest/heartbeat BERIKUTNYA (lihat
      //   gateway-rumah/src/main.cpp).
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Gagal mengirim perintah.')));
    } finally {
      if (mounted) setState(() => _sendingCommand = false);
    }
  }

  Future<void> _promptSetInterval() async {
    // Menampilkan DIALOG untuk mengetik interval baru (detik), lalu
    //   MENGIRIM command "set_interval" kalau pengguna mengonfirmasi.
    final controller = TextEditingController(text: '5');
    // Nilai AWAL "5" -- sesuai default SEND_INTERVAL di
    //   node-sawah/src/config.h (5000 ms = 5 detik), memberi pengguna
    //   titik awal yang masuk akal.
    final seconds = await showDialog<int>(
      // `showDialog<int>` -- generic type menandakan dialog ini
      //   DIHARAPKAN mengembalikan `int?` lewat `Navigator.pop(context,
      //   nilai)` -- pola YANG SAMA seperti `Navigator.push<bool>` di
      //   dashboard_screen.dart, tapi untuk dialog (bukan halaman penuh).
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Interval Kirim Data (detik)'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: 'mis. 5, 30, 60'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
          // `Navigator.pop(context)` TANPA argumen kedua -- otomatis
          //   mengembalikan `null` ke pemanggil `showDialog` -- kondisi
          //   `if (seconds == null...)` di bawah menangani kasus
          //   "dibatalkan" ini.
          FilledButton(
            onPressed: () => Navigator.pop(context, int.tryParse(controller.text)),
            // `int.tryParse(...)` -- kalau teks yang diketik BUKAN
            //   angka valid (mis. pengguna mengetik huruf), hasilnya
            //   `null` -- DIKEMBALIKAN APA ADANYA (termasuk null) ke
            //   pemanggil, divalidasi setelah dialog ditutup (bukan di
            //   dalam dialog itu sendiri) -- pendekatan yang lebih
            //   sederhana daripada validasi form penuh untuk dialog
            //   sesederhana ini.
            child: const Text('Terapkan'),
          ),
        ],
      ),
    );
    if (seconds == null || seconds <= 0) return;
    // Validasi SETELAH dialog ditutup: baik "dibatalkan" (null) MAUPUN
    //   "angka tidak valid/negatif/nol" (<=0) SAMA-SAMA dianggap "tidak
    //   ada tindakan" -- TIDAK ADA pesan error yang ditampilkan kalau
    //   pengguna mengetik angka tidak valid, cukup diam-diam diabaikan
    //   (CATATAN: ini SEDIKIT KURANG INFORMATIF -- pengguna yang salah
    //   ketik angka tidak akan tahu KENAPA tombol "Terapkan" sepertinya
    //   "tidak berbuat apa-apa"; validasi eksplisit dengan pesan error di
    //   dalam dialog akan memberi feedback yang lebih jelas).
    await _sendCommand({'dest': 'node', 'cmd': 'set_interval', 'value': seconds});
    // Command diarahkan ke `dest: 'node'` (bukan gateway) -- karena
    //   interval kirim SENSOR diatur di firmware NODE (lihat
    //   node-sawah/src/main.cpp: `sendIntervalMs`), gateway hanya
    //   MENERUSKAN command ini apa adanya lewat LoRa.
  }

  Future<void> _promptWifiUpdate() async {
    // Dialog untuk mengganti kredensial WiFi GATEWAY dari JARAK JAUH
    //   (lewat internet, BUKAN lewat AP setup fisik) -- lihat
    //   applyWifiUpdate() di gateway-rumah/src/wifi_provision.cpp untuk
    //   sisi firmware.
    final ssidController = TextEditingController();
    final passwordController = TextEditingController();
    var obscurePassword = true;
    // `var` (bukan `final`) -- variabel INI PERLU BISA DIUBAH (lihat
    //   `setDialogState` di bawah, dipakai men-toggle visibilitas
    //   password DI DALAM dialog).

    final result = await showDialog<({String ssid, String password})>(
      // Generic type-nya RECORD TYPE `({String ssid, String
      //   password})` -- sama dengan pola di `ApiClient.provisionDevice()`,
      //   mengembalikan SEPASANG nilai bernama sekaligus tanpa perlu
      //   class terpisah.
      context: context,
      builder: (context) => StatefulBuilder(
        // `StatefulBuilder` -- WIDGET KHUSUS yang membungkus builder
        //   dialog ini supaya PUNYA `setState`-nya SENDIRI
        //   (`setDialogState`), TERPISAH dari `setState` milik
        //   `_DeviceDetailScreenState` -- DIPERLUKAN di sini karena
        //   dialog ini punya STATE INTERNAL-nya sendiri (toggle
        //   `obscurePassword`) yang HANYA relevan SELAMA dialog ini
        //   terbuka -- tanpa `StatefulBuilder`, dialog (yang dibangun
        //   lewat `builder:` closure biasa, BUKAN `StatefulWidget`
        //   terpisah) TIDAK PUNYA cara untuk rebuild DIRINYA SENDIRI
        //   saat `obscurePassword` berubah.
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Ganti WiFi Gateway'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Gateway akan pindah ke jaringan WiFi baru ini dan restart. '
                'Kalau SSID/password salah, gateway otomatis kembali ke mode '
                'setup (tidak akan terkunci).',
                style: TextStyle(fontSize: AppText.caption, color: AppColors.inkMuted),
                // Teks penjelasan ini SECARA LANGSUNG mengonfirmasi ke
                //   pengguna mekanisme "fail-safe" yang dijelaskan di
                //   gateway-rumah/src/wifi_provision.h (kalau SSID/
                //   password baru gagal, gateway otomatis kembali ke
                //   mode setup AP) -- transparansi yang baik: pengguna
                //   diberi tahu APA yang akan terjadi kalau salah ketik,
                //   mengurangi kekhawatiran akan "mengunci" gateway
                //   secara permanen.
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ssidController,
                decoration: const InputDecoration(
                  labelText: 'Nama WiFi (SSID)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordController,
                obscureText: obscurePassword,
                decoration: InputDecoration(
                  labelText: 'Password WiFi',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setDialogState(() => obscurePassword = !obscurePassword),
                    // Memakai `setDialogState` (BUKAN `setState` biasa
                    //   milik State layar) -- inilah alasan
                    //   `StatefulBuilder` dipakai: cuma dialog ini yang
                    //   perlu rebuild saat toggle ditekan, bukan seluruh
                    //   layar `DeviceDetailScreen` di belakangnya.
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
            FilledButton(
              onPressed: () {
                if (ssidController.text.trim().isEmpty) return;
                // Validasi MINIMAL: SSID tidak boleh kosong -- kalau
                //   kosong, tombol "Terapkan" TIDAK melakukan apa pun
                //   (dialog TETAP terbuka, mirip validasi
                //   _promptSetInterval yang diam-diam mengabaikan input
                //   tidak valid tanpa pesan error eksplisit).
                Navigator.pop(context, (
                  ssid: ssidController.text.trim(),
                  password: passwordController.text,
                  // Password TIDAK di-trim (konsisten dengan alasan
                  //   yang SAMA di login_screen.dart: spasi bisa jadi
                  //   bagian SAH dari password WiFi).
                ));
              },
              child: const Text('Terapkan'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;

    await _confirmAndRun(
      // PERHATIKAN: ADA DIALOG KONFIRMASI KEDUA di sini (lewat
      //   _confirmAndRun di bawah) SETELAH dialog input SSID/password di
      //   atas -- pengguna harus melewati DUA LANGKAH konfirmasi untuk
      //   perintah ini (isi form, lalu konfirmasi ulang) -- perlakuan
      //   EKSTRA HATI-HATI yang MASUK AKAL karena perintah ini BERISIKO
      //   TINGGI (bisa memutus komunikasi gateway kalau salah, walau ada
      //   fail-safe) dibanding perintah lain yang cukup SATU dialog
      //   konfirmasi saja (restart node/gateway, lihat build() di
      //   bawah).
      'Ganti WiFi Gateway?',
      'Gateway akan restart dan mencoba konek ke "${result.ssid}". '
          'Pastikan jaringan ini bisa dijangkau dari lokasi gateway.',
      () => _sendCommand(
        {'dest': 'gateway', 'cmd': 'wifi_update', 'ssid': result.ssid, 'password': result.password},
        successMessage: 'Perintah ganti WiFi terkirim. Gateway akan restart & mencoba konek.',
      ),
    );
  }

  Future<void> _confirmAndRun(String title, String message, VoidCallback onConfirm) async {
    // Helper GENERIK untuk dialog "Ya/Batal" sederhana -- dipakai
    //   BERULANG KALI di build() (restart node, restart gateway, wifi
    //   update, rekey) -- menghindari duplikasi kode dialog konfirmasi
    //   yang IDENTIK strukturnya di banyak tempat.
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Lanjutkan')),
        ],
      ),
    );
    if (confirmed == true) onConfirm();
    // `== true` (bukan cuma `if (confirmed)`) -- SENGAJA, karena
    //   `confirmed` bertipe `bool?` (nullable): kalau pengguna menutup
    //   dialog TANPA menekan tombol apa pun (mis. tap di luar area
    //   dialog/tombol back Android), `showDialog` mengembalikan `null`
    //   -- `confirmed == true` secara EKSPLISIT menolak baik `false`
    //   MAUPUN `null` sebagai "tidak dikonfirmasi", hanya `true` yang
    //   BENAR-BENAR eksplisit yang menjalankan `onConfirm`.
  }

  Future<void> _rekeyDevice() async {
    await _confirmAndRun(
      'Rekey Device?',
      'Ini akan membuat kredensial baru untuk device ini. Gateway akan menerapkannya '
          'otomatis setelah menerima perintah ini (butuh koneksi internet gateway aktif).',
      () async {
        try {
          final newSecret = await ApiClient.instance.rekeyDevice(widget.deviceId);
          // CATATAN ALUR: ini memanggil `rekeyDevice()` LANGSUNG (BUKAN
          //   lewat helper `_sendCommand()` yang dipakai perintah lain di
          //   atas) -- karena endpoint `/rekey` (server/src/routes/devices.js)
          //   MENGEMBALIKAN NILAI PENTING (secret baru) yang HARUS
          //   ditampilkan ke pengguna, berbeda dari `sendCommand()` yang
          //   cuma perlu tahu sukses/gagal tanpa data balik yang berarti.
          if (!mounted) return;
          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            // Perbaikan: dialog secret BARU TIDAK bisa ditutup dengan
            //   tap di luar area dialog. Secret rekey HANYA dikembalikan
            //   SEKALI oleh server (lihat routes/devices.js POST /rekey),
            //   jadi kalau dialog ini kelepas sebelum disalin, nilainya
            //   TIDAK BISA dilihat lagi lewat app tanpa rekey ulang.
            //   Memaksa pengguna menekan "Salin" atau "Selesai" mencegah
            //   kehilangan secret tidak sengaja.
            builder: (context) => AlertDialog(
              title: const Text('Secret Baru'),
              content: SelectableText(newSecret),
              // `SelectableText` (BUKAN `Text` biasa) -- teks INI BISA
              //   DIPILIH/DI-BLOK oleh pengguna secara manual (mis. untuk
              //   menyalin sebagian saja) -- penting untuk data seperti
              //   secret yang mungkin perlu disalin/diverifikasi karakter
              //   demi karakter.
              actions: [
                TextButton(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: newSecret));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Disalin ke clipboard.')));
                  },
                  child: const Text('Salin'),
                ),
                FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Selesai')),
              ],
            ),
          );
          // PENTING: dialog ini TIDAK BISA DITUTUP TANPA SENGAJA lewat
          //   `barrierDismissible` default (true) -- CATATAN: `showDialog`
          //   di sini TIDAK secara eksplisit mengeset
          //   `barrierDismissible: false`, artinya pengguna BISA menutup
          //   dialog ini dengan tap di luar area dialog TANPA sempat
          //   menyalin secret barunya -- kalau itu terjadi, secret baru
          //   ini TIDAK BISA dilihat lagi lewat app (server hanya
          //   mengembalikannya SEKALI saat rekey, lihat
          //   server/src/routes/devices.js) -- perlu rekey ULANG untuk
          //   mendapat secret BARU LAGI kalau nilai ini sampai
          //   terlewat/hilang -- SATU AREA yang bisa dipertimbangkan
          //   untuk diperketat (`barrierDismissible: false`) supaya
          //   pengguna TIDAK BISA menutup dialog ini secara tidak
          //   sengaja sebelum menyalin nilainya.
        } on ApiException catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
        }
      },
    );
  }

  bool _deleting = false;
  // Flag TERPISAH dari `_sendingCommand` -- sengaja tidak digabung,
  //   karena kalau digabung, delete yang sedang berjalan juga akan
  //   menonaktifkan tombol-tombol perintah lain (yang sudah tidak relevan
  //   lagi begitu proses hapus dimulai, layar ini akan segera ditutup),
  //   dan sebaliknya. Dipakai HANYA untuk mencegah pengguna menekan tombol
  //   "Hapus Device" dua kali sambil menunggu request pertama selesai.

  // Threshold (angka patokan) per sensor, disimpan lokal per device+reading.
  // Kunci: "$deviceId::$readingId". Diambil dari SecureStorage saat init.
  final Map<String, double> _thresholds = {};
  final Map<String, TextEditingController> _thresholdControllers = {};

  String _thresholdKey(String readingId) => '${widget.deviceId}::$readingId';

  Future<void> _loadThresholds(List<String> readingIds) async {
    for (final id in readingIds) {
      final v = await SecureStorageService.instance
          .readThreshold(_thresholdKey(id));
      if (v != null) _thresholds[id] = v;
    }
  }

  Future<void> _saveThreshold(String readingId, double? value) async {
    if (value == null) {
      _thresholds.remove(readingId);
      await SecureStorageService.instance.removeThreshold(_thresholdKey(readingId));
    } else {
      _thresholds[readingId] = value;
      await SecureStorageService.instance
          .saveThreshold(_thresholdKey(readingId), value);
    }
    if (mounted) setState(() {});
  }

  Future<void> _deleteDevice() async {
    // KONFIRMASI GANDA yang LEBIH KETAT daripada `_confirmAndRun` biasa
    //   (yang cuma dialog Ya/Batal) -- pengguna WAJIB MENGETIK ULANG label
    //   device persis sama dulu, baru tombol "Hapus" aktif. Perlakuan
    //   se-ekstra ini SENGAJA karena aksi ini (BEDA dari rekey/restart)
    //   TIDAK BISA DIBATALKAN sama sekali: histori data sensor device ini
    //   ikut terhapus permanen di server (lihat
    //   server/src/routes/devices.js DELETE /:id yang memakai
    //   db.recursiveDelete), bukan sekadar mengubah kredensial/status.
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final matches = controller.text == widget.label;
          return AlertDialog(
            title: const Text('Hapus Device?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Device "${widget.label}" beserta SELURUH histori datanya akan '
                  'dihapus permanen dan TIDAK BISA dikembalikan. Ketik ulang label '
                  'device untuk konfirmasi:',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    hintText: widget.label,
                  ),
                  onChanged: (_) => setDialogState(() {}),
                  // `setDialogState` (BUKAN `setState` biasa) -- pola yang
                  //   sama dipakai di dialog ganti WiFi di atas (lihat
                  //   `showDialog<({String ssid, String password})>`):
                  //   `StatefulBuilder` diperlukan supaya isi DIALOG bisa
                  //   rebuild sendiri (mis. mengaktifkan tombol "Hapus" saat
                  //   teks sudah cocok) TANPA rebuild seluruh
                  //   DeviceDetailScreen di baliknya.
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Batal')),
              FilledButton(
                onPressed: matches ? () => Navigator.pop(context, true) : null,
                // `null` kalau teks BELUM cocok -- tombol tampak abu-abu/
                //   nonaktif, konsisten dengan konvensi Flutter "onPressed:
                //   null artinya disabled" yang dipakai di seluruh app ini.
                style: FilledButton.styleFrom(backgroundColor: AppColors.danger(context)),
                child: const Text('Hapus'),
              ),
            ],
          );
        },
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting = true);
    try {
      await ApiClient.instance.deleteDevice(widget.deviceId);
      if (!mounted) return;
      Navigator.of(context).pop();
      // Kembali ke dashboard SETELAH berhasil hapus -- layar detail ini
      //   sendiri sudah tidak relevan lagi (device-nya sudah tidak ada),
      //   dashboard akan otomatis tidak menampilkannya lagi di polling
      //   berikutnya.
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Gagal menghapus device.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final coreReading = _latestCore;
    final coreReadings = (coreReading?.readings ?? const []).where((r) => r.unit != 'raw').toList();
    // Evaluasi threshold "standar industri" untuk badge peringatan di
    // tiap kartu sensor.
    final alerts = evaluateReadings(coreReadings);
    final alertsByReadingId = <String, Alert>{};
    for (final a in alerts) {
      final sensorId = a.id.contains('_') ? a.id.split('_').first : a.id;
      alertsByReadingId.putIfAbsent(sensorId, () => a);
    }
    final numericReadings = coreReadings
        .where((r) => r.unit != 'bool' && r.value != null)
        .toList(growable: false);
    // Filter TAMBAHAN khusus untuk Sparkline: HANYA reading yang
    //   NUMERIK & BUKAN boolean & MEMILIKI nilai (bukan null) yang layak
    //   digambar sebagai GRAFIK GARIS TREN -- reading boolean (mis.
    //   "motion") secara konsep TIDAK PUNYA "tren garis" yang bermakna
    //   (nilainya cuma 0/1), jadi tidak ditampilkan sebagai Sparkline
    //   sama sekali.

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.label),
        actions: [
          IconButton(
            tooltip: 'Hapus Device',
            onPressed: _deleting ? null : _deleteDevice,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: TextStyle(color: AppColors.danger(context))),
              ),
            if (coreReadings.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: Text('Belum ada data dari device ini.')),
              )
            else ...[
              LayoutBuilder(
                builder: (context, constraints) {
                  const cols = 2;
                  const gap = 10.0;
                  final itemWidth = (constraints.maxWidth - (cols - 1) * gap) / cols;
                  return Wrap(
                    spacing: gap,
                    runSpacing: gap,
                    children: [
                      for (final r in coreReadings)
                        SizedBox(
                          width: itemWidth,
                          child: ReadingCard(
                            reading: r,
                            threshold: _thresholds[r.id],
                            alert: alertsByReadingId[r.id],
                            // Bug #9: sensor analog yang belum disambung/kalibrasi
                            // kirim 0 terus. Tandai sebagai "PERLU KALIBRASI"
                            // biar pengguna paham, bukan mengira 0 itu kondisi nyata.
                            needsCalibration: r.unit != 'bool' &&
                                r.unit != 'raw' &&
                                r.value is num &&
                                (r.value as num) == 0,
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              Text('Riwayat', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final r in numericReadings) ...[
                // `for` DI DALAM `children: [...]` LUAR (bukan di
                //   dalam GridView terpisah) -- setiap reading numerik
                //   menghasilkan TIGA widget berturutan (label, grafik,
                //   spasi) yang ditumpuk VERTIKAL sebagai bagian dari
                //   `ListView` utama -- BEDA dari GridView di atas yang
                //   menyusun kartu-kartu secara GRID 2 kolom.
                Row(
                  children: [
                    Expanded(
                      child: Text('${r.id} (${r.unit})',
                          style: Theme.of(context).textTheme.labelMedium),
                    ),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        // Input "angka patokan" (threshold) per sensor --
                        //   disimpan lokal, digambar sebagai garis merah
                        //   putus-putus di Sparkline di bawah.
                        controller: _thresholdControllers.putIfAbsent(
                          r.id,
                          () => TextEditingController(
                            text: _thresholds[r.id]?.toString() ?? '',
                          ),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(
                          isCollapsed: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          hintText: 'Patokan',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (val) {
                          final v = double.tryParse(val.trim());
                          _saveThreshold(r.id, v);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Sparkline(
                  values: _historyFor(r.id),
                  threshold: _thresholds[r.id],
                ),
                const SizedBox(height: 16),
              ],
            ],
            const Divider(height: 32),
            Text('Kontrol', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              // `Wrap` (bukan `Row`/`Column`) -- widget yang MENYUSUN
              //   children secara HORIZONTAL, tapi OTOMATIS "melipat" ke
              //   baris BERIKUTNYA kalau tidak muat di lebar layar --
              //   cocok untuk KUMPULAN TOMBOL yang jumlahnya banyak &
              //   panjang labelnya bervariasi, tanpa perlu menghitung
              //   manual berapa yang muat per baris (responsif otomatis
              //   terhadap lebar layar berbeda).
              spacing: 8,
              runSpacing: 8,
              // `spacing` = jarak HORIZONTAL antar tombol dalam satu
              //   baris; `runSpacing` = jarak VERTIKAL antar-baris yang
              //   ter-"lipat" -- dua parameter terpisah karena `Wrap`
              //   punya dua ARAH jarak yang independen.
              children: [
                OutlinedButton.icon(
                  onPressed: _sendingCommand ? null : _promptSetInterval,
                  icon: const Icon(Icons.timer_outlined),
                  label: const Text('Atur Interval'),
                ),
                OutlinedButton.icon(
                  onPressed: _sendingCommand
                      ? null
                      : () => _confirmAndRun(
                            'Restart Node?',
                            'Node sensor akan restart. Perintah diterapkan saat node berikutnya kirim/terima data lewat gateway.',
                            () => _sendCommand({'dest': 'node', 'cmd': 'restart'}),
                          ),
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Restart Node'),
                ),
                OutlinedButton.icon(
                  onPressed: _sendingCommand
                      ? null
                      : () => _confirmAndRun(
                            'Hemat Node?',
                            'Node sensor masuk mode hemat baterai (tetap hidup & bisa dikendalikan). Interval kirim diperlambat untuk menghemat daya. Untuk kembali normal, colok ulang/listrik node (tidak bisa diaktifkan dari jauh).',
                            () => _sendCommand({'dest': 'node', 'cmd': 'power_save', 'value': true}),
                          ),
                  icon: const Icon(Icons.bedtime_outlined),
                  label: const Text('Hemat Node'),
                ),
                OutlinedButton.icon(
                  onPressed: _sendingCommand
                      ? null
                      : () => _confirmAndRun(
                            'Restart Gateway?',
                            'Gateway rumah akan restart.',
                            () => _sendCommand({'dest': 'gateway', 'cmd': 'restart'}),
                          ),
                  icon: const Icon(Icons.router_outlined),
                  label: const Text('Restart Gateway'),
                  // CATATAN: dua tombol restart di atas (Node & Gateway)
                  //   MEMBEDAKAN target lewat field `dest` yang berbeda
                  //   ("node" vs "gateway") -- teks pesan konfirmasinya
                  //   juga DIBEDAKAN eksplisit ("Node sensor akan restart.
                  //   Perintah diterapkan saat node berikutnya..." vs
                  //   "Gateway rumah akan restart." yang lebih singkat
                  //   karena gateway TIDAK punya keterlambatan serupa,
                  //   ia LANGSUNG menerima & mengeksekusi command dari
                  //   respons ingest-nya sendiri).
                ),
                OutlinedButton.icon(
                  onPressed: _sendingCommand
                      ? null
                      : () => _confirmAndRun(
                            'Hemat Gateway?',
                            'Gateway rumah masuk mode hemat (tetap hidup & bisa dikendalikan). '
                            'Pengecekan perintah dari server diperlambat. Untuk kembali normal, '
                            'cukup colok ulang/listrik gateway (tidak bisa diaktifkan dari jauh).',
                            () => _sendCommand({'dest': 'gateway', 'cmd': 'power_save', 'value': true}),
                          ),
                  icon: const Icon(Icons.bedtime_outlined),
                  label: const Text('Hemat Gateway'),
                ),
                OutlinedButton.icon(
                  onPressed: _sendingCommand ? null : _promptWifiUpdate,
                  icon: const Icon(Icons.wifi_outlined),
                  label: const Text('Ganti WiFi Gateway'),
                ),
                OutlinedButton.icon(
                  onPressed: _sendingCommand
                      ? null
                      : () {
                          AppRoute.push(
                            context,
                            CalibrationScreen(
                              deviceId: widget.deviceId,
                              label: widget.label,
                            ),
                          );
                        },
                  icon: const Icon(Icons.tune),
                  label: const Text('Kalibrasi Sensor'),
                ),
                OutlinedButton.icon(
                  onPressed: _sendingCommand ? null : _rekeyDevice,
                  style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger(context)),
                  // WARNA MERAH khusus untuk tombol ini -- secara
                  //   visual menandakan aksi ini LEBIH SENSITIF/
                  //   berisiko dibanding tombol lain (mengubah kredensial
                  //   keamanan device), memberi ISYARAT VISUAL tambahan
                  //   selain dialog konfirmasi yang sama-sama dipakai
                  //   semua tombol berisiko lainnya.
                  icon: const Icon(Icons.key_off_outlined),
                  label: const Text('Rekey Device'),
                ),
                OutlinedButton.icon(
                  onPressed: _sendingCommand
                      ? null
                      : () => _confirmAndRun(
                            'Factory Reset Gateway?',
                            'Semua setting gateway akan dihapus (WiFi, identitas device, & secret LoRa). '
                            'Gateway akan restart dan muncul kembali sebagai perangkat BARU -- '
                            'HP Anda perlu terhubung ke WiFi "Gateway-Setup-XXX" untuk memprovisioning ulang. '
                            'Tindakan ini TIDAK bisa dibatalkan.',
                            () => _sendCommand(
                              {'dest': 'gateway', 'cmd': 'factory_reset'},
                              successMessage: 'Perintah Factory Reset terkirim. Gateway akan menghapus semua setting & restart.',
                            ),
                          ),
                  style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger(context)),
                  // Sama berisiko dengan Rekey/Hapus: merah, dan pakai
                  //   DUA langkah konfirmasi implisit (icon + dialog) karena
                  //   ini menghapus SELURUH identitas gateway -- setara
                  //   dengan erase flash, cuma dari jauh tanpa pegang HW.
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('Factory Reset'),
                ),
                OutlinedButton.icon(
                  onPressed: _deleting ? null : _deleteDevice,
                  style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger(context)),
                  // Sama-sama merah dengan "Rekey Device" -- keduanya
                  //   aksi berisiko/tidak-bisa-dibatalkan, tapi "Hapus
                  //   Device" ini yang PALING destruktif (makanya juga
                  //   diberi tombol duplikat di AppBar di atas, supaya
                  //   mudah dijangkau tanpa perlu scroll ke bawah dulu).
                  icon: _deleting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_forever_outlined),
                  label: Text(_deleting ? 'Menghapus...' : 'Hapus Device'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
