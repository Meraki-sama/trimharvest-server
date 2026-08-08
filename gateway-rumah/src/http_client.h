#ifndef HTTP_CLIENT_H
#define HTTP_CLIENT_H
#include <Arduino.h>
#include <ArduinoJson.h>

// Klien HTTP ke Server Node.js (API Gateway, lihat /PROTOCOL.md 2). Gateway HANYA bicara ke server ini, menandatangani tiap request dengan HMAC-SHA256 pakai device_secret (tanpa menyimpan kredensial server).
// ARSITEKTUR: gateway hanya simpan device_secret yang berlaku untuk device_id-nya sendiri (blast radius kecil), server-lah yang menegakkan otorisasi ke database.

// Panggil sekali setelah WiFi tersambung (SEBELUM httpIngest()). Memulai sinkron NTP (dibutuhkan untuk timestamp tanda tangan request).
void initHttpClient();
// ESP32 tak punya RTC akurat; waktu mulai dari epoch tiap boot. NTP wajib sebelum request pertama atau server menolak timestamp salah.

// True kalau waktu sudah tersinkron NTP. httpIngest() gagal cepat selama false (tidak kirim request yang pasti ditolak).
bool isTimeSynced();
// Gagal cepat lokal: kalau tahu request pasti ditolak, lebih baik tidak mengirimnya.

// Kirim bodyDoc (lihat /PROTOCOL.md 2.2; jangan isi "seq" sendiri) ke POST /api/ingest, ditandatangani HMAC. True kalau server 200 OK; outResponse berisi JSON respons (termasuk "commands" kalau ada).
// outHttpCode mengembalikan kode status HTTP mentah dari server (200, 401, dll) -- dipakai caller untuk mendeteksi 401 (device dihapus di server) guna memicu reset WiFi.
bool httpIngest(JsonDocument &bodyDoc, JsonDocument &outResponse, int &outHttpCode);
// Fungsi inti: isi "seq" otomatis, susun header X-Device-Id/X-Timestamp/X-Signature, POST HTTPS, parse respons ke outResponse (via referensi).

#endif
