#include "lora_node.h"
#include "config.h"
#include "lora_security.h"

// PERBAIKAN BUG (dari versi sebelumnya): initLoRa() dulu memanggil
// `while (1);` kalau LoRa.begin() gagal -- membuat node macet TOTAL sejak
// setup(), sebelum sensor/OLED sempat berjalan, tanpa log apa pun. Sekarang
// TIDAK PERNAH blocking: kalau gagal, dicatat & program tetap lanjut, dan
// ensureLoRaReady() dipanggil tiap loop() supaya node otomatis mencoba
// sambung ulang secara berkala.
// ^ CATATAN UNTUK SIDANG: komentar di atas ini adalah CATATAN PERBAIKAN
//   BUG yang SUDAH DILAKUKAN developer sebelumnya (bagus dijadikan contoh
//   proses debugging & iterasi desain di laporan) -- bandingkan dengan pola
//   `while (1);` (infinite loop kosong yang mengunci total mikrokontroler)
//   yang sering ditemui di kode contoh Arduino pemula: pola itu berbahaya
//   untuk perangkat IoT yang dipasang jarak jauh/di lapangan, karena kalau
//   satu subsistem (di sini: radio LoRa) gagal inisialisasi, SELURUH
//   fungsi node (termasuk sensor & layar yang sebenarnya tidak tergantung
//   radio) ikut mati total dan perlu intervensi fisik (reset manual) untuk
//   pulih -- desain "graceful degradation" (tetap berjalan sebagian,
//   bukan mati total) di sini jauh lebih andal untuk sistem tak-berawak.
static bool loraReady = false;
// ^ Flag status radio SAAT INI -- dibaca semua fungsi publik modul ini
//   (sendLoRaData, receiveLoRaCommand) untuk memutuskan apakah boleh
//   memakai radio atau harus diam saja (tidak crash).
static unsigned long lastLoraRetryMs = 0;
// ^ Timestamp (dari millis(), waktu sejak boot dalam ms) percobaan
//   sambung-ulang TERAKHIR -- dipakai ensureLoRaReady() untuk membatasi
//   frekuensi percobaan (tidak mencoba di SETIAP loop() yang bisa
//   berjalan ribuan kali per detik, cukup tiap LORA_RETRY_INTERVAL_MS).
static const unsigned long LORA_RETRY_INTERVAL_MS = 10000UL;
// ^ Coba sambung ulang setiap 10 detik kalau radio belum siap.

static bool tryStartLoRa() {
    // ^ `static` (di scope file, bukan di dalam class) = fungsi INTERNAL,
    //   hanya bisa dipanggil dari dalam file ini sendiri, tidak diekspos
    //   lewat lora_node.h ke file lain -- detail implementasi yang
    //   disembunyikan dari pemanggil luar (main.cpp).
    SPI.begin(LORA_SCK, LORA_MISO, LORA_MOSI, LORA_SS);
    // ^ Inisialisasi bus SPI dengan pin-pin custom dari config.h (ESP32
    //   memungkinkan remapping pin SPI, tidak harus memakai pin default).
    LoRa.setPins(LORA_SS, 23, LORA_DIO0); // Pin RST di T-Beam standar adalah 23
    // ^ Beri tahu library LoRa pin mana yang dipakai untuk Slave Select,
    //   Reset, dan DIO0 (interrupt) -- pin RST (23) di-hardcode langsung
    //   di sini (bukan lewat #define config.h) karena memang tetap/baku
    //   untuk board T-Beam ini.
    if (!LoRa.begin(BAND)) {
        // ^ Coba inisialisasi radio di frekuensi BAND (915 MHz, config.h)
        //   -- return false kalau modul tidak merespons (wiring salah,
        //   modul rusak, dst).
        return false;
    }
    LoRa.setSyncWord(0xF3); // pemisah channel radio saja, BUKAN mekanisme keamanan
    // ^ PENTING DIPAHAMI: sync word BUKAN kunci enkripsi/keamanan -- ini
    //   cuma "kode saluran" tingkat radio supaya modul LoRa lain yang
    //   kebetulan memakai frekuensi sama tapi sync word BEDA tidak saling
    //   mengganggu/menerima paket satu sama lain (mirip nomor channel WiFi).
    //   Keamanan SUNGGUHAN (kerahasiaan & keaslian data) sepenuhnya
    //   ditangani oleh lora_security.h/.cpp (AES+HMAC), TIDAK oleh nilai
    //   sync word ini -- 0xF3 boleh saja diketahui publik tanpa mengurangi
    //   keamanan sistem sama sekali.
    return true;
}

void initLoRa() {
    loraSecurityBegin();
    // ^ Siapkan kunci turunan AES/HMAC & muat counter seq dari NVS SEBELUM
    //   mencoba apa pun terkait radio fisik -- urutan ini tidak kritis
    //   (loraSecurityBegin tidak bergantung radio), tapi logis untuk
    //   menyiapkan "lapisan keamanan" lebih dulu sebelum "lapisan
    //   transport".
    loraReady = tryStartLoRa();
    lastLoraRetryMs = millis();
    // ^ Catat waktu percobaan PERTAMA ini juga sebagai "waktu retry
    //   terakhir" -- supaya ensureLoRaReady() tidak langsung mencoba lagi
    //   sepersekian detik kemudian kalau initLoRa() baru saja gagal,
    //   melainkan menunggu LORA_RETRY_INTERVAL_MS penuh dulu.

    if (loraReady) {
        Serial.println("LoRa Node Ready.");
    } else {
        Serial.println("LoRa Node GAGAL (cek wiring/modul)! Sensor & OLED tetap "
                        "jalan, radio akan dicoba sambung ulang otomatis.");
        // ^ Pesan log yang JELAS & INFORMATIF (menyebutkan APA yang gagal,
        //   APA yang harus dicek, dan APA yang tetap terjadi) -- praktik
        //   logging yang baik untuk memudahkan debugging di lapangan lewat
        //   Serial Monitor, dibanding pesan generik seperti "Error!".
    }
}

void ensureLoRaReady() {
    if (loraReady) return;
    // ^ Kalau radio sudah siap, tidak ada yang perlu dilakukan -- keluar
    //   secepatnya (fungsi ini dipanggil TIAP iterasi loop(), jadi harus
    //   sangat ringan saat tidak ada yang perlu dikerjakan).

    unsigned long now = millis();
    if (now - lastLoraRetryMs < LORA_RETRY_INTERVAL_MS) return;
    // ^ Idiom umum Arduino untuk interval non-blocking (dibanding delay()
    //   yang MEMBLOKIR seluruh program): bandingkan SELISIH waktu, bukan
    //   waktu absolut -- idiom ini juga AMAN terhadap overflow millis()
    //   (yang terjadi setelah ~49 hari nonstop) karena aritmetika unsigned
    //   overflow di C++ "wrap around" dengan benar secara matematis untuk
    //   kasus pengurangan seperti ini.
    lastLoraRetryMs = now;

    loraReady = tryStartLoRa();
    if (loraReady) {
        Serial.println("LoRa berhasil tersambung ulang.");
    }
    // ^ Kalau masih gagal lagi, TIDAK ada log tambahan di sini (supaya
    //   Serial Monitor tidak dibanjiri pesan gagal yang sama tiap 10 detik
    //   selama radio belum pulih) -- log kegagalan HANYA sekali di
    //   initLoRa() saat percobaan pertama.
}

void sendLoRaData(const String &payload) {
    if (!loraReady) return;
    // ^ Kalau radio belum siap, diam saja (tidak crash, tidak error) --
    //   data sensor untuk siklus ini "hilang" (tidak terkirim), tapi
    //   siklus berikutnya akan mencoba lagi normal begitu ensureLoRaReady()
    //   berhasil menyambungkan ulang.

    uint8_t frame[LORA_SEC_MAX_FRAME_LEN];
    // ^ Buffer STATIS (dialokasikan di stack, ukuran tetap saat compile
    //   time) -- BUKAN alokasi dinamis (malloc/new) yang bisa
    //   menyebabkan fragmentasi memori pada mikrokontroler dengan RAM
    //   terbatas yang berjalan lama tanpa henti (masalah umum firmware
    //   embedded jangka panjang).
    size_t frameLen = 0;
    if (!loraSecureWrap(payload, frame, sizeof(frame), frameLen)) {
        // ^ Kalau payload JSON ternyata lebih besar dari
        //   LORA_SEC_MAX_BODY_LEN, loraSecureWrap menolak (return false)
        //   -- dicek di sini, BUKAN diabaikan diam-diam, supaya
        //   developer tahu lewat Serial kalau body-nya "kelewat besar".
        Serial.println("sendLoRaData: payload terlalu besar, dibatalkan (cek LORA_SEC_MAX_BODY_LEN).");
        return;
    }

    LoRa.beginPacket();
    LoRa.write(frame, frameLen);
    LoRa.endPacket();
    // ^ Tiga langkah standar library LoRa untuk transmisi: mulai paket,
    //   tulis byte frame (frame TERENKRIPSI, bukan payload JSON mentah),
    //   selesaikan & kirim paket lewat udara.
}

String receiveLoRaCommand() {
    if (!loraReady) return "";

    int packetSize = LoRa.parsePacket();
    // ^ Cek non-blocking: kembalikan ukuran paket yang sudah selesai
    //   diterima radio (0 kalau belum ada paket baru sejak pemanggilan
    //   terakhir).
    if (packetSize <= 0) return "";
    if ((size_t)packetSize > LORA_SEC_MAX_FRAME_LEN) {
        // Paket lebih besar dari yang pernah kita kirim sendiri -- pasti
        // bukan dari firmware gateway yang serasi, buang tanpa diproses.
        while (LoRa.available()) LoRa.read();
        // ^ WAJIB mengosongkan buffer penerima radio walau paket ini
        //   dibuang -- kalau tidak dibaca habis, sisa byte paket ini akan
        //   "menyampah" & mengacaukan pembacaan paket BERIKUTNYA (radio
        //   akan menganggap sisa byte lama ini bagian dari paket baru).
        return "";
    }

    uint8_t raw[LORA_SEC_MAX_FRAME_LEN];
    int idx = 0;
    while (LoRa.available() && idx < packetSize) {
        raw[idx++] = (uint8_t)LoRa.read();
        // ^ Baca byte satu-per-satu dari buffer radio ke buffer lokal
        //   `raw` -- dibatasi DUA kondisi (`LoRa.available()` DAN
        //   `idx < packetSize`) sebagai pengaman ganda terhadap
        //   overflow buffer `raw` (yang ukurannya tetap
        //   LORA_SEC_MAX_FRAME_LEN, sudah dicek cukup besar di atas).
    }

    uint8_t body[LORA_SEC_MAX_BODY_LEN];
    size_t bodyLen = 0;
    if (!loraSecureUnwrap(raw, (size_t)idx, body, sizeof(body), bodyLen)) {
        return ""; // signature/replay tidak valid, atau noise radio -- diabaikan
        // ^ SEMUA kegagalan verifikasi (MAC salah, seq replay, atau
        //   sekadar interferensi radio yang merusak byte paket)
        //   diperlakukan SAMA: diam-diam diabaikan, TANPA log error
        //   (berbeda dari sendLoRaData yang mencetak log saat gagal) --
        //   ini SENGAJA, karena gangguan radio/paket asing yang lewat di
        //   udara adalah kejadian NORMAL yang bisa sering terjadi, bukan
        //   kondisi anomali yang perlu diperhatikan developer tiap kali
        //   muncul di Serial Monitor.
    }

    String result;
    result.reserve(bodyLen);
    // ^ .reserve() memberi tahu Arduino String untuk langsung
    //   mengalokasikan kapasitas memori sebesar bodyLen SEKALI di awal --
    //   menghindari realokasi berkali-kali (yang terjadi otomatis kalau
    //   String bertambah panjang sedikit demi sedikit lewat operator +=
    //   tanpa reserve terlebih dulu), sedikit lebih efisien dari sisi
    //   memori/performa.
    for (size_t i = 0; i < bodyLen; i++) {
        result += (char)body[i];
        // ^ Konversi byte-demi-byte dari buffer biner `body` (hasil
        //   dekripsi, sudah dijamin teks JSON valid oleh loraSecureUnwrap)
        //   ke Arduino String -- BARU DI SINI data "berubah bentuk" dari
        //   representasi byte mentah ke String, sesuai catatan desain di
        //   lora_security.h (String tidak dipakai untuk data biner
        //   ciphertext).
    }
    return result;
    // ^ Dikembalikan ke pemanggil (main.cpp) sebagai JSON siap-parse
    //   (lewat ArduinoJson) berisi perintah dari gateway/app.
}
