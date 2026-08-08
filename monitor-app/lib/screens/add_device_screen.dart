import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../services/provisioning_service.dart';
import '../theme.dart';
import '../services/secure_storage_service.dart';

// Alur "Tambah Device Baru" -- lihat /PROTOCOL.md bagian 3 & catatan di
// gateway-rumah/src/wifi_provision.h. Ada 2 tahap KOMUNIKASI YANG BERBEDA:
//   1. App <-> Server (lewat internet, WiFi/data HP normal): daftarkan
//      device baru, dapat device_id + device_secret.
//   2. App <-> Gateway (lewat WiFi Access Point setup gateway sendiri,
//      HP HARUS pindah WiFi dulu secara manual): kirim SSID rumah +
//      device_id/device_secret/server_url ke gateway.
class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

enum _Step { label, connectToGatewayAp, wifiForm, done }
// Layar ini adalah WIZARD (form bertahap) dengan 4 TAHAP -- state
//   `_step` menentukan tahap MANA yang sedang ditampilkan (lihat
//   `_buildStep()` di bawah, pola `switch` sederhana) -- alih-alih 4
//   halaman terpisah (dengan Navigator.push berlapis), semua tahap
//   ditampilkan dalam SATU Scaffold/layar yang sama, cuma ISI body-nya
//   yang berganti -- lebih ringan & mempertahankan konteks/data yang
//   sudah dikumpulkan di tahap sebelumnya (mis. _deviceId dari tahap 1
//   tetap tersedia di tahap 3) tanpa perlu meneruskan lewat parameter
//   constructor antar-halaman.

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  _Step _step = _Step.label;
  // Selalu MULAI dari tahap "label" -- wizard ini TIDAK BISA dimulai
  //   dari tengah (state MULAI tetap sama setiap kali layar ini dibuka).
  final _labelController = TextEditingController();

  bool _busy = false;
  String? _error;
  // CATATAN: `_busy`/`_error` bersifat GLOBAL untuk SELURUH wizard
  //   (bukan per-tahap) -- setiap tahap punya tombol "Lanjut"-nya
  //   sendiri yang memakai flag YANG SAMA ini -- konsekuensinya, error
  //   dari tahap SEBELUMNYA otomatis "hilang" (di-set null) setiap kali
  //   memulai aksi BARU di tahap manapun (lihat pola `setState({_error =
  //   null})` di awal tiap fungsi _register*/_check*/_submit* di
  //   bawah).

  String? _deviceId;
  String? _deviceSecret;
  // Hasil dari TAHAP 1 (registrasi ke server) -- disimpan di state
  //   supaya bisa dipakai lagi di TAHAP 3 (dikirim ke gateway lewat
  //   `_provisioning.configure()`).

  final _provisioning = GatewayProvisioningService();
  // Instance BARU dibuat LANGSUNG di sini (bukan singleton seperti
  //   ApiClient) -- masuk akal karena layanan ini HANYA relevan SELAMA
  //   wizard provisioning berjalan (tidak perlu dipakai bersama di
  //   bagian app lain), jadi tidak perlu pola singleton global.
  List<WifiNetwork> _networks = [];
  // Hasil scan WiFi dari TAHAP 2, dipakai menampilkan daftar pilihan
  //   di TAHAP 3.
  String? _selectedSsid;
  final _wifiPasswordController = TextEditingController();
  final _manualSsidController = TextEditingController();
  bool _useManualSsid = false;
  // Toggle antara "pilih dari daftar hasil scan" vs "ketik manual" --
  //   dipakai untuk kasus jaringan WiFi TERSEMBUNYI (tidak muncul di
  //   hasil scan, lihat catatan di provisioning_service.dart
  //   handleScan()) atau kalau scan gagal menemukan jaringan yang
  //   dimaksud karena alasan lain.

  @override
  void dispose() {
    _labelController.dispose();
    _wifiPasswordController.dispose();
    _manualSsidController.dispose();
    super.dispose();
    // Tiga TextEditingController -- SEMUANYA wajib di-dispose, tidak
    //   ada yang terlewat.
  }

  Future<void> _registerOnServer() async {
    // AKSI TAHAP 1: daftarkan device baru ke SERVER (lewat internet).
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ApiClient.instance.provisionDevice(label: _labelController.text.trim());
      if (!mounted) return;
      setState(() {
        _deviceId = result.deviceId;
        _deviceSecret = result.deviceSecret;
        _step = _Step.connectToGatewayAp;
        // BERHASIL -> LANGSUNG pindah ke tahap BERIKUTNYA (mengubah
        //   `_step` memicu rebuild yang menampilkan tahap 2) -- semuanya
        //   terjadi DALAM satu `setState`, jadi UI langsung menampilkan
        //   tahap baru begitu data tersimpan.
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
      // CATATAN: baris ini TIDAK dibungkus `if (!mounted) return;`
      //   seperti cabang `try` di atas -- SEDIKIT INKONSISTENSI kecil
      //   (walau risikonya rendah: exception dari `await` di atas hanya
      //   bisa terjadi setelah request selesai, jendela waktu widget
      //   "sempat di-dispose" di antaranya relatif singkat, tapi secara
      //   teori TETAP mungkin terjadi & berisiko error runtime kalau
      //   widget sudah tidak ada).
    } catch (e) {
      setState(() => _error = 'Gagal mendaftarkan device ke server.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkGatewayAndScan() async {
    // AKSI TAHAP 2: verifikasi HP SUDAH tersambung ke AP setup gateway,
    //   lalu langsung SCAN jaringan WiFi yang terlihat dari sana.
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _provisioning.getStatus(); // pastikan HP sudah tersambung ke AP gateway
      // Hasil `getStatus()` TIDAK dipakai/diperiksa isinya di sini --
      //   pemanggilan ini SEMATA-MATA sebagai "tes konektivitas": kalau
      //   request ini BERHASIL sama sekali (tidak melempar exception),
      //   berarti HP MEMANG sudah bisa menjangkau gateway di
      //   192.168.4.1, kalau GAGAL (timeout/connection refused), berarti
      //   HP BELUM tersambung ke AP yang benar -- inilah asumsi implisit
      //   di balik komentar "pastikan HP sudah tersambung ke AP gateway".
      final networks = await _provisioning.scanNetworks();
      if (!mounted) return;
      setState(() {
        _networks = networks;
        _step = _Step.wifiForm;
      });
    } catch (e) {
      // Menangkap SEMUA jenis exception (bukan cuma tipe tertentu) --
      //   karena kegagalan di tahap ini SELALU berarti hal yang SAMA
      //   dari sudut pandang pengguna ("belum bisa menghubungi
      //   gateway"), terlepas dari penyebab teknis SPESIFIKNYA (timeout,
      //   connection refused, dst) -- pesan error yang DITAMPILKAN
      //   cukup SATU pesan GENERIK yang actionable.
      setState(() => _error =
          'Belum bisa menghubungi gateway. Pastikan HP sudah tersambung ke WiFi '
          '"Gateway-Setup-..." milik gateway ini, lalu coba lagi.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitWifiConfig() async {
    // AKSI TAHAP 3: kirim SEMUA konfigurasi (WiFi rumah + identitas
    //   device dari tahap 1) ke gateway.
    final ssid = _useManualSsid ? _manualSsidController.text.trim() : (_selectedSsid ?? '');
    // Ambil SSID dari SUMBER YANG SESUAI tergantung mode saat ini
    //   (`_useManualSsid`) -- kalau mode manual, dari TextField; kalau
    //   mode pilih dari daftar, dari radio button yang dipilih
    //   (`_selectedSsid`, fallback string kosong kalau belum ada yang
    //   dipilih sama sekali).
    if (ssid.isEmpty) {
      setState(() => _error = 'Pilih atau ketik nama WiFi rumah dulu.');
      return;
      // Validasi SEBELUM mengirim apa pun -- BEDA dari beberapa
      //   validasi "diam-diam diabaikan" di layar lain (mis.
      //   _promptSetInterval di device_detail_screen.dart), di SINI
      //   pesan error EKSPLISIT ditampilkan -- konsisten dengan
      //   pentingnya langkah ini (SSID kosong akan membuat gateway
      //   gagal konek WiFi sama sekali).
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final serverUrl = await SecureStorageService.instance.readServerBaseUrl();
      // Ambil URL server yang TERSIMPAN (dari ServerSetupScreen
      //   sebelumnya) -- URL INI JUGA dikirim ke gateway, supaya
      //   FIRMWARE gateway tahu ke MANA harus mengirim data (lihat
      //   device_identity.h: server_base_url disimpan di NVS gateway) --
      //   BUKAN cuma device_id/secret saja yang perlu disinkronkan,
      //   URL server-nya JUGA harus konsisten antara app & firmware.
      await _provisioning.configure(
        ssid: ssid,
        password: _wifiPasswordController.text,
        deviceId: _deviceId,
        deviceSecret: _deviceSecret,
        serverUrl: serverUrl,
      );
      if (!mounted) return;
      setState(() => _step = _Step.done);
    } catch (e) {
      setState(() => _error =
          'Gagal mengirim konfigurasi ke gateway. Pastikan masih tersambung ke WiFi setup-nya, lalu coba lagi.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tambah Device Baru')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: _buildStep(),
        // `build()` UTAMA sangat SEDERHANA -- HANYA menampilkan
        //   Scaffold + AppBar tetap, lalu MENDELEGASIKAN isi body
        //   sepenuhnya ke `_buildStep()` yang berganti sesuai `_step`
        //   saat ini.
      ),
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case _Step.label:
        return _labelStep();
      case _Step.connectToGatewayAp:
        return _connectToGatewayApStep();
      case _Step.wifiForm:
        return _wifiFormStep();
      case _Step.done:
        return _doneStep();
      // CATATAN: `switch` atas ENUM di Dart TIDAK butuh `default`
      //   kalau SEMUA nilai enum sudah tercakup (compiler Dart bisa
      //   memverifikasi ini secara statis disebut "exhaustiveness
      //   checking") -- kalau suatu saat `_Step` ditambah nilai BARU
      //   tapi lupa ditambahkan case-nya di sini, compiler akan
      //   memberi PERINGATAN/ERROR, membantu mencegah bug "tahap baru
      //   tidak punya tampilan".
    }
  }

  Widget _labelStep() {
    // TAHAP 1 UI: form label device (opsional) + tombol daftar.
    return ListView(
      children: [
        const Text('Langkah 1 dari 3', style: TextStyle(color: AppColors.inkMuted, fontSize: AppText.caption)),
        // Indikator progres TEKS SEDERHANA ("Langkah 1 dari 3") --
        //   BUKAN progress bar visual/stepper widget -- pilihan yang
        //   PALING SEDERHANA untuk memberi konteks "sedang di mana"
        //   tanpa kompleksitas widget Stepper Flutter yang lebih berat.
        //   CATATAN: walau ada 4 nilai `_Step` (termasuk `done`), teks
        //   ini konsisten menyebut "3 langkah" -- tahap `done` memang
        //   BUKAN "langkah" tambahan secara konseptual, melainkan LAYAR
        //   PENUTUP/konfirmasi setelah 3 langkah utama selesai.
        const SizedBox(height: 4),
        Text('Daftarkan Device', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        TextField(
          controller: _labelController,
          decoration: const InputDecoration(
            labelText: 'Nama Device (opsional)',
            hintText: 'mis. Sawah Belakang',
            border: OutlineInputBorder(),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: AppColors.danger(context))),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _registerOnServer,
          child: _busy
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Daftarkan ke Server'),
        ),
      ],
    );
  }

  Widget _connectToGatewayApStep() {
    // TAHAP 2 UI: INSTRUKSI MANUAL untuk pengguna (bukan aksi
    //   otomatis) -- app TIDAK BISA memaksa HP pindah jaringan WiFi
    //   secara terprogram (batasan platform/OS demi keamanan pengguna),
    //   jadi pengguna HARUS melakukan ini SENDIRI lewat pengaturan
    //   sistem operasi, app hanya bisa MEMANDU lewat instruksi tertulis.
    return ListView(
      children: [
        const Text('Langkah 2 dari 3', style: TextStyle(color: AppColors.inkMuted, fontSize: AppText.caption)),
        const SizedBox(height: 4),
        Text('Sambungkan ke Gateway', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        const Card(
          child: Padding(
            padding: EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('1. Buka Pengaturan WiFi di HP kamu.'),
                SizedBox(height: 6),
                Text('2. Sambungkan ke WiFi bernama "Gateway-Setup-..." '
                    '(nama & password tercetak di Serial Monitor saat gateway pertama kali dinyalakan).'),
                    // Instruksi ini SECARA JUJUR mengasumsikan pengguna
                    //   PUNYA akses ke Serial Monitor (kabel USB +
                    //   komputer) untuk melihat password AP acak (lihat
                    //   gateway-rumah/src/wifi_provision.cpp
                    //   apSetupPassword()) -- KONSEKUENSI dari desain
                    //   keamanan yang SENGAJA tidak menurunkan password
                    //   dari sesuatu yang bisa ditebak (lihat komentar di
                    //   firmware tersebut): trade-off keamanan lebih baik
                    //   ini berarti proses setup AWAL memerlukan langkah
                    //   ekstra (akses USB sekali di awal) dibanding kalau
                    //   password-nya "tertebak" langsung dari MAC address
                    //   atau semacamnya.
                SizedBox(height: 6),
                Text('3. Kembali ke app ini, lalu tekan tombol di bawah.'),
              ],
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: AppColors.danger(context))),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _checkGatewayAndScan,
          child: _busy
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Saya Sudah Tersambung'),
        ),
      ],
    );
  }

  Widget _wifiFormStep() {
    // TAHAP 3 UI: pilih/ketik SSID WiFi rumah + password, lalu kirim
    //   semuanya ke gateway.
    return ListView(
      children: [
        const Text('Langkah 3 dari 3', style: TextStyle(color: AppColors.inkMuted, fontSize: AppText.caption)),
        const SizedBox(height: 4),
        Text('Pilih WiFi Rumah', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 16),
        if (!_useManualSsid) ...[
          // MODE DEFAULT: tampilkan daftar RadioListTile dari hasil
          //   scan (`_networks`, diisi `_checkGatewayAndScan()` di tahap
          //   sebelumnya).
          for (final net in _networks)
            RadioListTile<String>(
              value: net.ssid,
              // ignore: deprecated_member_use
              groupValue: _selectedSsid,
              // `groupValue` SAMA untuk SEMUA RadioListTile dalam loop
              //   ini (`_selectedSsid`) -- inilah yang membuat SEMUA
              //   tile ini berperilaku sebagai SATU GRUP radio button
              //   (hanya SATU yang bisa terpilih pada satu waktu), walau
              //   masing-masing dibuat sebagai widget TERPISAH lewat
              //   loop `for`. (Catatan: `groupValue`/`onChanged` masih
              //   dipakai karena `RadioGroup` baru di Flutter 3.32+ belum
              //   stabil di versi SDK ini; ignore sengaja agar lint bersih.)
              // ignore: deprecated_member_use
              onChanged: (v) => setState(() => _selectedSsid = v),
              title: Text(net.ssid),
              secondary: Icon(net.secure ? Icons.lock_outline : Icons.lock_open),
              // Ikon GEMBOK (terkunci/terbuka) sebagai indikator visual
              //   cepat apakah jaringan ini butuh password -- dari field
              //   `secure` yang di-parse WifiNetwork.fromJson (lihat
              //   provisioning_service.dart).
            ),
          TextButton(
            onPressed: () => setState(() => _useManualSsid = true),
            child: const Text('WiFi tidak ada di daftar? Ketik manual'),
          ),
        ] else ...[
          // MODE MANUAL: TextField biasa untuk mengetik SSID langsung.
          TextField(
            controller: _manualSsidController,
            decoration: const InputDecoration(labelText: 'Nama WiFi (SSID)', border: OutlineInputBorder()),
          ),
          TextButton(
            onPressed: () => setState(() => _useManualSsid = false),
            child: const Text('Pilih dari daftar hasil scan'),
            // Tombol untuk KEMBALI ke mode daftar -- wizard ini
            //   membiarkan pengguna BOLAK-BALIK antara dua mode kapan
            //   saja sebelum menekan "Kirim ke Gateway" (tidak ada
            //   pembatasan "sekali pilih manual, tidak bisa kembali").
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          controller: _wifiPasswordController,
          obscureText: true,
          // CATATAN: BERBEDA dari login_screen.dart/device_detail_screen.dart
          //   yang punya tombol MATA untuk toggle visibilitas password,
          //   field password WiFi DI SINI SELALU tersembunyi TANPA opsi
          //   untuk menampilkannya -- kemungkinan sekadar KELALAIAN
          //   kecil dalam konsistensi UX (bukan keputusan keamanan yang
          //   disengaja, karena field password serupa di layar LAIN
          //   pada app yang SAMA justru diberi opsi tampil/sembunyi).
          decoration: const InputDecoration(labelText: 'Password WiFi', border: OutlineInputBorder()),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: TextStyle(color: AppColors.danger(context))),
        ],
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _busy ? null : _submitWifiConfig,
          child: _busy
              ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Kirim ke Gateway'),
        ),
      ],
    );
  }

  Widget _doneStep() {
    // TAHAP AKHIR (bukan "langkah" ke-4, lihat catatan di _labelStep):
    //   layar konfirmasi SUKSES, TANPA form/input apa pun lagi -- cuma
    //   pesan & SATU tombol untuk kembali.
    return ListView(
      children: [
        const SizedBox(height: 40),
        const Icon(Icons.check_circle, color: AppColors.okGreen, size: 64),
        const SizedBox(height: 16),
        Center(
          child: Text('Selesai!', style: Theme.of(context).textTheme.headlineSmall),
        ),
        const SizedBox(height: 8),
        const Center(
          child: Text(
            'Gateway akan restart & mencoba tersambung ke WiFi rumah. '
            'Device akan muncul di dashboard begitu online.',
            // Teks ini KEMBALI mengelola EKSPEKTASI pengguna dengan
            //   jujur: proses BELUM benar-benar "selesai" secara teknis
            //   pada detik ini (gateway MASIH dalam proses restart &
            //   menyambung WiFi baru), device baru akan MUNCUL di
            //   dashboard SETELAH itu berhasil -- bukan mengklaim
            //   "device sudah aktif sepenuhnya" yang bisa menyesatkan
            //   kalau ternyata gateway gagal konek WiFi (mis. password
            //   salah ketik) dan otomatis kembali ke mode setup.
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          // `pop(true)` -- INILAH nilai `bool` yang diterima
          //   dashboard_screen.dart sebagai `added` (lihat
          //   `Navigator.push<bool>` di sana) -- memicu
          //   dashboard_screen.dart memanggil `_load()` untuk
          //   memperbarui daftar device dengan yang baru ini.
          child: const Text('Kembali ke Dashboard'),
        ),
      ],
    );
  }
}
