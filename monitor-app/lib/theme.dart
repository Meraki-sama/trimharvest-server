import 'package:flutter/material.dart';

// ===========================================================================
// theme.dart — Design system TrimHarvest.
//
// Tema "Pertanian Hipnotis": palet dikalibrasi dari psikologi warna
// (hijau=pertumbuhan/tenang, tanah=stabilitas, amber=panen/energi,
// biru=air/keandalan), spacing & tipografi mengikuti proporsi GOLDEN RATIO
// (φ ≈ 1.618) supaya layout terasa seimbang & menenangkan tanpa terasa
// dihitung. Font utama Poppins (rounded, ramah, mudah dibaca orang awam).
// ===========================================================================

// --- Spacing scale GOLDEN RATIO ---
// Basis 8px, dikalikan φ berturut-turut: 8, 13, 21, 34, 55, 89.
// Angka ini dipakai konsisten di seluruh app (padding, gap, radius) agar
// proporsi antar elemen selalu harmonis.
class AppSpacing {
  static const double xs = 8; // 8
  static const double sm = 13; // 8 * φ
  static const double md = 21; // 13 * φ
  static const double lg = 34; // 21 * φ
  static const double xl = 55; // 34 * φ
  static const double xxl = 89; // 55 * φ

  // Radius sudut mengikuti skala yang sama (membulat = ramah/hipnotis).
  static const double radiusSm = 13;
  static const double radiusMd = 21;
  static const double radiusLg = 34;

  // --- Target sentuh (aksesibilitas) ---
  // 48dp adalah ukuran minimum yang direkomendasikan Material Design & WCAG
  // 2.5.5 untuk area yang bisa disentuh. Ini BUKAN soal estetika melainkan
  // soal jari: pengguna lanjut usia, jari kasar bekas kerja sawah, atau
  // tangan gemetar sering meleset pada target kecil. Angka 55 (= 34 × φ,
  // masih di skala golden ratio kita) dipakai untuk tombol aksi UTAMA supaya
  // lebih mudah lagi dikenai, tanpa keluar dari sistem proporsi.
  static const double touchMin = 48;
  static const double touchComfortable = 55; // 34 * φ
}

// --- Ambang kontras (WCAG 2.1) ---
// Dipakai sebagai acuan saat memilih warna teks. Nilai kontras seluruh
// pasangan warna di file ini sudah dihitung: lihat komentar per warna.
//   - Teks normal  : minimal 4.5:1  (AA)
//   - Teks besar   : minimal 3.0:1  (AA, >=18pt atau >=14pt tebal)
//   - Komponen UI  : minimal 3.0:1  (AA, batas/ikon fungsional)
// Di sawah, layar HP sering dilihat di bawah MATAHARI LANGSUNG -- kontras
// tinggi bukan kemewahan, tapi syarat supaya angka sensornya terbaca.

// --- Warna terkalibrasi (Material Design 3 tonal) ---
// Diambil dari hex manual supaya tonalitas "alami" konsisten di light/dark,
// bukan sekadar colorSchemeSeed otomatis.
class AppColors {
  // Light
  static const Color leaf = Color(0xFF2E7D32); // hijau daun (primary)
  static const Color leafSoft = Color(0xFF66BB6A); // hijau muda aksen
  static const Color soil = Color(0xFF6D4C41); // cokelat tanah (secondary)
  static const Color sun = Color(0xFFF9A825); // amber matahari (accent/panen)
  static const Color sky = Color(0xFF0288D1); // biru langit (info/air)
  static const Color berry = Color(0xFFC62828); // merah muda (error/bahaya)
  static const Color cream = Color(0xFFF1F8E9); // krem muda (surface terang)
  static const Color mossBg = Color(0xFFE8F5E9); // latar belakang kehijauan lembut

  // --- Teks sekunder (pengganti Colors.grey) ---
  // `Colors.grey` (#9E9E9E) hanya 2.68:1 di atas putih dan 2.38:1 di atas
  // mossBg -- JAUH di bawah ambang 4.5:1, praktis tidak terbaca oleh mata
  // lanjut usia apalagi di bawah sinar matahari. Dua warna di bawah adalah
  // penggantinya, dipilih agar tetap terasa "redup/sekunder" secara visual
  // TAPI lulus kontras:
  static const Color inkMuted = Color(0xFF5D4B43); // 8.23:1 di putih, 7.31:1 di mossBg
  // cokelat abu hangat, senada dengan palet tanah (soil) sehingga tidak
  //   merusak nuansa agrikultur, berbeda dari abu-abu netral yang terasa
  //   "dingin".
  static const Color inkStrong = Color(0xFF2A211C); // 15.76:1 di putih -- teks utama pekat.

  // Amber "periksa/peringatan" yang AMAN kontras. `AppColors.sun` (#F9A825)
  // cuma 1.97:1 di atas putih -- gagal sebagai ikon/teks. Nada gelap di
  // bawah (4.81:1 di putih, 4.28:1 di mossBg) dipakai untuk ikon status
  // "data null, PERIKSA alat" di kartu sensor (lihat reading_card).
  static const Color alertAmber = Color(0xFF8D6E00);

  // Hijau "aktif/ya" yang aman kontras. `Colors.green` (#4CAF50) hanya
  // 2.78:1 di atas putih; nada di bawah ini lebih pekat (5.13:1) tapi tetap
  // hijau segar, dipakai untuk label status seperti "Ya"/"Aktif" dan ikon
  // sensor aktif di reading_card.
  static const Color okGreen = Color(0xFF2E7D32);

  // Dark
  static const Color leafDark = Color(0xFF81C784);
  static const Color soilDark = Color(0xFFA1887F);
  static const Color sunDark = Color(0xFFFFD54F);
  static const Color skyDark = Color(0xFF4FC3F7);
  static const Color berryDark = Color(0xFFEF9A9A);
  static const Color inkDark = Color(0xFF0E1A12); // latar gelap kehijauan
  static const Color surfaceDark = Color(0xFF13241A);

  // --- Helper kontekstual (otomatis menyesuaikan light/dark) ---
  // Dipakai menggantikan Colors.red/green/amber HARDCODE yang TIDAK
  // berubah saat tema gelap aktif (warna terang di bg gelap = kontras
  // rusak / tidak terbaca). Semua helper di bawah mengambil Brightness
  // dari context sehingga AMAN di kedua mode.
  static Color success(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? leafDark : okGreen;
  // Hijau "aktif/ya/online/sukses" -- okGreen(2E7D32) di light,
  //   leafDark(81C784) di dark (okGreen terlalu gelap di bg gelap).
  static Color alert(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? sunDark : alertAmber;
  // Amber "periksa/peringatan" -- alertAmber(8D6E00) di light,
  //   sunDark(FFD54F) di dark.
  static Color danger(BuildContext c) => Theme.of(c).colorScheme.error;
  // Merah error/bahaya -- langsung pakai colorScheme.error (sudah
  //   punya variant light/dark: berry / berryDark).
  static Color onAccent(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? inkDark : Colors.white;
  // Warna teks/ikon DI ATAS permukaan berwarna (tombol, badge) -- putih
  //   di light, tinta gelap di dark (kontras aman di kedua mode).
  static Color hint(BuildContext c) {
    // Pengganti Colors.grey: abu netral yang gagal kontras. Di light
    //   pakai inkMuted (cokelat hangat), di dark pakai soilDark.
    final b = Theme.of(c).brightness;
    return b == Brightness.dark ? soilDark : inkMuted;
  }
}

// --- Tipografi ramah (gaptek-friendly) ---
// FontSize juga mengikuti rasio φ dari basis 13 (body): 13, 21, 34, 55...
// sehingga hierarki teks proporsional & mudah dibaca.
class AppText {
  static const String fontFamily = 'Poppins';

  // Ukuran dinaikkan dari basis lama (body 14) karena target penggunanya
  // termasuk petani lanjut usia yang membaca di bawah matahari. `caption`
  // sengaja disetel 14 -- BUKAN 11/12 seperti sebelumnya: di bawah 14 teks
  // mulai sulit dibaca mata presbiopi (rabun tua), dan badge status seperti
  // "OFFLINE" justru termasuk informasi PALING penting di app ini, jadi
  // tidak masuk akal menampilkannya paling kecil.
  static const double caption = 14; // lantai baca -- tidak ada teks di bawah ini
  static const double body = 16; // naik dari 14; standar nyaman baca di HP
  static const double title = 21; // 13 × φ
  static const double headline = 34; // 21 × φ
  static const double display = 42;

  // Angka sensor di kartu dashboard: dibuat besar & tebal supaya terbaca
  // sekilas dari jarak lengan, tanpa perlu mendekatkan HP ke mata.
  static const double metric = 34;

  static const TextStyle bodyStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: body,
    height: 1.5, // line-height longgar = mudah dibaca
    letterSpacing: 0.2,
  );

  /// Gaya untuk teks kecil/sekunder yang TETAP terbaca (14pt, warna
  /// berkontras cukup). Dipakai menggantikan pola lama
  /// `TextStyle(fontSize: 12, color: Colors.grey)` yang tersebar di app.
  static const TextStyle captionStyle = TextStyle(
    fontFamily: fontFamily,
    fontSize: caption,
    height: 1.45,
    color: AppColors.inkMuted,
  );
}

// --- Tema LIGHT ---
ThemeData buildLightTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    fontFamily: AppText.fontFamily,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.leaf,
      brightness: Brightness.light,
      primary: AppColors.leaf,
      secondary: AppColors.soil,
      tertiary: AppColors.sun,
      error: AppColors.berry,
      surface: Colors.white,
      surfaceTint: AppColors.mossBg,
      ),
      scaffoldBackgroundColor: AppColors.mossBg,
    // Card membulat besar = lembut/hipnotis.
    cardTheme: CardThemeData(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      color: Colors.white,
      margin: const EdgeInsets.all(AppSpacing.xs),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.leaf,
        foregroundColor: Colors.white,
        minimumSize: const Size(64, AppSpacing.touchComfortable),
        // Tinggi 55dp (di atas minimum 48dp) untuk tombol aksi utama --
        //   lihat AppSpacing.touchComfortable.
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        ),
        textStyle: const TextStyle(
          fontFamily: AppText.fontFamily,
          fontSize: AppText.body,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, AppSpacing.touchComfortable),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        ),
        textStyle: const TextStyle(
          fontFamily: AppText.fontFamily,
          fontSize: AppText.body,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, AppSpacing.touchComfortable),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        ),
        textStyle: const TextStyle(
          fontFamily: AppText.fontFamily,
          fontSize: AppText.body,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    // Tombol teks (mis. "Batal" di dialog) juga wajib >=48dp: di dialog
    // konfirmasi, "Batal" adalah jalan keluar yang aman -- justru TIDAK BOLEH
    // lebih sulit dikenai daripada tombol aksi yang berisiko.
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(64, AppSpacing.touchMin),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        textStyle: const TextStyle(
          fontFamily: AppText.fontFamily,
          fontSize: AppText.body,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    // Ikon tap (mis. tombol mata "lihat password", refresh di AppBar) dibuat
    // 28dp di dalam area sentuh 48dp -- ikon 24dp default terasa kecil bagi
    // mata & jari lanjut usia.
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(AppSpacing.touchMin, AppSpacing.touchMin),
        iconSize: 28,
      ),
    ),
    iconTheme: const IconThemeData(size: 26),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        borderSide: const BorderSide(color: AppColors.leaf, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.md,
      ),
      // vertical dinaikkan sm(13) -> md(21) supaya tinggi kolom isian
      //   melewati 48dp: kolom input adalah target sentuh juga.
      labelStyle: const TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.body,
        color: AppColors.inkMuted,
      ),
      hintStyle: const TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.body,
        color: AppColors.inkMuted,
      ),
      // Pesan galat dibuat sebesar teks biasa & merah pekat -- pesan error
      // yang mungil justru paling sering terlewat oleh yang paling butuh.
      errorStyle: const TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.caption,
        color: AppColors.berry,
        fontWeight: FontWeight.w600,
      ),
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.title,
        fontWeight: FontWeight.w700,
        color: AppColors.leaf,
      ),
      iconTheme: IconThemeData(color: AppColors.leaf),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      labelStyle: const TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.caption,
        fontWeight: FontWeight.w600,
        color: AppColors.inkStrong,
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
    ),
    // Dialog: judul & isi dibesarkan karena di sinilah keputusan berisiko
    // diambil ("Hapus Device?"). Teks yang kecil di titik ini berbahaya --
    // pengguna bisa menyetujui sesuatu yang tidak sepenuhnya ia baca.
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      titleTextStyle: const TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.title,
        fontWeight: FontWeight.w700,
        color: AppColors.inkStrong,
      ),
      contentTextStyle: const TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.body,
        height: 1.5,
        color: AppColors.inkStrong,
      ),
    ),
    // SnackBar: umpan balik setelah aksi. Dibuat sebesar teks biasa supaya
    // konfirmasi "berhasil"/"gagal" tidak terlewat.
    snackBarTheme: const SnackBarThemeData(
      contentTextStyle: TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.body,
        color: Colors.white,
      ),
      behavior: SnackBarBehavior.floating,
    ),
    listTileTheme: const ListTileThemeData(
      minVerticalPadding: AppSpacing.sm,
      titleTextStyle: TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.body,
        fontWeight: FontWeight.w600,
        color: AppColors.inkStrong,
      ),
      subtitleTextStyle: AppText.captionStyle,
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(fontFamily: AppText.fontFamily, fontSize: AppText.body, height: 1.5, color: AppColors.inkStrong),
      bodyMedium: AppText.bodyStyle,
      bodySmall: AppText.captionStyle,
      labelSmall: AppText.captionStyle,
      titleMedium: TextStyle(fontFamily: AppText.fontFamily, fontSize: AppText.title, fontWeight: FontWeight.w600, color: AppColors.inkStrong),
      headlineSmall: TextStyle(fontFamily: AppText.fontFamily, fontSize: AppText.headline, fontWeight: FontWeight.w700, color: AppColors.inkStrong),
    ),
  );
  return base;
}

// --- Tema DARK ---
ThemeData buildDarkTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: AppText.fontFamily,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.leafDark,
      brightness: Brightness.dark,
      primary: AppColors.leafDark,
      secondary: AppColors.soilDark,
      tertiary: AppColors.sunDark,
      error: AppColors.berryDark,
      surface: AppColors.surfaceDark,
      surfaceTint: AppColors.inkDark,
      ),
      scaffoldBackgroundColor: AppColors.inkDark,
    cardTheme: CardThemeData(
      elevation: 0,
      color: AppColors.surfaceDark,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      margin: const EdgeInsets.all(AppSpacing.xs),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.leafDark,
        foregroundColor: AppColors.inkDark,
        minimumSize: const Size(64, AppSpacing.touchComfortable),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        ),
        textStyle: const TextStyle(
          fontFamily: AppText.fontFamily,
          fontSize: AppText.body,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, AppSpacing.touchComfortable),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, AppSpacing.touchComfortable),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(64, AppSpacing.touchMin),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        textStyle: const TextStyle(
          fontFamily: AppText.fontFamily,
          fontSize: AppText.body,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(AppSpacing.touchMin, AppSpacing.touchMin),
        iconSize: 28,
      ),
    ),
    iconTheme: const IconThemeData(size: 26),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surfaceDark,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        borderSide: const BorderSide(color: AppColors.leafDark, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.md,
      ),
      labelStyle: const TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.body,
        color: AppColors.leafDark,
      ),
      hintStyle: const TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.body,
        color: AppColors.leafDark,
      ),
      errorStyle: const TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.caption,
        color: AppColors.berryDark,
        fontWeight: FontWeight.w600,
      ),
    ),
    appBarTheme: const AppBarTheme(
      centerTitle: true,
      backgroundColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.title,
        fontWeight: FontWeight.w700,
        color: AppColors.leafDark,
      ),
      iconTheme: IconThemeData(color: AppColors.leafDark),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      labelStyle: const TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.caption,
        fontWeight: FontWeight.w600,
        color: AppColors.inkDark,
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
      ),
      titleTextStyle: const TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.title,
        fontWeight: FontWeight.w700,
        color: AppColors.leafDark,
      ),
      contentTextStyle: const TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.body,
        height: 1.5,
        color: AppColors.leafDark,
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      contentTextStyle: TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.body,
        color: Colors.white,
      ),
      behavior: SnackBarBehavior.floating,
    ),
    listTileTheme: const ListTileThemeData(
      minVerticalPadding: AppSpacing.sm,
      titleTextStyle: TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.body,
        fontWeight: FontWeight.w600,
        color: AppColors.leafDark,
      ),
      subtitleTextStyle: TextStyle(
        fontFamily: AppText.fontFamily,
        fontSize: AppText.caption,
        color: AppColors.leafDark,
      ),
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(fontFamily: AppText.fontFamily, fontSize: AppText.body, height: 1.5, color: AppColors.leafDark),
      bodyMedium: TextStyle(fontFamily: AppText.fontFamily, fontSize: AppText.body, height: 1.5, color: AppColors.leafDark),
      bodySmall: TextStyle(fontFamily: AppText.fontFamily, fontSize: AppText.caption, height: 1.45, color: AppColors.leafDark),
      labelSmall: TextStyle(fontFamily: AppText.fontFamily, fontSize: AppText.caption, height: 1.45, color: AppColors.leafDark),
      titleMedium: TextStyle(fontFamily: AppText.fontFamily, fontSize: AppText.title, fontWeight: FontWeight.w600, color: AppColors.leafDark),
      headlineSmall: TextStyle(fontFamily: AppText.fontFamily, fontSize: AppText.headline, fontWeight: FontWeight.w700, color: AppColors.leafDark),
    ),
  );
}
