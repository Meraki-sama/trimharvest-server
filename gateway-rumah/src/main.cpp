// =============================================================================
// iot-gateway-rumah — ENTRY POINT firmware gateway (ESP32 DevKit + WiFi + LoRa)
// =============================================================================
// UNTUK MAINTAINER BARU: baca file ini dulu, lalu /PROTOCOL.md di root repo.
// Gateway ini adalah JEMBATAN antara node sensor (radio LoRa saja, tanpa
// internet) dan Server Node.js (lihat folder /server) -- app Flutter TIDAK
// PERNAH bicara langsung ke gateway/node, dan gateway TIDAK PERNAH bicara
// langsung ke server. Semua lewat server.
//
// Alur singkat:
//   setup()  -> URUTAN PENTING:
//               1. deviceIdentityBegin() -- muat identitas dari NVS.
//               2. wifiProvisionBegin() -- coba konek WiFi tersimpan. Kalau
//                  belum ada/gagal, buka mode Access Point & RETURN FALSE
//                  (setup() berhenti di sini sampai user selesai setting
//                  lewat app, lalu gateway restart sendiri).
//               3. Kalau WiFi berhasil: initHttpClient() (mulai sinkron NTP)
//                  lalu initLoRaGateway().
//   loop()   -> tiap iterasi (kalau servicesStarted):
//               1. Terima data sensor dari node lewat LoRa, teruskan ke
//                  server lewat POST /api/ingest (HMAC-signed).
//               2. Proses command yang dititipkan server di respons ingest:
//                  dest "node" diteruskan lewat LoRa downlink, dest
//                  "gateway" dieksekusi langsung (restart/rekey).
//               3. Kirim heartbeat berkala (juga bisa membawa command).
// =============================================================================
#include <Arduino.h>
#include <WiFi.h>
#include <Preferences.h>
#include <ArduinoJson.h>
#include "config.h"
#include "device_identity.h"
#include "wifi_provision.h"
#include "http_client.h"
#include "lora_gateway.h"

unsigned long lastHeartbeat = 0;
bool servicesStarted = false;
// Flag yang menandakan "apakah setup() berhasil menyelesaikan
//   inisialisasi PENUH (WiFi + HTTP + LoRa)" -- dibaca di loop() untuk
//   memutuskan apakah tugas normal (ingest, heartbeat) boleh dijalankan,
//   atau harus menunggu (masih dalam mode setup AP).
unsigned long bootMillis = 0;
// Timestamp millis() saat setup() dimulai -- dipakai menghitung
//   "uptime_s" (lama gateway sudah menyala) yang dikirim di heartbeat.

bool powerSaveMode = false;
// Mode hemat gateway: kalau AKTIF, interval heartbeat (dan dengan
//   itu pengambilan command dari server) diperlambat supaya gateway
//   lebih jarang "terbangun" koneksi HTTPS -- menghemat daya. Gateway
//   TETAP hidup & TETAP bisa menerima command (termasuk "Aktifkan"/
//   power_save off) karena heartbeat tetap berjalan, cuma lebih jarang.
//   Diubah lewat command {"dest":"gateway","cmd":"power_save","value":...}
//   dari app (lihat juga firmware node yang punya mekanisme serupa).

// Command dari server SELALU berbentuk {"dest":"node"|"gateway","cmd":"...",...}
// -- lihat /PROTOCOL.md 2.2 (field ini SENGAJA dinamai "dest", bukan
// "target", supaya tidak bentrok dengan field "target" milik command
// calib_clear sendiri yang bisa ada di objek yang sama). Command
// "dest":"node" diteruskan APA ADANYA (minus field "dest") ke node lewat
// LoRa downlink; command "dest":"gateway" dieksekusi langsung di sini.
static void processServerCommands(JsonArray commands) {
    // `commands` adalah array command yang dititipkan server di respons
    //   POST /api/ingest (lihat routes/ingest.js: field `commands` di
    //   response, diisi dari `pendingCommands` device di Postgres).
    for (JsonObject cmd : commands) {
        String dest = cmd["dest"] | "";

        if (dest == "node") {
            JsonDocument nodeCmdDoc;
            for (JsonPair kv : cmd) {
                if (String(kv.key().c_str()) == "dest") continue;
                nodeCmdDoc[kv.key()] = kv.value();
                // SALIN SEMUA field KECUALI "dest" ke objek command
                //   baru -- field "dest" hanya relevan untuk ROUTING di
                //   GATEWAY ini (memutuskan diteruskan ke node atau
                //   dieksekusi lokal), node tidak perlu tahu/tidak butuh
                //   field ini sama sekali di JSON yang diterimanya lewat
                //   LoRa (menghemat byte juga, konsisten dengan filosofi
                //   hemat bandwidth radio di seluruh protokol ini).
            }
            String nodeCmdPayload;
            serializeJson(nodeCmdDoc, nodeCmdPayload);
            sendLoRaDownlink(nodeCmdPayload);
            // Command untuk NODE diteruskan APA ADANYA lewat radio LoRa
            //   (dienkripsi otomatis oleh lora_gateway.cpp) -- gateway
            //   TIDAK PERLU memahami ISI command ini (set_interval,
            //   calib_set_fork, dst), cukup meneruskannya -- pemahaman
            //   semantik command sepenuhnya ada di firmware node
            //   (handleIncomingCommand() di node-sawah/src/main.cpp).

        } else if (dest == "gateway") {
            // Command untuk GATEWAY SENDIRI -- di sinilah gateway perlu
            //   memahami & mengeksekusi arti tiap command, BERBEDA dari
            //   cabang "node" di atas yang cuma "meneruskan buta".
            String gwCmd = cmd["cmd"] | "";
            if (gwCmd == "restart") {
                Serial.println("Perintah RESTART (dari server) diterima, restart sekarang...");
                delay(200);
                ESP.restart();
            } else if (gwCmd == "rekey") {
                String newSecret = cmd["new_secret"] | "";
                applyRekey(newSecret); // bisa memicu ESP.restart() di dalamnya
                // Ini adalah command YANG SAMA yang dibuat server saat
                //   POST /api/devices/:id/rekey dipanggil dari app (lihat
                //   server/src/routes/devices.js) -- alurnya: app minta
                //   rekey -> server simpan nextSecret & antre command ini
                //   -> gateway ingest berikutnya menerima command ini di
                //   respons -> applyRekey() dipanggil di sini -> gateway
                //   simpan secret baru & restart -> request BERIKUTNYA
                //   dari gateway memakai secret baru, dicocokkan server
                //   lewat pengecekan nextSecret di deviceAuth.js.
            } else if (gwCmd == "wifi_update") {
                String newSsid = cmd["ssid"] | "";
                String newPassword = cmd["password"] | "";
                if (newSsid.isEmpty()) {
                    Serial.println("Perintah wifi_update ditolak: ssid kosong.");
                } else {
                    applyWifiUpdate(newSsid, newPassword); // memicu ESP.restart() di dalamnya
                }
            } else if (gwCmd == "power_save") {
                // Mode hemat gateway: memperlambat heartbeat (pengambilan
                //   command) -- lihat powerSaveMode di atas & pemakaiannya
                //   di loop() bawah. TETAP bisa dibangunkan lewat command
                //   power_save off (heartbeat tetap jalan, cuma lebih jarang).
                powerSaveMode = cmd["value"] | false;
                Serial.printf("Mode hemat gateway: %s\n", powerSaveMode ? "AKTIF" : "NONAKTIF");
            } else if (gwCmd == "factory_reset") {
                // Reset TOTAL jarak jauh: hapus WiFi + identitas device +
                //   secret LoRa sekaligus, lalu restart -> gateway balik ke
                //   mode setup (seperti unit baru) tanpa perlu tekan tombol
                //   fisik atau erase flash. Praktis untuk mengalihkan gateway
                //   ke pemilik/rumah lain lewat app Flutter.
                Serial.println("Perintah FACTORY_RESET (dari server) diterima, menghapus semua config & restart...");
                clearAllIdentity();
                // Hapus identitas & secret LoRa (di namespace NVS terpisah).
                //   Kredensial WiFi juga dihapus di bawah sebelum restart.
                Preferences wifiPrefs;
                wifiPrefs.begin("wifi_cfg", false);
                wifiPrefs.remove("ssid");
                wifiPrefs.remove("pass");
                wifiPrefs.end();
                delay(300);
                ESP.restart();
            } else if (gwCmd == "sleep") {
                // Alias: sleep = power_save on (konsisten dgn app lama).
                powerSaveMode = true;
                Serial.println("Perintah SLEEP -> mode hemat gateway AKTIF.");
            } else if (gwCmd == "wake") {
                // Alias: wake = power_save off.
                powerSaveMode = false;
                Serial.println("Perintah WAKE -> mode hemat gateway NONAKTIF.");
            } else {
                Serial.println("Perintah gateway tidak dikenal: " + gwCmd);
                // Forward-compatible: command gateway yang belum
                //   dikenal firmware versi ini diabaikan dengan aman,
                //   bukan crash -- sama seperti prinsip di firmware node.
            }
        }
        // CATATAN: kalau `dest` bukan "node" MAUPUN "gateway" (mis.
        //   typo atau nilai lain yang tidak dikenal), command ini
        //   DIABAIKAN sepenuhnya tanpa log apa pun -- sedikit berbeda
        //   dari cabang gwCmd tidak dikenal di atas yang MENCATAT log;
        //   di sini cukup jarang terjadi (server sendiri yang
        //   membuat command, jadi `dest` yang tidak valid seharusnya
        //   tidak pernah muncul dalam praktiknya kecuali ada bug di
        //   server itu sendiri).
    }
}

static void handleIngestResponse(bool ok, JsonDocument &response, int httpCode = -1) {
    // Fungsi kecil pembantu yang dipanggil SETELAH SETIAP httpIngest()
    //   (baik dari uplink data sensor maupun heartbeat) -- memastikan
    //   command yang dititipkan server SELALU diproses terlepas dari
    //   JALUR mana yang memicu request ke server (data sensor ATAU
    //   heartbeat keduanya bisa "membawa pulang" command tertunda).
    // httpCode: kode status HTTP mentah dari server (lihat http_client.cpp).
    if (!ok && httpCode == 401) {
        // Server membalas 401 = device ini TIDAK dikenali lagi (sudah
        //   dihapus di sisi server, mis. lewat app Flutter). Sesuai
        //   permintaan, gateway otomatis menghapus WiFi tersimpan agar
        //   siap dipasang ulang ke rumah/akun lain, lalu restart masuk
        //   mode setup AP. Identitas device SENGAJA dipertahankan.
        Serial.println("Server 401: device dianggap dihapus -> reset WiFi & restart...");
        clearWifiOnly();
        delay(200);
        ESP.restart();
        return;
    }
    if (!ok) return;
    // Kalau request GAGAL (httpIngest return false), `response` tidak
    //   berisi data yang valid untuk diproses -- keluar lebih awal.
    if (!response["commands"].is<JsonArray>()) return;
    // Cek TIPE field "commands" secara eksplisit (bukan cuma
    //   `response["commands"]` truthy) -- respons server SEHARUSNYA
    //   selalu menyertakan array ini (lihat routes/ingest.js: `commands:
    //   pendingCommands`, bisa array kosong TAPI selalu array), tapi
    //   pengecekan tipe eksplisit ini tetap aman kalau suatu saat format
    //   respons berubah/rusak.
    processServerCommands(response["commands"].as<JsonArray>());
}

void setup() {
    Serial.begin(115200);
    bootMillis = millis();

    // PALING AWAL -- wifiProvisionBegin() (nama AP setup) & http_client.cpp
    // (deviceId/secret/server_url) butuh ini sudah siap.
    deviceIdentityBegin();

    if (wifiProvisionBegin()) {
        initHttpClient();
        initLoRaGateway();
        servicesStarted = true;
        // Cabang ini HANYA dijalankan kalau WiFi BERHASIL tersambung
        //   (wifiProvisionBegin() mengembalikan true) -- kalau gateway
        //   masuk mode setup AP (return false), TIDAK ADA satu pun dari
        //   ketiga baris ini yang dijalankan -- setup() langsung selesai
        //   TANPA inisialisasi HTTP/LoRa, dan loop() nanti hanya akan
        //   melayani web server setup (lihat cabang wifiProvisionIsActive()
        //   di loop() di bawah).
    } else {
        Serial.println("Menunggu WiFi & identitas diatur lewat app Flutter (mode setup)...");
    }
}

void loop() {
    // Selama mode setup aktif, cukup layani request HTTP dari app dan
    // jangan sentuh LoRa/server sama sekali (belum konek internet).
    if (wifiProvisionIsActive()) {
        wifiProvisionLoop();
        return;
        // `return` di sini KELUAR dari loop() untuk iterasi ini --
        //   Arduino otomatis memanggil loop() lagi segera setelahnya
        //   (loop() dipanggil berulang TANPA HENTI oleh framework), jadi
        //   ini bukan menghentikan program, cuma "melewati" sisa kode
        //   loop() di bawahnya untuk iterasi SEKARANG.
    }

    if (!servicesStarted) return; // jaga-jaga, seharusnya tidak pernah kejadian
    // Pengaman TAMBAHAN: secara logika, kalau wifiProvisionIsActive()
    //   di atas sudah false, servicesStarted SEHARUSNYA selalu true
    //   (satu-satunya jalur yang membuat apModeActive false adalah lewat
    //   WiFi berhasil tersambung, yang JUGA men-set servicesStarted =
    //   true di setup()) -- baris ini murni jaga-jaga defensif terhadap
    //   kemungkinan state yang tidak terduga, bukan jalur yang diharapkan
    //   benar-benar tereksekusi dalam kondisi normal.

    ensureLoRaReady();

    // 1. Uplink: terima data sensor dari node, teruskan ke server.
    String nodeBody = receiveLoRa();
    if (nodeBody != "") {
        JsonDocument nodeDoc;
        DeserializationError error = deserializeJson(nodeDoc, nodeBody);

        if (!error && nodeDoc["t"].is<const char *>() && nodeDoc["r"].is<JsonArray>()) {
            // Validasi GANDA: (1) JSON berhasil di-parse, (2) field "t"
            //   & "r" ADA dan bertipe yang DIHARAPKAN -- data yang lolos
            //   verifikasi kriptografi (loraSecureUnwrap) belum tentu
            //   berisi STRUKTUR JSON yang benar (lihat prinsip yang sama
            //   di handleIncomingCommand() firmware node), jadi tetap
            //   divalidasi terpisah di sini.
            // Konversi bentuk tuple ringkas [id,value,unit] (hemat byte di
            // radio LoRa, lihat /PROTOCOL.md 1.1) menjadi bentuk object
            // {id,value,unit} untuk dikirim ke server -- di jalur HTTPS
            // ukuran bukan kendala, dan bentuk object lebih jelas dibaca.
            JsonDocument outDoc;
            String t = nodeDoc["t"].as<String>();
            outDoc["type"] = "sensor";
            outDoc["node_msg_type"] = (t == "c") ? "calib" : "core";
            // Terjemahkan kode tipe SATU HURUF dari protokol LoRa yang
            //   hemat byte ("r"/"c") ke nama yang LEBIH DESKRIPTIF untuk
            //   API HTTP ("core"/"calib") -- konsisten dengan filosofi
            //   "hemat di radio, jelas di HTTP" yang sama seperti
            //   konversi tuple->object di bawah.
            JsonArray readings = outDoc["readings"].to<JsonArray>();
            for (JsonArray tuple : nodeDoc["r"].as<JsonArray>()) {
                if (tuple.size() < 3) continue;
                // Lewati tuple yang MALFORMED (kurang dari 3 elemen) --
                //   pengaman defensif terhadap data yang entah kenapa
                //   tidak sesuai format yang diharapkan, alih-alih
                //   mengakses index array yang tidak ada (undefined
                //   behavior).
                JsonObject reading = readings.add<JsonObject>();
                reading["id"] = tuple[0];
                reading["value"] = tuple[1];
                reading["unit"] = tuple[2];
                // Inilah KONVERSI FORMAT yang disebut komentar di atas:
                //   dari ["tds", 123.4, "ppm"] (tuple ringkas LoRa) jadi
                //   {"id":"tds","value":123.4,"unit":"ppm"} (object jelas
                //   untuk HTTP) -- lihat juga server/src/routes/ingest.js
                //   yang menyimpan `readings` ini apa adanya ke Postgres
                //   dalam bentuk object ini.
            }

            // Teruskan flag power-save node ke server (jangan dibuang).
            // Field `psv` dikirim node di body sensor; kalau tidak diteruskan,
            // kolom node_power_save di server tetap false & badge "HEMAT" di
            // app node tidak akan pernah menyala. Default 0 kalau field absen.
            outDoc["psv"] = nodeDoc["psv"] | 0;

            JsonDocument response;
            int code = 0;
            bool ok = httpIngest(outDoc, response, code);
            if (ok) {
                Serial.println("Data sensor diteruskan ke server.");
            } else {
                Serial.println("Gagal meneruskan data sensor ke server (lihat log di atas).");
                // CATATAN: kalau httpIngest() gagal (mis. internet
                //   putus sesaat), data sensor untuk siklus INI "hilang"
                //   -- TIDAK ADA mekanisme antrian/retry untuk mengirim
                //   ulang data yang sama nanti (berbeda dengan pendingCommands
                //   di sisi server yang memang dirancang untuk diambil
                //   ulang). Trade-off yang wajar untuk data monitoring
                //   berkala (data yang hilang sesekali tidak signifikan
                //   dibanding kompleksitas menambahkan antrian retry
                //   penuh di mikrokontroler dengan RAM terbatas).
            }
            handleIngestResponse(ok, response, code);
        } else {
            Serial.println("Data dari node tidak dikenali formatnya, diabaikan.");
        }
    }

    // 2. Heartbeat berkala -- juga membawa command tertunda dari server
    //    (lihat /PROTOCOL.md 2.2), jadi tidak perlu endpoint polling terpisah.
    unsigned long now = millis();
    // Saat mode hemat, heartbeat (dan pengecekan command) diperlambat
    //   supaya gateway lebih jarang membuka koneksi HTTPS -> menghemat
    //   daya. Gateway TETAP hidup & TETAP bisa menerima command "Aktifkan"
    //   karena heartbeat tetap berjalan, cuma lebih jarang.
    const unsigned long hbInterval = powerSaveMode ? (HEARTBEAT_INTERVAL_MS * 6) : HEARTBEAT_INTERVAL_MS;
    if (now - lastHeartbeat >= hbInterval) {
        lastHeartbeat = now;

        JsonDocument hbDoc;
        hbDoc["type"] = "heartbeat";
        hbDoc["uptime_s"] = (now - bootMillis) / 1000UL;
        // Lama gateway sudah menyala sejak boot TERAKHIR (dalam detik)
        //   -- berguna untuk operator/server mendeteksi kalau gateway
        //   sering restart sendiri (uptime_s yang selalu kecil menandakan
        //   ada masalah, mis. brown-out power supply atau crash berulang).
        hbDoc["gpsv"] = powerSaveMode ? 1 : 0;
        // Power-save flag gateway (1=hemat, 0=normal) -- diumumkan lewat
        //   heartbeat supaya server & app bisa menampilkan badge "HEMAT GW"
        //   TANPA harus colok USB ke gateway. Server simpan ke kolom
        //   gateway_power_save (lihat server/src/routes/ingest.js).

        JsonDocument response;
        int code = 0;
        bool ok = httpIngest(hbDoc, response, code);
        handleIngestResponse(ok, response, code);
        // PENTING: heartbeat JUGA memanggil handleIngestResponse() --
        //   ini yang membuat command dari server (rekey, restart, dst)
        //   TETAP bisa sampai ke gateway walau KEBETULAN tidak ada data
        //   sensor baru dari node untuk sementara waktu (mis. node sedang
        //   mati/di luar jangkauan LoRa) -- heartbeat berfungsi sebagai
        //   "jalur cadangan" pengambilan command, memastikan command dari
        //   app tidak pernah menunggu terlalu lama untuk diterima gateway.
    }
}
