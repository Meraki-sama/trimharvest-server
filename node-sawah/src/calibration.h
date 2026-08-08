#ifndef CALIBRATION_H
#define CALIBRATION_H
#include <Arduino.h>

// ---------------------------------------------------------------------------
// Modul Kalibrasi Sensor (Fork/konduktivitas, Capacitive/kelembaban tanah,
// TDS) -- supaya pengguna bisa mengkalibrasi sendiri lewat app, TANPA perlu
// edit config.h & flash ulang firmware.
//
// Kenapa cuma 3 sensor ini yang dikalibrasi lewat software:
//  - Sensor Fork & Capacitive: pembacaannya "mentah" (raw ADC 0-2 titik
//    referensi kering/basah), jadi kalibrasi 2 titik lewat app sangat
//    berguna (tiap probe & tanah punya karakteristik listrik sedikit
//    berbeda).
//  - Sensor TDS: kurva bawaan (lihat TDS_CALIB_TABLE di sensors.cpp) hasil
//    pengujian larutan garam dapur -- kalibrasi 2 titik pakai larutan
//    referensi yang PPM-nya sudah diketahui (mis. larutan kalibrasi TDS
//    yang dijual, atau diukur pakai TDS meter terpisah) akan lebih akurat
//    untuk kondisi air/tanah spesifik lokasi kamu.
//  - Sensor PIR TIDAK disertakan di sini: sensitivitas & delay PIR diatur
//    lewat 2 potensiometer FISIK di modulnya sendiri (lihat spesifikasi
//    PIR), bukan lewat firmware/ADC, jadi tidak ada apa pun yang bisa
//    dikalibrasi lewat app untuk sensor ini.
//
// Alur pakai dari app:
//  1. Firmware SELALU menyertakan raw ADC (fork_raw, cap_raw, tds_raw) di
//     tiap payload data sensor yang dikirim (lihat main.cpp sendSensorData()),
//     jadi app bisa menampilkan angka raw ini secara live saat pengguna
//     menempatkan probe di kondisi referensi (mis. kering di udara, atau
//     dicelup ke air/larutan referensi).
//  2. Pengguna menekan tombol di app untuk "mengambil" raw saat ini sebagai
//     salah satu titik kalibrasi, mengulanginya untuk titik ke-2, lalu
//     tekan Simpan -- app mengirim perintah "calib_set_fork" / "calib_set_cap"
//     / "calib_set_tds" (lewat gateway, seperti perintah kontrol lain) berisi
//     titik-titik itu.
//  3. Firmware menyimpan titik kalibrasi ke NVS (flash) lewat modul ini,
//     dan LANGSUNG dipakai mulai pembacaan berikutnya (tidak perlu restart).
//  4. Nilai bawaan (#define di config.h / TDS_CALIB_TABLE di sensors.cpp)
//     TETAP ADA sebagai fallback -- dipakai otomatis kalau belum pernah ada
//     kalibrasi kustom, dan dipakai LAGI kalau pengguna menghapus kalibrasi
//     kustomnya (perintah "calib_clear") kapan saja lewat app.
//
// CATATAN TEKNIS: "NVS" (Non-Volatile Storage) adalah area flash ESP32
// yang KHUSUS untuk menyimpan data kecil secara persisten (bertahan
// walau device mati/restart) -- berbeda dari RAM biasa yang isinya
// hilang setiap kali device di-reset/mati listrik. Ini yang membuat
// kalibrasi kustom pengguna tidak hilang setelah node di-restart/
// baterai habis.
// ---------------------------------------------------------------------------

// Panggil sekali di setup(), SEBELUM initSensors() dipakai untuk membaca
// sensor (supaya nilai kalibrasi kustom -- kalau ada -- langsung terpakai
// sejak pembacaan pertama).
void initCalibration();
// Membuka namespace NVS milik modul kalibrasi & memuat titik kalibrasi
//   kustom (kalau pernah disimpan sebelumnya) ke variabel di memori
//   -- urutan pemanggilan di setup() PENTING (harus sebelum initSensors())
//   supaya calibForkDryRaw() dkk di bawah sudah mengembalikan nilai yang
//   benar sejak awal, bukan nilai default yang salah sesaat.

// --- Fork (sensor tanah garpu / indeks konduktivitas) ---
// Kalau belum pernah dikalibrasi kustom, mengembalikan nilai bawaan dari
// config.h (FORK_SENSOR_DRY_RAW/FORK_SENSOR_WET_RAW).
int calibForkDryRaw();
int calibForkWetRaw();
// Nilai raw ADC titik referensi "kering" & "basah" yang SEDANG DIPAKAI
//   (baik itu kustom hasil kalibrasi pengguna, atau default dari config.h)
//   -- inilah yang benar-benar dipakai readForkSensor() (sensors.cpp) untuk
//   memetakan raw ADC ke persentase.
bool calibForkIsCustom();
// True kalau pengguna PERNAH mengkalibrasi sensor ini secara kustom
//   (dipakai app untuk menampilkan status "sudah dikalibrasi" vs "masih
//   pakai nilai bawaan").
void calibSetFork(int dryRaw, int wetRaw);
// Simpan titik kalibrasi BARU ke variabel memori DAN ke NVS (persisten)
//   -- dipanggil saat perintah "calib_set_fork" diterima dari app.
void calibClearFork();
// Hapus kalibrasi kustom, KEMBALI memakai nilai default config.h --
//   dipanggil saat perintah "calib_clear" diterima.

// --- Capacitive (sensor kelembaban tanah kapasitif) ---
int calibCapDryRaw();
int calibCapWetRaw();
bool calibCapIsCustom();
void calibSetCap(int dryRaw, int wetRaw);
void calibClearCap();
// Pasangan fungsi identik perannya dengan grup Fork di atas, tapi untuk
//   sensor Capacitive -- disimpan & dimuat sebagai pasangan titik
//   kalibrasi terpisah (tidak saling memengaruhi kalibrasi Fork).

// --- TDS (kalibrasi 2 titik: raw ADC <-> ppm larutan referensi) ---
// Kalau belum pernah dikalibrasi kustom, sensors.cpp memakai
// TDS_CALIB_TABLE bawaan (interpolasi 5 titik) seperti sebelumnya.
bool calibTdsIsCustom();
float calibTdsRaw0();
float calibTdsPpm0();
float calibTdsRaw1();
float calibTdsPpm1();
// TDS memakai representasi kalibrasi BERBEDA dari Fork/Capacitive:
//   bukan cuma "raw kering/basah", tapi DUA PASANG (raw, ppm) -- karena
//   yang dikalibrasi adalah HUBUNGAN raw ADC dengan nilai ppm larutan
//   referensi yang SUDAH DIKETAHUI ppm-nya sebelumnya (bukan sekadar
//   "titik ekstrem kering/basah" seperti sensor kelembaban tanah).
void calibSetTds(float raw0, float ppm0, float raw1, float ppm1);
void calibClearTds();

#endif
