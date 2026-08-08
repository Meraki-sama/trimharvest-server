#include "device_identity.h"
#include "config.h"

#include <Preferences.h>

namespace {

Preferences prefs;
const char *PREF_NAMESPACE = "device_cfg";
const char *KEY_DEVICE_ID = "device_id";
const char *KEY_SECRET = "secret";
const char *KEY_SERVER_URL = "server_url";
// Namespace NVS "device_cfg" -- TERPISAH dari "lora_sec" (lora_security.cpp)
//   walau sama-sama menyimpan "identitas rahasia" -- device_secret ini
//   untuk autentikasi ke SERVER (HTTPS), sedangkan LORA_PSK (di
//   lora_security.cpp) untuk autentikasi ke NODE (LoRa) -- dua rahasia
//   yang sepenuhnya independen, disimpan di "folder" NVS terpisah.

String cachedDeviceId;
String cachedSecret;
String cachedServerUrl;
// Cache RAM -- dibaca berulang kali oleh http_client.cpp SETIAP kali
//   mengirim request (httpIngest dipanggil berkala tiap HEARTBEAT_INTERVAL_MS
//   atau saat ada data sensor baru), jadi PENTING nilai ini di RAM
//   (cepat), bukan baca NVS setiap kali (lambat).

} // namespace

void deviceIdentityBegin() {
    prefs.begin(PREF_NAMESPACE, false);

    cachedDeviceId = prefs.getString(KEY_DEVICE_ID, "");
    cachedSecret = prefs.getString(KEY_SECRET, "");
    cachedServerUrl = prefs.getString(KEY_SERVER_URL, "");
    // Default "" (string kosong) kalau key belum pernah ada -- dipakai
    //   sebagai penanda "belum pernah di-provisioning" di pengecekan
    //   berikutnya.

    if (cachedDeviceId.isEmpty() || cachedSecret.isEmpty()) {
        // Kalau SALAH SATU dari device_id/secret kosong (unit benar-
        //   benar baru, atau NVS somehow ter-reset sebagian), anggap
        //   BELUM PERNAH di-provisioning sama sekali -- isi keduanya
        //   SEKALIGUS dari config.h (tidak masuk akal punya device_id
        //   tanpa secret atau sebaliknya, jadi keduanya ditimpa bersamaan).
        cachedDeviceId = String(DEVICE_ID);
        cachedSecret = String(DEVICE_SECRET);
        prefs.putString(KEY_DEVICE_ID, cachedDeviceId);
        prefs.putString(KEY_SECRET, cachedSecret);
        Serial.println("Device identity: belum pernah di-provisioning, pakai nilai awal "
                        "dari config.h (kemungkinan besar TIDAK akan lolos autentikasi server "
                        "sampai kamu provisioning lewat app).");
        // Pesan log yang JUJUR & INFORMATIF: developer/operator yang
        //   melihat log ini langsung tahu bahwa gateway BELUM SIAP
        //   berfungsi penuh & apa yang harus dilakukan (provisioning
        //   lewat app) -- bukan sekadar "identity loaded" yang
        //   menyesatkan.
    } else {
        Serial.print("Device identity dimuat dari NVS, device_id: ");
        Serial.println(cachedDeviceId);
        // CATATAN KEAMANAN KECIL: device_secret SENGAJA TIDAK dicetak
        //   ke Serial di sini (hanya device_id yang bukan rahasia) --
        //   mencegah rahasia terekam di log/screen capture Serial
        //   Monitor secara tidak sengaja.
    }

    if (cachedServerUrl.isEmpty()) {
        cachedServerUrl = String(DEFAULT_SERVER_BASE_URL);
        prefs.putString(KEY_SERVER_URL, cachedServerUrl);
        // server_url dicek & diisi TERPISAH dari device_id/secret di
        //   atas (blok if/else sendiri) -- karena secara logis independen:
        //   memungkinkan skenario device_id/secret SUDAH ada (sudah
        //   pernah provisioning) tapi server_url entah kenapa belum
        //   tersimpan (mis. field ini ditambahkan di versi firmware yang
        //   lebih baru dari saat unit pertama kali di-provisioning).
    }
}

String currentDeviceId() { return cachedDeviceId; }
String currentSecret() { return cachedSecret; }
String currentServerBaseUrl() { return cachedServerUrl; }
// Tiga getter sederhana dari cache RAM.

void applyRekey(const String &newSecret) {
    if (newSecret.length() < 16) {
        // Validasi dasar: secret baru dari server HARUS cukup panjang
        //   (server sesungguhnya selalu mengirim 64 karakter hex, lihat
        //   randomToken(32) di server/src/lib/crypto.js -- validasi 16 di
        //   sini jauh lebih longgar, cuma pengaman dasar terhadap data
        //   yang jelas rusak/terlalu pendek untuk jadi kunci HMAC yang
        //   aman, bukan validasi format yang ketat).
        Serial.println("Rekey ditolak: secret baru tidak valid (minimal 16 karakter).");
        return;
    }

    prefs.putString(KEY_SECRET, newSecret);
    // CATATAN: baris ini HANYA menulis ke NVS, TIDAK mengupdate
    //   `cachedSecret` di RAM -- ini AMAN & DISENGAJA karena baris
    //   berikutnya langsung ESP.restart(), dan begitu boot ulang,
    //   deviceIdentityBegin() akan membaca NILAI BARU ini dari NVS ke
    //   cache RAM dari awal -- tidak ada celah waktu di mana cachedSecret
    //   RAM & NVS "tidak sinkron" yang bisa dipakai untuk request apa
    //   pun, karena program langsung restart tanpa sempat memakai
    //   cachedSecret RAM yang sudah basi ini untuk request lain.

    Serial.println("Secret baru (rekey dari server) tersimpan. Restart untuk menerapkan...");
    delay(500);
    // Jeda sebelum restart -- memberi waktu pesan log di atas benar-
    //   benar terkirim lewat Serial (sama seperti pola delay(200) di
    //   handleIncomingCommand() node-sawah sebelum ESP.restart()).
    ESP.restart();
}

void saveIdentityFromProvisioning(const String &deviceId, const String &secret,
                                   const String &serverBaseUrl) {
    if (!deviceId.isEmpty()) prefs.putString(KEY_DEVICE_ID, deviceId);
    if (!secret.isEmpty()) prefs.putString(KEY_SECRET, secret);
    if (!serverBaseUrl.isEmpty()) prefs.putString(KEY_SERVER_URL, serverBaseUrl);
    // Tiga `if` TERPISAH (bukan validasi "semua atau tidak sama
    //   sekali") -- SESUAI dengan yang didokumentasikan di
    //   wifi_provision.h: field yang DIKOSONGKAN oleh app dianggap
    //   "biarkan apa adanya" (mis. hanya mau ganti WiFi, identitas device
    //   lama tetap dipakai), bukan dianggap "hapus nilai lama". CATATAN:
    //   fungsi ini TIDAK mengupdate cache RAM (cachedDeviceId dkk) --
    //   ini AMAN karena (sesuai device_identity.h) proses provisioning
    //   secara keseluruhan SELALU diakhiri wifi_provision.cpp dengan
    //   ESP.restart(), yang akan memuat ulang identitas dari NVS lewat
    //   deviceIdentityBegin() -- pola yang KONSISTEN dengan applyRekey()
    //   di atas.
}

// Hapus SELURUH identitas device (device_id, secret, server_url) dari NVS.
// Dipakai oleh reset total (tombol fisik maupun command "factory_reset")
// supaya gateway balik ke keadaan "baru keluar kotak" -- app Flutter bisa
// memprovisioning ulang dari nol tanpa perlu erase flash manual.
// CATATAN: secret LoRa (LORA_PSK di namespace NVS "lora_sec") juga dihapus
// supaya node tidak bisa lagi bicara ke gateway lama sampai di-pair ulang.
void clearAllIdentity() {
    prefs.remove(KEY_DEVICE_ID);
    prefs.remove(KEY_SECRET);
    prefs.remove(KEY_SERVER_URL);

    // Hapus secret LoRa (dipisah namespace NVS) secara langsung.
    Preferences loraPrefs;
    loraPrefs.begin("lora_sec", false);
    loraPrefs.remove("psk");
    loraPrefs.end();

    // Bersihkan cache RAM supaya tidak ada sisa nilai lama di memori.
    cachedDeviceId = "";
    cachedSecret = "";
    cachedServerUrl = "";

    Serial.println("Identitas device & secret LoRa dihapus (factory reset identitas).");
}
