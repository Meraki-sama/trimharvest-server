#ifndef LORA_NODE_H
#define LORA_NODE_H
#include <LoRa.h>
// Library driver radio LoRa (sandeepmistry/LoRa, lihat platformio.ini) --
//   menyediakan API tingkat rendah (LoRa.begin, LoRa.beginPacket, dst) yang
//   dibungkus lagi oleh fungsi-fungsi di lora_node.cpp supaya pemanggilnya
//   (main.cpp) tidak perlu tahu detail radio, cukup panggil fungsi di
//   bawah ini.

void initLoRa();
// Inisialisasi modul radio LoRa: set pin SPI (LORA_SCK/MISO/MOSI/SS/DIO0
//   dari config.h), set frekuensi band (BAND), dan konfigurasi parameter
//   radio lain (spreading factor, bandwidth, dst -- lihat implementasi di
//   lora_node.cpp). Dipanggil sekali di setup().

// Mengenkripsi (lihat lora_security.h) & mengirim payload JSON `payload`
// lewat LoRa. Tidak melakukan apa pun kalau radio belum siap atau payload
// terlalu besar (lihat LORA_SEC_MAX_BODY_LEN).
void sendLoRaData(const String &payload);
// Fungsi TINGKAT TINGGI yang dipanggil main.cpp -- menerima JSON MENTAH
//   (belum dienkripsi) sebagai Arduino String, lalu SECARA INTERNAL
//   memanggil loraSecureWrap() (lora_security.h) untuk mengenkripsi &
//   membungkusnya jadi frame biner, baru mengirimkannya lewat radio.
//   Pemanggil (main.cpp) TIDAK PERLU tahu detail enkripsi sama sekali.

// Cek non-blocking apakah ada paket masuk dari gateway (perintah downlink).
// Mengembalikan "" kalau tidak ada paket baru / paket gagal verifikasi.
String receiveLoRaCommand();
// "Non-blocking" artinya fungsi ini LANGSUNG kembali (return) walau
//   belum ada paket masuk -- TIDAK menunggu/memblokir eksekusi program
//   (penting untuk mikrokontroler single-thread seperti ini, supaya
//   loop() utama tetap responsif mengerjakan tugas lain seperti membaca
//   sensor). Dipanggil berulang di loop() utama untuk "polling" apakah
//   ada perintah baru dari gateway (mis. set_interval, calib_stream, dst).
//   String kosong "" berarti "tidak ada apa-apa" ATAU "ada paket tapi
//   verifikasi keamanannya gagal" -- keduanya diperlakukan sama oleh
//   pemanggil (diam-diam diabaikan, bukan error yang mengganggu jalannya
//   program).

// Non-blocking: coba sambung ulang radio secara berkala kalau belum siap.
void ensureLoRaReady();
// Mekanisme "self-healing": kalau initLoRa() sebelumnya gagal (mis.
//   modul radio belum terpasang sempurna saat boot, atau ada gangguan
//   sesaat), fungsi ini dipanggil berulang di loop() untuk MENCOBA ULANG
//   inisialisasi radio secara berkala, tanpa perlu me-restart seluruh
//   ESP32 -- membuat firmware lebih tahan-banting terhadap kegagalan
//   hardware sesaat di lapangan.

#endif
