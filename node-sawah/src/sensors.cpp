#include "sensors.h"
#include "config.h"
#include "calibration.h"
#include <math.h>
// Header C standar untuk fabs() (nilai mutlak untuk float, dipakai di
//   applyFilter di bawah -- beda dari abs() yang untuk integer).

Adafruit_ADS1115 ads;
// Definisi SUNGGUHAN dari variabel global `ads` yang dideklarasikan
//   `extern` di sensors.h -- objek driver ADC eksternal.
XPowersLibInterface *power = nullptr;
// Pointer ke driver PMIC (chip manajemen daya) -- dimulai nullptr,
//   baru diisi (atau tetap nullptr kalau gagal) di initBatteryMonitor()
//   di bawah. Dipakai pointer (bukan objek langsung) karena XPowersLib
//   punya beberapa VARIAN chip (interface sama, implementasi beda) --
//   `XPowersLibInterface*` adalah pointer ke kelas dasar abstrak,
//   sementara objek sungguhan yang dibuat (di bawah) adalah
//   `XPowersAXP2101` -- pola polymorphism C++ standar.

// Variabel dideklarasikan di sini agar bisa diakses seluruh fungsi di file ini
static bool motionEventLatched = false;
// "Latch" (kait) -- sekali diset true oleh readPIRSensor(), TETAP true
//   sampai ada yang membacanya lewat consumeMotionEvent() (yang otomatis
//   mereset ke false) -- pola ini memastikan kejadian gerakan singkat
//   TIDAK TERLEWAT walau fungsi pembacanya kebetulan tidak dipanggil
//   PERSIS di saat gerakan terjadi (mis. loop() sedang sibuk mengerjakan
//   hal lain sesaat).

// Raw ADC mentah dari pembacaan read*Sensor() terakhir -- lihat komentar
// lastTdsRaw()/lastForkRaw()/lastCapRaw() di sensors.h.
static int g_lastTdsRaw = 0;
static int g_lastForkRaw = 0;
static int g_lastCapRaw = 0;
// Prefix "g_" (konvensi umum untuk "variabel global") -- di-cache di
//   sini setiap kali read*Sensor() dipanggil, dibaca lagi lewat
//   fungsi last*Raw() tanpa perlu membaca ADC ulang (lihat sensors.h).

static int stablePercent[3] = {0, 0, 0};
static bool stablePercentInitialized[3] = {false, false, false};
// Array berindeks channel (0=TDS, 1=Fork, 2=Capacitive) -- menyimpan
//   state INTERNAL algoritma "stabilisasi persentase" di bawah, terpisah
//   per sensor supaya histeresis satu sensor tidak memengaruhi sensor lain.

static int applyPercentStability(uint8_t ch, int value) {
    // Algoritma "smoothing" TAMBAHAN, khusus untuk nilai PERSENTASE hasil
    //   akhir (Fork & Capacitive) -- terpisah dari applyFilter() di bawah
    //   yang bekerja di level RAW ADC. Tujuannya: mencegah angka persen
    //   yang ditampilkan di app "gemetar naik-turun 1-2%" terus-menerus
    //   walau kondisi tanah sebenarnya stabil, TAPI tetap bisa mengejar
    //   perubahan besar (mis. tanah baru disiram) dengan cukup responsif.
    if (!stablePercentInitialized[ch]) {
        // Pemanggilan PERTAMA untuk channel ini -- langsung terima nilai
        //   apa adanya sebagai titik awal, tidak ada "riwayat" untuk
        //   dibandingkan.
        stablePercent[ch] = value;
        stablePercentInitialized[ch] = true;
        return value;
    }
    int delta = value - stablePercent[ch];
    // Selisih antara nilai baru dari sensor dengan nilai STABIL yang
    //   SEDANG ditampilkan/dipakai saat ini.
    if (abs(delta) < SENSOR_STABLE_DEADBAND) {
        // Kalau selisihnya KECIL (di bawah deadband, config.h: 2),
        //   abaikan -- anggap noise, TIDAK mengubah nilai stabil sama
        //   sekali (mencegah "gemetar" 1% terus-menerus).
        return stablePercent[ch];
    }
    int step = (abs(delta) > 15) ? 5 : SENSOR_STABLE_STEP;
    // Tentukan "langkah" pergerakan maksimum per pemanggilan: kalau
    //   selisihnya BESAR (>15%, mis. tanah baru disiram/dicabut sensornya),
    //   pakai langkah lebih besar (5%) supaya mengejar lebih cepat; kalau
    //   selisihnya sedang-sedang saja, pakai langkah kecil dari config.h
    //   (SENSOR_STABLE_STEP = 3%) -- ini "adaptive step size", bukan step
    //   tetap, sehingga sensor tetap RESPONSIF untuk perubahan besar tapi
    //   tetap HALUS untuk fluktuasi kecil.
    stablePercent[ch] += (delta > 0) ? min(step, delta) : max(-step, delta);
    // Gerakkan nilai stabil MAKSIMAL sejumlah `step` menuju nilai baru
    //   (tidak langsung melompat ke nilai baru) -- kalau delta lebih kecil
    //   dari step, cukup gerakkan sejumlah delta saja (supaya tidak
    //   "overshoot"/melewati nilai target).
    return stablePercent[ch];
}

// CATATAN HARDWARE (bukan bug kode, tapi penting dicek secara fisik):
// TTGO T-Beam punya beberapa revisi board dengan chip power management
// (PMIC) yang BERBEDA -- T-Beam v1.1 memakai AXP2101 (yang dipakai di
// bawah), sementara T-Beam v0.7/v1.0 (lebih lama) memakai AXP192. Kalau
// board fisikmu ternyata revisi lama, power->init() akan GAGAL TERUS
// (dicetak "AXP2101 not detected" ke Serial, lalu battery monitor
// nonaktif) -- readBatteryVoltage()/readBatteryPercent() akan selalu
// mengembalikan 0V/0% walau baterai sehat, TANPA gejala lain yang
// mencurigakan. Kalau kamu melihat baterai selalu 0% padahal baterai baru,
// cek dulu revisi board T-Beam-mu (biasanya tertulis di PCB) sebelum
// mengira ada bug di firmware.
// CATATAN INI SANGAT BAIK untuk disebut di sidang sebagai contoh
//   "keterbatasan yang diketahui & didokumentasikan" (known limitation)
//   -- menunjukkan kesadaran developer akan variasi hardware di lapangan,
//   dan mendokumentasikannya secara eksplisit alih-alih membiarkan orang
//   lain kebingungan mencari "bug" yang sebenarnya adalah ketidakcocokan
//   revisi board.
void initBatteryMonitor() {
    if (!power) {
        // Hanya coba inisialisasi kalau `power` masih nullptr --
        //   mencegah pembuatan objek berulang kalau fungsi ini somehow
        //   dipanggil lebih dari sekali.
        power = new XPowersAXP2101(Wire, I2C_SDA, I2C_SCL);
        // Alokasi dinamis (new) -- SATU-SATUNYA alokasi dinamis di
        //   seluruh modul sensor ini (dibanding buffer statis di modul
        //   lain), dilakukan HANYA SEKALI di awal (bukan berulang di
        //   loop()), jadi risiko fragmentasi memori minim.
        if (!power->init()) {
            Serial.println("AXP2101 not detected");
            delete power;
            // Bersihkan memori yang sudah dialokasikan kalau
            //   inisialisasi gagal -- mencegah memory leak.
            power = nullptr;
            // Kembalikan ke nullptr -- SEMUA fungsi baterai lain di
            //   bawah (readBatteryRaw dkk) mengecek `power &&
            //   power->isBatteryConnect()` sebelum memakainya, jadi
            //   dengan power == nullptr, fungsi-fungsi itu akan aman
            //   mengembalikan 0 / 0.0f, TIDAK crash (null pointer
            //   dereference).
        }
    }
}

static void sortSamples(int16_t *samples, uint8_t count) {
    // Insertion sort sederhana -- algoritma sortir yang cocok untuk
    //   ARRAY KECIL (di sini cuma ADS_SAMPLE_COUNT = 8 elemen), lebih
    //   ringan/sederhana kodenya dibanding quicksort/mergesort untuk
    //   ukuran sekecil ini, dan tidak butuh memori tambahan (in-place).
    for (uint8_t i = 1; i < count; i++) {
        int16_t key = samples[i];
        int8_t j = i - 1;
        while (j >= 0 && samples[j] > key) {
            samples[j + 1] = samples[j];
            j--;
        }
        samples[j + 1] = key;
    }
    // Hasil akhir: array `samples` terurut MENAIK -- dipakai getAvg() di
    //   bawah untuk membuang nilai ekstrem (outlier) sebelum dirata-rata.
}

struct SensorFilter {
    float value;      // Nilai hasil filter SAAT INI (yang "dipercaya").
    bool initialized; // Sudah pernah menerima sampel pertama atau belum.
};

static SensorFilter filters[3] = {{0.0f, false}, {0.0f, false}, {0.0f, false}};
// Satu filter EMA (Exponential Moving Average) TERPISAH per channel
//   (0=TDS, 1=Fork, 2=Capacitive) -- konsisten dengan pola array
//   ber-index-channel yang sama seperti stablePercent[] di atas.

static float applyFilter(uint8_t ch, float raw) {
    // Filter low-pass eksponensial DENGAN deadband & adaptive alpha --
    //   bekerja di level RAW ADC (SEBELUM dipetakan ke persen/ppm),
    //   berbeda dari applyPercentStability() yang bekerja di level HASIL
    //   AKHIR (persen) -- keduanya dipakai BERSAMAAN untuk Fork &
    //   Capacitive (dua lapis smoothing), sementara TDS hanya memakai
    //   applyFilter() saja (karena hasilnya berupa ppm, bukan persen
    //   yang perlu histeresis serupa).
    if (!filters[ch].initialized) {
        filters[ch].value = raw;
        filters[ch].initialized = true;
        return filters[ch].value;
    }
    float delta = raw - filters[ch].value;
    float absDelta = fabs(delta);
    if (absDelta < SENSOR_FILTER_DEADBAND) {
        // Perubahan raw yang sangat kecil (di bawah 8.0, config.h)
        //   dianggap noise ADC, diabaikan sepenuhnya -- nilai filter
        //   TIDAK bergerak sama sekali.
        return filters[ch].value;
    }
    float alpha = (absDelta > 40.0f) ? SENSOR_FILTER_ALPHA_FAST : SENSOR_FILTER_ALPHA;
    // Sama seperti applyPercentStability(): adaptive -- perubahan besar
    //   (>40 unit raw ADC) memakai alpha lebih besar (0.45, respons
    //   lebih cepat), perubahan sedang memakai alpha standar (0.22,
    //   respons lebih halus/lambat).
    filters[ch].value += delta * alpha;
    // Rumus EMA standar: nilai_baru = nilai_lama + alpha * (raw -
    //   nilai_lama) -- setara dengan: nilai_baru = alpha*raw +
    //   (1-alpha)*nilai_lama, yaitu rata-rata berbobot antara sampel baru
    //   dan riwayat sebelumnya.
    return filters[ch].value;
}

static int mapSensorRawToPercent(int raw, int dryRaw, int wetRaw, int maxPercent) {
    // Fungsi GENERIK pemetaan raw ADC -> persentase, dipakai BAIK untuk
    //   Fork maupun Capacitive (parameter dryRaw/wetRaw/maxPercent beda
    //   sesuai kalibrasi masing-masing sensor) -- menghindari duplikasi
    //   logika pemetaan yang sama persis di dua tempat.
    int clamped = constrain(raw, wetRaw, dryRaw);
    // `constrain(x, lo, hi)` fungsi bawaan Arduino: batasi `raw` supaya
    //   tidak kurang dari wetRaw & tidak lebih dari dryRaw -- MENCEGAH
    //   hasil map() di bawah menghasilkan persentase di luar rentang
    //   0-maxPercent akibat raw yang sedikit melebihi titik kalibrasi
    //   (mis. karena noise sensor sesaat).
    if (dryRaw <= wetRaw) return 0;
    // Validasi jaga-jaga: dryRaw SEHARUSNYA selalu > wetRaw (raw ADC
    //   makin besar = makin kering, sesuai karakteristik sensor ini) --
    //   kalau titik kalibrasi yang disimpan pengguna ternyata TERBALIK/
    //   rusak (mis. akibat kesalahan input di app), fungsi ini
    //   mengembalikan 0 alih-alih menghasilkan angka aneh (persentase
    //   negatif/di luar akal, atau pembagian dengan nol implisit di
    //   dalam map() Arduino).
    return constrain(map(clamped, dryRaw, wetRaw, 0, maxPercent), 0, maxPercent);
    // `map()` bawaan Arduino: pemetaan LINEAR dari rentang [dryRaw,
    //   wetRaw] ke rentang [0, maxPercent] -- perhatikan urutan dryRaw
    //   SEBELUM wetRaw (bukan wetRaw dulu) karena raw besar (dryRaw)
    //   harus memetakan ke persen KECIL (0%, kering=sedikit air) dan raw
    //   kecil (wetRaw) memetakan ke persen BESAR (maxPercent%, basah).
    //   Hasil map() dibungkus constrain() SEKALI LAGI sebagai pengaman
    //   ekstra (map() Arduino bisa sedikit melampaui batas akibat
    //   pembulatan integer).
}

static int mapForkToConductivityIndex(int raw) {
    // calibForkDryRaw()/calibForkWetRaw() mengembalikan titik kalibrasi
    // kustom pengguna (kalau pernah disimpan lewat app), atau nilai bawaan
    // FORK_SENSOR_DRY_RAW/WET_RAW dari config.h kalau belum -- lihat
    // calibration.h.
    int percent = mapSensorRawToPercent(raw, calibForkDryRaw(), calibForkWetRaw(), FORK_SENSOR_MAX_PERCENT);
    return constrain(percent - FORK_SENSOR_BASELINE_OFFSET, 0, 100);
    // Setelah pemetaan generik di atas, sensor Fork MASIH mendapat
    //   penyesuaian TAMBAHAN: dikurangi FORK_SENSOR_BASELINE_OFFSET
    //   (config.h: 15) -- kalibrasi sekunder EMPIRIS khusus sensor ini,
    //   kemungkinan supaya skala akhirnya "terasa" lebih sesuai dengan
    //   kondisi tanah sungguhan di lapangan (mis. hasil pemetaan linear
    //   murni terasa terlalu tinggi dibanding kondisi kering yang
    //   dirasakan langsung di sawah).
}

int getAvg(uint8_t ch) {
    int16_t samples[ADS_SAMPLE_COUNT];
    for (int i = 0; i < ADS_SAMPLE_COUNT; i++) {
        samples[i] = ads.readADC_SingleEnded(ch);
        // Baca 1 sampel ADC mentah dari channel `ch` (single-ended =
        //   tegangan relatif terhadap ground, bukan diferensial).
        delayMicroseconds(ADS_SAMPLE_DELAY_US);
        // Jeda singkat (200 mikrodetik) antar-sampel, config.h.
    }
    sortSamples(samples, ADS_SAMPLE_COUNT);
    int discard = max(1, ADS_SAMPLE_COUNT / 4);
    // Buang 1/4 sampel TERKECIL & 1/4 sampel TERBESAR (minimal 1 kalau
    //   ADS_SAMPLE_COUNT kecil) -- ini teknik "trimmed mean"/rata-rata
    //   terpangkas, MENGHINDARI pengaruh outlier ekstrem (mis. lonjakan
    //   noise sesaat) yang bisa mendistorsi rata-rata biasa.
    int count = ADS_SAMPLE_COUNT - (discard * 2);
    // Sisa sampel yang benar-benar dipakai untuk rata-rata (mis. dari 8
    //   sampel, buang 2 terkecil + 2 terbesar = sisa 4 yang dirata-rata).
    long sum = 0;
    // `long` (bukan int) untuk akumulator jumlah -- mencegah overflow
    //   kalau ADS_SAMPLE_COUNT besar & nilai ADC besar (walau untuk 8
    //   sampel int biasa sebenarnya sudah cukup, ini praktik defensif).
    for (int i = discard; i < ADS_SAMPLE_COUNT - discard; i++) {
        sum += samples[i];
        // Hanya menjumlahkan sampel di TENGAH array yang sudah terurut
        //   (melewati `discard` sampel pertama & berhenti sebelum
        //   `discard` sampel terakhir).
    }
    return (int)(sum / count);
}

// Status kesehatan ADS1115. Lihat sensorsAdcOk() di sensors.h: kalau chip
// ADC tidak terdeteksi, SEMUA pembacaan analog adalah sampah dan HARUS
// dilaporkan sebagai `null` ke app -- bukan angka yang terlihat wajar.
static bool g_adsOk = false;
static unsigned long g_adsLastRetryMs = 0;
#define ADS_RETRY_INTERVAL_MS 30000UL
// Coba deteksi ulang tiap 30 detik saja -- cukup cepat untuk pulih
//   otomatis dari gangguan sesaat, tapi tidak membanjiri bus I2C.

bool sensorsAdcOk() { return g_adsOk; }

void sensorsRetryAdc() {
    if (g_adsOk) return; // sudah sehat, tidak perlu apa-apa
    unsigned long now = millis();
    if (now - g_adsLastRetryMs < ADS_RETRY_INTERVAL_MS) return;
    // Pengurangan unsigned ini AMAN terhadap millis() overflow (~49 hari):
    //   hasilnya tetap benar karena aritmetika unsigned membungkus (wrap).
    g_adsLastRetryMs = now;
    if (ads.begin(ADS1115_ADDR)) {
        ads.setGain(GAIN_ONE);
        // Gain WAJIB di-set ulang setelah begin() yang berhasil -- tanpa
        //   ini chip kembali ke gain default (+/-6.144V) dan SEMUA titik
        //   kalibrasi di TDS_CALIB_TABLE (yang diukur pada GAIN_ONE) jadi
        //   salah skala tanpa gejala yang kelihatan.
        g_adsOk = true;
        Serial.println("ADS1115 pulih: pembacaan analog kembali valid.");
    }
}

void initSensors() {
    g_adsOk = ads.begin(ADS1115_ADDR);
    if (!g_adsOk) {
        Serial.println("ERROR: ADS1115 not found on I2C bus");
        Serial.println("  -> TDS/fork/capacitive akan dikirim sebagai null (tidak valid),");
        Serial.println("     dan node mencoba deteksi ulang tiap 30 detik lewat sensorsRetryAdc().");
        // SEBELUMNYA: kegagalan ini HANYA dicetak lalu kode lanjut
        //   memanggil ads.readADC_SingleEnded() seolah tidak terjadi apa-apa,
        //   sehingga node mengirim angka sampah TERUS-MENERUS tanpa ada cara
        //   bagi pengguna untuk tahu dari app. Sekarang statusnya direkam di
        //   g_adsOk supaya main.cpp bisa melaporkannya sebagai `null`, dan
        //   ada mekanisme retry seperti yang sudah dipunyai LoRa.
    }
    ads.setGain(GAIN_ONE);
    // Set gain ADC ke 1x (rentang input +/-4.096V) -- dipilih sesuai
    //   rentang tegangan output sensor-sensor analog yang dipakai (fork,
    //   capacitive, TDS semuanya menghasilkan tegangan dalam rentang ini).
    pinMode(PIR_PIN, INPUT);
    initBatteryMonitor();
}

// ==== Tabel hasil kalibrasi TDS BAWAAN/DEFAULT (raw ADC -> ppm) ====
// Diambil dari pengukuran manual pakai larutan garam dapur yang diencerkan
// bertahap. Kurva sensor ini terbukti nonlinear (melengkung, makin datar
// di ppm tinggi), sehingga dipakai interpolasi per-segmen (piecewise),
// bukan 1 rumus garis lurus.
//
// Tabel ini HANYA dipakai kalau pengguna belum pernah menyimpan kalibrasi
// kustom (2 titik) lewat app -- lihat calibration.h calibSetTds() &
// interpolateTdsPpm() di bawah. Kalibrasi kustom bisa dihapus lagi kapan
// saja dari app untuk kembali memakai tabel bawaan ini.
struct TdsCalibPoint {
    int raw;
    float ppm;
};

static const TdsCalibPoint TDS_CALIB_TABLE[] = {
    {304,   0.0f},
    {3840,  50.0f},
    {8486,  100.0f},
    {11360, 231.0f},
    {17344, 498.0f},
};
// 5 titik referensi HASIL PENGUJIAN EMPIRIS (bukan rumus teoritis dari
//   datasheet) -- baik disebut secara eksplisit di sidang sebagai bagian
//   metodologi kalibrasi sensor: nilai-nilai ini didapat dengan
//   mencelupkan sensor ke larutan garam dapur pada konsentrasi berbeda-
//   beda & mencatat raw ADC yang dihasilkan untuk tiap konsentrasi
//   (ppm) yang sudah diketahui/dihitung.
static const int TDS_CALIB_POINTS = sizeof(TDS_CALIB_TABLE) / sizeof(TDS_CALIB_TABLE[0]);
// Idiom C/C++ umum untuk menghitung JUMLAH ELEMEN array secara otomatis
//   dari ukuran total dibagi ukuran satu elemen -- kalau baris data tabel
//   di atas ditambah/dikurangi di kemudian hari, angka ini otomatis
//   ikut menyesuaikan tanpa perlu diubah manual (menghindari bug "lupa
//   update angka N" kalau tabel diedit).

// Interpolasi linear 2 titik kalibrasi KUSTOM milik pengguna (kalau pernah
// disimpan lewat app, lihat calibration.h calibSetTds()). Sama seperti
// ekstrapolasi di bawah titik pertama / di atas titik terakhir pada tabel
// bawaan: di luar rentang 2 titik ini, hasil di-ekstrapolasi lurus pakai
// slope yang sama (kasar, tapi lebih baik daripada terpotong).
static float interpolateTdsPpmCustom(int raw) {
    float raw0 = calibTdsRaw0(), ppm0 = calibTdsPpm0();
    float raw1 = calibTdsRaw1(), ppm1 = calibTdsPpm1();
    if (raw1 == raw0) return ppm0; // jaga-jaga pembagian nol kalau data rusak
    // Kalau kedua titik kalibrasi kustom kebetulan sama persis (mis.
    //   kesalahan input pengguna: menekan "simpan" dua kali tanpa
    //   mengubah posisi probe), `slope` di bawah akan melibatkan
    //   pembagian dengan nol -- dicegah di sini dengan early return.

    float slope = (ppm1 - ppm0) / (raw1 - raw0);
    // Kemiringan garis lurus antara 2 titik (raw0,ppm0) & (raw1,ppm1) --
    //   rumus dasar interpolasi/ekstrapolasi linear: y = y0 + slope*(x-x0).
    float ppm = ppm0 + slope * ((float)raw - raw0);
    return (ppm < 0.0f) ? 0.0f : ppm;
    // Hasil ppm TIDAK PERNAH dibiarkan negatif (dibatasi minimum 0) --
    //   nilai ppm negatif tidak masuk akal secara fisik.
}

// Interpolasi linear antar 2 titik kalibrasi terdekat pada tabel BAWAAN
// (TDS_CALIB_TABLE). Di bawah titik pertama atau di atas titik terakhir,
// hasil di-ekstrapolasi pakai slope segmen ujung terdekat (kasar, tapi
// lebih baik daripada terpotong). Dipanggil hanya kalau pengguna belum
// pernah menyimpan kalibrasi kustom (lihat interpolateTdsPpm() di bawah).
static float interpolateTdsPpmDefault(int raw) {
    if (raw <= TDS_CALIB_TABLE[0].raw) {
        // KASUS 1: raw di BAWAH titik pertama tabel -- ekstrapolasi
        //   memakai kemiringan segmen PERTAMA (antara titik 0 dan 1).
        const TdsCalibPoint &p0 = TDS_CALIB_TABLE[0];
        const TdsCalibPoint &p1 = TDS_CALIB_TABLE[1];
        float slope = (p1.ppm - p0.ppm) / (float)(p1.raw - p0.raw);
        float ppm = p0.ppm + slope * (raw - p0.raw);
        return (ppm < 0.0f) ? 0.0f : ppm;
    }

    if (raw >= TDS_CALIB_TABLE[TDS_CALIB_POINTS - 1].raw) {
        // KASUS 2: raw di ATAS titik TERAKHIR tabel -- ekstrapolasi
        //   memakai kemiringan segmen TERAKHIR (antara titik ke-(N-2) dan
        //   ke-(N-1)).
        const TdsCalibPoint &p0 = TDS_CALIB_TABLE[TDS_CALIB_POINTS - 2];
        const TdsCalibPoint &p1 = TDS_CALIB_TABLE[TDS_CALIB_POINTS - 1];
        float slope = (p1.ppm - p0.ppm) / (float)(p1.raw - p0.raw);
        return p1.ppm + slope * (raw - p1.raw);
        // CATATAN: khusus kasus ini, tidak ada clamp `< 0.0f -> 0.0f`
        //   seperti dua kasus lain -- kemungkinan karena secara logika
        //   ekstrapolasi ke ATAS (raw makin besar) hasilnya juga makin
        //   BESAR (ppm makin tinggi), jadi risiko hasil negatif di sini
        //   pada praktiknya sangat kecil/tidak realistis.
    }

    for (int i = 0; i < TDS_CALIB_POINTS - 1; i++) {
        // KASUS 3 (paling umum): raw berada DI ANTARA titik pertama &
        //   terakhir -- cari SEGMEN mana (antara titik ke-i & ke-(i+1))
        //   yang mengapit nilai raw ini, lalu interpolasi LINIER hanya
        //   dalam segmen itu (bukan satu garis lurus untuk seluruh
        //   rentang -- inilah "piecewise"/interpolasi per-segmen yang
        //   disebut di komentar header, mengakomodasi kurva sensor yang
        //   melengkung/nonlinear secara keseluruhan).
        const TdsCalibPoint &p0 = TDS_CALIB_TABLE[i];
        const TdsCalibPoint &p1 = TDS_CALIB_TABLE[i + 1];
        if (raw >= p0.raw && raw <= p1.raw) {
            float slope = (p1.ppm - p0.ppm) / (float)(p1.raw - p0.raw);
            return p0.ppm + slope * (raw - p0.raw);
        }
    }

    return 0.0f; // fallback, seharusnya tidak pernah sampai sini
    // Baris ini SECARA LOGIKA tidak akan pernah tercapai (dua kondisi
    //   if di atas + loop for sudah mencakup SELURUH kemungkinan nilai
    //   raw), tapi tetap ditulis eksplisit -- praktik yang baik di C++:
    //   compiler mensyaratkan fungsi non-void punya return value di
    //   SEMUA jalur eksekusi yang mungkin (secara sintaksis), walau
    //   secara logika jalur ini mustahil tercapai.
}

// Dipanggil oleh readTDSSensor(): pakai kalibrasi kustom pengguna (2 titik)
// kalau pernah disimpan lewat app, atau tabel bawaan (5 titik) kalau belum
// -- lihat calibration.h.
static float interpolateTdsPpm(int raw) {
    if (calibTdsIsCustom()) return interpolateTdsPpmCustom(raw);
    return interpolateTdsPpmDefault(raw);
}

int lastTdsRaw() { return g_lastTdsRaw; }
int lastForkRaw() { return g_lastForkRaw; }
int lastCapRaw() { return g_lastCapRaw; }

// Forward declaration: kedua fungsi ini didefinisikan DI BAWAH (setelah
// readTDSSensor), tapi readTDSSensor() memanggil readWaterTemperatureC(),
// yang pada gilirannya memanggil readAxpTemperatureC(). Tanpa deklarasi
// awal ini, compiler (yang membaca dari atas ke bawah) akan melaporkan
// "not declared in this scope" saat menemukan pemanggilan di readTDSSensor().
float readWaterTemperatureC();
float readAxpTemperatureC();

float readTDSSensor() {
    float raw = applyFilter(0, (float)getAvg(0));
    // Channel 0 = sensor TDS -- baca rata-rata trimmed (getAvg), lalu
    //   haluskan lagi lewat filter EMA (applyFilter).
    g_lastTdsRaw = (int)raw;
    // Simpan raw HASIL FILTER (bukan raw ADC mentah sebelum filter) ke
    //   cache -- inilah nilai yang dikirim ke app sebagai "tds_raw".
    float volts = ads.computeVolts((int)raw);
    // Konversi raw ADC ke satuan Volt (dipakai untuk cek saturasi di
    //   bawah, bukan untuk perhitungan ppm langsung).

    // Sensor sudah saturasi (di luar rentang yang tervalidasi ~0-500ppm),
    // bacaan ppm tidak lagi bisa dipercaya -> tandai dengan nilai sentinel.
    if (volts >= TDS_SATURATION_VOLTS) {
        return 999.0f;
        // "Sentinel value" -- angka yang SECARA KONVENSI berarti "tidak
        //   valid/di luar jangkauan", bukan pembacaan ppm sungguhan.
        //   App/server yang menerima nilai 999.0 di field ini HARUS tahu
        //   konvensi ini (didokumentasikan di /PROTOCOL.md) untuk
        //   menampilkannya secara berbeda (mis. "saturasi"), bukan
        //   sebagai angka ppm biasa.
    }

    float ppm = interpolateTdsPpm((int)raw);
    // ppm hasil interpolasi tabel kalibrasi -- tabel ini diukur pada
    //   suhu ruang referensi TDS (lihat TDS_TEMP_REF_C di bawah), jadi
    //   angka ini BELUM dikompensasi suhu air saat ini.

    // --- KOMPENSASI SUHU TDS ---
    // Konduktivitas larutan (dan karena itu estimasi TDS) bergantung suhu
    //   secara signifikan: naik ~2%/°C (koefisien TDS standar, TDS_TEMP_COEF
    //   di bawah). Tanpa kompensasi, bacaan TDS meleset saat suhu air beda
    //   dari suhu kalibrasi -- padahal spec sensor menyebut operasi 5-50°C.
    //   Rumus kompensasi ke suhu referensi:
    //     ppm_ref = ppm_now / (1 + coef * (T_now - T_ref))
    //   (pembagi > 1 saat T_now > T_ref, karena TDS terbaca LEBIH TINGGI
    //   pada suhu panas, jadi dibagi untuk mengembalikan ke nilai rujuk).
    const float t = readWaterTemperatureC();
    if (t > -20.0f && t < 80.0f) {  // jaga dari suhu tidak wajar (sensor rusak)
        ppm = ppm / (1.0f + TDS_TEMP_COEF * (t - TDS_TEMP_REF_C));
        if (ppm < 0.0f) ppm = 0.0f;
    }
    return ppm;
}

// Suhu air untuk kompensasi TDS. Secara default memakai suhu DIE INTERNAL
//   PMIC AXP2101 (readAxpTemperatureC) -- ini APPROKSIMASI: chip berada di
//   board dekat baterai, BUKAN di air, jadi cuma mendekati suhu air dalam
//   keadaan tenang/lambat. Untuk akurasi tinggi, pasang PROBE SUHU AIR
//   (DS18B20/NTC) dan definisikan fungsi `externalWaterTemperatureC()` --
//   karena ditandai `weak`, definisi itu AKAN MENGGANTIKAN default ini
//   OTOMATIS tanpa perlu mengubah kode di sini (pola weak symbol).
float readWaterTemperatureC() __attribute__((weak));
float readWaterTemperatureC() {
    return readAxpTemperatureC();
}

// Suhu dari PMIC AXP2101 (chip manajemen daya bawaan T-Beam). Mengembalikan
//   suhu dalam °C, atau TDS_TEMP_REF_C (suhu ruang kalibrasi) kalau PMIC
//   tidak tersedia/tidak valid -- supaya kompensasi tetap netral (faktor 1).
float readAxpTemperatureC() {
    if (power && power->isBatteryConnect()) {
        // `power` bertipe XPowersLibInterface* (kelas dasar abstrak), tapi
        // method getTemperature() hanya ada di kelas turunan XPowersAXP2101
        // (objek yang dibuat di initBatteryMonitor()). Karena itu kita
        // static_cast ke XPowersAXP2101* supaya compiler mengenali member
        // getTemperature() -- cast aman karena kita SUDAH cek `power`
        // tidak nullptr & isBatteryConnect() di atas.
        float t = static_cast<XPowersAXP2101*>(power)->getTemperature();
        if (t > -40.0f && t < 125.0f) return t;  // rentang wajar AXP2101
    }
    return TDS_TEMP_REF_C;
}

int readForkSensor() {
    int raw = (int)applyFilter(1, (float)getAvg(1));
    // Channel 1 = sensor Fork.
    g_lastForkRaw = raw;
    return applyPercentStability(1, mapForkToConductivityIndex(raw));
    // Alur LENGKAP: getAvg (trimmed mean) -> applyFilter (EMA level
    //   raw) -> mapForkToConductivityIndex (raw->persen dengan
    //   kalibrasi+offset) -> applyPercentStability (histeresis level
    //   persen) -- DUA LAPIS smoothing berbeda diterapkan berurutan.
}

int readCapacitiveSensor() {
    int raw = (int)applyFilter(2, (float)getAvg(2));
    // Channel 2 = sensor Capacitive.
    g_lastCapRaw = raw;
    // calibCapDryRaw()/calibCapWetRaw() mengembalikan titik kalibrasi
    // kustom pengguna (kalau ada) atau nilai bawaan config.h kalau belum.
    int moisturePercent = mapSensorRawToPercent(raw, calibCapDryRaw(), calibCapWetRaw(), CAPACITIVE_SENSOR_MAX_PERCENT);
    return applyPercentStability(2, moisturePercent);
    // Alur sama seperti Fork, TAPI TANPA offset baseline tambahan
    //   (mapForkToConductivityIndex punya `- FORK_SENSOR_BASELINE_OFFSET`
    //   sementara di sini langsung memakai hasil mapSensorRawToPercent
    //   apa adanya) -- perbedaan ini konsisten dengan karakteristik fisik
    //   sensor yang berbeda (lihat komentar FORK_SENSOR_BASELINE_OFFSET
    //   di config.h).
}

bool readPIRSensor() {
    static bool pirLastRawState = false;
    static bool pirStableState = false;
    static unsigned long pirLastTransitionMs = 0;
    // `static` LOKAL di dalam fungsi (bukan namespace/file) -- nilainya
    //   bertahan antar-pemanggilan fungsi ini (tidak direset tiap
    //   dipanggil), tapi hanya BISA diakses dari dalam fungsi ini sendiri
    //   (lebih terenkapsulasi dibanding variabel static di scope file).
    bool raw = digitalRead(PIR_PIN) == HIGH;
    unsigned long now = millis();
    if (raw != pirLastRawState) {
        // Sinyal PIN berubah dibanding pembacaan MENTAH sebelumnya --
        //   berpotensi jadi transisi status (gerak<->diam), tapi perlu
        //   dicek debounce dulu di bawah.
        if (pirLastTransitionMs == 0 || (now - pirLastTransitionMs) >= PIR_DEBOUNCE_MS) {
            // HANYA terima perubahan status kalau sudah cukup lama
            //   (>=1200ms, config.h) sejak transisi STABIL terakhir --
            //   mencegah PIR yang "flicker"/berkedip cepat akibat noise
            //   elektrik dianggap sebagai banyak kejadian gerakan
            //   terpisah.
            pirLastRawState = raw;
            pirStableState = raw;
            pirLastTransitionMs = now;
        }
        // Kalau BELUM cukup lama sejak transisi terakhir, perubahan
        //   sinyal mentah ini DIABAIKAN sepenuhnya -- pirStableState
        //   TIDAK berubah, dan pirLastRawState pun TIDAK diupdate (jadi
        //   perubahan sinyal mentah berikutnya masih dibandingkan dengan
        //   raw state SEBELUM percobaan transisi yang ditolak ini).
    } else {
        pirLastTransitionMs = now;
        // CATATAN: baris ini di-update SETIAP KALI sinyal raw SAMA
        //   dengan sebelumnya (bukan hanya saat transisi) -- efeknya,
        //   `pirLastTransitionMs` sebenarnya berfungsi sebagai "waktu
        //   observasi/pengecekan terakhir", bukan murni "waktu transisi
        //   terakhir" secara harfiah. Ini detail implementasi yang agak
        //   halus/berpotensi membingungkan pembaca kode -- baik
        //   didiskusikan di sidang sebagai contoh nuansa debouncing yang
        //   perlu ekstra hati-hati saat membaca ulang kodenya sendiri.
    }
    if (pirStableState) motionEventLatched = true;
    // Setiap kali status stabil menunjukkan "sedang gerak", pastikan
    //   latch ter-set (lihat consumeMotionEvent()) -- walau fungsi ini
    //   dipanggil berkali-kali selama gerakan berlangsung, latch cuma
    //   perlu di-set true (idempotent, aman diulang).
    return pirStableState;
}

bool consumeMotionEvent() {
    bool triggered = motionEventLatched;
    motionEventLatched = false;
    // "Consume" -- baca nilai lalu LANGSUNG reset ke false, memastikan
    //   kejadian gerakan yang sama tidak dilaporkan dua kali ke pemanggil
    //   berikutnya (lihat penjelasan pola latch di atas file).
    return triggered;
}

int readBatteryRaw() {
    if (power && power->isBatteryConnect()) return (int)power->getBattVoltage();
    // Selalu cek `power` TIDAK nullptr DULU (short-circuit && akan
    //   berhenti di sini kalau power == nullptr, TIDAK memanggil
    //   power->isBatteryConnect() yang akan crash kalau dipanggil lewat
    //   pointer null) -- pola pengaman yang konsisten di seluruh fungsi
    //   baterai, langsung berkat initBatteryMonitor() yang menjamin
    //   `power` SELALU nullptr kalau memang gagal inisialisasi.
    return 0;
}

float readBatteryVoltage() {
    if (power && power->isBatteryConnect()) {
        uint16_t mv = power->getBattVoltage();
        // Nilai dari library PMIC dalam satuan milivolt (integer).
        if (mv > 0) {
            float volts = mv / 1000.0f;
            return (volts >= BATTERY_MIN_VALID_VOLTAGE) ? volts : 0.0f;
            // Lapis validasi TAMBAHAN: walau PMIC melaporkan tegangan
            //   > 0, kalau hasilnya di bawah BATTERY_MIN_VALID_VOLTAGE
            //   (0.5V, config.h), dianggap TIDAK VALID (kemungkinan
            //   baterai lepas/rusak, bukan baterai yang benar-benar
            //   ber-tegangan sangat rendah) -- dikembalikan 0.0f sebagai
            //   sinyal "data tidak dapat dipercaya", bukan angka
            //   sungguhan yang menyesatkan.
        }
    }
    return 0.0f;
}

int readBatteryPercent() {
    float voltage = readBatteryVoltage();
    if (voltage <= BATTERY_LOW_VOLTAGE) return 0;
    if (voltage >= BATTERY_FULL_VOLTAGE) return 100;
    return (int)constrain(((voltage - BATTERY_LOW_VOLTAGE) / (BATTERY_FULL_VOLTAGE - BATTERY_LOW_VOLTAGE)) * 100.0f, 0.0f, 100.0f);
    // Interpolasi linear sederhana antara BATTERY_LOW_VOLTAGE (3.0V=0%)
    //   dan BATTERY_FULL_VOLTAGE (4.2V=100%) -- catatan: ini APROKSIMASI
    //   KASAR, karena kurva discharge baterai Li-ion/Li-Po SEBENARNYA
    //   tidak linear (tegangan turun cepat di awal & akhir, landai di
    //   tengah) -- tapi cukup untuk indikasi kasar "baterai lemah/penuh"
    //   pada aplikasi monitoring seperti ini, tidak perlu presisi tinggi
    //   seperti perangkat konsumen (HP, dst) yang punya "fuel gauge IC"
    //   khusus.
}

void calibrationPrint() {
    int16_t raw = ads.readADC_SingleEnded(1); // channel 1 = fork sensor
    float volts = ads.computeVolts(raw);
    Serial.printf("FORK raw=%d  volts=%.3f\n", raw, volts);
    // Fungsi DEBUG murni: baca ADC LANGSUNG (bukan lewat getAvg/filter)
    //   & cetak ke Serial -- dipakai developer saat menentukan titik
    //   kalibrasi (dryRaw/wetRaw) secara MANUAL via kabel USB, sebelum
    //   fitur kalibrasi lewat app tersedia/sebagai alat bantu tambahan.
}

void calibrationPrintCap() {
    int16_t raw = ads.readADC_SingleEnded(2); // channel 2 = capacitive sensor
    float volts = ads.computeVolts(raw);
    Serial.printf("CAP raw=%d  volts=%.3f\n", raw, volts);
}

// Debug PIR: bandingkan sinyal mentah (langsung dari pin, tanpa debounce)
// dengan status setelah debounce, supaya bisa dilihat apakah "stuck di gerak"
// disebabkan sinyal mentah yang memang HIGH terus, atau debounce yang terlalu lama.
void debugPrintPir() {
    bool raw = digitalRead(PIR_PIN) == HIGH;
    bool stable = readPIRSensor(); // ini juga meng-update motionEventLatched seperti biasa
    // CATATAN: memanggil readPIRSensor() di sini punya EFEK SAMPING
    //   sungguhan (bisa men-set motionEventLatched) -- fungsi debug ini
    //   BUKAN cuma "melihat" tanpa mengubah apa pun, ia tetap berperan
    //   penuh dalam alur normal pembacaan PIR, hanya SEKALIGUS mencetak
    //   info tambahan ke Serial untuk keperluan debugging.
    Serial.printf("PIR raw=%s  stable=%s\n", raw ? "GERAK" : "diam", stable ? "GERAK" : "diam");
}

void calibrationPrintTds() {
    int16_t raw = ads.readADC_SingleEnded(0); // channel 0 = TDS sensor
    float volts = ads.computeVolts(raw);

    if (volts >= TDS_SATURATION_VOLTS) {
        Serial.printf("TDS raw=%d  volts=%.3f  ppm=SATURASI (di luar rentang kalibrasi)\n", raw, volts);
        return;
    }

    float ppm = interpolateTdsPpm(raw);
    Serial.printf("TDS raw=%d  volts=%.3f  ppm=%.2f\n", raw, volts, ppm);
}
