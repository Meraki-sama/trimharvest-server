#include "calibration.h"
#include "config.h"
#include <Preferences.h>

namespace {
// ^ Anonymous namespace -- semua di dalamnya cuma terlihat di file ini
//   (lihat penjelasan sama di lora_security.cpp).

Preferences prefs;
const char *PREF_NAMESPACE = "sensor_calib";
// ^ Namespace NVS TERPISAH ("sensor_calib") dari yang dipakai
//   lora_security.cpp ("lora_sec") -- walau sama-sama pakai NVS flash,
//   data kalibrasi & data keamanan LoRa disimpan di "folder" yang
//   berbeda, tidak saling tumpang tindih.

// Kunci NVS. "*_has" adalah flag bool eksplisit penanda "pengguna pernah
// menyimpan kalibrasi kustom untuk sensor ini" -- dibuat terpisah (bukan
// menyimpulkan dari nilai 0) supaya raw ADC 0 yang sah (kalau memang
// pernah terjadi) tidak disalahartikan sebagai "belum dikalibrasi".
const char *KEY_FORK_HAS = "fork_has";
const char *KEY_FORK_DRY = "fork_dry";
const char *KEY_FORK_WET = "fork_wet";

const char *KEY_CAP_HAS = "cap_has";
const char *KEY_CAP_DRY = "cap_dry";
const char *KEY_CAP_WET = "cap_wet";

const char *KEY_TDS_HAS = "tds_has";
const char *KEY_TDS_RAW0 = "tds_raw0";
const char *KEY_TDS_PPM0 = "tds_ppm0";
const char *KEY_TDS_RAW1 = "tds_raw1";
const char *KEY_TDS_PPM1 = "tds_ppm1";
// ^ Total 3 kelompok kunci NVS, satu untuk tiap sensor yang bisa
//   dikalibrasi -- pola nama key mengikuti prefix sensor + apa yang
//   disimpan (has/dry/wet untuk Fork&Cap, has/raw0/ppm0/raw1/ppm1 untuk TDS).

// Semua nilai di-cache di RAM saat initCalibration() supaya pembacaan
// sensor yang berjalan tiap SENSOR_SAMPLE_MS (250ms) tidak perlu buka NVS
// berulang-ulang -- NVS/flash jauh lebih lambat & lebih baik tidak ditulis
// terlalu sering, tapi cukup cepat untuk DIBACA sekali di boot.
struct CalibCache {
    // ^ Satu struct yang menampung SEMUA nilai kalibrasi (3 sensor
    //   sekaligus) di RAM -- fungsi calib*() di bawah membaca dari struct
    //   ini (operasi RAM, sangat cepat), TIDAK langsung dari NVS setiap
    //   kali dipanggil.
    bool forkHas = false;
    int forkDry = FORK_SENSOR_DRY_RAW;
    int forkWet = FORK_SENSOR_WET_RAW;
    // ^ Nilai INISIALISASI DEFAULT struct ini langsung memakai konstanta
    //   dari config.h -- kalau initCalibration() nanti TERNYATA tidak
    //   menemukan kalibrasi kustom di NVS (forkHas tetap false), nilai
    //   default inilah yang otomatis dipakai TANPA perlu logika if/else
    //   tambahan (praktik yang bersih: default value langsung di
    //   deklarasi struct).

    bool capHas = false;
    int capDry = CAPACITIVE_SENSOR_DRY_RAW;
    int capWet = CAPACITIVE_SENSOR_WET_RAW;

    bool tdsHas = false;
    float tdsRaw0 = 0, tdsPpm0 = 0, tdsRaw1 = 0, tdsPpm1 = 0;
    // ^ TDS TIDAK punya nilai default dari config.h di sini -- karena
    //   kalau tdsHas == false, sensors.cpp memakai TDS_CALIB_TABLE bawaan
    //   (kurva 5 titik) secara TERPISAH, bukan lewat 2 titik (raw,ppm)
    //   seperti struct ini (lihat komentar di calibration.h).
};

CalibCache cache;
// ^ Satu instance global (tapi terbatas ke file ini berkat anonymous
//   namespace) dari struct di atas -- inilah "state" sesungguhnya yang
//   dibaca-tulis oleh seluruh fungsi publik modul kalibrasi ini.

} // namespace

void initCalibration() {
    prefs.begin(PREF_NAMESPACE, false);
    // ^ Buka namespace NVS "sensor_calib" mode baca-tulis.

    cache.forkHas = prefs.getBool(KEY_FORK_HAS, false);
    // ^ Baca flag "pernah dikalibrasi" -- default false kalau key belum
    //   pernah ada (node baru/pertama kali).
    if (cache.forkHas) {
        // ^ HANYA baca dryRaw/wetRaw dari NVS kalau memang pernah
        //   dikalibrasi -- kalau tidak, cache.forkDry/forkWet TETAP
        //   memakai nilai default dari inisialisasi struct di atas
        //   (tidak perlu dibaca ulang, sudah benar sejak awal).
        cache.forkDry = prefs.getInt(KEY_FORK_DRY, FORK_SENSOR_DRY_RAW);
        cache.forkWet = prefs.getInt(KEY_FORK_WET, FORK_SENSOR_WET_RAW);
    }

    cache.capHas = prefs.getBool(KEY_CAP_HAS, false);
    if (cache.capHas) {
        cache.capDry = prefs.getInt(KEY_CAP_DRY, CAPACITIVE_SENSOR_DRY_RAW);
        cache.capWet = prefs.getInt(KEY_CAP_WET, CAPACITIVE_SENSOR_WET_RAW);
    }
    // ^ Pola identik dengan Fork di atas, untuk sensor Capacitive.

    cache.tdsHas = prefs.getBool(KEY_TDS_HAS, false);
    if (cache.tdsHas) {
        cache.tdsRaw0 = prefs.getFloat(KEY_TDS_RAW0, 0);
        cache.tdsPpm0 = prefs.getFloat(KEY_TDS_PPM0, 0);
        cache.tdsRaw1 = prefs.getFloat(KEY_TDS_RAW1, 0);
        cache.tdsPpm1 = prefs.getFloat(KEY_TDS_PPM1, 0);
    }
    // ^ Pola sama, tapi 4 nilai float (2 pasang raw+ppm) untuk TDS.
}

// --- Fork ---
int calibForkDryRaw() { return cache.forkDry; }
int calibForkWetRaw() { return cache.forkWet; }
bool calibForkIsCustom() { return cache.forkHas; }
// ^ Tiga "getter" sederhana -- cuma membaca dari cache RAM, TIDAK
//   menyentuh NVS sama sekali (cepat, aman dipanggil sesering apa pun,
//   termasuk di siklus baca sensor tiap 250ms).

void calibSetFork(int dryRaw, int wetRaw) {
    cache.forkHas = true;
    cache.forkDry = dryRaw;
    cache.forkWet = wetRaw;
    // ^ Update cache RAM DULU -- supaya pembacaan sensor BERIKUTNYA
    //   (bisa terjadi dalam hitungan milidetik) langsung memakai nilai
    //   baru, TANPA harus menunggu operasi tulis NVS di bawah selesai.
    prefs.putBool(KEY_FORK_HAS, true);
    prefs.putInt(KEY_FORK_DRY, dryRaw);
    prefs.putInt(KEY_FORK_WET, wetRaw);
    // ^ BARU setelah cache RAM diupdate, tulis juga ke NVS supaya nilai
    //   ini PERSISTEN (bertahan setelah restart/mati listrik) -- dipanggil
    //   saat perintah "calib_set_fork" diterima dari app lewat main.cpp.
}

void calibClearFork() {
    cache.forkHas = false;
    cache.forkDry = FORK_SENSOR_DRY_RAW;
    cache.forkWet = FORK_SENSOR_WET_RAW;
    // ^ Kembalikan cache RAM ke nilai DEFAULT dari config.h.
    prefs.putBool(KEY_FORK_HAS, false);
    prefs.remove(KEY_FORK_DRY);
    prefs.remove(KEY_FORK_WET);
    // ^ `prefs.remove()` (bukan sekadar putInt dengan 0) -- benar-benar
    //   MENGHAPUS key dari NVS, bukan menimpanya dengan nilai lain. Kalau
    //   suatu saat initCalibration() membaca lagi, getInt() akan
    //   memberikan nilai DEFAULT-nya sendiri (parameter kedua getInt)
    //   karena key-nya memang sudah tidak ada.
}

// --- Capacitive ---
// (pola identik dengan grup Fork di atas, hanya beda sensor & nama key)
int calibCapDryRaw() { return cache.capDry; }
int calibCapWetRaw() { return cache.capWet; }
bool calibCapIsCustom() { return cache.capHas; }

void calibSetCap(int dryRaw, int wetRaw) {
    cache.capHas = true;
    cache.capDry = dryRaw;
    cache.capWet = wetRaw;
    prefs.putBool(KEY_CAP_HAS, true);
    prefs.putInt(KEY_CAP_DRY, dryRaw);
    prefs.putInt(KEY_CAP_WET, wetRaw);
}

void calibClearCap() {
    cache.capHas = false;
    cache.capDry = CAPACITIVE_SENSOR_DRY_RAW;
    cache.capWet = CAPACITIVE_SENSOR_WET_RAW;
    prefs.putBool(KEY_CAP_HAS, false);
    prefs.remove(KEY_CAP_DRY);
    prefs.remove(KEY_CAP_WET);
}

// --- TDS ---
// (pola sama, tapi menyimpan 2 pasang titik (raw, ppm) alih-alih
// dry/wet -- lihat penjelasan perbedaan skema kalibrasi TDS di calibration.h)
bool calibTdsIsCustom() { return cache.tdsHas; }
float calibTdsRaw0() { return cache.tdsRaw0; }
float calibTdsPpm0() { return cache.tdsPpm0; }
float calibTdsRaw1() { return cache.tdsRaw1; }
float calibTdsPpm1() { return cache.tdsPpm1; }

void calibSetTds(float raw0, float ppm0, float raw1, float ppm1) {
    cache.tdsHas = true;
    cache.tdsRaw0 = raw0;
    cache.tdsPpm0 = ppm0;
    cache.tdsRaw1 = raw1;
    cache.tdsPpm1 = ppm1;
    prefs.putBool(KEY_TDS_HAS, true);
    prefs.putFloat(KEY_TDS_RAW0, raw0);
    prefs.putFloat(KEY_TDS_PPM0, ppm0);
    prefs.putFloat(KEY_TDS_RAW1, raw1);
    prefs.putFloat(KEY_TDS_PPM1, ppm1);
}

void calibClearTds() {
    cache.tdsHas = false;
    // ^ CATATAN KECIL: berbeda dari calibClearFork/calibClearCap yang
    //   juga mengembalikan cache.*Dry/*Wet ke nilai default eksplisit,
    //   di sini cache.tdsRaw0/ppm0/raw1/ppm1 TIDAK direset ke 0 secara
    //   eksplisit -- tapi ini tidak masalah secara fungsional, karena
    //   sensors.cpp HANYA membaca nilai-nilai ini kalau calibTdsIsCustom()
    //   bernilai true (sudah false di sini), jadi nilai lama yang masih
    //   "menempel" di cache tidak akan pernah terpakai lagi sampai
    //   calibSetTds() dipanggil ulang.
    prefs.putBool(KEY_TDS_HAS, false);
    prefs.remove(KEY_TDS_RAW0);
    prefs.remove(KEY_TDS_PPM0);
    prefs.remove(KEY_TDS_RAW1);
    prefs.remove(KEY_TDS_PPM1);
}
