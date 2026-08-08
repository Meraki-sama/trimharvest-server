import 'package:flutter/material.dart';
import '../services/secure_storage_service.dart';
import '../services/api_client.dart';
import '../theme.dart';

// URL server default (Railway). Dipakai sebagai nilai awal field & tombol
// "Gunakan Server Default" supaya pengguna TIDAK perlu mengetik URL manual
// setiap pasang app di HP baru. Ganti nilai ini kalau server pindah host.
const String kDefaultServerUrl = 'https://trimharvest-server-production-f7d1.up.railway.app';

// Layar pertama kali app dibuka: minta URL server (Node.js API Gateway,
// lihat /server di root repo) sebelum apa pun lain bisa dilakukan --
// lihat /PROTOCOL.md bagian 3.
class ServerSetupScreen extends StatefulWidget {
  final VoidCallback onDone;
  // Sama seperti `onLoggedIn` di LoginScreen -- layar ini TIDAK
  //   melakukan navigasi sendiri, cukup memanggil callback saat proses
  //   selesai; pemanggilnya (main.dart ATAU login_screen.dart, lihat
  //   `_changeServer()` di sana) yang menentukan apa yang terjadi
  //   selanjutnya (lanjut ke login, atau `pop()` kembali).
  final String? initialUrl;
  // URL yang sudah tersimpan -- ditampilkan sebagai nilai awal field
  //   supaya pengguna TIDAK menimpanya dengan default kalau cuma mau
  //   menekan Simpan. Kosongkan (null) untuk pakai URL default Railway
  //   (kasus pertama kali buka app).
  const ServerSetupScreen({super.key, required this.onDone, this.initialUrl});

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  // Nilai awal diisi di initState dari widget.initialUrl (atau default)
  //   -- TIDAK di konstruktor langsung karena butuh baca widget.
  bool _saving = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _urlController.text = widget.initialUrl?.isNotEmpty == true
        ? widget.initialUrl!
        : kDefaultServerUrl;
    // Tampilkan URL tersimpan (bila ada) supaya user bisa langsung
    //   Simpan tanpa mengetik ulang; kalau belum ada, pakai default Railway.
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  String? _validateUrl(String? value) {
    // Validator TERPISAH sebagai method sendiri (bukan closure inline
    //   seperti di login_screen.dart) -- karena logikanya LEBIH KOMPLEKS
    //   (beberapa aturan validasi berurutan), memisahkannya jadi method
    //   membuat kode lebih mudah dibaca dibanding menulis semuanya
    //   sebagai satu closure panjang di dalam `validator: (v) => ...`.
    final v = (value ?? '').trim();
    if (v.isEmpty) return 'URL server wajib diisi.';
    final uri = Uri.tryParse(v);
    if (uri == null || !uri.isAbsolute || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      // TIGA syarat URL dianggap valid, SEMUANYA harus terpenuhi:
      //   (1) berhasil di-parse sebagai Uri sama sekali, (2) `isAbsolute`
      //   -- URL harus LENGKAP dengan skema (bukan path relatif seperti
      //   "/api" saja), (3) skemanya harus http ATAU https (menolak
      //   skema aneh lain seperti "ftp://" atau input yang bukan URL
      //   sama sekali tapi kebetulan ter-parse sebagai Uri).
      return 'URL tidak valid. Contoh: https://server-kamu.example.com';
    }
    if (v.endsWith('/')) return 'Jangan pakai trailing slash (/) di akhir URL.';
    // Validasi TAMBAHAN yang SANGAT SPESIFIK & PENTING: server_base_url
    //   ini akan digabung LANGSUNG dengan path endpoint di api_client.dart
    //   (mis. `'$base/api/auth/login'`) -- kalau pengguna memasukkan URL
    //   dengan trailing slash (mis. "https://server.com/"), hasil
    //   gabungannya akan jadi "https://server.com//api/auth/login"
    //   (SLASH GANDA) yang BISA menyebabkan request gagal/salah rute di
    //   beberapa konfigurasi server/proxy -- validasi INI MENCEGAH bug
    //   yang KEMUNGKINAN BESAR sulit dilacak penyebabnya kalau baru
    //   ketahuan belakangan (error 404 yang membingungkan), jadi lebih
    //   baik dicegah SEJAK INPUT di sini.
    if (uri.path.isNotEmpty && uri.path != '/') {
      // Tolak URL yang membawa PATH (mis. ".../api/auth/login") -- base
      //   URL HARUS murni origin (https://host), karena api_client yang
      //   akan menambahkan path endpoint. Ini mencegah dobel-path
      //   (".../api/auth/login/api/auth/login") yang membuat login gagal.
      return 'URL cukup sampai nama host saja, jangan sertakan /api/... di belakangnya.';
    }
    return null;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _errorText = null;
    });
    try {
      await SecureStorageService.instance.saveServerBaseUrl(ApiClient.normalizeServerUrl(_urlController.text));
      widget.onDone();
      // Pemanggil (main.dart / login_screen) menangani navigasi lanjutannya
      //   lewat callback ini. Kita TAMBAH pop dengan nilai `true` supaya
      //   pemanggil yang membuka layar ini lewat `push` (mis. Dashboard ->
      //   Pengaturan Server) tahu URL SUDAH berubah & bisa logout.
      if (mounted) Navigator.of(context).pop(true);
      //   ApiClient (request JARINGAN ke server), fungsi ini HANYA
      //   MENYIMPAN string URL secara LOKAL (secure storage) -- TIDAK
      //   ADA verifikasi bahwa URL ini SUNGGUHAN mengarah ke server
      //   TrimHarvest yang valid/bisa dijangkau. Kalau pengguna salah
      //   ketik URL (tapi formatnya tetap valid secara sintaks, mis.
      //   "https://typo-server.com"), kesalahan ini BARU akan ketahuan
      //   NANTI saat mencoba login di LoginScreen (yang baru benar-benar
      //   melakukan request jaringan) -- desain ini SEDERHANA (memisahkan
      //   tanggung jawab: layar ini cuma soal alamat, layar login cuma
      //   soal kredensial), TAPI berarti feedback kesalahan URL SEDIKIT
      //   TERTUNDA (baru terlihat satu langkah kemudian, bukan seketika
      //   di layar ini).
    } catch (e) {
      if (mounted) setState(() => _errorText = 'Gagal menyimpan pengaturan: $e');
      // Kegagalan di sini SEHARUSNYA sangat jarang terjadi (menulis ke
      //   secure storage lokal biasanya andal), kemungkinan besar hanya
      //   terjadi dalam kondisi tidak umum (mis. penyimpanan device
      //   penuh, atau masalah OS-level pada keychain/keystore).
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pengaturan Server')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Masukkan alamat Server TrimHarvest (API Gateway Node.js) '
                'yang sudah kamu jalankan/deploy. Lihat README di folder /server.',
                // Teks penjelasan yang JUJUR soal prasyarat: layar ini
                //   MENGASUMSIKAN server SUDAH di-deploy sebelumnya
                //   (bukan bagian dari app ini menyediakan server-nya) --
                //   sesuai arsitektur proyek ini yang server-nya adalah
                //   proyek Node.js TERPISAH (lihat /server), bukan
                //   sesuatu yang otomatis tersedia begitu app di-install.
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'URL Server',
                  hintText: 'https://server-kamu.example.com',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                // `TextInputType.url` -- memberi tahu keyboard virtual
                //   OS untuk menampilkan LAYOUT yang dioptimalkan untuk
                //   mengetik URL (mis. tombol "/" dan "." lebih mudah
                //   diakses, tombol "Enter"/"Go" berlabel sesuai
                //   konteks) -- UX yang lebih nyaman dibanding keyboard
                //   teks biasa untuk input jenis ini.
                validator: _validateUrl,
              ),
              TextButton.icon(
                // Tombol bantuan: isi field dengan URL default Railway
                //   (kDefaultServerUrl) tanpa perlu mengetik manual sama
                //   sekali -- cocok buat pasang app di HP baru.
                onPressed: _saving
                    ? null
                    : () {
                        _urlController.text = kDefaultServerUrl;
                        // Langsung set teks field; pengguna tinggal tap
                        //   "Simpan & Lanjutkan" (atau diedit dulu kalau
                        //   mau pakai server lain).
                        if (mounted) setState(() {});
                        // Paksa rebuild biar field ikut update tampilan.
                      },
                icon: const Icon(Icons.rocket_launch_outlined, size: 18),
                label: const Text('Gunakan Server Default (Railway)'),
              ),
              if (_errorText != null) ...[
                const SizedBox(height: 12),
                Text(_errorText!, style: TextStyle(color: AppColors.danger(context))),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Simpan & Lanjutkan'),
                // Pola tombol loading yang IDENTIK dengan LoginScreen --
                //   konsistensi UI antar-layar dalam app yang sama.
              ),
            ],
          ),
        ),
      ),
    );
  }
}
