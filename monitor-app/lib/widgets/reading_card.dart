import 'package:flutter/material.dart';
import '../models/reading.dart';
import '../models/alert.dart';
import '../theme.dart';

// Kartu metrik GENERIK -- lihat /PROTOCOL.md bagian 4. Widget ini memilih
// cara render berdasarkan `reading.unit`, BUKAN `reading.id` -- supaya
// sensor baru dengan `unit` yang sudah dikenal ("%", "bool", angka biasa)
// otomatis tampil benar tanpa perlu sentuh kode ini sama sekali.
class ReadingCard extends StatelessWidget {
  // `StatelessWidget` -- widget ini TIDAK punya state internal yang
  //   berubah sendiri (tidak ada animasi/timer/dst di dalamnya) -- setiap
  //   kali data `reading` berubah, Flutter membuat instance BARU widget
  //   ini (bukan me-mutasi yang lama), sesuai gaya deklaratif Flutter
  //   pada umumnya.
  final Reading reading;
  final double? threshold;
  // `threshold` (opsional) -- "angka patokan" dari pengguna. Kalau
  //   diset & nilai reading melewatinya, kartu diberi aksen MERAH +
  //   badge "LEWAT BATAS" (lihat _isBreached di bawah) -- alert visual
  //   agar penyimpangan langsung terlihat tanpa harus menatap grafik.
  final bool needsCalibration;
  // `needsCalibration` (opsional, default false) -- TRUE bila sensor
  //   ini kemungkinan BELUM dikalibrasi: nilainya 0 terus (khas sensor
  //   analog yang belum disambung/terkalibrasi, lihat bug #9). Memberi
  //   badge kuning "PERLU KALIBRASI" supaya pengguna tidak bingung melihat
  //   angka 0 melulu. Diisi dari layar detail berdasarkan unit + nilai.
  final Alert? alert;
  // `alert` (opsional) -- bila sensor ini sedang memicu peringatan
  //   threshold "standar industri" (lihat thresholds.dart), kartu
  //   menampilkan badge "PERINGATAN" + tint sesuai level (merah/amber).

  const ReadingCard({
    super.key,
    required this.reading,
    this.threshold,
    this.needsCalibration = false,
    this.alert,
  });

  // Apakah nilai reading melewati patokan (butuh threshold numerik &
  // nilai numerik yg valid). Untuk saat ini cukup "nilai > patokan".
  bool get _isBreached {
    if (threshold == null) return false;
    final v = reading.value;
    if (v is! num) return false;
    return v > threshold!;
  }

  Color? _breachTint(BuildContext context) {
    // Warna aksen kartu kalau breached -- merah lembut biar tetap
    //   nyaman di mata tapi jelas sebagai peringatan.
    if (!_isBreached) return null;
    final cs = Theme.of(context).colorScheme;
    return cs.errorContainer;
  }

  // Warna tint kartu kalau sedang ada alert standar industri (merah/
  // amber sesuai level) -- menggantikan tint hijau default biar kondisi
  // tidak-normal LANGSUNG mencolok mata.
  //
  // FIX: sebelumnya amber non-kritis SELALU pakai 0xFFFFF3E0 (amber sangat
  // pucat) walau di mode gelap -- warna itu dikalibrasi untuk latar TERANG,
  // di atas surfaceDark (#13241A) warna ini malah menyilaukan/pecah kontras
  // dengan sisa UI gelap di sekitarnya. Sekarang brightness-aware.
  Color? _alertTint(BuildContext context) {
    if (alert == null) return null;
    final cs = Theme.of(context).colorScheme;
    if (alert!.level == AlertLevel.critical) return cs.errorContainer;
    return cs.brightness == Brightness.dark
        ? const Color(0xFF3A2E0F) // amber gelap lembut, senada surfaceDark
        : const Color(0xFFFFF3E0); // amber pucat (mode terang)
  }

  // Badge teks untuk alert (mis. "PERINGATAN"). Warna disesuaikan level.
  String? get _alertBadge {
    if (alert == null) return null;
    return alert!.level == AlertLevel.critical
        ? 'KRITIS'
        : 'PERINGATAN';
  }

  String get _humanLabel {
    // Getter yang MENGUBAH id teknis (mis. "batt_pct", "tds_raw") jadi
    //   label yang lebih manusiawi untuk ditampilkan (mis. "Batt pct",
    //   "Tds raw") -- transformasi SEDERHANA & GENERIK (ganti underscore
    //   jadi spasi + kapitalisasi huruf pertama), BUKAN kamus terjemahan
    //   per-id seperti _translateError() di api_client.dart -- konsisten
    //   dengan filosofi "generik, tidak perlu tahu nama sensor spesifik"
    //   yang disebut di komentar header file ini.
    final spaced = reading.id.replaceAll('_', ' ');
    if (spaced.isEmpty) return spaced;
    return spaced[0].toUpperCase() + spaced.substring(1);
    // Kapitalisasi HANYA huruf PERTAMA dari keseluruhan string (bukan
    //   setiap kata) -- mis. "batt pct" jadi "Batt pct", bukan "Batt Pct"
    //   -- pilihan gaya penulisan yang sederhana & konsisten.
  }

  @override
  Widget build(BuildContext context) {
    switch (reading.unit) {
      case '%':
        return _percentCard(context);
      case 'bool':
        return _boolCard(context);
      case 'raw':
        return _plainCard(context, dimmed: true);
        // Reading dengan unit "raw" (mis. tds_raw/fork_raw/cap_raw dari
        //   body kalibrasi tipe "c", lihat node-sawah/src/main.cpp
        //   sendCalibReadings()) ditampilkan dengan `dimmed: true` --
        //   sedikit TRANSPARAN/redup secara visual, menandakan ini data
        //   "teknis/mentah" yang kurang relevan untuk monitoring biasa
        //   dibanding data "raw" ini biasanya hanya muncul saat mode
        //   kalibrasi aktif.
      default:
        return _plainCard(context, dimmed: false);
        // Unit APA PUN yang tidak dikenal secara khusus (mis. "ppm",
        //   "V", atau unit BARU yang belum pernah ada saat kode ini
        //   ditulis) jatuh ke tampilan `_plainCard` biasa -- INILAH INTI
        //   dari "UI dinamis": firmware bisa mengirim sensor dengan unit
        //   baru apa pun & app TETAP menampilkannya dengan wajar (angka +
        //   satuan), tanpa perlu update kode app sama sekali.
    }
  }

  Widget _cardShell(BuildContext context, {required Widget child, Color? tint, String? badge}) {
    // Helper "bingkai" bersama -- SEMUA jenis kartu (_percentCard,
    //   _boolCard, _plainCard) memakai `Card` + `Padding` yang SAMA
    //   persis, hanya ISI (`child`) di dalamnya yang berbeda -- menghindari
    //   duplikasi styling di ketiga method di bawah.
    final cs = Theme.of(context).colorScheme;
    final effectiveTint = tint ?? (cs.brightness == Brightness.dark
        ? const Color(0xFF1B2A1B) // hijau gelap lembut (tema gelap)
        : const Color(0xFFEAF3EA)); // hijau pucat lembut (tema terang)
    // Tint default hijau "pertanian" (sesuai palet) -- kartu tidur
    //   tenang; berubah MERAH kalau `breached` (lihat panggilan di bawah).
    return AnimatedContainer(
      // FIX kekakuan: sebelumnya `Card(color: effectiveTint)` -- warna
      //   kartu berganti SEKETIKA tiap kali status berubah (mis. alert
      //   muncul/hilang tiap poll 3 detik, atau breach threshold) --
      //   terasa "kedip"/patah. `AnimatedContainer` menganimasikan
      //   perubahan warna (& shape) secara halus dalam 300ms setiap kali
      //   `effectiveTint` berbeda dari sebelumnya, tanpa perlu
      //   AnimationController manual.
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      margin: EdgeInsets.zero,
      // Margin NOL -- jarak antar-kartu diatur oleh WIDGET PEMBUNGKUS
      //   di layar yang memakainya (mis. GridView dengan spacing sendiri
      //   di dashboard/device_detail_screen), bukan oleh kartu ini
      //   sendiri -- mencegah margin DOBEL (dari Card + dari grid
      //   spacing sekaligus).
      decoration: BoxDecoration(
        color: effectiveTint,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (badge != null)
              Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  // Merah untuk "LEWAT BATAS" (breach), amber untuk
                  // "PERLU KALIBRASI" -- beda warna = beda urgensi.
                  color: badge == 'LEWAT BATAS' ? cs.error : const Color(0xFFB26A00),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                      color: AppColors.onAccent(context),
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.3),
                ),
              ),
            child,
          ],
        ),
      ),
    );
  }

  Widget _percentCard(BuildContext context) {
    // Tampilan KHUSUS untuk reading dengan unit "%" -- dilengkapi
    //   progress bar visual, BUKAN cuma angka teks biasa seperti
    //   _plainCard -- memberi kesan visual "seberapa penuh/tinggi" yang
    //   langsung terlihat sekilas (cocok untuk kelembaban tanah, baterai,
    //   dst).
    final v = reading.value;
    final pct = v == null ? null : (v.toDouble().clamp(0, 100)) / 100.0;
    // `.clamp(0, 100)` -- BATASI nilai persentase ke rentang 0-100
    //   SEBELUM dibagi 100 untuk `LinearProgressIndicator` (yang
    //   mengharapkan `value` dalam rentang 0.0-1.0) -- pengaman kalau
    //   data dari server SOMEHOW di luar rentang wajar (mis. bug di
    //   firmware yang menghasilkan >100%), progress bar TIDAK akan
    //   error/melebihi batas visualnya.
    return _cardShell(
      context,
      tint: _alertTint(context) ?? _breachTint(context),
      badge: _alertBadge ??
          (_isBreached ? 'LEWAT BATAS' : (needsCalibration ? 'PERLU KALIBRASI' : null)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        // `min` -- jangan paksa Column mengambil tinggi maksimal
        //   available (default max) yg bisa melebihi tinggi kartu yg
        //   dibatasi GridView (childAspectRatio), penyebab "BOTTOM
        //   OVERFLOWED BY 3 PIXELS" di layar sempit. Dengan `min`, kartu
        //   cukup tinggi sesuai isi & tidak meluap.
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_humanLabel, style: Theme.of(context).textTheme.labelMedium,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          if (pct == null)
            const Text('—', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))
          else ...[
            SizedBox(
              height: 8,
              // Tinggi FIX untuk progress bar -- mencegah
              //   LinearProgressIndicator (yang punya tinggi minimum
              //   internal) menambah tinggi tak terduga ke Column.
              // FIX kekakuan: sebelumnya bar melompat LANGSUNG ke nilai
              // baru tiap poll (3 detik) -- terasa patah-patah, apalagi
              // di sensor yang nilainya naik/turun cepat (mis. kelembaban
              // saat hujan). TweenAnimationBuilder menganimasikan
              // perpindahan antar nilai secara halus.
              child: TweenAnimationBuilder<double>(
                tween: Tween(begin: pct, end: pct),
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOutCubic,
                builder: (context, animatedPct, _) =>
                    LinearProgressIndicator(value: animatedPct, minHeight: 8),
              ),
            ),
            const SizedBox(height: 6),
            AnimatedSwitcher(
              // Angka besar (mis. "42%") juga fade-transition halus saat
              //   berubah, bukan "berkedip" mengganti teks seketika.
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
              child: Text('${v!.toStringAsFixed(0)}%',
                  key: ValueKey(v.toStringAsFixed(0)),
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _boolCard(BuildContext context) {
    // Tampilan untuk reading dengan unit "bool" (mis. "motion" dari
    //   sensor PIR) -- ikon centang/lingkaran kosong + teks Ya/Tidak,
    //   BUKAN angka.
    final v = reading.value;
    final isActive = v != null && v != 0;
    // Nilai boolean dikirim SEBAGAI ANGKA lewat protokol (0 atau 1,
    //   lihat node-sawah/src/main.cpp: `motion.add(consumeMotionEvent()
    //   ? 1 : 0)`) -- karena format tuple JSON [id,value,unit] ini
    //   generik untuk SEMUA jenis reading (termasuk yang numerik), tidak
    //   ada representasi boolean JSON asli (`true`/`false`) yang dipakai
    //   di sini -- app-lah yang menerjemahkan `value != 0` menjadi
    //   makna boolean berdasarkan `unit == "bool"`.
    return _cardShell(
      context,
      tint: _alertTint(context) ?? _breachTint(context),
      badge: _alertBadge ??
          (_isBreached ? 'LEWAT BATAS' : (needsCalibration ? 'PERLU KALIBRASI' : null)),
      child: Row(
        children: [
          AnimatedSwitcher(
            // Transisi fade+scale halus saat status berubah (mis. sensor
            //   gerak mendeteksi Ya<->Tidak tiap poll) -- sebelumnya ikon
            //   berganti SEKETIKA (langsung "meloncat"), terasa kaku/patah.
            //   `key` beda per state -> AnimatedSwitcher tahu kapan harus
            //   menganimasikan transisi.
            duration: const Duration(milliseconds: 250),
            transitionBuilder: (child, anim) =>
                ScaleTransition(scale: anim, child: FadeTransition(opacity: anim, child: child)),
            child: Icon(
              isActive ? Icons.check_circle : Icons.radio_button_unchecked,
              key: ValueKey<bool?>(v == null ? null : isActive),
              // Warna kini MEMBEDAKAN ketiga keadaan, dan brightness-aware
              // (FIX: sebelumnya AppColors.alertAmber/okGreen/inkMuted
              // dipakai LANGSUNG tanpa cek mode gelap -- warna-warna itu
              // dikalibrasi kontras untuk latar TERANG saja, di atas kartu
              // gelap kontrasnya jauh di bawah standar WCAG yang justru jadi
              // alasan warna ini dibuat. Sekarang pakai helper context-aware
              // yang sama dipakai di seluruh app, lihat theme.dart):
              //   - null  -> AppColors.alert(context)   = "periksa alat"
              //   - false -> AppColors.hint(context)    = netral/nonaktif
              //   - true  -> AppColors.success(context) = "aktif"
              color: v == null
                  ? AppColors.alert(context)
                  : (isActive ? AppColors.success(context) : AppColors.hint(context)),
              size: 28, // ikon diperbesar agar terbaca dari jarak lengan
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(_humanLabel, style: Theme.of(context).textTheme.labelMedium),
          ),
          Text(
            v == null ? '—' : (isActive ? 'Ya' : 'Tidak'),
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  Widget _plainCard(BuildContext context, {required bool dimmed}) {
    // Tampilan FALLBACK/default untuk unit apa pun yang tidak punya
    //   perlakuan khusus (%/bool) -- angka + satuan biasa, opsional
    //   diredupkan (`dimmed`) untuk data "raw" (lihat build() di atas).
    final v = reading.value;
    final text = v == null ? '—' : '${_formatNumber(v)}${reading.unit.isEmpty ? '' : ' ${reading.unit}'}';
    // Susunan teks: angka diformat rapi (lihat _formatNumber di bawah)
    //   + SPASI + satuan, TAPI HANYA kalau satuan tidak kosong (beberapa
    //   reading mungkin tidak punya unit yang bermakna) -- mencegah
    //   tampilan aneh seperti "123 " (spasi menggantung tanpa apa pun
    //   sesudahnya) kalau unit kebetulan kosong.
    return _cardShell(
      context,
      tint: _alertTint(context) ?? _breachTint(context),
      badge: _alertBadge ??
          (_isBreached ? 'LEWAT BATAS' : (needsCalibration ? 'PERLU KALIBRASI' : null)),
      child: Opacity(
        opacity: dimmed ? 0.6 : 1.0,
        // `Opacity` widget -- membungkus SELURUH isi kartu dengan
        //   tingkat transparansi 60% kalau `dimmed` true -- cara paling
        //   sederhana untuk memberi kesan visual "kurang penting/data
        //   teknis" tanpa perlu mendefinisikan skema warna terpisah.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_humanLabel, style: Theme.of(context).textTheme.labelMedium,
              maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            AnimatedSwitcher(
              // Sama seperti _percentCard: fade halus tiap nilai baru
              //   masuk (tiap poll 3 detik), bukan ganti teks seketika.
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
              child: Text(text,
                  key: ValueKey(text),
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  String _formatNumber(num v) {
    // Helper pemformatan angka yang MEMPERHATIKAN apakah nilainya
    //   sebenarnya bilangan BULAT atau PECAHAN -- menghindari tampilan
    //   canggung seperti "45.00%" untuk nilai yang sebenarnya bulat, TAPI
    //   tetap menampilkan desimal yang BERMAKNA (mis. "23.45") untuk
    //   nilai yang memang pecahan.
    if (v is int) return v.toString();
    // Kalau tipe Dart-nya MEMANG `int` (bukan `double`), langsung
    //   tampilkan apa adanya (mis. "42", bukan "42.0").
    final d = v.toDouble();
    if (d == d.roundToDouble()) return d.toStringAsFixed(0);
    // Kalau tipenya `double` TAPI nilainya KEBETULAN bulat (mis.
    //   50.0 dari server, bisa terjadi karena JSON tidak membedakan
    //   int/float secara ketat) -- tampilkan TANPA desimal ("50", bukan
    //   "50.0") -- `d.roundToDouble()` membulatkan `d` ke integer
    //   terdekat (masih bertipe double), lalu dibandingkan dengan `d`
    //   asli: kalau SAMA, berarti `d` memang sudah bulat sempurna.
    return d.toStringAsFixed(2);
    // Untuk nilai pecahan SUNGGUHAN, tampilkan dengan 2 angka di
    //   belakang koma -- cukup presisi untuk sebagian besar pembacaan
    //   sensor (mis. ppm TDS, tegangan baterai) tanpa berlebihan.
  }
}
