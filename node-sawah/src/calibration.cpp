#include "calibration.h"
#include "config.h"
#include <Preferences.h>

namespace {
// Semua simbol di bawah hanya terlihat dalam file ini (namespace anonim).
Preferences prefs;
const char *PREF_NAMESPACE = "sensor_calib";
// Namespace NVS terpisah dari "lora_sec" agar data kalibrasi tak tumpang tindih dengan data keamanan.

// Flag "*_has" menandai apakah pengguna pernah menyimpan kalibrasi kustom,
// sehingga raw 0 yang sah tak disalahartikan sebagai "belum dikalibrasi".
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
// Tiga grup kunci NVS (satu per sensor) dengan pola nama prefix + jenis nilai.

// Nilai di-cache di RAM saat init agar pembacaan tiap 250ms tak perlu baca NVS berulang.
struct CalibCache {
    // Struct ini menampung semua nilai kalibrasi di RAM; fungsi calib*() membaca dari sini.
    bool forkHas = false;
    int forkDry = FORK_SENSOR_DRY_RAW;
    int forkWet = FORK_SENSOR_WET_RAW;
    // Default langsung dari config.h: bila tak ada kalibrasi kustom, nilai ini otomatis terpakai.

    bool capHas = false;
    int capDry = CAPACITIVE_SENSOR_DRY_RAW;
    int capWet = CAPACITIVE_SENSOR_WET_RAW;

    bool tdsHas = false;
    float tdsRaw0 = 0, tdsPpm0 = 0, tdsRaw1 = 0, tdsPpm1 = 0;
    // TDS tak punya default di sini; bila tdsHas==false, sensors.cpp pakai TDS_CALIB_TABLE.
};

CalibCache cache;
// Instance global (terbatas file ini) yang menyimpan state kalibrasi sesungguhnya.
} // namespace

void initCalibration() {
    prefs.begin(PREF_NAMESPACE, false);
    // Buka namespace NVS "sensor_calib" mode baca-tulis.

    cache.forkHas = prefs.getBool(KEY_FORK_HAS, false);
    // Baca flag "pernah dikalibrasi"; default false bila key belum ada.
    if (cache.forkHas) {
        // Hanya baca dry/wet dari NVS bila memang pernah dikalibrasi;
        // bila tidak, cache tetap pakai default struct.
        cache.forkDry = prefs.getInt(KEY_FORK_DRY, FORK_SENSOR_DRY_RAW);
        cache.forkWet = prefs.getInt(KEY_FORK_WET, FORK_SENSOR_WET_RAW);
    }

    cache.capHas = prefs.getBool(KEY_CAP_HAS, false);
    if (cache.capHas) {
        cache.capDry = prefs.getInt(KEY_CAP_DRY, CAPACITIVE_SENSOR_DRY_RAW);
        cache.capWet = prefs.getInt(KEY_CAP_WET, CAPACITIVE_SENSOR_WET_RAW);
    }
    // Pola identik dengan Fork, untuk sensor Capacitive.

    cache.tdsHas = prefs.getBool(KEY_TDS_HAS, false);
    if (cache.tdsHas) {
        cache.tdsRaw0 = prefs.getFloat(KEY_TDS_RAW0, 0);
        cache.tdsPpm0 = prefs.getFloat(KEY_TDS_PPM0, 0);
        cache.tdsRaw1 = prefs.getFloat(KEY_TDS_RAW1, 0);
        cache.tdsPpm1 = prefs.getFloat(KEY_TDS_PPM1, 0);
    }
    // Pola sama, namun 4 nilai float (2 pasang raw+ppm) untuk TDS.
}

// --- Fork ---
int calibForkDryRaw() { return cache.forkDry; }
int calibForkWetRaw() { return cache.forkWet; }
bool calibForkIsCustom() { return cache.forkHas; }
// Getter sederhana yang membaca cache RAM (cepat, aman dipanggil tiap 250ms).

void calibSetFork(int dryRaw, int wetRaw) {
    cache.forkHas = true;
    cache.forkDry = dryRaw;
    cache.forkWet = wetRaw;
    // Update cache RAM dulu agar pembacaan berikutnya langsung pakai nilai baru.
    prefs.putBool(KEY_FORK_HAS, true);
    prefs.putInt(KEY_FORK_DRY, dryRaw);
    prefs.putInt(KEY_FORK_WET, wetRaw);
    // Baru tulis ke NVS agar persisten (dipanggil saat perintah calib_set_fork diterima).
}

void calibClearFork() {
    cache.forkHas = false;
    cache.forkDry = FORK_SENSOR_DRY_RAW;
    cache.forkWet = FORK_SENSOR_WET_RAW;
    // Kembalikan cache ke default config.h.
    prefs.putBool(KEY_FORK_HAS, false);
    prefs.remove(KEY_FORK_DRY);
    prefs.remove(KEY_FORK_WET);
    // remove() benar-benar menghapus key, bukan menimpa dengan 0.
}

// --- Capacitive ---
// (pola identik dengan grup Fork, beda sensor & nama key)
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
// (pola sama, menyimpan 2 pasang titik (raw, ppm) alih-alih dry/wet)
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
    // cache.tdsRaw*/ppm* tak direset, tapi tak berdampak karena sensors.cpp
    // hanya memakainya bila calibTdsIsCustom()==true (sudah false di sini).
    prefs.putBool(KEY_TDS_HAS, false);
    prefs.remove(KEY_TDS_RAW0);
    prefs.remove(KEY_TDS_PPM0);
    prefs.remove(KEY_TDS_RAW1);
    prefs.remove(KEY_TDS_PPM1);
}
