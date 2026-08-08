#ifndef DEVICE_IDENTITY_H
#define DEVICE_IDENTITY_H
#include <Arduino.h>

// Identitas gateway di server (device_id + device_secret untuk menandatangani request HTTP, lihat /PROTOCOL.md 2.1). Disimpan di NVS, diisi lewat app Flutter saat provisioning atau nilai awal config.h.
// KEAMANAN: device_secret disimpan PLAINTEXT di NVS (bukan hash) karena skema HMAC butuh secret asli tiap request, bukan sekadar cocok-hash seperti password login.

void deviceIdentityBegin();
// Muat device_id/secret/server_url dari NVS ke RAM; kalau belum ada, pakai default config.h.

String currentDeviceId();
String currentSecret();
String currentServerBaseUrl();
// Getter dipakai http_client.cpp untuk header auth & URL tiap httpIngest().

// Dipanggil saat command "rekey" dari respons /api/ingest. Hanya secret yang diganti (device_id tetap). Simpan ke NVS lalu restart. Tepercaya karena datang lewat TLS + HMAC.
void applyRekey(const String &newSecret);
// Aman tanpa verifikasi tambahan: rekey datang dari respons request gateway sendiri yang sudah lewat TLS & HMAC dengan secret lama.

// Dipanggil dari wifi_provision.cpp saat app mengirim provisioning lengkap. Simpan ke NVS tanpa restart (restart dilakukan wifi_provision setelah semua field tersimpan).
void saveIdentityFromProvisioning(const String &deviceId, const String &secret,
                                   const String &serverBaseUrl);

// Hapus SELURUH identitas device & secret LoRa dari NVS. Dipakai reset total (tombol fisik/command "factory_reset") agar gateway balik ke keadaan baru.
void clearAllIdentity();
// Tidak restart sendiri (berbeda dari applyRekey) karena dipanggil sebagai bagian provisioning yang di-restart sekali oleh wifi_provision setelah semua data tersimpan.

#endif
