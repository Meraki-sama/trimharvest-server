#include "http_client.h"
#include "config.h"
#include "device_identity.h"

#include <WiFi.h>
#include <WiFiClientSecure.h>
// Varian WiFiClient yang mendukung TLS/HTTPS (bukan HTTP polos) --
//   dipakai bersama HTTPClient di bawah.
#include <HTTPClient.h>
// Library klien HTTP tingkat tinggi bawaan Arduino-ESP32 (menangani
//   method, header, body, status code, dst) di atas WiFiClientSecure.
#include <Preferences.h>
#include <time.h>
// Header C standar untuk time_t/time() -- dipakai bersama configTime()
//   (fungsi ESP32-specific) untuk mengakses waktu hasil sinkronisasi NTP.
#include "mbedtls/md.h"

namespace {

bool warnedInsecureTls = false;
// Flag supaya peringatan "TLS tidak aman" (lihat di bawah) HANYA
//   dicetak SEKALI ke Serial, bukan berulang setiap request (yang bisa
//   terjadi tiap belasan detik) -- mencegah log dibanjiri pesan yang sama.

Preferences seqPrefs;
const char *SEQ_PREF_NAMESPACE = "http_seq";
const char *SEQ_KEY = "seq";
uint32_t httpSeq = 0;
uint32_t httpSeqFlushedAt = 0;
// Sama seperti tx_seq LoRa (lihat lora_security.cpp): di-batch ke flash
// supaya tidak menulis NVS di SETIAP request (gateway ingest/heartbeat
// bisa terjadi tiap beberapa detik, terus-menerus selama gateway hidup).
const uint32_t SEQ_FLUSH_INTERVAL = 20;
const uint32_t SEQ_BOOT_MARGIN = SEQ_FLUSH_INTERVAL * 3;
// Konsep IDENTIK dengan tx_seq LoRa di firmware node (lihat
//   node-sawah/src/lora_security.cpp) -- tapi perannya di SINI BUKAN
//   nonce kriptografis (HMAC HTTP di bawah tidak butuh nonce unik seperti
//   AES-CTR), melainkan MURNI anti-replay: server (routes/ingest.js)
//   menolak `seq` yang <= seq terakhir tersimpan untuk device ini,
//   mencegah request lama yang direkam penyerang dikirim ulang persis
//   apa adanya di kemudian hari.

// hex(HMAC-SHA256(key, data)) -- 64 karakter hex, dipakai persis seperti
// yang dijelaskan di /PROTOCOL.md 2.1 (X-Signature).
String hmacHex(const String &key, const String &data) {
    uint8_t out[32];
    const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    mbedtls_md_hmac(info, (const unsigned char *)key.c_str(), key.length(),
                     (const unsigned char *)data.c_str(), data.length(), out);
    // Hitung HMAC-SHA256 PENUH (32 byte) -- BERBEDA dari HMAC LoRa yang
    //   dipotong jadi 8 byte (lora_security.cpp) -- di sini TIDAK
    //   dipotong, karena HTTP tidak punya batas ukuran seketat LoRa
    //   (bandwidth internet jauh lebih longgar dari radio LoRa), jadi
    //   tidak perlu trade-off menghemat ukuran seperti di kanal radio.
    //   HARUS PERSIS SAMA dengan hmacHex() di server (server/src/lib/crypto.js).

    char hex[65]; // 64 karakter hex + 1 null terminator
    for (int i = 0; i < 32; i++) {
        snprintf(hex + (i * 2), 3, "%02x", out[i]);
        // Ubah tiap byte jadi 2 karakter hex huruf KECIL ("%02x") --
        //   HARUS konsisten huruf besar/kecilnya dengan yang diharapkan
        //   server (server memakai .toLowerCase() saat membandingkan,
        //   lihat deviceAuth.js, jadi sebenarnya kasusnya tidak terlalu
        //   kritis, tapi tetap konsisten sejak awal lebih baik).
    }
    hex[64] = '\0';
    return String(hex);
}

uint32_t nextHttpSeq() {
    httpSeq++;
    if (httpSeq - httpSeqFlushedAt >= SEQ_FLUSH_INTERVAL) {
        seqPrefs.putUInt(SEQ_KEY, httpSeq);
        httpSeqFlushedAt = httpSeq;
    }
    return httpSeq;
    // Pola IDENTIK dengan txSeq di lora_security.cpp -- naikkan dulu,
    //   flush ke NVS tiap N kali, kembalikan nilai baru.
}

// PERBAIKAN BUG (dulu di sini timestamp 64-bit dikonversi lewat
// `(unsigned long)timestamp`, yang di ESP32 cuma 32-bit -- MEMBUANG
// sebagian besar nilainya). Fungsi ini mengubah uint64_t jadi String
// DESIMAL PENUH tanpa cast ke tipe lebih kecil apa pun, supaya
// X-Timestamp yang dikirim ke server SAMA PERSIS dengan Date.now() yang
// dibandingkan server (dalam batas presisi detik, lihat currentUnixMillis()).
String uint64ToString(uint64_t value) {
    char buf[21]; // uint64_t maksimum 20 digit desimal + 1 null terminator
    snprintf(buf, sizeof(buf), "%llu", (unsigned long long)value);
    // "%llu" -- format specifier untuk unsigned long long (64-bit),
    //   didukung newlib/printf yang dipakai Arduino-ESP32 -- BEDA dari
    //   "%lu" (unsigned long, 32-bit) yang SEBELUMNYA dipakai secara
    //   TIDAK SENGAJA lewat `String((unsigned long)timestamp)`.
    return String(buf);
}

} // namespace

void initHttpClient() {
    // GMT offset & DST offset = 0 -- kita cuma butuh waktu UNIX yang benar
    // (UTC), bukan waktu lokal yang diformat -- lihat currentUnixMillis().
    configTime(0, 0, "pool.ntp.org", "time.google.com", "time.windows.com");
    // Tiga server NTP publik yang dicoba SECARA BERURUTAN (redundansi
    //   -- kalau server pertama tidak terjangkau/lambat, ESP32 mencoba
    //   yang berikutnya) -- sinkronisasi berjalan di LATAR BELAKANG,
    //   fungsi ini TIDAK menunggu sampai selesai (non-blocking), makanya
    //   ada isTimeSynced() terpisah untuk MENGECEK apakah sudah selesai.
    Serial.println("Sinkronisasi waktu NTP dimulai (dibutuhkan sebelum request pertama ke server)...");

    seqPrefs.begin(SEQ_PREF_NAMESPACE, false);
    uint32_t stored = seqPrefs.getUInt(SEQ_KEY, 0);
    httpSeq = stored + SEQ_BOOT_MARGIN;
    seqPrefs.putUInt(SEQ_KEY, httpSeq);
    httpSeqFlushedAt = httpSeq;
    // Margin lompat saat boot -- SAMA alasannya dengan txSeq LoRa:
    //   mencegah pengulangan nilai seq yang mungkin sudah pernah dipakai
    //   sebelum sempat di-flush ke NVS (kalau gateway mati listrik
    //   mendadak).
}

bool isTimeSynced() {
    time_t now;
    time(&now);
    // 1700000000 ~ November 2023 -- kalau waktu sistem masih di bawah ini,
    // NTP jelas belum pernah berhasil sinkron (ESP32 mulai dari epoch 0).
    return now > 1700000000;
    // Trik sederhana & efektif: ESP32 yang BELUM tersinkron NTP
    //   biasanya punya waktu sistem MENDEKATI 0 (epoch, 1 Jan 1970) atau
    //   nilai kecil lain -- membandingkannya dengan angka acuan yang
    //   "pasti sudah lama lewat" (sengaja jauh di masa lalu relatif
    //   terhadap kapan pun kode ini benar-benar dijalankan) sudah cukup
    //   untuk membedakan "sudah sinkron" vs "belum sinkron", tanpa perlu
    //   API status NTP yang lebih rumit.
}

static uint64_t currentUnixMillis() {
    time_t now;
    time(&now);
    return (uint64_t)now * 1000ULL;
    // `time()` mengembalikan waktu dalam DETIK (time_t, standar POSIX),
    //   dikalikan 1000 untuk mendapat MILIDETIK -- sesuai format timestamp
    //   yang diharapkan server (X-Timestamp dalam ms, lihat
    //   server/src/middleware/deviceAuth.js yang membandingkan dengan
    //   Date.now() JavaScript yang juga dalam ms).
    //   CATATAN: karena `time()` hanya presisi ke DETIK (bukan
    //   milidetik sungguhan), timestamp yang dihasilkan SELALU berakhiran
    //   000 (mis. ...123000, bukan ...123456) -- ini TIDAK masalah untuk
    //   toleransi jendela waktu 120 detik yang dipakai (REQUEST_TIMESTAMP_WINDOW_MS),
    //   presisi detik sudah lebih dari cukup.
}

bool httpIngest(JsonDocument &bodyDoc, JsonDocument &outResponse, int &outHttpCode) {
    outHttpCode = -1; // belum ada respons HTTP (gagal sebelum request dikirim)
    if (WiFi.status() != WL_CONNECTED) {
        Serial.println("httpIngest: WiFi belum tersambung, dibatalkan.");
        return false;
        // Cek koneksi WiFi SEBELUM mencoba apa pun -- gagal cepat tanpa
        //   membuang waktu memanggil HTTPClient yang pasti akan gagal
        //   juga (tapi lebih lambat & dengan pesan error kurang jelas).
    }
    if (!isTimeSynced()) {
        Serial.println("httpIngest: waktu NTP belum sinkron, dibatalkan (server akan menolak timestamp yang salah).");
        return false;
    }

    bodyDoc["seq"] = nextHttpSeq();
    // Field "seq" DITAMBAHKAN OTOMATIS di sini ke JsonDocument yang
    //   SUDAH disiapkan pemanggil (main.cpp) -- konsisten dengan
    //   dokumentasi di http_client.h ("JANGAN isi field seq sendiri").
    String bodyJson;
    serializeJson(bodyDoc, bodyJson);
    // Serialisasi ke string JSON compact -- string INILAH yang
    //   ditandatangani HMAC di bawah, dan JUGA yang benar-benar dikirim
    //   sebagai body HTTP -- HARUS BYTE PERSIS SAMA (server memverifikasi
    //   HMAC atas raw body yang diterima, lihat deviceAuth.js).

    String deviceId = currentDeviceId();
    String secret = currentSecret();
    String serverUrl = currentServerBaseUrl();
    uint64_t timestamp = currentUnixMillis();

    // PERBAIKAN BUG: versi lama kode ini mengonversi `timestamp` (uint64_t,
    // 64-bit) lewat `(unsigned long)timestamp` -- di ESP32/Arduino,
    // `unsigned long` HANYA 32-bit (maksimum ~4,294,967,295), sementara
    // unix-ms sungguhan sudah melewati batas itu sejak ~49 hari setelah
    // 1 Jan 1970. Cast itu MEMBUANG sebagian besar nilai timestamp (hasil
    // "modulo 2^32"), yang akan membuat server MENOLAK SEMUA request
    // gateway (timestamp_di_luar_jendela_toleransi, lihat
    // server/src/middleware/deviceAuth.js). Sekarang dipakai
    // `uint64ToString()` (didefinisikan di atas) yang menyimpan SELURUH
    // nilai 64-bit sebagai string desimal, tanpa truncation.
    String timestampStr = uint64ToString(timestamp);

    String signInput = deviceId + "|" + timestampStr + "|" + bodyJson;
    // Format signInput ini HARUS PERSIS SAMA formulanya dengan yang
    //   dihitung server (server/src/middleware/deviceAuth.js: signInput =
    //   `${deviceId}|${timestampHeader}|${req.rawBody}`) -- kini
    //   `timestampStr` membawa NILAI PENUH (bukan hasil cast 32-bit),
    //   jadi cocok dengan `Date.now()` server dalam batas presisi detik.
    String signature = hmacHex(secret, signInput);

    WiFiClientSecure client;
    if (strlen(SERVER_ROOT_CA_PEM) > 0) {
        client.setCACert(SERVER_ROOT_CA_PEM);
        // Jalur AMAN: validasi sertifikat server penuh memakai root CA
        //   yang di-hardcode di config.h.
    } else {
        // Lihat komentar SERVER_ROOT_CA_PEM di config.h -- ini SENGAJA
        // tidak memvalidasi sertifikat server sama sekali kalau root CA
        // belum diisi. Aman untuk development, TIDAK untuk produksi.
        client.setInsecure();
        // Menonaktifkan TOTAL validasi sertifikat TLS -- koneksi TETAP
        //   terenkripsi (lawan bicara tidak bisa "menyadap" isi data
        //   secara pasif), TAPI TIDAK ADA jaminan bahwa "lawan bicara"
        //   itu benar-benar server TrimHarvest yang sah (rentan terhadap
        //   penyerang aktif yang menyamar sebagai server -- man-in-the-
        //   middle) -- karena itu SERVER_ROOT_CA_PEM di config.h sudah
        //   diisi dengan sertifikat ISRG Root X1 yang valid untuk
        //   proyek ini, sehingga baris `client.setInsecure()` ini
        //   SEHARUSNYA tidak pernah tereksekusi dalam kondisi normal
        //   (hanya jalur fallback kalau root CA dikosongkan manual).
        if (!warnedInsecureTls) {
            warnedInsecureTls = true;
            Serial.println("!!! PERINGATAN KEAMANAN: SERVER_ROOT_CA_PEM kosong -- koneksi TLS ke "
                            "server TIDAK memvalidasi sertifikat (rentan man-in-the-middle). "
                            "Isi SERVER_ROOT_CA_PEM di config.h untuk produksi. Lihat /SECURITY.md.");
            // Peringatan yang MENCOLOK ("!!!") & menjelaskan RISIKO
            //   KONKRET (bukan sekadar "warning: insecure") -- praktik
            //   logging keamanan yang baik, memastikan developer tidak
            //   bisa melewatkan/mengabaikan pesan ini secara tidak
            //   sengaja.
        }
    }

    HTTPClient http;
    String url = serverUrl + "/api/ingest";
    if (!http.begin(client, url)) {
        Serial.println("httpIngest: gagal memulai koneksi HTTPS (cek server_url).");
        outHttpCode = 0; // gagal level koneksi, bukan respons HTTP
        return false;
        // http.begin() bisa gagal kalau URL malformed (mis. server_url
        //   hasil provisioning salah ketik) -- dicek eksplisit di sini.
    }
    http.setTimeout(HTTP_REQUEST_TIMEOUT_MS);
    http.addHeader("Content-Type", "application/json");
    http.addHeader("X-Device-Id", deviceId);
    http.addHeader("X-Timestamp", timestampStr);
    http.addHeader("X-Signature", signature);
    // Tiga header autentikasi sesuai /PROTOCOL.md 2.1 -- diverifikasi
    //   server lewat middleware/deviceAuth.js.

    int code = http.POST(bodyJson);
    // Kirim request POST dengan body JSON yang SAMA PERSIS dengan yang
    //   sudah ditandatangani di atas (bodyJson, bukan bodyDoc yang di-
    //   serialize ulang -- penting supaya tidak ada perbedaan akibat
    //   serialisasi kedua yang urutan key-nya berbeda).

    if (code != 200) {
        outHttpCode = code; // kode respons HTTP sungguhan (termasuk 401)
        Serial.printf("httpIngest: server membalas kode %d (bukan 200).\n", code);
        if (code > 0) {
            // `code` NEGATIF berarti error tingkat KONEKSI (timeout,
            //   DNS gagal, dst -- ditentukan library HTTPClient), BUKAN
            //   respons HTTP sungguhan dari server -- dalam kasus itu,
            //   http.getString() tidak akan berisi apa pun yang berguna
            //   (tidak ada respons HTTP untuk dibaca), makanya dicek
            //   `code > 0` dulu sebelum mencoba membaca body respons.
            Serial.println("Isi respons: " + http.getString());
        }
        http.end();
        return false;
    }

    outHttpCode = 200;
    String responseBody = http.getString();
    http.end();
    // `http.end()` WAJIB dipanggil untuk melepas koneksi/resource
    //   internal HTTPClient -- dipanggil di KEDUA cabang (gagal & sukses)
    //   supaya tidak ada resource yang "bocor"/tidak dilepas.

    DeserializationError err = deserializeJson(outResponse, responseBody);
    if (err) {
        Serial.println("httpIngest: respons server bukan JSON valid, diabaikan.");
        return false;
        // Walau server MEMBALAS 200 OK (dicek di atas), respons body-nya
        //   masih bisa saja gagal di-parse (mis. proxy/load balancer di
        //   depan server mengembalikan halaman HTML error, bukan JSON) --
        //   divalidasi terpisah di sini.
    }

    return true;
    // `outResponse` sekarang berisi JSON hasil parse respons server
    //   (termasuk field "commands" kalau ada, lihat http_client.h) --
    //   dibaca pemanggil (main.cpp) untuk meneruskan command apa pun ke
    //   node lewat lora_gateway.cpp.
}
