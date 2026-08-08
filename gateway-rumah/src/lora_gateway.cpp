#include "lora_gateway.h"
#include <LoRa.h>
#include "config.h"
#include "lora_security.h"
// Struktur file ini SANGAT MIRIP dengan node-sawah/src/lora_node.cpp --
//   wajar, karena keduanya menjalankan PERAN RADIO yang setara (kirim +
//   terima lewat LoRa dengan mekanisme keamanan sama), hanya arah kirim/
//   terimanya saling berlawanan (gateway MENGIRIM command/downlink & MENERIMA
//   data sensor/uplink, node sebaliknya).

static bool loraReady = false;
static unsigned long lastLoraRetryMs = 0;
static const unsigned long LORA_RETRY_INTERVAL_MS = 10000UL;
// Pola self-healing radio yang identik dengan node-sawah -- lihat
//   penjelasan lengkap di lora_node.cpp.

static bool tryStartLoRa() {
    LoRa.setPins(LORA_SS, LORA_RST, LORA_DIO0);
    // Pin sesuai wiring gateway (config.h) -- berbeda nomor pin dari
    //   node, tapi API pemanggilannya sama.
    if (!LoRa.begin(LORA_BAND)) {
        return false;
    }
    // WAJIB sama dengan sync word di node (lora_node.cpp) -- kalau beda,
    // paket dari node tidak akan pernah "terdengar" oleh gateway ini.
    // (Ini cuma pemisah channel radio, BUKAN mekanisme keamanan -- keamanan
    // sesungguhnya ada di lora_security.h/.cpp.)
    LoRa.setSyncWord(0xF3);
    return true;
}

void initLoRaGateway() {
    loraSecurityBegin();
    // TIDAK PERNAH blocking kalau gagal (lihat catatan yang sama di
    // lora_node.cpp) -- WiFi/HTTP ke server tetap jalan normal walau LoRa
    // bermasalah, dan ensureLoRaReady() akan otomatis coba sambung ulang.
    // Ini adalah PERBAIKAN GRACEFUL DEGRADATION yang SAMA seperti di
    //   node-sawah, tapi konsekuensinya di sisi GATEWAY sedikit berbeda:
    //   kalau LoRa gagal di sini, gateway MASIH BISA berfungsi sebagai
    //   "pelapor status" ke server (heartbeat lewat HTTP tetap jalan),
    //   hanya saja tidak akan pernah menerima data sensor dari node/
    //   meneruskan command ke node -- desain ini memastikan SATU
    //   subsistem yang bermasalah (radio) tidak melumpuhkan subsistem
    //   LAIN yang independen (koneksi WiFi/HTTP ke server).
    loraReady = tryStartLoRa();
    lastLoraRetryMs = millis();

    if (loraReady) {
        Serial.println("LoRa Gateway Ready.");
    } else {
        Serial.println("LoRa Gateway GAGAL (cek wiring/modul)! Gateway tetap jalan, akan dicoba lagi otomatis.");
    }
}

void ensureLoRaReady() {
    if (loraReady) return;

    unsigned long now = millis();
    if (now - lastLoraRetryMs < LORA_RETRY_INTERVAL_MS) return;
    lastLoraRetryMs = now;

    loraReady = tryStartLoRa();
    if (loraReady) {
        Serial.println("LoRa berhasil tersambung ulang.");
    }
    // Identik dengan versi node -- lihat penjelasan detail di
    //   node-sawah/src/lora_node.cpp.
}

String receiveLoRa() {
    if (!loraReady) return "";

    int packetSize = LoRa.parsePacket();
    if (packetSize <= 0) return "";
    if ((size_t)packetSize > LORA_SEC_MAX_FRAME_LEN) {
        while (LoRa.available()) LoRa.read();
        return "";
        // Sama seperti versi node: buang paket yang jelas bukan format
        //   protokol ini, KOSONGKAN buffer radio supaya tidak mencemari
        //   pembacaan paket berikutnya.
    }

    uint8_t raw[LORA_SEC_MAX_FRAME_LEN];
    int idx = 0;
    while (LoRa.available() && idx < packetSize) {
        raw[idx++] = (uint8_t)LoRa.read();
    }

    uint8_t body[LORA_SEC_MAX_BODY_LEN];
    size_t bodyLen = 0;
    if (!loraSecureUnwrap(raw, (size_t)idx, body, sizeof(body), bodyLen)) {
        Serial.println("LoRa RX ditolak (signature/replay tidak valid, diabaikan).");
        return "";
        // CATATAN PERBEDAAN KECIL dari receiveLoRaCommand() di node:
        //   di SINI (gateway) kegagalan verifikasi TETAP DICATAT ke
        //   Serial log, sedangkan di node kegagalan yang sama DIAM-DIAM
        //   diabaikan tanpa log. Kemungkinan alasannya: gateway biasanya
        //   ditempatkan di rumah dengan akses Serial/USB developer lebih
        //   mudah dijangkau untuk debugging dibanding node yang terpasang
        //   di tengah sawah, jadi log tambahan di sini lebih berguna
        //   praktis tanpa banyak merepotkan.
    }

    String result;
    result.reserve(bodyLen);
    for (size_t i = 0; i < bodyLen; i++) {
        result += (char)body[i];
    }
    return result;
    // Hasil dekripsi (JSON body tipe "r"/"c" dari node) dikembalikan ke
    //   main.cpp, yang akan meneruskannya sebagai bagian dari request
    //   POST /api/ingest ke server (lewat http_client.cpp).
}

void sendLoRaDownlink(const String &payload) {
    if (!loraReady) return;

    uint8_t frame[LORA_SEC_MAX_FRAME_LEN];
    size_t frameLen = 0;
    if (!loraSecureWrap(payload, frame, sizeof(frame), frameLen)) {
        Serial.println("sendLoRaDownlink: payload terlalu besar, dibatalkan.");
        return;
    }

    LoRa.beginPacket();
    LoRa.write(frame, frameLen);
    LoRa.endPacket();
    Serial.println("LoRa TX (perintah ke node): " + payload);
    // Log payload PLAINTEXT command yang dikirim (sebelum dienkripsi) --
    //   sama seperti node-sawah, ini aman karena cuma terlihat lewat USB
    //   lokal, bukan lewat radio yang benar-benar mengirim versi
    //   terenkripsi.
}
