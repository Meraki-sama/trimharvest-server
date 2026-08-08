#include "wifi_provision.h"
#include "config.h"
#include "device_identity.h"

#include <WiFi.h>
#include <WebServer.h>
#include <HTTPClient.h>
// HTTPClient: dipakai untuk mengecek "apakah server benar-benar
//   terjangkau" setelah WiFi connect -- lihat serverReachable() di bawah.
//   Ini mencegah gateway "terjebak" di WiFi yang connect tapi tidak ada
//   internet/servernya (kasus umum: WiFi tamu, AP tetangga, atau server
//   sudah nonaktif).
#include <Preferences.h>
#include <ArduinoJson.h>
#include <esp_system.h> // untuk esp_random() -- lihat apSetupPassword()

namespace {

Preferences prefs;
WebServer server(80);
// Web server mendengarkan di port 80 (HTTP standar) -- hanya aktif
//   melayani request SELAMA mode AP (lihat startSetupAccessPoint()).
bool apModeActive = false;
// Flag global modul ini -- dibaca wifiProvisionIsActive() &
//   wifiProvisionLoop() untuk menentukan apakah web server perlu
//   diproses tiap loop().

// Cek apakah server benar-benar terjangkau lewat WiFi yang sudah connect.
// Mengembalikan true kalau bisa melakukan HTTP request (kode < 400) ke
// server_base_url dalam waktu singkat. Dipakai sebagai "health check"
// agar gateway otomatis balik ke mode setup bila WiFi connect tapi server
// tidak bisa dihubungi -- tidak perlu tekan tombol reset secara fisik.
bool serverReachable() {
    String url = currentServerBaseUrl();
    if (url.isEmpty()) return false;
    // Pastikan ada koneksi IP sebelum mencoba HTTP.
    if (WiFi.status() != WL_CONNECTED) return false;

    HTTPClient http;
    http.setTimeout(4000); // tunggu maksimal 4 detik
    if (!http.begin(url)) return false;
    // Cukup HEAD/GET ringan; kita hanya peduli "bisa sampai server atau tidak".
    int code = http.GET();
    http.end();
    // code -1 = gagal konek; selain itu (termasuk 404/401/200) artinya
    // jaringan & server terjangkau -> gateway bisa lanjut.
    return code > 0;
}

const char *PREF_NAMESPACE = "wifi_cfg";
const char *PREF_KEY_SSID = "ssid";
const char *PREF_KEY_PASS = "pass";
// Namespace NVS "wifi_cfg" -- TERPISAH dari "device_cfg"
//   (device_identity.cpp) -- kredensial WiFi & identitas device disimpan
//   di "folder" NVS berbeda, walau secara konsep proses provisioning
//   menyimpan KEDUANYA sekaligus (lihat handleConfigure() di bawah).

// Endpoint /configure hanya pernah dipanggil dari native HTTP client app
// Flutter (bukan dari browser), jadi header CORS sengaja tidak ditambahkan
// -- native HTTP client tidak tunduk aturan CORS (itu aturan browser), dan
// menambahkannya justru membuka celah request lintas-origin dari browser
// manapun yang kebetulan tersambung ke AP setup ini.
void handleOptions() {
    server.send(204);
    // Handler untuk method OPTIONS (preflight CORS) yang didaftarkan di
    //   startSetupAccessPoint() -- CATATAN: walau komentar di atas
    //   menjelaskan CORS SENGAJA tidak ditambahkan (karena klien native,
    //   bukan browser), handler OPTIONS tetap didaftarkan untuk KETIGA
    //   endpoint sebagai jaga-jaga/kompatibilitas (membalas 204 No
    //   Content kosong, respons standar minimal untuk preflight yang
    //   TIDAK menambahkan header Access-Control-Allow-* apa pun -- jadi
    //   secara efektif browser TETAP akan diblokir CORS-nya, konsisten
    //   dengan tujuan yang dijelaskan di komentar).
}

void handleStatus() {
    JsonDocument doc;
    doc["device_id"] = currentDeviceId();
    doc["mode"] = "setup";
    doc["ip"] = WiFi.softAPIP().toString();
    // IP gateway dalam mode AP -- SELALU 192.168.4.1 (default ESP32
    //   SoftAP), tapi diambil secara DINAMIS lewat API (bukan
    //   di-hardcode) supaya kode ini tetap benar kalau default itu
    //   berubah di versi framework mendatang.
    String out;
    serializeJson(doc, out);
    server.send(200, "application/json", out);
    // Dipakai app Flutter untuk KONFIRMASI sudah tersambung ke gateway
    //   yang benar (mencocokkan device_id yang ditampilkan dengan yang
    //   diharapkan) sebelum melanjutkan ke langkah /configure.
}

void handleScan() {
    int n = WiFi.scanNetworks();
    // Pemindaian WiFi BLOCKING (menunggu sampai selesai, bisa
    //   memakan waktu beberapa detik) -- dapat diterima di sini karena
    //   dipanggil HANYA saat mode setup (di mana tidak ada tugas lain
    //   yang lebih mendesak sedang berjalan bersamaan), berbeda dari
    //   loop() normal yang harus non-blocking.
    JsonDocument doc;
    JsonArray networks = doc["networks"].to<JsonArray>();

    // Gabungkan SSID duplikat (banyak router siarkan SSID sama di beberapa
    // channel/band), tampilkan sekali saja dengan sinyal terkuat.
    for (int i = 0; i < n; i++) {
        String ssid = WiFi.SSID(i);
        if (ssid.isEmpty()) continue;
        // Lewati SSID kosong -- jaringan WiFi "hidden"/tersembunyi
        //   (yang tidak menyiarkan nama SSID-nya) TIDAK ditampilkan di
        //   daftar (pengguna dengan jaringan tersembunyi harus mengetik
        //   manual, di luar cakupan scan ini -- kemungkinan keterbatasan
        //   yang disengaja demi kesederhanaan UI).

        bool merged = false;
        for (JsonObject existing : networks) {
            // Loop bersarang O(n²) -- cari apakah SSID ini SUDAH ada
            //   di daftar `networks` yang sedang disusun. Untuk jumlah
            //   jaringan WiFi yang realistis (biasanya puluhan, bukan
            //   ribuan), kompleksitas O(n²) ini tidak masalah secara
            //   performa.
            if (existing["ssid"].as<String>() == ssid) {
                if (WiFi.RSSI(i) > existing["rssi"].as<int>()) {
                    existing["rssi"] = WiFi.RSSI(i);
                    // Kalau SSID yang sama ditemukan LAGI dengan sinyal
                    //   (RSSI) LEBIH KUAT (band/channel lain dari router
                    //   yang sama), UPDATE nilai RSSI yang ditampilkan --
                    //   pengguna melihat kekuatan sinyal TERBAIK yang
                    //   tersedia untuk jaringan itu, bukan sinyal
                    //   pertama yang kebetulan terdeteksi.
                }
                merged = true;
                break;
            }
        }
        if (merged) continue;
        // Sudah ditangani sebagai duplikat -- JANGAN tambahkan entri
        //   BARU untuk SSID yang sama.

        JsonObject net = networks.add<JsonObject>();
        net["ssid"] = ssid;
        net["rssi"] = WiFi.RSSI(i);
        // RSSI (Received Signal Strength Indicator) dalam dBm --
        //   angka NEGATIF, makin mendekati 0 makin kuat sinyalnya (mis.
        //   -50 jauh lebih kuat dari -85).
        net["secure"] = WiFi.encryptionType(i) != WIFI_AUTH_OPEN;
        // Boolean sederhana: true kalau jaringan BUTUH password
        //   (enkripsi apa pun selain WIFI_AUTH_OPEN), false kalau
        //   jaringan terbuka -- app cukup butuh info ini untuk
        //   menentukan apakah harus menampilkan kolom password saat
        //   pengguna memilih jaringan ini.
    }
    WiFi.scanDelete();
    // Bebaskan memori internal hasil scan -- WAJIB dipanggil setelah
    //   selesai memproses hasil scanNetworks(), kalau tidak, memori hasil
    //   scan sebelumnya bisa menumpuk (memory leak) kalau fungsi ini
    //   dipanggil berulang kali (mis. pengguna menekan tombol "scan
    //   ulang" beberapa kali di app).

    String out;
    serializeJson(doc, out);
    server.send(200, "application/json", out);
}

void handleConfigure() {
    if (server.method() != HTTP_POST) {
        server.send(405, "application/json", "{\"ok\":false,\"error\":\"method_not_allowed\"}");
        return;
        // Walau endpoint ini didaftarkan khusus untuk HTTP_POST (lihat
        //   startSetupAccessPoint()), pengecekan EKSPLISIT ini tetap ada
        //   sebagai lapis pertahanan tambahan/jaga-jaga.
    }

    JsonDocument doc;
    DeserializationError err = deserializeJson(doc, server.arg("plain"));
    // `server.arg("plain")` adalah cara library WebServer ESP32
    //   mengambil RAW BODY request (bukan query parameter biasa) --
    //   nama "plain" ini konvensi khusus library ini untuk body mentah.
    if (err) {
        server.send(400, "application/json", "{\"ok\":false,\"error\":\"invalid_json\"}");
        return;
    }

    String ssid = doc["ssid"] | "";
    String password = doc["password"] | "";
    if (ssid.isEmpty()) {
        server.send(400, "application/json", "{\"ok\":false,\"error\":\"ssid_kosong\"}");
        return;
        // SSID wajib diisi (tidak masuk akal menyambung ke WiFi tanpa
        //   nama jaringan) -- password TIDAK divalidasi wajib di sini
        //   (jaringan WiFi terbuka/tanpa password itu valid, password
        //   kosong memang sah untuk kasus itu).
    }

    prefs.putString(PREF_KEY_SSID, ssid);
    prefs.putString(PREF_KEY_PASS, password);

    // Field identitas device BERSIFAT OPSIONAL di request ini -- kalau
    // pengguna hanya mengganti WiFi (gateway pindah lokasi tapi tetap
    // device yang sama), field ini boleh dikosongkan/tidak disertakan sama
    // sekali, dan identitas lama di NVS tetap dipakai apa adanya.
    String deviceId = doc["device_id"] | "";
    String deviceSecret = doc["device_secret"] | "";
    String serverUrl = doc["server_url"] | "";
    if (!deviceId.isEmpty() || !deviceSecret.isEmpty() || !serverUrl.isEmpty()) {
        // Hanya panggil saveIdentityFromProvisioning() kalau MINIMAL
        //   SATU dari ketiga field ini diisi -- kalau app memang cuma
        //   mengirim ssid+password (skenario "hanya ganti WiFi"), fungsi
        //   ini TIDAK dipanggil sama sekali, identitas lama benar-benar
        //   tidak tersentuh.
        saveIdentityFromProvisioning(deviceId, deviceSecret, serverUrl);
    }

    server.send(200, "application/json", "{\"ok\":true,\"message\":\"Tersimpan, gateway akan restart.\"}");

    // Beri waktu respons HTTP benar-benar terkirim ke app sebelum restart.
    delay(1000);
    ESP.restart();
    // Restart WAJIB di sini -- kredensial WiFi baru hanya benar-benar
    //   dipakai lewat WiFi.begin() di wifiProvisionBegin(), yang cuma
    //   dipanggil sekali di setup() -- restart adalah cara paling
    //   sederhana & andal untuk "memulai ulang" seluruh alur inisialisasi
    //   dengan konfigurasi baru.
}

void handleNotFound() {
    server.send(404, "application/json", "{\"ok\":false,\"error\":\"not_found\"}");
}

// Password AP di-generate ACAK MURNI (esp_random(), bukan diturunkan dari
// MAC address -- 3 byte pertama MAC ESP32 adalah kode pabrikan/OUI yang
// tetap & publik, jadi ruang tebakan efektif akan jauh lebih kecil kalau
// dari MAC) sekali saat unit ini pertama kali masuk mode setup, lalu
// disimpan permanen di NVS.
String apSetupPassword() {
    // PENJELASAN TAMBAHAN: pendekatan "turunkan password dari MAC
    //   address" MEMANG terlihat menarik sekilas (tidak perlu generate &
    //   simpan apa pun, tinggal hitung ulang dari MAC yang sudah pasti
    //   ada) -- TAPI MAC address ESP32 punya struktur SEBAGIAN PUBLIK/
    //   DAPAT DITEBAK (3 byte pertama = OUI, kode vendor chip yang sama
    //   untuk SEMUA unit ESP32 dari pabrikan yang sama), sehingga
    //   penyerang yang tahu skema turunannya bisa MEMPERSEMPIT ruang
    //   tebakan password secara signifikan -- inilah alasan developer
    //   SENGAJA memilih esp_random() (acak murni dari hardware RNG chip)
    //   dan menyimpannya permanen, bukan menurunkan dari sesuatu yang
    //   bisa ditebak.
    String stored = prefs.getString("ap_setup_pass", "");
    if (stored.length() >= 8) return stored;
    // Kalau SUDAH pernah di-generate sebelumnya (tersimpan & cukup
    //   panjang), pakai yang lama -- password AP TIDAK BERUBAH tiap
    //   restart/masuk mode setup ulang, supaya pengguna yang sudah
    //   pernah tahu passwordnya (mis. dicatat) tidak perlu mencari tahu
    //   lagi kalau perlu masuk mode setup kedua kalinya.

    uint8_t randomBytes[6];
    for (int i = 0; i < 6; i++) {
        randomBytes[i] = (uint8_t)(esp_random() & 0xFF);
        // `esp_random()` = fungsi ESP-IDF yang memakai HARDWARE RNG
        //   bawaan chip ESP32 (bukan pseudo-random software biasa) --
        //   cocok untuk keperluan yang butuh keacakan sungguhan seperti
        //   password ini.
    }
    char buf[13]; // 12 karakter hex + 1 null terminator
    snprintf(buf, sizeof(buf), "%02X%02X%02X%02X%02X%02X",
             randomBytes[0], randomBytes[1], randomBytes[2],
             randomBytes[3], randomBytes[4], randomBytes[5]);
    // 6 byte acak -> 12 karakter HEX HURUF BESAR -- panjang & format
    //   ini dipilih supaya mudah DIBACA & DIKETIK MANUAL oleh pengguna
    //   (mis. dari layar OLED gateway kalau ditampilkan, atau dari
    //   dokumentasi/stiker di unit fisik), sekaligus cukup panjang
    //   (12 karakter hex = 48-bit keacakan) untuk sulit ditebak brute-
    //   force dalam waktu wajar oleh siapa pun yang kebetulan berada
    //   dalam jangkauan WiFi AP ini.
    String generated(buf);
    prefs.putString("ap_setup_pass", generated);
    return generated;
}

void startSetupAccessPoint() {
    apModeActive = true;

    String apName = "Gateway-Setup-";
    apName += currentDeviceId();
    // Nama AP menyertakan device_id -- kalau ada BANYAK gateway yang
    //   sedang di-setup bersamaan di lingkungan yang sama (mis. beberapa
    //   sawah bertetangga), pengguna bisa membedakan AP mana milik unit
    //   mana lewat namanya, bukan cuma "Gateway-Setup" generik yang sama
    //   untuk semua unit.
    String apPass = apSetupPassword();

    WiFi.mode(WIFI_AP_STA); // AP_STA supaya WiFi.scanNetworks() tetap bisa jalan sambil AP aktif
    // ESP32 mendukung mode WiFi GANDA sekaligus: AP (jadi hotspot untuk
    //   HP pengguna) + STA (Station, bisa scan/nantinya connect sebagai
    //   client) -- kalau hanya WIFI_AP (tanpa _STA), WiFi.scanNetworks()
    //   di handleScan() TIDAK akan berfungsi (radio hanya bisa
    //   "mendengarkan" sebagai AP, tidak bisa sekaligus scan jaringan
    //   lain).
    WiFi.softAP(apName.c_str(), apPass.c_str());

    Serial.println("=== MODE SETUP AKTIF (WiFi + Identitas Device) ===");
    Serial.print("Hubungkan HP ke WiFi: ");
    Serial.println(apName);
    Serial.print("Password AP (acak, unik per unit, tersimpan permanen di flash): ");
    Serial.println(apPass);
    // Password DICETAK ke Serial -- ini SATU-SATUNYA cara developer/
    //   instalatur melihat password AP acak ini (karena tidak ada layar
    //   OLED di firmware gateway seperti di node-sawah) -- perlu akses
    //   USB fisik untuk membaca log ini saat pertama kali setup unit,
    //   TIDAK terekspos lewat jaringan mana pun.
    Serial.print("Lalu buka app dan tambahkan device lewat menu 'Tambah Device Baru'. IP gateway: ");
    Serial.println(WiFi.softAPIP());

    server.on("/status", HTTP_GET, handleStatus);
    server.on("/status", HTTP_OPTIONS, handleOptions);
    server.on("/scan", HTTP_GET, handleScan);
    server.on("/scan", HTTP_OPTIONS, handleOptions);
    server.on("/configure", HTTP_POST, handleConfigure);
    server.on("/configure", HTTP_OPTIONS, handleOptions);
    server.onNotFound(handleNotFound);
    // Daftarkan routing endpoint -- pola mirip Express.js di server
    //   Node.js (app.get/app.post), tapi API library WebServer ESP32 ini
    //   jauh lebih sederhana/minimalis, cocok untuk sumber daya
    //   mikrokontroler terbatas.
    server.begin();
}

// Tombol reset WiFi ditekan (ke GND) sejak boot? Kalau ya, hapus kredensial
// WiFi tersimpan supaya gateway jatuh ke mode setup meski WiFi lama masih
// valid (berguna saat gateway dipindah ke lokasi dengan WiFi baru).
// Identitas device (device_id/secret/server_url) TIDAK ikut dihapus --
// tombol ini cuma untuk pindah jaringan, bukan re-provisioning identitas.
bool wifiResetButtonHeld() {
    pinMode(WIFI_RESET_BUTTON_PIN, INPUT_PULLUP);
    // INPUT_PULLUP: pin secara internal "ditarik" ke HIGH secara
    //   default -- tombol fisik menghubungkan pin ini ke GND saat
    //   ditekan, sehingga MEMBACA LOW berarti "tombol SEDANG ditekan"
    //   (logika terbalik/active-low, pola umum untuk tombol sederhana
    //   yang menghindari kebutuhan resistor eksternal).
    delay(50); // debounce singkat
    // Jeda singkat SEBELUM membaca pin -- mengantisipasi noise
    //   elektrik sesaat setelah pinMode() diatur (bukan debounce untuk
    //   MENDETEKSI PERUBAHAN status seperti PIR di firmware node, di
    //   sini cuma memastikan pembacaan pertama stabil).
    return digitalRead(WIFI_RESET_BUTTON_PIN) == LOW;
}

} // namespace

bool wifiProvisionBegin() {
    prefs.begin(PREF_NAMESPACE, false);

    if (wifiResetButtonHeld()) {
        Serial.println("Tombol reset ditekan saat boot -- menghapus WiFi & identitas device (factory reset total).");
        prefs.remove(PREF_KEY_SSID);
        prefs.remove(PREF_KEY_PASS);
        // Hapus SSID & password WiFi.
        clearAllIdentity();
        // Hapus JUGA identitas device (device_id/secret/server_url) &
        //   secret LoRa -- supaya gateway balik ke keadaan "baru" sepenuhnya,
        //   siap di-provisioning ulang lewat app TANPA perlu erase flash.
        startSetupAccessPoint();
        return false;
        // Langsung masuk mode setup (seperti unit baru) -- tidak perlu
        //   lanjut mencoba konek apa pun.
    }

    String savedSsid = prefs.getString(PREF_KEY_SSID, "");

    if (savedSsid.isEmpty()) {
        Serial.println("Belum ada WiFi tersimpan -- masuk mode setup.");
        startSetupAccessPoint();
        return false;
        // Return `false` memberi tahu main.cpp: "JANGAN lanjutkan
        //   inisialisasi yang butuh jaringan (HTTP client, dst), cukup
        //   panggil wifiProvisionLoop() terus" -- sesuai kontrak yang
        //   didokumentasikan di wifi_provision.h.
    }

    String savedPass = prefs.getString(PREF_KEY_PASS, "");

    WiFi.mode(WIFI_STA);
    // Mode Station murni (client biasa) -- BEDA dari WIFI_AP_STA yang
    //   dipakai saat mode setup, karena di sini gateway TIDAK perlu jadi
    //   AP sendiri, cukup menyambung sebagai client ke jaringan WiFi
    //   rumah yang sudah ada.
    WiFi.begin(savedSsid.c_str(), savedPass.c_str());
    Serial.print("Menghubungkan ke WiFi tersimpan (");
    Serial.print(savedSsid);
    Serial.print(")");

    unsigned long start = millis();
    while (WiFi.status() != WL_CONNECTED && (millis() - start) < WIFI_CONNECT_TIMEOUT_MS) {
        delay(400);
        Serial.print(".");
        // SATU-SATUNYA tempat di seluruh kode gateway yang memakai
        //   delay() BLOCKING sungguhan (menahan eksekusi program) -- ini
        //   DAPAT DITERIMA di sini karena terjadi HANYA SEKALI saat
        //   setup() (belum masuk loop() utama, jadi belum ada tugas lain
        //   yang "ketinggalan" akibat blocking ini), dan dibatasi waktu
        //   maksimum oleh WIFI_CONNECT_TIMEOUT_MS (15 detik, config.h) --
        //   titik-titik "..." yang dicetak juga memberi indikator visual
        //   progres ke developer yang memantau lewat Serial Monitor.
    }

    if (WiFi.status() == WL_CONNECTED) {
        Serial.println("\nWiFi Terhubung!");
        // Health-check: jangan langsung lanjut kalau server tidak
        // terjangkau (kasus khas: WiFi connect tapi tidak ada internet /
        // server sudah mati / salah URL). Tanpa cek ini, gateway akan
        // "terjebak" mencoba kirim data dan gagal terus. Kalau server
        // tidak bisa dihubungi, otomatis balik ke mode setup supaya
        // bisa dikonfigurasi ulang lewat app -- tanpa tekan tombol reset.
        if (!serverReachable()) {
            Serial.println("WiFi terhubung TAPI server tidak terjangkau "
                           "(periksa URL server / koneksi internet). "
                           "Otomatis masuk mode setup supaya bisa diatur ulang.");
            startSetupAccessPoint();
            return false;
        }
        return true;
        // Return `true` -> main.cpp lanjut menginisialisasi subsistem
        //   lain yang butuh jaringan (initHttpClient, dst).
    }

    Serial.println("\nGagal konek ke WiFi tersimpan -- masuk mode setup supaya bisa diganti.");
    startSetupAccessPoint();
    return false;
    // INI BAGIAN PENTING dari desain resiliensi yang disebut di
    //   wifi_provision.h: kalau kredensial WiFi TERSIMPAN ternyata SALAH
    //   atau jaringan itu SUDAH TIDAK ADA (mis. gateway dipindah rumah,
    //   atau password WiFi rumah diganti), gateway TIDAK terjebak diam
    //   mencoba terus-menerus tanpa harapan -- setelah timeout, otomatis
    //   kembali ke mode setup AP supaya bisa dikonfigurasi ulang, PERSIS
    //   seperti unit yang benar-benar baru.
}

void wifiProvisionLoop() {
    if (!apModeActive) return;
    server.handleClient();
    // `handleClient()` inilah yang benar-benar memproses request HTTP
    //   masuk yang cocok dengan routing yang didaftarkan di
    //   startSetupAccessPoint() -- HARUS dipanggil BERULANG di loop()
    //   (library WebServer ESP32 ini bersifat polling, bukan berbasis
    //   event/interrupt), makanya wajib dipanggil terus-menerus dari
    //   main.cpp SELAMA mode setup aktif.
}

bool wifiProvisionIsActive() {
    return apModeActive;
}

void applyWifiUpdate(const String &ssid, const String &password) {
    // `prefs` sudah dibuka (prefs.begin) sejak wifiProvisionBegin() di awal
    // boot dan tetap terbuka sepanjang hidup proses ini, jadi aman ditulis
    // ulang di sini kapan saja setelah boot -- lihat /PROTOCOL.md 2.2 untuk
    // format command "wifi_update" lengkap.
    Serial.println("Perintah GANTI WIFI (dari server/app) diterima -- menyimpan kredensial baru & restart...");
    prefs.putString(PREF_KEY_SSID, ssid);
    prefs.putString(PREF_KEY_PASS, password);
    delay(200);
    ESP.restart();
    // Jalur INI TIDAK melalui web server /configure (yang butuh HP
    //   terhubung fisik ke AP setup) -- dipicu lewat command dari server
    //   (gateway MASIH ONLINE lewat WiFi LAMA saat menerima perintah ini,
    //   lihat komentar lengkap di wifi_provision.h) -- setelah restart,
    //   wifiProvisionBegin() akan mencoba SSID/password BARU ini; kalau
    //   ternyata SALAH, otomatis jatuh ke mode setup AP (lihat logika di
    //   wifiProvisionBegin() di atas) -- TIDAK PERNAH terkunci permanen.
}

void clearWifiOnly() {
    // Hapus HANYA kredensial WiFi (SSID & password) dari NVS namespace
    //   "wifi_cfg" -- identitas device (device_id/secret/server_url di
    //   namespace "device_cfg") SENGAJA TIDAK dihapus, supaya gateway tetap
    //   "ingat" siapa dirinya tapi LUPA jaringan WiFi yang terakhir dipakai.
    //   Setelah caller memanggil ESP.restart(), wifiProvisionBegin() akan
    //   mencoba konek dengan SSID kosong -> GAGAL -> otomatis masuk mode
    //   setup AP (Gateway-Setup-<DEVICE_ID>) menunggu provisioning ulang.
    //   Ini dipicu saat server membalas 401 (device dihapus di sisi server),
    //   sehingga menghapus device di app = gateway otomatis lupa WiFi.
    Serial.println("clearWifiOnly: menghapus kredensial WiFi tersimpan (tetap pertahankan identitas device)...");
    prefs.remove(PREF_KEY_SSID);
    prefs.remove(PREF_KEY_PASS);
    // Tidak restart di sini -- caller (main.cpp) yang mengatur urutan restart
    //   supaya log/serial sempat tercetak & tidak ada double-restart.
}
