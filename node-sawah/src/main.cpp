// =============================================================================
// iot-node-sawah — ENTRY POINT firmware node sensor sawah (ESP32 T-Beam + LoRa)
// =============================================================================
// UNTUK MAINTAINER BARU: baca file ini dulu, lalu /PROTOCOL.md di root repo
// untuk detail lengkap format data & keamanan.
//
// Alur singkat:
//   setup()  -> nyalakan sensor, OLED, radio LoRa (dengan AES-128-CTR +
//               HMAC + anti-replay, lihat lora_security.h), lalu loop().
//   loop()   -> tiap iterasi:
//               1. Baca perintah masuk dari gateway (lihat handleIncomingCommand()).
//               2. Baca sensor secara berkala.
//               3. Kirim body tipe "r" (readings inti) tiap sendIntervalMs;
//                  kirim body tipe "c" (raw+kalibrasi) tiap
//                  CALIB_BROADCAST_EVERY_N kali (atau tiap kali kalau
//                  calibStreamMode aktif) -- lihat /PROTOCOL.md 1.0-1.1.
//               4. Update tampilan OLED.
//
// Node ini TIDAK terhubung ke WiFi/internet sama sekali -- satu-satunya
// jalur keluar-masuk data adalah radio LoRa ke gateway (proyek
// iot-gateway-rumah), yang barulah terhubung ke server.
// =============================================================================
#include <Arduino.h>
#include <SPI.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <ArduinoJson.h>
#include "config.h"
#include "sensors.h"
#include "calibration.h"
#include "lora_node.h"

Adafruit_SSD1306 display(128, 64, &Wire, -1);
// Objek driver layar OLED 128x64 piksel, terhubung lewat I2C (&Wire),
//   parameter terakhir -1 berarti "tidak ada pin reset terpisah" (banyak
//   modul OLED I2C kecil memang tidak butuh pin reset khusus).
unsigned long lastSend = 0;
unsigned long lastDisplay = 0;
unsigned long lastBatteryDebug = 0;
unsigned long lastSample = 0;
// Timestamp (millis()) terakhir masing-masing "tugas berkala" dijalankan
//   -- pola non-blocking timer yang konsisten dengan ensureLoRaReady() di
//   lora_node.cpp (bandingkan selisih waktu, bukan delay() yang blocking).
uint32_t sendCountSinceCalib = 0;
// Penghitung berapa kali sendCoreReadings() sudah dipanggil sejak body
//   kalibrasi ("c") terakhir dikirim -- dipakai sendSensorData() untuk
//   menentukan kapan giliran mengirim body "c" lagi.

float displayTds = 0;
int displayFork = 0;
int displayCap = 0;
float displayBattery = 0;
int displayBatteryPct = 0;
bool displayMotion = false;
// "Snapshot" nilai sensor TERKINI -- dibaca sekali per siklus sampling
//   (sampleSensors()) lalu DIPAKAI ULANG oleh updateDisplay() DAN
//   sendCoreReadings() tanpa membaca sensor lagi -- menjaga konsistensi
//   (apa yang ditampilkan di OLED = apa yang dikirim lewat LoRa untuk
//   siklus yang sama) & menghindari pembacaan ADC berlebihan.

unsigned long sendIntervalMs = SEND_INTERVAL;
// Interval kirim AKTIF SAAT INI -- dimulai dari default config.h, tapi
//   bisa DIUBAH JARAK JAUH lewat perintah "set_interval" (lihat
//   handleIncomingCommand()) -- variabel non-const karena memang perlu
//   berubah saat runtime.
bool powerSaveMode = false;
bool calibStreamMode = false; // aktif selama app membuka layar Kalibrasi
unsigned long calibStreamStartedAt = 0;

static void sampleSensors() {
    // Satu fungsi yang memanggil SEMUA fungsi read*Sensor() sekaligus,
    //   menyimpan hasilnya ke variabel display* global -- dipanggil
    //   berkala (SENSOR_SAMPLE_MS = 250ms) dari loop(), TERPISAH dari
    //   frekuensi pengiriman data (sendIntervalMs, default 5000ms) --
    //   sensor dibaca & difilter LEBIH SERING daripada data dikirim,
    //   supaya filter EMA di sensors.cpp punya cukup sampel untuk
    //   menghasilkan nilai yang stabil & akurat SAAT saatnya dikirim.
    displayTds = readTDSSensor();
    displayFork = readForkSensor();
    displayCap = readCapacitiveSensor();
    displayBattery = readBatteryVoltage();
    displayBatteryPct = readBatteryPercent();
    displayMotion = readPIRSensor();
}

static void updateDisplay() {
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);

    display.setCursor(0, 0);
    if (displayTds >= 999.0f) {
        display.println("TDS  : SATURASI");
        // Menampilkan teks yang JELAS untuk manusia ("SATURASI"),
        //   BUKAN angka 999 mentah -- konversi dari sentinel value teknis
        //   (lihat readTDSSensor() di sensors.cpp) ke representasi yang
        //   mudah dipahami operator yang melihat langsung layar OLED di
        //   lapangan.
    } else {
        display.printf("TDS  : %.0f ppm\n", displayTds);
    }
    display.printf("Fork : %d %%\n", displayFork);
    display.printf("Cap  : %d %%\n", displayCap);
    display.printf("Batt : %.2fV (%d%%)\n", displayBattery, displayBatteryPct);
    display.printf("PIR  : %s\n", displayMotion ? "GERAK" : "diam");
    if (powerSaveMode) display.println("[Hemat baterai]");
    if (calibStreamMode) display.println("[Kalibrasi live]");
    // Dua baris status TAMBAHAN hanya muncul KONDISIONAL (kalau mode
    //   terkait sedang aktif) -- layar tetap ringkas saat kondisi normal,
    //   memberi info ekstra hanya saat relevan.

    display.display();
    // Baris TERAKHIR wajib untuk library Adafruit SSD1306 -- semua
    //   perintah gambar sebelumnya (println/printf) hanya menulis ke
    //   BUFFER internal di RAM, `display.display()` inilah yang benar-
    //   benar mengirim buffer itu ke layar fisik lewat I2C.
}

// Body tipe "r": readings inti, format tuple [id, value, unit] -- lihat
// /PROTOCOL.md 1.1 untuk kenapa tuple (bukan object) dipakai (hemat byte,
// LoRa punya batas keras 256 byte/paket).
static void sendCoreReadings() {
    JsonDocument doc;
    // ArduinoJson v7: JsonDocument otomatis mengelola memori secara
    //   dinamis-terbatas (berbeda dari v6 lama yang butuh ukuran buffer
    //   statis ditentukan manual) -- lebih mudah dipakai, cocok untuk
    //   dokumen kecil seperti ini.
    doc["t"] = "r";
    // Field "t" (type) = "r" (readings/core) -- dibaca server & app
    //   untuk tahu jenis body ini (lihat /PROTOCOL.md 1.1).
    doc["psv"] = powerSaveMode ? 1 : 0;
    // Power-save flag node (1=hemat, 0=normal) -- diumumkan lewat body
    //   sensor supaya server & app bisa menampilkan badge "HEMAT" TANPA
    //   harus colok USB ke node. Server simpan ke kolom node_power_save
    //   (lihat server/src/routes/ingest.js) & app menampilkan badge-nya.
    JsonArray r = doc["r"].to<JsonArray>();
    // Buat field "r" sebagai ARRAY (bukan object) -- isinya nanti
    //   berupa daftar tuple [id, value, unit], BUKAN object {id: {value,
    //   unit}} -- pilihan desain ini menghemat byte JSON (tidak perlu
    //   mengulang nama key "value"/"unit" untuk tiap entri), penting
    //   karena LoRa punya batas ketat per-paket (lihat komentar di atas
    //   fungsi ini & LORA_SEC_MAX_BODY_LEN di lora_security.h).

    // Kalau ADS1115 tidak terdeteksi (lihat sensorsAdcOk() di sensors.h),
    // KETIGA sensor analog di bawah dikirim sebagai `null` -- angka apa pun
    // dari chip yang tidak terinisialisasi adalah sampah, dan mengirimkannya
    // sebagai angka wajar jauh lebih berbahaya daripada mengaku tidak tahu.
    const bool adcOk = sensorsAdcOk();

    JsonArray tds = r.add<JsonArray>();
    tds.add("tds");
    if (!adcOk || displayTds >= 999.0f) tds.add(nullptr); else tds.add(displayTds);
    // Dua sebab `null`: (1) ADC mati total, (2) TDS saturasi (sentinel
    //   999.0f). Keduanya sama-sama berarti "nilai ini tidak bisa dipercaya"
    //   menurut konvensi /PROTOCOL.md 1.1.
    tds.add("ppm");
    // Hasil akhir: ["tds", <angka atau null>, "ppm"] -- tuple 3 elemen
    //   [id, value, unit] sesuai format yang disebut di komentar header.

    JsonArray fork = r.add<JsonArray>();
    fork.add("fork");
    if (!adcOk) fork.add(nullptr); else fork.add(displayFork);
    fork.add("%");

    JsonArray cap = r.add<JsonArray>();
    cap.add("cap");
    if (!adcOk) cap.add(nullptr); else cap.add(displayCap);
    cap.add("%");

    JsonArray battV = r.add<JsonArray>();
    battV.add("batt_v"); battV.add(displayBattery); battV.add("V");

    JsonArray battPct = r.add<JsonArray>();
    battPct.add("batt_pct"); battPct.add(displayBatteryPct); battPct.add("%");

    JsonArray motion = r.add<JsonArray>();
    motion.add("motion"); motion.add(consumeMotionEvent() ? 1 : 0); motion.add("bool");
    // PERHATIKAN: consumeMotionEvent() dipanggil DI SINI (saat MENYUSUN
    //   payload untuk dikirim), BUKAN di sampleSensors() -- artinya latch
    //   gerakan "dikonsumsi" tepat saat data benar-benar akan dikirim
    //   lewat radio, memastikan setiap kejadian gerakan hanya dilaporkan
    //   SATU KALI dalam SATU paket "r" (bukan berpotensi terlewat/
    //   terhitung dobel akibat perbedaan timing sampling vs pengiriman).

    String payload;
    serializeJson(doc, payload);
    // Ubah JsonDocument jadi string JSON compact (tanpa indentasi/
    //   whitespace ekstra) -- menghemat byte lagi.
    sendLoRaData(payload);
    // Kirim lewat lora_node.cpp (yang secara internal mengenkripsi &
    //   membungkusnya jadi frame biner sebelum benar-benar dipancarkan).
    Serial.print("LoRa TX [r]: ");
    Serial.println(payload);
    // Log ke Serial Monitor: mencetak PAYLOAD JSON PLAINTEXT (sebelum
    //   dienkripsi) untuk keperluan debugging lewat kabel USB -- ini AMAN
    //   karena hanya terlihat oleh siapa pun yang PUNYA akses fisik ke
    //   port USB node (yang notabene sudah bisa mengakses banyak hal lain
    //   di firmware juga), TIDAK terekspos lewat radio LoRa (yang memang
    //   mengirim versi terenkripsi, bukan plaintext ini).
}

// Body tipe "c": raw ADC + status kalibrasi kustom -- dipakai layar
// Kalibrasi di app supaya pengguna bisa melihat angka raw secara live saat
// menempatkan probe di kondisi referensi. Lihat /PROTOCOL.md 1.1 & 1.5
// (perintah calib_stream) untuk kapan body ini dikirim.
static void sendCalibReadings() {
    JsonDocument doc;
    doc["t"] = "c";
    JsonArray r = doc["r"].to<JsonArray>();

    JsonArray tdsRaw = r.add<JsonArray>();
    tdsRaw.add("tds_raw"); tdsRaw.add(lastTdsRaw()); tdsRaw.add("raw");
    // Memakai lastTdsRaw() (nilai CACHE dari pembacaan terakhir), BUKAN
    //   memanggil readTDSSensor() lagi -- menghindari pembacaan ADC ganda
    //   untuk siklus yang sama (lihat komentar di sensors.h).

    JsonArray forkRaw = r.add<JsonArray>();
    forkRaw.add("fork_raw"); forkRaw.add(lastForkRaw()); forkRaw.add("raw");

    JsonArray capRaw = r.add<JsonArray>();
    capRaw.add("cap_raw"); capRaw.add(lastCapRaw()); capRaw.add("raw");

    JsonArray tdsCal = r.add<JsonArray>();
    tdsCal.add("tds_cal"); tdsCal.add(calibTdsIsCustom() ? 1 : 0); tdsCal.add("bool");
    // Field tambahan penanda "apakah sensor ini SUDAH pernah
    //   dikalibrasi kustom" -- dipakai app untuk menampilkan status
    //   (mis. badge "Terkalibrasi" vs "Bawaan pabrik") di layar Kalibrasi.

    JsonArray forkCal = r.add<JsonArray>();
    forkCal.add("fork_cal"); forkCal.add(calibForkIsCustom() ? 1 : 0); forkCal.add("bool");

    JsonArray capCal = r.add<JsonArray>();
    capCal.add("cap_cal"); capCal.add(calibCapIsCustom() ? 1 : 0); capCal.add("bool");

    String payload;
    serializeJson(doc, payload);
    sendLoRaData(payload);
    Serial.print("LoRa TX [c]: ");
    Serial.println(payload);
}

static void sendSensorData() {
    sendCoreReadings();
    // Body "r" SELALU dikirim setiap kali fungsi ini dipanggil (tiap
    //   sendIntervalMs) -- ini "data inti" yang harus selalu tersedia.

    sendCountSinceCalib++;
    bool dueForCalib = calibStreamMode || (sendCountSinceCalib >= CALIB_BROADCAST_EVERY_N);
    // Body "c" (raw+kalibrasi) TIDAK selalu dikirim -- HANYA kalau:
    //   (a) mode calibStream sedang aktif (app sedang membuka layar
    //       Kalibrasi -> perlu update raw SESERING mungkin), ATAU
    //   (b) sudah lewat CALIB_BROADCAST_EVERY_N (default 6) kali kirim
    //       body "r" sejak body "c" terakhir dikirim (broadcast periodik
    //       biasa, lebih jarang untuk hemat airtime & baterai saat tidak
    //       sedang aktif dikalibrasi).
    if (dueForCalib) {
        sendCountSinceCalib = 0;
        // Reset counter SETIAP kali body "c" benar-benar dikirim --
        //   termasuk saat calibStreamMode aktif, sehingga begitu mode itu
        //   nonaktif lagi, hitungan "N kali" dimulai dari 0 (bukan dari
        //   angka besar yang mungkin sudah terkumpul selama mode
        //   kalibrasi berjalan lama).
        sendCalibReadings();
    }
}

// Cek & terapkan perintah baru dari app (diteruskan gateway lewat LoRa
// downlink). Lihat /PROTOCOL.md 1.5 untuk daftar lengkap command.
static void handleIncomingCommand() {
    String raw = receiveLoRaCommand();
    if (raw == "") return;
    // Tidak ada perintah baru (atau gagal verifikasi keamanan, sudah
    //   ditangani transparan di lora_node.cpp) -- keluar cepat, TIDAK ada
    //   pekerjaan lain yang perlu dilakukan fungsi ini.

    JsonDocument doc;
    DeserializationError error = deserializeJson(doc, raw);
    if (error) {
        Serial.println("Perintah masuk tidak valid (noise?), diabaikan.");
        return;
        // Body sudah lolos verifikasi HMAC (dijamin keaslian & keutuhan
        //   datanya oleh lora_security.cpp), TAPI parsing JSON masih bisa
        //   gagal kalau isi JSON-nya sendiri malformed -- lapis validasi
        //   TERPISAH dari lapis keamanan kriptografi, sesuai prinsip
        //   "jangan pernah percaya input sepenuhnya walau sudah
        //   terverifikasi asal-usulnya".
    }

    String cmd = doc["cmd"] | "";
    // Idiom ArduinoJson: `doc["cmd"] | ""` berarti "ambil field cmd,
    //   kalau tidak ada/tipe salah, pakai default string kosong" --
    //   MENCEGAH crash/undefined behavior kalau body JSON valid secara
    //   sintaks tapi tidak punya field "cmd" sama sekali.

    if (cmd == "restart") {
        Serial.println("Perintah RESTART diterima, restart sekarang...");
        delay(200);
        // Jeda singkat SEBELUM restart -- memberi waktu buffer Serial
        //   untuk benar-benar mengirim pesan log di atas lewat USB
        //   sebelum ESP.restart() memutus semuanya secara instan (tanpa
        //   jeda ini, pesan log kadang tidak sempat "keluar" sebelum
        //   restart terjadi).
        ESP.restart();
        // Restart software penuh ESP32 -- dipakai operator lewat app
        //   kalau node "stuck"/berperilaku aneh, tanpa perlu akses fisik.
    } else if (cmd == "set_interval") {
        long valueS = doc["value"] | 0;
        // Nilai dari app dalam SATUAN DETIK (lebih intuitif untuk
        //   pengguna app dibanding milidetik).
        unsigned long ms = (unsigned long)valueS * 1000UL;
        if (ms < MIN_SEND_INTERVAL_MS) ms = MIN_SEND_INTERVAL_MS;
        if (ms > MAX_SEND_INTERVAL_MS) ms = MAX_SEND_INTERVAL_MS;
        // VALIDASI/CLAMP di sisi FIRMWARE (bukan cuma percaya app sudah
        //   memvalidasi) -- pertahanan berlapis: walau app SEHARUSNYA
        //   sudah membatasi input di UI-nya sendiri, firmware tetap
        //   membatasi ulang di sini supaya nilai yang benar-benar dipakai
        //   TIDAK PERNAH di luar rentang aman config.h, apa pun yang
        //   dikirim (termasuk kalau ada bug di app, atau command dikirim
        //   manual/diedit di tengah jalan).
        sendIntervalMs = ms;
        Serial.printf("Interval kirim diubah jadi %lu ms\n", sendIntervalMs);
    } else if (cmd == "power_save") {
        powerSaveMode = doc["value"] | false;
        Serial.printf("Mode hemat baterai: %s\n", powerSaveMode ? "AKTIF" : "NONAKTIF");
    } else if (cmd == "calib_stream") {
        calibStreamMode = doc["on"] | false;
        calibStreamStartedAt = millis();
        // Catat/RESET waktu mulai SETIAP kali perintah ini diterima --
        //   termasuk saat app mengirim "calib_stream{on:true}" ULANG
        //   ketika pengguna masih aktif di layar Kalibrasi (mis. app
        //   mengirim heartbeat serupa berkala selama layar itu terbuka)
        //   -- ini yang membuat mekanisme fail-safe CALIB_STREAM_MAX_MS
        //   (lihat config.h & loop() di bawah) "diperpanjang" selama app
        //   masih aktif memakainya, bukan timeout tetap sejak PERTAMA
        //   kali diaktifkan.
        Serial.printf("Mode kalibrasi live: %s\n", calibStreamMode ? "AKTIF" : "NONAKTIF");
    } else if (cmd == "calib_set_fork") {
        int dryRaw = doc["dry_raw"] | -1;
        int wetRaw = doc["wet_raw"] | -1;
        // Default -1 untuk field yang HARUS berupa raw ADC (yang
        //   secara fisik selalu >= 0) -- kalau field tidak ada di JSON
        //   (atau memang -1), pengecekan `< 0` di bawah akan menangkapnya
        //   sebagai input tidak valid.
        if (dryRaw < 0 || wetRaw < 0 || dryRaw == wetRaw) {
            // Validasi: kedua nilai harus non-negatif DAN tidak boleh
            //   SAMA (dryRaw == wetRaw akan membuat mapSensorRawToPercent
            //   di sensors.cpp menghasilkan pembagian bermasalah/rentang
            //   kalibrasi nol, sudah diantisipasi ganda di sana lewat cek
            //   `dryRaw <= wetRaw`, tapi tetap baik ditolak SEDINI
            //   mungkin di titik masuk perintah ini).
            Serial.println("calib_set_fork ditolak: dry_raw/wet_raw tidak valid.");
        } else {
            calibSetFork(dryRaw, wetRaw);
            Serial.printf("Kalibrasi Fork disimpan: dry_raw=%d wet_raw=%d\n", dryRaw, wetRaw);
        }
    } else if (cmd == "calib_set_cap") {
        int dryRaw = doc["dry_raw"] | -1;
        int wetRaw = doc["wet_raw"] | -1;
        if (dryRaw < 0 || wetRaw < 0 || dryRaw == wetRaw) {
            Serial.println("calib_set_cap ditolak: dry_raw/wet_raw tidak valid.");
        } else {
            calibSetCap(dryRaw, wetRaw);
            Serial.printf("Kalibrasi Capacitive disimpan: dry_raw=%d wet_raw=%d\n", dryRaw, wetRaw);
        }
        // Pola identik dengan calib_set_fork di atas, untuk sensor
        //   Capacitive.
    } else if (cmd == "calib_set_tds") {
        float raw0 = doc["raw0"] | -1.0f;
        float ppm0 = doc["ppm0"] | -1.0f;
        float raw1 = doc["raw1"] | -1.0f;
        float ppm1 = doc["ppm1"] | -1.0f;
        if (raw0 < 0 || raw1 < 0 || ppm0 < 0 || ppm1 < 0 || raw0 == raw1) {
            Serial.println("calib_set_tds ditolak: titik kalibrasi tidak valid.");
        } else {
            calibSetTds(raw0, ppm0, raw1, ppm1);
            Serial.printf("Kalibrasi TDS disimpan: (raw0=%.0f,ppm0=%.1f) (raw1=%.0f,ppm1=%.1f)\n",
                          raw0, ppm0, raw1, ppm1);
        }
    } else if (cmd == "calib_clear") {
        String target = doc["target"] | "";
        if (target == "fork" || target == "all") calibClearFork();
        if (target == "cap" || target == "all") calibClearCap();
        if (target == "tds" || target == "all") calibClearTds();
        // Tiga `if` TERPISAH (bukan if/else if) -- SENGAJA, supaya
        //   target=="all" bisa memicu KETIGA-tiganya sekaligus (setiap
        //   if dicek independen, tidak saling meng-exclude).
        if (target == "fork" || target == "cap" || target == "tds" || target == "all") {
            Serial.println("Kalibrasi kustom dihapus untuk: " + target + " (kembali ke bawaan).");
        } else {
            Serial.println("calib_clear diabaikan: target tidak dikenal.");
        }
    } else if (cmd == "sleep") {
        // Alias SLEEP = power_save ON -- node masuk mode hemat (interval
        //   kirim diperlambat, lihat powerSaveMode di loop) TAPI TETAP HIDUP
        //   & TETAP bisa dibangunkan lewat command power_save off (app kirim
        //   "Aktifkan Node"). Berbeda dari deep sleep (mati total, butuh reset
        //   fisik) -- ini sengaja dibuat bisa dikontrol penuh dari app.
        powerSaveMode = true;
        Serial.println("Perintah SLEEP -> mode hemat node AKTIF.");
    } else if (cmd == "wake") {
        // Alias WAKE = power_save OFF.
        powerSaveMode = false;
        Serial.println("Perintah WAKE -> mode hemat node NONAKTIF.");
    } else {
        Serial.println("Perintah tidak dikenal: " + cmd);
        // Perintah dengan `cmd` yang tidak cocok SATU PUN kondisi di
        //   atas -- diabaikan dengan aman (tidak crash), hanya dicatat ke
        //   log. Desain ini FORWARD-COMPATIBLE: kalau server/app suatu
        //   saat mengirim jenis command BARU yang belum dikenal firmware
        //   versi lama, firmware lama tidak akan crash, cuma mengabaikan
        //   perintah yang tidak dipahaminya.
    }
}

void setup() {
    Serial.begin(115200);
    Wire.begin(I2C_SDA, I2C_SCL);
    if (display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
        // Inisialisasi OLED di alamat I2C 0x3C -- kalau GAGAL (misal
        //   layar tidak terpasang), blok if ini DILEWATI, program tetap
        //   lanjut TANPA layar (updateDisplay() nanti akan tetap
        //   dipanggil tapi tidak berefek apa pun secara visual karena
        //   objek display belum benar-benar siap -- pola graceful
        //   degradation yang sama seperti initLoRa()/initBatteryMonitor()).
        display.setRotation(2);
        // Putar tampilan 180 derajat -- kemungkinan karena orientasi
        //   fisik pemasangan layar OLED di board/casing terbalik dari
        //   default.
        display.clearDisplay();
    }
    // WAJIB sebelum initSensors() supaya kalibrasi kustom (kalau ada)
    // langsung terpakai sejak pembacaan pertama.
    initCalibration();
    initSensors();
    initLoRa();
    // Urutan inisialisasi PENTING & disengaja: kalibrasi dulu (baca
    //   NVS), baru sensor (supaya nilai kalibrasi tersedia sejak
    //   pembacaan pertama), baru radio (independen dari dua yang lain,
    //   diletakkan terakhir).
}

void loop() {
    unsigned long now = millis();

    ensureLoRaReady();
    // Dipanggil PALING AWAL tiap iterasi loop() -- kalau radio belum
    //   siap, ini memberi kesempatan tercepat untuk mencoba sambung ulang
    //   sebelum tugas-tugas lain di bawahnya dikerjakan.
    sensorsRetryAdc();
    // Pasangan ensureLoRaReady() untuk sisi SENSOR: kalau ADS1115 gagal
    //   terdeteksi saat boot, fungsi ini mencoba mendeteksinya lagi tiap 30
    //   detik (murah -- langsung return kalau ADC sudah sehat). Tanpa ini,
    //   gangguan I2C sesaat mengunci node mengirim `null` selamanya sampai
    //   ada orang datang me-restart-nya secara fisik di tengah sawah.
    handleIncomingCommand();
    // Dicek SETIAP iterasi loop() (bukan cuma tiap interval tertentu)
    //   -- karena LoRa.parsePacket() di dalamnya bersifat non-blocking &
    //   ringan (cuma cek status internal radio), tidak masalah dipanggil
    //   sesering mungkin -- justru penting supaya perintah masuk (mis.
    //   restart, set_interval) direspons SECEPAT MUNGKIN, tidak menunggu
    //   siklus sensor/kirim data.

    if (calibStreamMode && (now - calibStreamStartedAt >= CALIB_STREAM_MAX_MS)) {
        calibStreamMode = false;
        Serial.println("Mode kalibrasi live nonaktif otomatis (timeout, tidak ada perpanjangan dari app).");
        // Implementasi NYATA dari mekanisme fail-safe yang dijelaskan
        //   di config.h (CALIB_STREAM_MAX_MS) -- dicek setiap loop(),
        //   otomatis menonaktifkan mode kalibrasi live kalau sudah 10
        //   menit tanpa perpanjangan dari app.
    }

    if (now - lastSample >= SENSOR_SAMPLE_MS) {
        lastSample = now;
        sampleSensors();
        // Baca & filter sensor tiap 250ms (config.h) -- lebih sering
        //   dari pengiriman data, memberi filter EMA cukup banyak sampel.
    }

    unsigned long displayInterval = powerSaveMode ? DISPLAY_REFRESH_MS * 5 : DISPLAY_REFRESH_MS;
    // Saat mode hemat baterai aktif, refresh layar OLED 5x LEBIH JARANG
    //   -- update layar (walau kecil) tetap mengonsumsi daya lewat
    //   komunikasi I2C & panel OLED itu sendiri, jadi ikut dikurangi saat
    //   mode hemat daya.
    if (now - lastDisplay >= displayInterval) {
        lastDisplay = now;
        updateDisplay();
    }

    if (now - lastBatteryDebug >= BATTERY_DEBUG_MS) {
        lastBatteryDebug = now;
        Serial.printf("Battery debug: %.2fV (%d%%)\n", displayBattery, displayBatteryPct);
        // Log status baterai berkala TERPISAH ke Serial (2 detik,
        //   config.h) -- untuk debugging lewat USB, independen dari data
        //   yang dikirim lewat LoRa.
    }

    unsigned long effectiveInterval = powerSaveMode
        ? max(sendIntervalMs, (unsigned long)POWER_SAVE_INTERVAL_MS)
        : sendIntervalMs;
    // Saat mode hemat baterai aktif, interval kirim EFEKTIF adalah
    //   NILAI TERBESAR antara sendIntervalMs (yang mungkin sudah diubah
    //   manual lewat set_interval) dan POWER_SAVE_INTERVAL_MS (60 detik,
    //   config.h) -- artinya mode hemat baterai TIDAK PERNAH membuat
    //   pengiriman jadi lebih SERING dari yang sedang diatur operator,
    //   hanya bisa membuatnya LEBIH JARANG (kalau operator sudah mengatur
    //   interval lebih jarang dari 60 detik, itu yang dipakai; kalau
    //   operator mengatur lebih cepat dari 60 detik, mode hemat baterai
    //   akan memperlambatnya ke minimal 60 detik).
    if (now - lastSend >= effectiveInterval) {
        lastSend = now;
        sendSensorData();
    }
}
