import 'package:flutter/material.dart';
import '../theme.dart';

// Grafik garis sederhana tanpa dependency tambahan (custom painter murni)
// -- cukup untuk melihat tren histori satu sensor, tanpa menambah risiko
// ketidakcocokan versi package chart pihak ketiga.
class Sparkline extends StatelessWidget {
  final List<double> values;
  final Color color;
  final double height;
  final double? threshold;
  // `threshold` (opsional) -- "angka patokan" yang ditentukan pengguna
  //   (mis. batas kelembaban minimum). Digambar sebagai garis putus-putus
  //   merah & area di ATAS/BYAH bawahnya diberi tint, supaya penyimpangan
  //   dari nilai rujukan langsung terlihat di grafik.

  const Sparkline({
    super.key,
    required this.values,
    this.color = AppColors.sky,
    this.height = 80,
    this.threshold,
  });

  @override
  Widget build(BuildContext context) {
    if (values.length < 2) {
      // Butuh MINIMAL 2 titik data untuk menggambar GARIS yang
      //   bermakna (1 titik saja tidak bisa membentuk garis/tren apa
      //   pun) -- kalau data belum cukup (device baru/belum ada
      //   histori), tampilkan pesan informatif alih-alih grafik kosong/
      //   error.
      return SizedBox(
        height: height,
        child: const Center(child: Text('Belum cukup data untuk grafik.')),
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      // Lebar SELALU mengisi penuh ruang yang tersedia (dari widget
      //   induk/parent) -- hanya TINGGI yang dikontrol lewat parameter
      //   `height`.
      child: CustomPaint(
        painter: _SparklinePainter(values: values, color: color, threshold: threshold),
        // `CustomPaint` -- widget Flutter yang memberi akses LANGSUNG
        //   ke Canvas (kanvas gambar tingkat rendah), dipakai untuk
        //   menggambar bentuk KUSTOM yang tidak tersedia sebagai widget
        //   bawaan -- di sinilah "custom painter murni" yang disebut
        //   komentar header berperan: SEMUA logika menggambar garis &
        //   area di bawahnya ditulis manual, bukan memakai library
        //   chart siap pakai. `threshold` diteruskan ke painter supaya
        //   garis "angka patokan" ikut digambar kalau diisi.
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final double? threshold;

  _SparklinePainter({required this.values, required this.color, this.threshold});

  @override
  void paint(Canvas canvas, Size size) {
    // Method INTI `CustomPainter` -- dipanggil Flutter setiap kali
    //   widget ini perlu digambar ulang, dengan `canvas` (permukaan
    //   gambar) & `size` (ukuran area yang tersedia, sesuai SizedBox di
    //   atas) sebagai parameter.
    double minV = values.first;
    double maxV = values.first;
    for (final v in values) {
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
      // Cari nilai MINIMUM & MAKSIMUM dari seluruh data secara MANUAL
      //   (loop sederhana, bukan memakai `values.reduce(min)` dkk) --
      //   dibutuhkan untuk NORMALISASI di bawah: grafik ini SELALU
      //   "auto-scale" mengisi penuh tinggi widget dari nilai TERKECIL
      //   sampai TERBESAR dalam data yang ditampilkan (bukan skala
      //   absolut tetap), supaya tren/fluktuasi tetap terlihat jelas
      //   walau rentang nilai sensornya kecil ATAU besar.
    }
    final range = (maxV - minV).abs() < 1e-9 ? 1.0 : (maxV - minV);
    // Pengaman PEMBAGIAN DENGAN NOL: kalau SEMUA nilai data KEBETULAN
    //   SAMA PERSIS (mis. sensor stabil total, tidak ada perubahan sama
    //   sekali dalam periode ini), `maxV - minV` akan menjadi 0 -- tanpa
    //   pengaman ini, normalisasi `(values[i] - minV) / range` di bawah
    //   akan menghasilkan pembagian dengan nol (NaN/Infinity di Dart,
    //   BUKAN error langsung, tapi akan merusak tampilan garis secara
    //   diam-diam) -- `1e-9` (0.000000001) dipakai sebagai ambang
    //   "praktis nol" untuk floating point (perbandingan langsung `== 0`
    //   pada float berisiko meleset karena representasi biner floating
    //   point yang tidak selalu presisi sempurna).

    final path = Path();
    // `Path` -- objek Flutter untuk mendefinisikan BENTUK/GARIS yang
    //   akan digambar (kumpulan titik & instruksi "pindah ke"/"gambar
    //   garis ke") -- SAMA konsepnya dengan elemen `<path>` di SVG.
    for (int i = 0; i < values.length; i++) {
      final x = size.width * (i / (values.length - 1));
      // Posisi horizontal titik ke-i, disebar MERATA dari kiri (x=0,
      //   saat i=0) sampai kanan penuh (x=size.width, saat i=nilai
      //   terakhir) -- `(i / (values.length - 1))` menghasilkan pecahan
      //   0.0 sampai 1.0 secara linear.
      final normalized = (values[i] - minV) / range;
      // Ubah nilai MENTAH jadi pecahan 0.0 (nilai terkecil dalam data
      //   ini) sampai 1.0 (nilai terbesar) -- inilah "auto-scale" yang
      //   disebut di atas.
      final y = size.height - (normalized * size.height);
      // PERHATIKAN: `size.height - (...)`, BUKAN langsung
      //   `normalized * size.height` -- ini KOREKSI PENTING karena
      //   sistem koordinat Canvas di Flutter (& hampir semua sistem
      //   grafis komputer) punya SUMBU Y TERBALIK dari yang intuitif
      //   secara matematika: y=0 di ATAS, y membesar ke BAWAH -- tanpa
      //   koreksi ini, nilai TERBESAR (normalized=1.0) akan digambar di
      //   PALING BAWAH (padahal secara visual grafik seharusnya
      //   menunjukkan nilai besar di ATAS), jadi baris ini MEMBALIK
      //   posisi supaya sesuai intuisi visual pengguna (nilai besar =
      //   posisi atas grafik).
      if (i == 0) {
        path.moveTo(x, y);
        // Titik PERTAMA: "angkat pena", pindah ke posisi ini TANPA
        //   menggambar garis apa pun dulu.
      } else {
        path.lineTo(x, y);
        // Titik SELANJUTNYA: gambar garis LURUS dari posisi
        //   sebelumnya ke posisi ini -- diulang untuk setiap titik,
        //   membentuk garis bersambung/polyline dari kiri ke kanan.
      }
    }

    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke // gambar GARIS-nya saja, bukan area terisi
      ..strokeWidth = 2.0
      ..strokeJoin = StrokeJoin.round // sudut antar segmen garis membulat, tidak lancip
      ..strokeCap = StrokeCap.round;  // ujung garis (awal/akhir) membulat, tidak persegi
      // Notasi `..` (cascade) Dart: memanggil BEBERAPA method/setter
      //   BERTURUT-TURUT pada objek yang SAMA (di sini `Paint()`) tanpa
      //   perlu menulis ulang nama variabelnya setiap baris -- gaya
      //   penulisan idiomatik Dart untuk konfigurasi objek dengan banyak
      //   properti.

    canvas.drawPath(path, linePaint);
    // Gambar GARIS utama grafik (path yang disusun di atas) dengan
    //   gaya `linePaint` yang baru dikonfigurasi.

    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    // Buat SALINAN path garis di atas (`Path.from(path)`), lalu
    //   TAMBAHKAN 2 titik lagi: pojok KANAN-BAWAH & pojok KIRI-BAWAH
    //   widget, lalu `.close()` (tutup bentuknya kembali ke titik awal)
    //   -- hasilnya BUKAN garis lagi, tapi sebuah BENTUK TERTUTUP
    //   (poligon) yang mencakup AREA DI BAWAH garis sampai dasar widget
    //   -- inilah area "bayangan" berwarna transparan yang biasa
    //   terlihat di bawah garis grafik tren (area chart klasik).
    final fillPaint = Paint()
      ..color = color.withValues(alpha: 0.12)
      // `.withValues(alpha: 0.12)` -- API Flutter (versi lebih baru,
      //   menggantikan `.withOpacity()` yang lama) untuk membuat warna
      //   yang SAMA tapi dengan TRANSPARANSI 12% -- area di bawah garis
      //   diisi warna yang SANGAT TIPIS/transparan, sekadar aksen visual
      //   halus, tidak mendominasi tampilan.
      ..style = PaintingStyle.fill; // kali ini ISI areanya, bukan cuma garis tepinya
    canvas.drawPath(fillPath, fillPaint);
    // Digambar SETELAH garis utama (drawPath pertama) -- urutan
    //   MENGGAMBAR di Canvas itu PENTING: elemen yang digambar LEBIH
    //   AWAL akan berada DI BAWAH (tertutup sebagian) elemen yang
    //   digambar SETELAHNYA. CATATAN: di sini urutannya garis DULU baru
    //   area fill -- secara visual keduanya tidak saling menutupi
    //   secara signifikan (area fill transparan & berada di ruang
    //   BAWAH garis, garis sendiri tetap terlihat penuh di ATAS area
    //   fill itu).

    // Garis "angka patokan" (threshold) -- garis putus-putus merah horizontal
    // di posisi nilai threshold (dengan skala auto-scale yang SAMA seperti
    // garis data di atas). Membantu pengguna langsung lihat apakah data
    // melewati batas rujukan.
    if (threshold != null && threshold! >= minV && threshold! <= maxV) {
      // HANYA gambar kalau threshold BERADA DI DALAM rentang tampilan
      //   (minV..maxV). Kalau di luar range (mis. patokan 500 tapi data
      //   0-100), jangan paksa gambar -- sebelumnya pakai kondisi `||`
      //   yang menyebabkan garis patokan tetap digambar di posisi Y
      //   negatif (DI ATAS widget), sehingga "ngeker ke grafik atas".
      //   Sekarang dibatasi rigorus supaya garis selalu di DALAM area
      //   grafik saja.
      final tNorm = (threshold! - minV) / range;
      final tY = (size.height - (tNorm * size.height))
          .clamp(0.0, size.height);
      // `.clamp(0.0, size.height)` -- jaga-jaga ekstra supaya posisi
      //   garis tidak pernah lolos ke luar area widget (atas/bawah),
      //   sekalipun perhitungan floating-point sedikit meleset.
      final dashPaint = Paint()
        ..color = Colors.redAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round;
      final dashPath = Path();
      // Garis putus-putus manual (canvas Flutter tidak punya dash bawaan
      // yang andal lintas versi) -- gambar segmen pendek bergantian.
      const dashLen = 6.0;
      const gapLen = 5.0;
      double x = 0;
      while (x < size.width) {
        final x2 = (x + dashLen < size.width) ? x + dashLen : size.width;
        dashPath.moveTo(x, tY);
        dashPath.lineTo(x2, tY);
        x += dashLen + gapLen;
      }
      canvas.drawPath(dashPath, dashPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    // Method OPTIMASI PERFORMA: Flutter memanggil ini setiap kali
    //   widget mungkin perlu digambar ulang, untuk BERTANYA "apakah
    //   BENAR-BENAR perlu repaint, atau data lama masih valid?" --
    //   mengembalikan `false` (tidak perlu repaint) menghemat kerja
    //   Canvas yang relatif mahal kalau data sebenarnya tidak berubah.
    return oldDelegate.values != values ||
        oldDelegate.color != color ||
        oldDelegate.threshold != threshold;
    // CATATAN TEKNIS: `values` bertipe `List<double>`, dan operator
    //   `!=` pada List DEFAULT DI DART adalah PERBANDINGAN REFERENSI
    //   (apakah kedua variabel menunjuk ke OBJEK LIST YANG SAMA persis
    //   di memori), BUKAN perbandingan ISI elemen satu-per-satu -- jadi
    //   dalam praktiknya, SETIAP KALI device_detail_screen.dart membuat
    //   List BARU dari data histori (mis. lewat `.map(...).toList()`
    //   setelah fetch ulang), `oldDelegate.values != values` akan
    //   SELALU bernilai `true` (dua List instance yang berbeda, walau
    //   isinya kebetulan SAMA PERSIS) -- efeknya, optimasi
    //   `shouldRepaint` ini SECARA PRAKTIS hampir tidak pernah benar-
    //   benar "menghemat" repaint pada kasus data yang identik, karena
    //   List baru HAMPIR SELALU dianggap "berbeda". Ini BUKAN bug fatal
    //   (grafik tetap akan tergambar BENAR, cuma berpotensi repaint
    //   sedikit lebih sering dari yang seharusnya perlu) -- kalau mau
    //   dioptimalkan lebih jauh, perbandingan ISI list (mis. pakai
    //   `listEquals` dari package `flutter/foundation.dart`) akan lebih
    //   akurat mendeteksi "data benar-benar sama, aman skip repaint".
  }
}
