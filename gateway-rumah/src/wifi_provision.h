#ifndef WIFI_PROVISION_H
#define WIFI_PROVISION_H
#include <Arduino.h>

// Modul WiFi + identitas provisioning. Tujuannya: SSID/password WiFi & identitas device tidak perlu hardcode di config.h.
// Semua disimpan di NVS. Saat belum ada WiFi tersimpan/koneksi gagal, gateway masuk MODE SETUP (buka AP "Gateway-Setup-<DEVICE_ID>" + web server 192.168.4.1). App Flutter mengirim semua field lewat POST /configure, gateway simpan & restart.
// Pola "SoftAP": ESP32 sementara jadi AP sendiri — umum untuk IoT tanpa layar. Pengguna tak perlu flash ulang untuk ganti WiFi/pindah rumah.
// Endpoint saat setup (http://192.168.4.1): GET /status, GET /scan, POST /configure (body ssid,password,device_id,device_secret,server_url; field identitas boleh kosong = pertahankan yang lama). Balas {"ok":true} lalu restart.
// KEAMANAN: endpoint setup tanpa HTTPS/auth karena HANYA aktif saat setup & hanya bisa diakses perangkat terhubung ke AP gateway (dilindungi AP_SETUP_PASSWORD_FALLBACK), bukan internet luas.
// Tombol reset WiFi (WIFI_RESET_BUTTON_PIN): tahan saat boot untuk hapus kredensial WiFi & masuk mode setup (identitas device tidak ikut terhapus).

// Panggil sekali di setup(). True kalau WiFi berhasil (lanjut initLoRaGateway dkk); false kalau mode setup (cukup panggil wifiProvisionLoop() di loop()).
bool wifiProvisionBegin();
// Nilai balik menentukan cabang main.cpp: true -> inisialisasi normal; false -> hanya wifiProvisionLoop().

// Panggil terus di loop() SELAMA mode setup. Aman dipanggil kapan saja.
void wifiProvisionLoop();
// Menangani request web server setup (GET /status, GET /scan, POST /configure) — pola non-blocking.

// True selama gateway dalam mode setup (AP aktif, belum konek WiFi asli).
bool wifiProvisionIsActive();
// Dipakai main.cpp memilih cabang loop(): kalau true, HANYA wifiProvisionLoop() (tugas normal dilewati).

// Dipanggil saat command "wifi_update" dari server — beda dari /configure (butuh HP di AP setup): ini dipakai gateway yang MASIH online lewat WiFi lama mau pindah jaringan baru. Simpan & restart; kalau gagal, otomatis jatuh ke mode setup.
void applyWifiUpdate(const String &ssid, const String &password);
// Resiliensi: perubahan jarak jauh berisiko salah SSID/password tetap punya fallback AP fisik, gateway tak pernah terkunci permanen.

#endif
