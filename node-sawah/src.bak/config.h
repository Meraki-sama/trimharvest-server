#ifndef CONFIG_H
#define CONFIG_H
// ^ Include guard standar C/C++: mencegah isi file ini "ditempel" dua kali
//   kalau ada beberapa file .cpp yang sama-sama #include "config.h" dan
//   saling meng-include satu sama lain -- tanpa guard ini, compiler akan
//   error "redefinition" karena macro/konstanta didefinisikan berulang.
#include <Arduino.h>
// ^ Header inti framework Arduino -- dibutuhkan karena beberapa tipe di
//   bawah (mis. implisit lewat makro) bergantung pada definisi dasar
//   framework ini.

// =============================================================================
// Semua konstanta yang bisa/boleh diubah ada di sini. Untuk penjelasan
// menyeluruh soal protokol & keamanan, baca /PROTOCOL.md dan /SECURITY.md
// di root repo SEBELUM mengubah apa pun di bawah ini.
// =============================================================================

#define I2C_SDA 21
#define I2C_SCL 22
// ^ Nomor pin GPIO ESP32 untuk bus I2C (dipakai komunikasi ke ADS1115 &
//   OLED) -- SDA (data) & SCL (clock), sesuai wiring board TTGO T-Beam.

#define LORA_SCK  5
#define LORA_MISO 19
#define LORA_MOSI 27
#define LORA_SS   18
#define LORA_DIO0 26
// ^ Pin-pin bus SPI + kontrol untuk modul radio LoRa (SX127x): SCK/MISO/
//   MOSI adalah jalur SPI standar, SS (Slave Select) memilih chip LoRa
//   sebagai target komunikasi SPI, DIO0 adalah pin interrupt yang dipakai
//   modul LoRa memberi sinyal "ada paket masuk"/"transmisi selesai".

#define BAND 923E6
// ^ Frekuensi radio LoRa: band ISM yang boleh dipakai tanpa lisensi.
//   Indonesia mengalokasikan 920-923 MHz untuk LoRa/SRD -- BUKAN 915 MHz
//   (alokasi Amerika Utara) yang dipakai versi awal firmware ini.
//   HARUS SAMA PERSIS dengan LORA_BAND di gateway-rumah/src/config.h --
//   kalau beda, radio node & gateway tidak akan terhubung sama sekali.
#define PIR_PIN 13
// ^ Pin sensor PIR (Passive Infrared) -- mendeteksi gerakan/kehadiran
//   (nama sensor "motion" di data JSON, lihat /PROTOCOL.md 1.1).

// === Tegangan baterai: dibaca lewat PMIC AXP2101 (bawaan T-Beam) ===
// T-Beam membawa chip manajemen daya AXP2101 yang mengukur tegangan
// baterai 1-cell Li-Po LANGSUNG lewat I2C (lihat initBatteryMonitor() &
// readBatteryVoltage() di sensors.cpp). TIDAK memakai voltage divider
// manual / pin ADC eksternal -- karena itu, #define seperti BATTERY_PIN
// atau BATTERY_READ_SAMPLES (yang dulunya dipakai untuk pembagi tegangan
// resistor) SUDAH TIDAK RELEVAN dan sengaja DIHAPUS: menyisakannya hanya
// menyesatkan (seolah masih ada divider MT3608/ADC yang harus
//   dikalibrasi). Batas % di bawah ini dipakai interpolasi kasar.
#define ADS1115_ADDR 0x48
// ^ Alamat I2C default chip ADC eksternal ADS1115 (baca sensor analog
//   TDS/fork/capacitive).
#define BATTERY_MIN_VALID_VOLTAGE 0.5f
// ^ Di bawah tegangan ini, bacaan dianggap TIDAK VALID (mis. baterai tidak
//   terpasang / pin lepas) -- bukan berarti baterai benar-benar 0.5V.
#define BATTERY_LOW_VOLTAGE 3.0f
#define BATTERY_FULL_VOLTAGE 4.2f
// ^ Batas bawah/atas tegangan 1-cell Li-Po tipikal -- dipakai untuk
//   menghitung persentase baterai kasar (interpolasi linear antara kedua
//   nilai ini, lihat sensors.cpp).
#define ADS_SAMPLE_COUNT 8
// ^ Jumlah sampel yang diambil & dirata-rata dari ADS1115 per pembacaan
//   sensor analog (TDS/fork/capacitive).
#define ADS_SAMPLE_DELAY_US 200
// ^ Jeda antar-sampel ADC dalam mikrodetik -- memberi waktu ADC settle
//   antara satu pembacaan dan berikutnya.
#define SENSOR_FILTER_ALPHA 0.22f
// ^ Koefisien filter low-pass eksponensial (EMA -- Exponential Moving
//   Average) untuk menghaluskan bacaan sensor dari waktu ke waktu; nilai
//   kecil (0.22) berarti bacaan baru punya bobot rendah -> perubahan
//   halus/lambat, mengurangi noise tapi responsnya agak lambat mengikuti
//   perubahan nyata.
#define SENSOR_FILTER_ALPHA_FAST 0.45f
// ^ Versi alpha yang LEBIH BESAR (respons lebih cepat) -- kemungkinan
//   dipakai saat mode kalibrasi aktif, di mana pengguna butuh melihat
//   perubahan raw secara lebih responsif (lihat calibration.cpp).
#define SENSOR_FILTER_DEADBAND 8.0f
// ^ Ambang batas (deadband): perubahan bacaan filter di bawah nilai ini
//   dianggap "noise", tidak dianggap perubahan nyata -- mencegah nilai
//   yang ditampilkan/dikirim "gemetar" terus walau kondisi sebenarnya
//   stabil.
#define SENSOR_STABLE_DEADBAND 2
#define SENSOR_STABLE_STEP 3
// ^ Parameter tambahan untuk deteksi "bacaan sudah stabil" (dipakai logika
//   di sensors.cpp) -- dua ambang batas terpisah untuk keperluan berbeda
//   dalam algoritma stabilisasi bacaan.
#define SENSOR_SAMPLE_MS 250
// ^ Interval (ms) antar-siklus pembacaan sensor di loop utama -- lebih
//   cepat dari SEND_INTERVAL (lihat di bawah) karena filter EMA butuh
//   sampel lebih sering daripada frekuensi pengiriman data lewat radio.
#define PIR_DEBOUNCE_MS 1200
// ^ Waktu debounce sensor PIR (ms) -- setelah PIR mendeteksi gerakan,
//   abaikan pemicu berikutnya selama durasi ini, mencegah trigger
//   berulang-ulang untuk satu kejadian gerakan yang sama.

// Nilai BAWAAN/DEFAULT titik kalibrasi kering/basah Fork & Capacitive.
// Bisa ditimpa kapan saja lewat app (menu Kalibrasi Sensor) -- nilai
// kustom disimpan di NVS lewat calibration.h/.cpp. Lihat calibration.h
// untuk detail lengkap alurnya.
#define FORK_SENSOR_DRY_RAW 10000
#define FORK_SENSOR_WET_RAW 2200
// ^ Nilai ADC mentah (raw) saat sensor "fork" (kemungkinan sensor
//   kelembaban tipe garpu/fork moisture sensor) dalam kondisi benar-benar
//   kering vs benar-benar basah -- jadi acuan default sebelum pengguna
//   mengkalibrasi sendiri sesuai tanah/kondisi sesungguhnya.
#define FORK_SENSOR_MAX_PERCENT 100
#define FORK_SENSOR_BASELINE_OFFSET 15
// ^ Offset dasar yang ditambahkan/dikurangi dari hasil persentase --
//   kemungkinan kompensasi supaya persentase 0% tidak persis di titik
//   "basah total" (memberi margin sebelum dianggap benar-benar kering).
#define CAPACITIVE_SENSOR_DRY_RAW 15500
#define CAPACITIVE_SENSOR_WET_RAW 7200
#define CAPACITIVE_SENSOR_MAX_PERCENT 70
// ^ Set nilai kalibrasi default serupa untuk sensor kelembaban tipe
//   kapasitif (biasanya lebih tahan korosi dibanding sensor resistif).
//   MAX_PERCENT-nya 70 (bukan 100 seperti fork) -- kemungkinan karena
//   karakteristik sensor ini secara fisik tidak pernah membaca "100%
//   basah" dengan raw value serendah WET_RAW pada kondisi nyata di
//   lapangan, jadi dibatasi supaya skala persentase tetap masuk akal.
#define BATTERY_DEBUG_MS 2000
// ^ Interval (ms) untuk mencetak info debug baterai ke Serial (kalau ada
//   logika debug terkait di main.cpp/sensors.cpp).
#define SEND_INTERVAL 5000
// ^ Interval DEFAULT (ms) pengiriman data lewat LoRa = 5 detik -- bisa
//   diubah jarak jauh lewat command "set_interval" dari app (dibatasi
//   MIN/MAX_SEND_INTERVAL_MS di bawah), nilai yang berlaku disimpan di NVS.
#define DISPLAY_REFRESH_MS 200
// ^ Interval (ms) refresh layar OLED (kalau terpasang) -- lebih cepat dari
//   SEND_INTERVAL karena update visual sebaiknya terasa mulus di mata,
//   walau data yang dikirim lewat radio tidak sesering itu.

// Body tipe "c" (raw ADC + status kalibrasi kustom, lihat /PROTOCOL.md 1.1)
// dikirim tiap kelipatan ke-N dari sendIntervalMs biasa -- raw hanya
// berguna secara live saat pengguna sedang mengkalibrasi, jadi tidak perlu
// dikirim tiap paket data inti (hemat airtime radio & baterai). Saat mode
// calib_stream aktif (app sedang membuka layar Kalibrasi), body "c"
// dikirim TIAP interval biasa (N efektif = 1) -- lihat main.cpp.
#define CALIB_BROADCAST_EVERY_N 6
// ^ Body "c" (raw+kalibrasi) dikirim 1 dari setiap 6 kali kirim data inti
//   -- menghemat bandwidth radio & energi saat kondisi normal (bukan
//   sedang dikalibrasi).

// Jaga-jaga kalau app gagal mengirim calib_stream{on:false} (mis. app
// ditutup paksa/koneksi putus saat pengguna masih di layar Kalibrasi) --
// mode ini otomatis nonaktif sendiri setelah durasi ini walau tidak ada
// perintah "off" yang diterima, supaya node tidak boros baterai/airtime
// radio mengirim data raw terus-menerus tanpa batas waktu. Setiap kali
// calib_stream{on:true} diterima ulang (mis. app masih dipakai aktif),
// hitung mundur ini di-reset -- lihat main.cpp.
#define CALIB_STREAM_MAX_MS (10UL * 60UL * 1000UL)
// ^ 10 menit dalam milidetik -- ini contoh "fail-safe timeout" yang baik:
//   asumsi jaringan/app TIDAK selalu andal, jadi node punya batas waktu
//   sendiri untuk kembali ke mode hemat energi walau perintah "matikan"
//   dari app tidak pernah sampai.

// --- Kontrol jarak jauh (perintah dari app lewat gateway) ---
#define MIN_SEND_INTERVAL_MS 5000UL
#define MAX_SEND_INTERVAL_MS 300000UL // 5 menit
// ^ Batas atas & bawah yang DIPERBOLEHKAN saat operator mengubah interval
//   kirim lewat command "set_interval" -- mencegah operator (tanpa
//   sengaja/salah input) mengatur interval terlalu cepat (boros baterai &
//   airtime radio, berpotensi melanggar duty cycle regulasi ISM band) atau
//   terlalu lambat (data jadi tidak berguna untuk monitoring).
#define POWER_SAVE_INTERVAL_MS 60000UL
// ^ Interval kirim saat mode "power_save" (dari command jarak jauh)
//   diaktifkan -- 60 detik, jauh lebih jarang dari default 5 detik untuk
//   menghemat baterai signifikan saat monitoring intensif tidak diperlukan.

// Di atas tegangan ini sensor TDS sudah saturasi (hasil pengujian larutan
// garam pekat ~10.800ppm yang mentok di 2.398V) -> bacaan ppm tidak valid.
#define TDS_SATURATION_VOLTS 2.398f
// ^ Nilai ini didapat dari PENGUJIAN EMPIRIS (bukan datasheet teoritis) --
//   baik disebut di sidang sebagai bagian metodologi kalibrasi sensor:
//   nilai konstanta ini bukan angka sembarangan, tapi hasil eksperimen
//   dengan larutan garam berkonsentrasi tinggi untuk menemukan titik
//   saturasi sensor TDS yang dipakai.

// --- Kompensasi suhu TDS ---
// Tabel kalibrasi TDS diukur pada suhu ruang tertentu; bacaan TDS harus
//   dikembalikan ke suhu referensi ini agar konsisten (lihat
//   readTDSSensor() di sensors.cpp).
#define TDS_TEMP_REF_C 25.0f
// ^ Suhu rujukan kalibrasi TDS (°C) -- standar industri adalah 25°C.
#define TDS_TEMP_COEF 0.02f
// ^ Koefisien suhu TDS standar: konduktivitas naik ~2%/°C. Dipakai pada
//   rumus kompensasi ppm_ref = ppm_now / (1 + coef*(T_now - T_ref)).

// ---------------------------------------------------------------------------
// KEAMANAN KANAL LoRa (WAJIB DIBACA)
// ---------------------------------------------------------------------------
// LORA_PSK adalah SATU pre-shared key per pasangan node+gateway. Dari nilai
// ini diturunkan 2 kunci terpisah lewat SHA-256 dengan domain separation
// (lihat lora_security.cpp): kunci AES-128 untuk enkripsi isi paket, dan
// kunci HMAC-SHA256 untuk tanda tangan (encrypt-then-MAC) + anti-replay.
// Detail lengkap format paket ada di /PROTOCOL.md bagian 1.
//
// WAJIB diganti per pasangan gateway+node, HARUS SAMA PERSIS dengan
// LORA_PSK di firmware gateway (iot-gateway-rumah), jangan pernah dipakai
// apa adanya dari repo ini. Generate nilai acak baru dengan:
//   python3 -c "import secrets; print(secrets.token_hex(32))"
#define LORA_PSK "D38A2529E0B8CEA76AD74825FF49FB76E93A29B1939ABE571B0770150CCC07D4"
// ^ PERINGATAN UNTUK SIDANG/PRODUKSI: nilai di baris ini bukan lagi
//   placeholder generik (sudah berupa hex 64 karakter acak), TAPI karena
//   ada di dalam repository/kode sumber yang mungkin dibagikan, nilai ini
//   sebaiknya TETAP dianggap "harus diganti ulang" untuk setiap pasangan
//   node+gateway yang benar-benar dipasang di lapangan (lihat
//   /SECURITY.md poin 1) -- jangan menyalin nilai ini apa adanya ke unit
//   produksi lain.

// Kompilasi GAGAL kalau LORA_PSK masih placeholder di atas -- mencegah
// node ter-flash ke unit sungguhan tanpa sadar memakai kunci contoh yang
// sudah publik di source code ini.
namespace config_guard {
// ^ Namespace terpisah supaya fungsi `same()` di bawah tidak bentrok nama
//   dengan fungsi lain yang mungkin juga bernama "same" di file lain.
constexpr bool same(const char *a, const char *b) {
    // ^ `constexpr` = fungsi ini bisa (dan di sini MEMANG) dievaluasi
    //   SEPENUHNYA saat COMPILE TIME (bukan runtime) -- inilah triknya:
    //   perbandingan string biasa (strcmp) TIDAK bisa dipakai di dalam
    //   static_assert karena static_assert butuh ekspresi yang bisa
    //   dihitung compiler SEBELUM program benar-benar dijalankan.
    return (*a == '\0' && *b == '\0') ? true
         // ^ Base case rekursi: kalau kedua string sudah sampai akhir
         //   (null terminator) bersamaan, berarti seluruh isinya identik.
         : (*a == '\0' || *b == '\0') ? false
         // ^ Kalau HANYA SALAH SATU yang sudah berakhir (panjang beda),
         //   otomatis tidak sama.
         : (*a != *b) ? false
         // ^ Kalau karakter di posisi ini beda, langsung tidak sama
         //   (short-circuit, tidak perlu cek posisi selanjutnya).
         : same(a + 1, b + 1);
         // ^ Kalau karakter ini sama, rekursi maju satu karakter ke
         //   depan (a+1, b+1) untuk membandingkan sisa string.
}
static_assert(!same(LORA_PSK, "GANTI-DENGAN-KUNCI-ACAK-UNIK-SEPASANG-DENGAN-GATEWAY"),
              "LORA_PSK masih nilai placeholder -- ganti dulu (harus sama persis dengan gateway)!");
// ^ static_assert : pemeriksaan yang dijalankan COMPILER, bukan saat
//   firmware berjalan di ESP32 -- kalau kondisi di dalamnya FALSE, PROSES
//   KOMPILASI GAGAL TOTAL (tidak menghasilkan file .bin sama sekali),
//   dengan pesan error yang ada di argumen kedua. Di sini, kondisinya
//   adalah "LORA_PSK TIDAK SAMA DENGAN string placeholder" (`!same(...)`)
//   -- kalau developer lupa mengganti LORA_PSK dari nilai contoh generik
//   di atas, kompilasi akan gagal dengan pesan jelas, MENCEGAH firmware
//   dengan kunci placeholder ter-upload ke perangkat sungguhan sama sekali.
}

#endif
