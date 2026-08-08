import 'package:flutter/material.dart';
import '../services/api_client.dart';
import 'server_setup_screen.dart';
import '../theme.dart';

class LoginScreen extends StatefulWidget {
  // `StatefulWidget` (beda dari ReadingCard yang StatelessWidget) --
  //   layar ini PUNYA state internal yang berubah (loading, error text,
  //   isi form) sepanjang interaksi pengguna, jadi butuh pasangan kelas
  //   State terpisah (`_LoginScreenState` di bawah).
  final VoidCallback onLoggedIn;
  // Callback TANPA parameter & TANPA return value (`VoidCallback`) --
  //   dipanggil main.dart untuk memberi tahu "login SUDAH BERHASIL,
  //   silakan pindah ke layar dashboard" -- LoginScreen SENDIRI TIDAK
  //   melakukan navigasi/pindah layar setelah sukses (itu tanggung jawab
  //   PEMANGGIL widget ini, lihat main.dart) -- pola "inversion of
  //   control" yang membuat LoginScreen lebih independen/reusable, tidak
  //   perlu tahu APA yang terjadi setelah login sukses.
  const LoginScreen({super.key, required this.onLoggedIn});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  // `GlobalKey<FormState>` -- "pegangan" unik untuk mengakses widget
  //   `Form` di bawah (lihat build()) dari LUAR pohon widget-nya sendiri
  //   -- dipakai untuk memanggil `.validate()` (memicu SEMUA validator
  //   TextFormField sekaligus) tanpa perlu widget Form itu sendiri
  //   "tahu" kapan harus validasi.
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  // `TextEditingController` -- objek yang MENYIMPAN & MENGONTROL isi
  //   teks di TextFormField terkait -- dipakai (bukan hanya `onChanged`
  //   callback) karena kita perlu MEMBACA isinya secara terprogram saat
  //   tombol submit ditekan (`_usernameController.text`), bukan hanya
  //   bereaksi terhadap perubahan.
  bool _loading = false;
  String? _errorText;
  bool _obscurePassword = true;
  // Tiga variabel STATE yang mengontrol tampilan: `_loading`
  //   (menampilkan spinner & menonaktifkan tombol saat request
  //   berjalan), `_errorText` (pesan error dari percobaan login
  //   terakhir, null = tidak ada error), `_obscurePassword`
  //   (menyembunyikan/menampilkan karakter password, mulai TERSEMBUNYI
  //   secara default -- lebih aman sebagai default, pengguna bisa
  //   memilih menampilkannya lewat tombol mata).

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    // WAJIB "membuang" (dispose) SEMUA TextEditingController saat
    //   widget-nya dihancurkan (mis. pengguna berpindah layar) -- kalau
    //   dilupakan, controller ini akan terus memakai memori/resource
    //   walau widget-nya sudah tidak dipakai lagi (memory leak) --
    //   praktik WAJIB Flutter untuk setiap controller yang dibuat manual.
    super.dispose();
    // `super.dispose()` HARUS dipanggil PALING TERAKHIR (bukan
    //   pertama) -- urutan konvensi Flutter: bersihkan resource milik
    //   kelas TURUNAN dulu, baru serahkan ke kelas INDUK untuk
    //   membersihkan sisanya.
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    // `_formKey.currentState?.validate()` -- memicu SEMUA `validator`
    //   yang didefinisikan di TextFormField di bawah (lihat build()) --
    //   `?.` (null-safe access) dipakai karena `currentState` BISA null
    //   secara teori (kalau widget Form belum ter-render), dan `??
    //   false` memberi default aman kalau itu terjadi -- kalau validasi
    //   GAGAL (ada field kosong), fungsi ini LANGSUNG BERHENTI (`return`)
    //   tanpa mengirim request apa pun ke server -- validasi CLIENT-SIDE
    //   ini menghemat request yang PASTI akan ditolak server juga
    //   (username/password kosong).
    setState(() {
      _loading = true;
      _errorText = null;
      // Reset error LAMA saat memulai percobaan BARU -- kalau
      //   sebelumnya ada pesan error dari percobaan gagal, pesan itu
      //   HILANG dulu saat pengguna mencoba lagi (tidak menumpuk
      //   pesan lama yang sudah tidak relevan).
    });
    try {
      await ApiClient.instance.login(_usernameController.text.trim(), _passwordController.text);
      // `.trim()` HANYA untuk username (menghapus spasi di awal/akhir
      //   yang mungkin tidak sengaja terketik), TIDAK untuk password --
      //   password TIDAK di-trim karena SPASI adalah karakter yang SAH
      //   dalam password (kalau pengguna memang sengaja memasukkan
      //   spasi sebagai bagian password-nya, itu harus dihormati apa
      //   adanya, bukan dihapus diam-diam).
      widget.onLoggedIn();
      // Dipanggil HANYA kalau `login()` berhasil TANPA exception --
      //   memberi tahu main.dart untuk berpindah ke dashboard.
    } on ApiException catch (e) {
      // Tangkap KHUSUS `ApiException` (kegagalan yang SUDAH
      //   diterjemahkan jadi pesan ramah pengguna oleh
      //   _translateError() di api_client.dart, mis. "Username atau
      //   password salah.") -- ditangani TERPISAH dari exception LAIN
      //   yang lebih umum di bawah.
      if (mounted) setState(() => _errorText = e.message);
    } catch (e) {
      // Tangkap SEMUA exception LAIN yang TIDAK terduga (mis. tidak
      //   ada koneksi internet sama sekali, DNS gagal, dst -- error
      //   tingkat JARINGAN yang terjadi SEBELUM sempat mendapat respons
      //   HTTP apa pun dari server, jadi bukan `ApiException`) --
      //   ditampilkan dengan pesan yang MENYERTAKAN detail teknis
      //   mentahnya (`$e`) karena app tidak tahu persis APA yang salah
      //   dalam kasus ini.
      if (mounted) setState(() => _errorText = 'Tidak bisa terhubung ke server: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
      // `mounted` -- properti bawaan `State` yang menandakan APAKAH
      //   widget ini MASIH ADA di pohon widget (belum di-dispose) --
      //   PENTING dicek SEBELUM memanggil `setState()` di dalam blok
      //   `finally` (yang berjalan SETELAH `await` selesai): kalau
      //   pengguna KEBETULAN sudah berpindah/menutup layar ini SAAT
      //   request login masih berjalan (async), memanggil `setState()`
      //   pada widget yang SUDAH di-dispose akan melempar ERROR RUNTIME
      //   -- pengecekan `mounted` ini mencegah crash tersebut, pola yang
      //   SANGAT UMUM & PENTING di kode async Flutter mana pun.
    }
  }

  Future<void> _changeServer() async {
    final navigator = Navigator.of(context);
    // Simpan referensi `Navigator` SEBELUM `await` di bawah --
    //   CATATAN TEKNIS PENTING: mengakses `context` (mis.
    //   `Navigator.of(context)`) SETELAH sebuah `await` berisiko error
    //   "kalau widget sudah di-dispose selama menunggu" -- dengan
    //   menyimpan referensi navigator-nya LEBIH DULU (sebelum baris
    //   `await` di bawah), kode ini menghindari pola berisiko tersebut
    //   (mengakses `context` langsung setelah await).
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => ServerSetupScreen(onDone: () => navigator.pop()),
        // `ServerSetupScreen` diberi callback `onDone` yang MEMANGGIL
        //   `navigator.pop()` -- pola YANG SAMA seperti `onLoggedIn` di
        //   atas: ServerSetupScreen TIDAK tahu/tidak peduli APA yang
        //   terjadi setelah selesai, cukup memanggil callback yang
        //   diberikan pemanggilnya (di sini: "kembali ke layar
        //   sebelumnya", yaitu LoginScreen ini).
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Masuk'),
        actions: [
          IconButton(
            tooltip: 'Ganti Server',
            icon: const Icon(Icons.dns_outlined),
            onPressed: _changeServer,
            // Tombol di AppBar untuk mengganti URL server -- berguna
            //   kalau pengguna salah setup server ATAU memang mengelola
            //   LEBIH DARI SATU instalasi TrimHarvest (mis. server
            //   development vs produksi) dari app yang sama.
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          // Batas LEBAR MAKSIMUM 420 piksel logis -- di layar LEBAR
          //   (mis. tablet/desktop), form login TIDAK melebar penuh
          //   mengikuti layar (yang akan terlihat aneh/terlalu lebar
          //   untuk sekadar 2 kolom input), tetap terpusat dengan lebar
          //   yang nyaman dibaca.
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                // Column HANYA setinggi ISINYA (tidak memaksa mengisi
                //   penuh tinggi layar) -- penting supaya `Center` di
                //   luar bisa benar-benar MEMUSATKAN form ini secara
                //   vertikal (kalau Column memaksa full-height, Center
                //   tidak akan berefek apa pun secara visual).
                crossAxisAlignment: CrossAxisAlignment.stretch,
                // Semua children Column ini melebar PENUH mengikuti
                //   lebar Column (dibatasi maxWidth 420 di atas) -- jadi
                //   TextFormField & tombol "Masuk" semuanya selebar form,
                //   bukan hanya selebar kontennya sendiri.
                children: [
                  const Icon(Icons.agriculture, size: 64, color: AppColors.leaf),
                  // Ikon bertema PERTANIAN -- sesuai identitas visual
                  //   aplikasi "TrimHarvest" untuk monitoring sawah.
                  const SizedBox(height: 8),
                  Text('TrimHarvest', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      border: OutlineInputBorder(),
                    ),
                    validator: (v) => (v == null || v.isEmpty) ? 'Wajib diisi' : null,
                    // Validator MENGEMBALIKAN pesan error (String) kalau
                    //   TIDAK valid, atau `null` kalau SUDAH valid --
                    //   konvensi API `TextFormField` di Flutter.
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                        // Tombol MATA di dalam field password --
                        //   men-toggle `_obscurePassword`, yang lalu
                        //   mengubah `obscureText` di atas (rebuild
                        //   otomatis lewat setState) -- fitur standar UX
                        //   untuk membantu pengguna memverifikasi
                        //   password yang diketiknya benar sebelum
                        //   submit.
                      ),
                    ),
                    validator: (v) => (v == null || v.isEmpty) ? 'Wajib diisi' : null,
                    onFieldSubmitted: (_) => _submit(),
                    // Menekan tombol "Enter"/"Go" di keyboard virtual
                    //   SAAT berada di field PASSWORD ini otomatis
                    //   memicu submit -- UX yang lebih cepat, pengguna
                    //   tidak harus selalu menyentuh tombol "Masuk"
                    //   secara eksplisit setelah selesai mengetik
                    //   password (field username TIDAK memicu submit
                    //   serupa, karena logisnya pengguna masih perlu
                    //   pindah ke field password dulu setelahnya).
                  ),
                  if (_errorText != null) ...[
                    const SizedBox(height: 12),
                    Text(_errorText!, style: TextStyle(color: AppColors.danger(context))),
                    // Pesan error HANYA MUNCUL kalau ada (`_errorText
                    //   != null`) -- ruang untuknya TIDAK dialokasikan
                    //   sama sekali kalau tidak ada error (bukan
                    //   ditampilkan kosong/transparan), sehingga tata
                    //   letak form tidak "melompat" secara aneh saat
                    //   error muncul/hilang.
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _loading ? null : _submit,
                    // `onPressed: null` -- CARA STANDAR Flutter untuk
                    //   MENONAKTIFKAN tombol (tombol otomatis tampil
                    //   "redup"/disabled & tidak merespons tap) -- di
                    //   sini dipakai untuk mencegah pengguna menekan
                    //   "Masuk" BERKALI-KALI saat request SEDANG
                    //   berjalan (`_loading == true`), yang bisa memicu
                    //   beberapa request login paralel yang tidak perlu.
                    child: _loading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Masuk'),
                    // Isi tombol BERGANTI TOTAL antara teks "Masuk" &
                    //   spinner kecil -- feedback visual yang jelas
                    //   bahwa sistem sedang MEMPROSES, bukan diam saja
                    //   tanpa respons visual apa pun.
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Belum punya akun? Minta pemilik server membuatkannya lewat '
                    '"npm run create-operator" (lihat README /server).',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: AppText.caption, color: AppColors.inkMuted),
                    // Petunjuk kecil yang KONSISTEN dengan desain sistem
                    //   ini sebagai SINGLE-TENANT (lihat catatan di
                    //   server/scripts/create-operator.js): TIDAK ADA
                    //   tombol "Daftar" di layar ini SAMA SEKALI, karena
                    //   memang tidak ada endpoint signup publik --
                    //   pembuatan akun HANYA lewat akses terminal
                    //   server langsung, dan teks ini secara EKSPLISIT
                    //   memberi tahu pengguna alur yang benar.
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
