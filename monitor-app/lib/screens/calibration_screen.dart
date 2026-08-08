import 'dart:async';
import 'package:flutter/material.dart';

import '../models/reading.dart';
import '../theme.dart';
import '../services/api_client.dart';

// Layar Kalibrasi Sensor -- lihat /PROTOCOL.md bagian 1.5 (perintah
// calib_stream) & 1.1 (body tipe "c"). Mengaktifkan mode streaming raw
// data node selama layar ini terbuka, dan mematikannya lagi saat ditutup
// (firmware juga punya auto-timeout jaga-jaga, lihat config.h node --
// CALIB_STREAM_MAX_MS).
class CalibrationScreen extends StatefulWidget {
  final String deviceId;
  final String label;
  const CalibrationScreen({super.key, required this.deviceId, required this.label});

  @override
  State<CalibrationScreen> createState() => _CalibrationScreenState();
}

class _CalibrationScreenState extends State<CalibrationScreen> {
  Timer? _pollTimer;
  ReadingSnapshot? _latestCalib;
  String? _error;

  // Titik kalibrasi yang SEDANG DIAMBIL pengguna di layar ini (BELUM
  // dikirim ke node sampai tombol "Simpan Kalibrasi" ditekan) -- state
  // LOKAL layar ini, TERPISAH dari nilai yang SUDAH TERSIMPAN di firmware
  // (yang hanya diketahui lewat flag isCustom, TIDAK ditampilkan nilai
  // dry/wet lama yang tersimpan di node -- lihat catatan _sensorSection).
  num? _forkDryRaw;
  num? _forkWetRaw;
  num? _capDryRaw;
  num? _capWetRaw;

  num? _tdsRaw0;
  final _tdsPpm0Controller = TextEditingController();
  num? _tdsRaw1;
  final _tdsPpm1Controller = TextEditingController();
  // TDS butuh DUA jenis input PER TITIK: raw (diambil OTOMATIS dari
  //   streaming, makanya `num?` bukan controller) DAN ppm referensi
  //   (diketik MANUAL oleh pengguna, makanya `TextEditingController`) --
  //   konsisten dengan skema kalibrasi TDS yang BERBEDA dari Fork/Cap
  //   (lihat calibration.h di firmware: (raw,ppm) berpasangan, bukan
  //   sekadar dry/wet).

  @override
  void initState() {
    super.initState();
    _startStreaming();
    _pollLatest();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _pollLatest());
    // Interval polling LEBIH CEPAT (2 detik) dibanding
    //   dashboard/device_detail (8 detik) -- MASUK AKAL: layar ini
    //   secara AKTIF dipakai untuk kalibrasi LANGSUNG (pengguna
    //   menunggu & memantau perubahan raw SAAT probe dipindah-pindah),
    //   butuh update LEBIH RESPONSIF daripada monitoring pasif biasa.
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _stopStreaming();
    // WAJIB dipanggil saat layar ini DITUTUP -- memberi tahu node
    //   untuk BERHENTI mengirim body "c" tiap siklus (kembali ke jadwal
    //   normal CALIB_BROADCAST_EVERY_N) -- kalau lupa mematikan mode
    //   ini, node akan TERUS boros baterai/airtime radio mengirim data
    //   raw walau pengguna sudah tidak melihatnya -- makanya firmware
    //   JUGA punya auto-timeout CALIB_STREAM_MAX_MS sebagai jaring
    //   pengaman KEDUA kalau panggilan ini SOMEHOW gagal terkirim (mis.
    //   app di-force-close mendadak sebelum sempat memanggil dispose()).
    _tdsPpm0Controller.dispose();
    _tdsPpm1Controller.dispose();
    super.dispose();
  }

  Future<void> _startStreaming() async {
    try {
      await ApiClient.instance.sendCommand(widget.deviceId, {
        'dest': 'node',
        'cmd': 'calib_stream',
        'on': true,
      });
    } catch (_) {
      // Diabaikan -- layar tetap dipakai, _pollLatest() akan menunjukkan
      // kalau data raw tidak kunjung muncul (lihat tampilan "Menunggu data...").
      // Kegagalan MENGAKTIFKAN streaming TIDAK menghentikan/mem-block
      //   layar ini (tidak ada dialog error yang mengganggu) -- kalau
      //   perintah ini gagal terkirim, konsekuensinya cuma raw data akan
      //   ter-update LEBIH LAMBAT (mengikuti jadwal broadcast NORMAL
      //   CALIB_BROADCAST_EVERY_N, bukan tiap siklus) -- pengalaman
      //   pengguna DEGRADED (lebih lambat), bukan RUSAK TOTAL (tetap
      //   bisa dipakai, hanya kurang responsif).
    }
  }

  void _stopStreaming() {
    // SENGAJA tidak menunggu (fire-and-forget) -- widget sudah dalam
    // proses dispose, dan firmware punya auto-timeout jaga-jaga (lihat
    // komentar di atas) kalau perintah ini gagal terkirim.
    ApiClient.instance.sendCommand(widget.deviceId, {
      'dest': 'node',
      'cmd': 'calib_stream',
      'on': false,
    }).catchError((_) {});
    // CATATAN TEKNIS PENTING: fungsi ini `void` (BUKAN `async`/`Future`)
    //   -- SENGAJA TIDAK memakai `await`, karena `dispose()` (pemanggil
    //   fungsi ini) TIDAK BOLEH/TIDAK BISA bersifat `async` (kontrak API
    //   Flutter: `dispose()` harus selesai secara SINKRON) -- "fire and
    //   forget": permintaan dikirim, tapi kode TIDAK MENUNGGU hasilnya
    //   sama sekali (widget sudah dalam proses dihancurkan detik itu
    //   juga). `.catchError((_) {})` di akhir WAJIB ada -- tanpa ini,
    //   kalau `sendCommand()` gagal (mis. tidak ada internet), Future
    //   yang tidak ditangani errornya akan memicu "Unhandled exception"
    //   di log/console Flutter (walau tidak fatal bagi app, tetap
    //   "noise" yang sebaiknya dicegah) -- `catchError` di sini
    //   men-"diam"-kan error tersebut dengan sengaja, konsisten dengan
    //   filosofi "kalau gagal, firmware auto-timeout yang akan
    //   menyelesaikannya nanti, TIDAK PERLU app menanganinya lebih
    //   jauh".
  }

  Future<void> _pollLatest() async {
    try {
      final history = await ApiClient.instance.fetchReadings(widget.deviceId, limit: 20);
      // `limit: 20` -- JAUH LEBIH KECIL dari device_detail_screen.dart
      //   (100) -- layar ini HANYA butuh snapshot "calib" TERBARU (satu
      //   entri), tidak perlu histori panjang untuk grafik tren apa
      //   pun, jadi cukup ambil beberapa entri terakhir saja untuk
      //   kemungkinan menemukan snapshot "calib" paling baru.
      ReadingSnapshot? latestCalib;
      for (final snap in history.reversed) {
        if (snap.type == 'sensor' && snap.nodeMsgType == 'calib') {
          latestCalib = snap;
          break;
        }
      }
      // Pola pencarian yang SAMA PERSIS dengan `_latestCore` getter di
      //   device_detail_screen.dart, hanya beda kriteria filter
      //   (nodeMsgType == 'calib', bukan 'core') -- CATATAN: pola ini
      //   DIDUPLIKASI (ditulis ulang) di kedua file, alih-alih
      //   diekstrak jadi satu fungsi/method bersama (mis. static helper
      //   di model ReadingSnapshot itu sendiri: `findLatest(history,
      //   {required String type, String? nodeMsgType})`) -- perbaikan
      //   kecil yang bisa dipertimbangkan untuk mengurangi duplikasi
      //   kode, walau dampaknya minor pada skala aplikasi ini.
      if (!mounted) return;
      setState(() {
        _latestCalib = latestCalib;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      // diabaikan, akan dicoba lagi di polling berikutnya
      // BERBEDA dari cabang ApiException di atas (yang MENAMPILKAN
      //   error), exception UMUM lain (mis. jaringan lambat sesaat)
      //   DIAM-DIAM diabaikan sepenuhnya di sini -- polling tiap 2 detik
      //   cukup sering sehingga kegagalan SESAAT tidak perlu mengganggu
      //   tampilan dengan pesan error yang mungkin akan hilang lagi 2
      //   detik kemudian saat polling berikutnya berhasil.
    }
  }

  num? _rawValue(String id) => _latestCalib?.byId(id)?.value;
  // Helper singkat: ambil nilai `id` tertentu dari snapshot "calib"
  //   TERBARU -- dipakai berkali-kali di build() untuk mengambil
  //   tds_raw/fork_raw/cap_raw/fork_cal/cap_cal/tds_cal.

  Future<void> _sendCalibCommand(Map<String, dynamic> command, String successMessage) async {
    // Helper TERPUSAT untuk mengirim perintah TERKAIT KALIBRASI
    //   (calib_set_*/calib_clear) -- MIRIP `_sendCommand()` di
    //   device_detail_screen.dart, tapi versi LEBIH SEDERHANA di sini:
    //   TIDAK ADA state `_sendingCommand`/loading flag yang menonaktifkan
    //   tombol selama proses berjalan (BERBEDA dari layar detail device)
    //   -- CATATAN: ini berarti pengguna SECARA TEORI bisa menekan
    //   tombol simpan BEBERAPA KALI berturut-turut dengan cepat sebelum
    //   request pertama selesai -- risiko dalam praktik relatif RENDAH
    //   (perintah kalibrasi bersifat idempotent -- menyimpan nilai yang
    //   sama berkali-kali tidak merusak apa pun), tapi konsisten dengan
    //   pola `_sendingCommand` di layar lain akan sedikit lebih
    //   defensif/mencegah kebingungan urutan eksekusi.
    try {
      await ApiClient.instance.sendCommand(widget.deviceId, command);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(successMessage)));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Gagal mengirim perintah kalibrasi.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tdsRaw = _rawValue('tds_raw');
    final forkRaw = _rawValue('fork_raw');
    final capRaw = _rawValue('cap_raw');
    final forkCustom = _rawValue('fork_cal') == 1;
    final capCustom = _rawValue('cap_cal') == 1;
    final tdsCustom = _rawValue('tds_cal') == 1;
    // `_rawValue('fork_cal') == 1` -- INGAT bahwa nilai boolean di
    //   protokol ini dikirim sebagai ANGKA 0/1 (bukan `true`/`false`
    //   JSON asli, lihat komentar reading_card.dart _boolCard) --
    //   perbandingan `== 1` di sini menerjemahkan angka itu jadi boolean
    //   Dart yang dipakai UI (`forkCustom` dkk).

    return Scaffold(
      appBar: AppBar(title: Text('Kalibrasi — ${widget.label}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: TextStyle(color: AppColors.danger(context))),
            ),
          if (_latestCalib == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Row(
                children: [
                  SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Text('Menunggu data raw dari node (bisa sampai 1 interval kirim)...'),
                  // Pesan yang JUJUR soal LATENSI: data raw HANYA
                  //   muncul setelah node BENAR-BENAR mengirim body "c"
                  //   berikutnya -- kalau `_startStreaming()` di atas
                  //   GAGAL (mis. offline sesaat), node baru akan
                  //   mengirim body "c" sesuai jadwal NORMAL
                  //   (CALIB_BROADCAST_EVERY_N), yang BISA berarti
                  //   menunggu SAMPAI ~30 detik (6x interval kirim
                  //   default 5 detik) -- pesan "bisa sampai 1 interval
                  //   kirim" ini MEMBERI EKSPEKTASI yang wajar ke
                  //   pengguna, bukan diam saja tanpa penjelasan kalau
                  //   loading terasa lama.
                ],
              ),
            ),

          _sensorSection(
            title: 'Fork (Konduktivitas Tanah)',
            rawLabel: 'Raw saat ini',
            rawValue: forkRaw,
            isCustom: forkCustom,
            dryValue: _forkDryRaw,
            wetValue: _forkWetRaw,
            onCaptureDry: forkRaw == null ? null : () => setState(() => _forkDryRaw = forkRaw),
            // Tombol "Ambil (Kering)" DINONAKTIFKAN (`onPressed: null`)
            //   selama `forkRaw` masih null (data raw belum pernah
            //   diterima) -- mencegah pengguna "mengambil" nilai yang
            //   sebenarnya belum ada/tidak valid.
            onCaptureWet: forkRaw == null ? null : () => setState(() => _forkWetRaw = forkRaw),
            onSave: (_forkDryRaw != null && _forkWetRaw != null && _forkDryRaw != _forkWetRaw)
                ? () => _sendCalibCommand({
                      'dest': 'node',
                      'cmd': 'calib_set_fork',
                      'dry_raw': _forkDryRaw,
                      'wet_raw': _forkWetRaw,
                    }, 'Kalibrasi Fork disimpan.')
                : null,
                // Tombol "Simpan Kalibrasi" HANYA aktif kalau KEDUA
                //   titik (dry & wet) SUDAH diambil DAN keduanya TIDAK
                //   SAMA (`_forkDryRaw != _forkWetRaw`) -- validasi
                //   CLIENT-SIDE ini MENCERMINKAN validasi yang SAMA di
                //   firmware node (lihat handleIncomingCommand() di
                //   node-sawah/src/main.cpp: `dryRaw == wetRaw` ditolak)
                //   -- validasi di app TIDAK MENGGANTIKAN validasi
                //   firmware, tapi MENCEGAH request yang PASTI akan
                //   ditolak firmware dikirim sama sekali (feedback lebih
                //   cepat ke pengguna: tombol memang tidak bisa
                //   ditekan, bukan menunggu response server dulu baru
                //   tahu gagal).
            onClear: () => _sendCalibCommand(
                {'dest': 'node', 'cmd': 'calib_clear', 'target': 'fork'},
                'Kalibrasi Fork dikembalikan ke bawaan.'),
                // Tombol "Hapus" SELALU AKTIF (tidak ada kondisi
                //   `onClear: kondisi ? ... : null`) -- masuk akal,
                //   karena menghapus kalibrasi kustom (kembali ke
                //   bawaan) SELALU merupakan aksi yang SAH untuk
                //   dilakukan kapan saja, terlepas dari state
                //   dry/wetValue lokal di layar ini.
          ),
          const SizedBox(height: 20),
          _sensorSection(
            title: 'Capacitive (Kelembaban Tanah)',
            rawLabel: 'Raw saat ini',
            rawValue: capRaw,
            isCustom: capCustom,
            dryValue: _capDryRaw,
            wetValue: _capWetRaw,
            onCaptureDry: capRaw == null ? null : () => setState(() => _capDryRaw = capRaw),
            onCaptureWet: capRaw == null ? null : () => setState(() => _capWetRaw = capRaw),
            onSave: (_capDryRaw != null && _capWetRaw != null && _capDryRaw != _capWetRaw)
                ? () => _sendCalibCommand({
                      'dest': 'node',
                      'cmd': 'calib_set_cap',
                      'dry_raw': _capDryRaw,
                      'wet_raw': _capWetRaw,
                    }, 'Kalibrasi Capacitive disimpan.')
                : null,
            onClear: () => _sendCalibCommand(
                {'dest': 'node', 'cmd': 'calib_clear', 'target': 'cap'},
                'Kalibrasi Capacitive dikembalikan ke bawaan.'),
            // Struktur IDENTIK dengan section Fork di atas -- widget
            //   `_sensorSection()` di bawah adalah TEMPLATE BERSAMA
            //   untuk KEDUA sensor ini (Fork & Capacitive), menghindari
            //   duplikasi UI walau logika pemanggilannya (parameter yang
            //   dioper) tetap ditulis terpisah untuk masing-masing.
          ),
          const SizedBox(height: 20),
          _tdsSection(tdsRaw: tdsRaw, isCustom: tdsCustom),
          // TDS TIDAK memakai `_sensorSection()` yang sama -- karena
          //   skema kalibrasinya BERBEDA (2 pasang raw+ppm, bukan
          //   sekadar dry/wet raw) -- butuh WIDGET TERPISAH `_tdsSection()`
          //   dengan field input TAMBAHAN (ppm referensi).
        ],
      ),
    );
  }

  Widget _sensorSection({
    // Widget BERSAMA untuk Fork & Capacitive -- SEMUA parameter
    //   `required`, TIDAK ADA default -- memaksa pemanggil eksplisit
    //   soal SETIAP aspek section ini (judul, label, nilai, callback
    //   tombol) -- pola "widget builder" yang PARAMETERIK, mengurangi
    //   duplikasi struktur Card/Row/Column yang SAMA persis untuk kedua
    //   sensor.
    required String title,
    required String rawLabel,
    required num? rawValue,
    required bool isCustom,
    required num? dryValue,
    required num? wetValue,
    required VoidCallback? onCaptureDry,
    required VoidCallback? onCaptureWet,
    required VoidCallback? onSave,
    required VoidCallback onClear,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                Chip(
                  label: Text(isCustom ? 'Kustom aktif' : 'Bawaan pabrik'),
                  backgroundColor: isCustom ? AppColors.leafSoft.withValues(alpha: 0.28) : Theme.of(context).colorScheme.surfaceContainerHighest,
                  // Badge/label VISUAL yang MENCERMINKAN LANGSUNG status
                  //   `calibForkIsCustom()`/`calibCapIsCustom()` dari
                  //   firmware (lihat calibration.h) -- app TIDAK
                  //   MENGHITUNG sendiri apakah kalibrasi "kustom", cukup
                  //   MENAMPILKAN status yang SUDAH DILAPORKAN firmware
                  //   lewat body "c" (field fork_cal/cap_cal).
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('$rawLabel: ${rawValue?.toStringAsFixed(0) ?? '—'}'),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: onCaptureDry,
                    child: Text('Ambil (Kering)${dryValue != null ? ': ${dryValue.toStringAsFixed(0)}' : ''}'),
                    // Label tombol BERUBAH DINAMIS setelah nilai
                    //   "diambil" -- dari "Ambil (Kering)" saja menjadi
                    //   "Ambil (Kering): 8532" (mis.) -- memberi
                    //   FEEDBACK VISUAL LANGSUNG bahwa nilai SUDAH
                    //   tersimpan di state lokal, tanpa perlu elemen UI
                    //   tambahan terpisah untuk menampilkannya.
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: onCaptureWet,
                    child: Text('Ambil (Basah)${wetValue != null ? ': ${wetValue.toStringAsFixed(0)}' : ''}'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton(onPressed: onSave, child: const Text('Simpan Kalibrasi')),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: onClear,
                  style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger(context)),
                  child: const Text('Hapus'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _tdsSection({required num? tdsRaw, required bool isCustom}) {
    final canSave = _tdsRaw0 != null &&
        _tdsRaw1 != null &&
        _tdsRaw0 != _tdsRaw1 &&
        num.tryParse(_tdsPpm0Controller.text.trim()) != null &&
        num.tryParse(_tdsPpm1Controller.text.trim()) != null;
    // Perbaikan: validasi `canSave` SEKARANG juga mengecek bahwa teks
    //   ppm BENAR-BENAR bisa di-parse sebagai angka valid (`num.tryParse(...)
    //   != null`), bukan cuma `.isNotEmpty`. Sebelumnya pengguna bisa
    //   mengetik huruf di kolom ppm, tombol "Simpan" tetap aktif, tapi
    //   `num.tryParse(...)` di onPressed di bawah menghasilkan `null`
    //   yang dikirim ke server dan DIAM-DIAM ditolak firmware node
    //   (handleIncomingCommand() di node-sawah/src/main.cpp: `ppm0 < 0`
    //   true kalau field null) tanpa pesan error jelas ke pengguna.
    //   Sekarang tombol baru bisa ditekan kalau semua input valid secara
    //   numerik -- error tertangkap sedini mungkin di UI.

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('TDS (Padatan Terlarut)', style: Theme.of(context).textTheme.titleMedium)),
                Chip(
                  label: Text(isCustom ? 'Kustom aktif' : 'Bawaan pabrik'),
                  backgroundColor: isCustom ? AppColors.leafSoft.withValues(alpha: 0.28) : Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('Raw saat ini: ${tdsRaw?.toStringAsFixed(0) ?? '—'}'),
            const SizedBox(height: 4),
            const Text(
              'Celupkan probe ke larutan referensi pertama (mis. air murni), '
              'masukkan nilai ppm yang sebenarnya, lalu tekan "Ambil Raw".',
              style: TextStyle(fontSize: AppText.caption, color: AppColors.inkMuted),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _tdsPpm0Controller,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    // `decimal: true` -- keyboard virtual angka yang
                    //   MENYERTAKAN tombol titik desimal (BERBEDA dari
                    //   `TextInputType.number` polos yang mungkin tidak
                    //   menampilkan tombol titik di sebagian platform) --
                    //   penting karena nilai ppm bisa berupa PECAHAN
                    //   (mis. "23.5").
                    decoration: const InputDecoration(labelText: 'ppm referensi 1'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: tdsRaw == null ? null : () => setState(() => _tdsRaw0 = tdsRaw),
                  child: Text(_tdsRaw0 != null ? 'Raw: ${_tdsRaw0!.toStringAsFixed(0)}' : 'Ambil Raw'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _tdsPpm1Controller,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'ppm referensi 2'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: tdsRaw == null ? null : () => setState(() => _tdsRaw1 = tdsRaw),
                  child: Text(_tdsRaw1 != null ? 'Raw: ${_tdsRaw1!.toStringAsFixed(0)}' : 'Ambil Raw'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: canSave
                        ? () => _sendCalibCommand({
                              'dest': 'node',
                              'cmd': 'calib_set_tds',
                              'raw0': _tdsRaw0,
                              'ppm0': num.tryParse(_tdsPpm0Controller.text.trim()),
                              'raw1': _tdsRaw1,
                              'ppm1': num.tryParse(_tdsPpm1Controller.text.trim()),
                              // Lihat catatan di atas `canSave` -- kalau
                              //   `num.tryParse` di sini menghasilkan
                              //   `null` (teks bukan angka valid), field
                              //   ini akan dikirim sebagai `null` di
                              //   JSON, yang akan DITOLAK firmware node
                              //   (bukan menyebabkan crash, tapi kalibrasi
                              //   TIDAK tersimpan tanpa pesan error yang
                              //   jelas ke pengguna).
                            }, 'Kalibrasi TDS disimpan.')
                        : null,
                    child: const Text('Simpan Kalibrasi'),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => _sendCalibCommand(
                      {'dest': 'node', 'cmd': 'calib_clear', 'target': 'tds'},
                      'Kalibrasi TDS dikembalikan ke bawaan.'),
                  style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger(context)),
                  child: const Text('Hapus'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
