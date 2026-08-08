import 'package:flutter/material.dart';

import '../theme.dart';

// ============================================================================
// user_guide_screen.dart — Tab "Buku Panduan".
//
// Manual penggunaan aplikasi TrimHarvest secara STATIS (bukan tutorial
// interaktif ala game di OnboardingScreen). Ditulis dengan bahasa awam
// untuk pengguna usia 40-50 tahun (petani/pekebun): kalimat pendek,
// tanpa jargon, pakai sapaan Bapak/Ibu dan analogi sehari-hari.
// ============================================================================

class UserGuideScreen extends StatelessWidget {
  const UserGuideScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Buku Panduan')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: const [
          _GuideSection(
            icon: Icons.dashboard_outlined,
            title: '1. Halaman Utama (Daftar Alat)',
            body: 'Ini layar pembuka. Di sini Bapak/Ibu bisa melihat semua alat '
                'yang dipantau, tampil seperti kartu-kartu.\n\n'
                'Setiap kartu menunjukkan keadaan terkini: air tanah basah atau '
                'kering, tanaman sehat atau perlu perhatian, dan baterai masih '
                'atau hampir habis. Ada tanda "ONLINE" (alat hidup & kirim data) '
                'atau "OFFLINE" (alat tidak mengirim kabar, mungkin mati atau '
                'putus sinyal).\n\n'
                'Angka di kartu akan berubah sendiri tiap beberapa detik. Kalau '
                'ingin lebih cepat, tarik layar ke bawah dengan jari. Tekan satu '
                'kartu untuk melihat rinciannya.',
          ),
          _GuideSection(
            icon: Icons.add_circle_outline,
            title: '2. Daftarkan Alat Baru',
            body: 'Tekan tombol bergambar "+" di pojok kanan bawah. App akan '
                'memandu Bapak/Ibu menyambungkan alat ke HP langkah demi langkah.\n\n'
                'Cara kerjanya sederhana: HP akan sebentar terhubung ke alat '
                '(bukan WiFi rumah), lalu Bapak/Ibu cukup ketik nama WiFi rumah '
                'dan sandinya. Setelah itu alat akan otomatis kirim laporan ke '
                'telp Bapak/Ibu. Ikuti saja tulisan yang muncul di layar.',
          ),
          _GuideSection(
            icon: Icons.show_chart_outlined,
            title: '3. Lihat Grafik & Riwayat',
            body: 'Tekan satu kartu alat, lalu geser ke bawah. Bapak/Ibu akan '
                'melihat gambar grafik yang menunjukkan keadaan dari hari ke hari '
                '(seperti grafik naik-turun di berita cuaca).\n\n'
                'Ada garis yang bisa digeser untuk menandai batas "aman". '
                'Misalnya: kalau tanah sudah terlalu kering, app akan memberi '
                'tanda peringatan supaya Bapak/Ibu tahu waktunya menyiram.',
          ),
          _GuideSection(
            icon: Icons.tune_outlined,
            title: '4. Atur Supaya Ukurannya Tepat (Kalibrasi)',
            body: 'Kadang alat perlu "diajari" dulu supaya tidak salah ukur, sama '
                'seperti timbangan yang perlu disetel. Caranya mudah:\n\n'
                '1. Tekan "Simpan Kering" saat alat di udara terbuka.\n'
                '2. Tekan "Simpan Basah" setelah alat dicelup ke air atau tanah '
                'basah.\n\n'
                'Ingat: lakukan kering dulu, baru basah. Setelah itu ukuran alat '
                'akan jadi lebih akurat.',
          ),
          _GuideSection(
            icon: Icons.notifications_outlined,
            title: '5. Peringatan (Tab Lonceng)',
            body: 'Tab ini seperti buku catatan kejadian. Kalau ada yang tidak '
                'beres — misalnya tanah kekeringan, atau ada gerakan di sekitar '
                'tanaman — app mencatatnya di sini.\n\n'
                'Ada angka merah di tombol bawah yang menunjukkan berapa banyak '
                'peringatan yang belum dibaca. Tekan tombol itu untuk membaca dan '
                'menandainya sudah dibaca.',
          ),
          _GuideSection(
            icon: Icons.build_outlined,
            title: '6. Catatan Kerusakan (Tab Pin)',
            body: 'Tab ini untuk mencatat bila ada alat yang rusak atau perlu '
                'diperiksa, misalnya: "sensor air rusak, ganti kabel" atau '
                '"kotak alat mati lampu, cek stopkontak".\n\n'
                'Tekan ikon peniti (pin) supaya catatan itu menempel di atas dan '
                'gampang dicari bila sewaktu-waktu alat bermasalah mendadak. Catatan '
                'ini tersimpan di HP Bapak/Ibu, tidak hilang meski app ditutup.',
          ),
          _GuideSection(
            icon: Icons.bedtime_outlined,
            title: '7. Hemat Baterai',
            body: 'Kalau alat pakai baterai dan Bapak/Ibu ingin tahan lebih lama, '
                'nyalakan "Hemat". Alat akan kirim laporan lebih jarang, jadi '
                'baterai tidak cepat habis.\n\n'
                'Untuk mengembalikan ke normal, cukup colok alat ke listrik, atau '
                'matikan "Hemat" dari app. Sama seperti mengecilkan volume HP '
                'supaya baterai tahan lama.',
          ),
          _GuideSection(
            icon: Icons.lock_outline,
            title: '8. Ganti Kata Sandi',
            body: 'Tekan gambar gembok di halaman utama untuk mengganti kata '
                'sandi. Ini penting supaya orang lain tidak bisa buka app Bapak/Ibu.\n\n'
                'Kalau HP hilang, segera ganti kata sandi dari HP lain — semua '
                'orang yang pakai kata sandi lama akan langsung terputus. Aman.',
          ),
          _GuideSection(
            icon: Icons.help_outline,
            title: '9. Kalau Ada Masalah',
            body: '• Data tidak muncul: periksa alat menyala dan tersambung ke '
                'WiFi rumah. Tanda "OFFLINE" artinya alat sedang tidak kirim kabar.\n'
                '• Angka sensor kosong/blank: biasanya kabel alat longgar atau '
                'rusak. Catat di Tab Pin supaya tidak lupa.\n'
                '• Ukuran terasa salah: lakukan pengaturan di nomor 4 (Kalibrasi).\n'
                '• Tulisan "Tidak bisa terhubung": periksa kembali alamat server '
                'di layar pengaturan awal.',
          ),
          SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }
}

class _GuideSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _GuideSection({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: AppColors.leaf.withValues(alpha: 0.12),
                  child: Icon(icon, color: AppColors.leaf),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700, fontSize: AppText.title)),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(body, style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
