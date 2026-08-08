#ifndef LORA_SECURITY_H
#define LORA_SECURITY_H
#include <Arduino.h>

// ---------------------------------------------------------------------------
// Keamanan kanal LoRa: KERAHASIAAN (AES-128-CTR) + INTEGRITAS/ANTI-PALSU
// (HMAC-SHA256, encrypt-then-MAC) + ANTI-REPLAY (rolling counter/seq).
// Format lengkap & alasan tiap keputusan desain ada di /PROTOCOL.md bagian 1.
//
// CATATAN DESAIN PENTING: fungsi di modul ini bekerja dengan BUFFER BYTE
// mentah (uint8_t*), BUKAN Arduino String -- karena payload di sini adalah
// ciphertext biner (bisa mengandung byte 0x00 di tengah), dan Arduino
// String tidak selalu aman dipakai untuk data biner sembarang (beberapa
// operasi internal mengasumsikan C-string yang diakhiri null). Konversi ke
// String (kalau perlu, mis. untuk JSON) HANYA dilakukan setelah dekripsi,
// atas hasil yang sudah dijamin berupa teks JSON valid.
//
// Format bingkai biner (lihat /PROTOCOL.md bagian 1.2):
//   [0]        version (0x01)
//   [1..4]     seq, uint32 big-endian (juga dipakai sebagai nonce AES-CTR)
//   [5..N-9]   ciphertext AES-128-CTR (panjang == panjang plaintext body,
//              stream cipher jadi TANPA padding)
//   [N-8..N-1] 8 byte pertama HMAC-SHA256(MAC_KEY, version||seq||ciphertext)
// ---------------------------------------------------------------------------
// PENJELASAN TAMBAHAN skema di atas untuk pembaca yang belum familiar:
// - "encrypt-then-MAC": urutan operasinya SELALU enkripsi dulu, baru MAC
//   (tanda tangan) dihitung ATAS ciphertext (bukan atas plaintext) --
//   urutan ini disepakati komunitas kriptografi sebagai yang PALING AMAN
//   dari 3 kombinasi yang mungkin (encrypt-then-MAC, MAC-then-encrypt,
//   encrypt-and-MAC), karena verifier bisa menolak ciphertext yang rusak/
//   dipalsukan SEBELUM repot-repot mendekripsinya.
// - `seq` dipakai DUA PERAN sekaligus: (1) nonce/counter untuk AES-CTR
//   (setiap seq HARUS unik supaya keystream yang dihasilkan tidak pernah
//   berulang -- mengulang nonce di mode CTR adalah kesalahan kriptografi
//   fatal yang bisa membocorkan plaintext), dan (2) angka anti-replay
//   (penerima menolak seq yang <= seq terakhir yang pernah diterima).
// - MAC dipotong jadi 8 byte (truncated, bukan 32 byte penuh SHA-256) --
//   trade-off SADAR untuk menghemat airtime radio LoRa yang mahal &
//   lambat (lihat LORA_SEC_FRAME_OVERHEAD), dengan tetap memberi tingkat
//   keamanan yang wajar untuk skala ancaman proyek ini (bukan sistem
//   finansial bernilai tinggi) -- didiskusikan eksplisit di /PROTOCOL.md.
// ---------------------------------------------------------------------------

#define LORA_SEC_MAX_BODY_LEN 220
// Batas atas panjang PLAINTEXT (body JSON sebelum dienkripsi) yang boleh
//   dikirim dalam satu frame -- dipilih supaya frame akhir (body +
//   overhead) tetap di bawah batas payload LoRa yang wajar untuk radio ini.
#define LORA_SEC_FRAME_OVERHEAD 13
// Overhead per frame di luar body: 1 byte version + 4 byte seq + 8 byte
//   MAC terpotong = 13 byte tambahan (lihat format bingkai di komentar
//   atas).
#define LORA_SEC_MAX_FRAME_LEN (LORA_SEC_MAX_BODY_LEN + LORA_SEC_FRAME_OVERHEAD)
// Total panjang frame maksimum = body maksimum + overhead tetap --
//   dipakai untuk menentukan ukuran buffer statis yang perlu disiapkan
//   pemanggil (menghindari alokasi memori dinamis yang rawan fragmentasi
//   di mikrokontroler dengan RAM terbatas).

void loraSecurityBegin();
// Inisialisasi modul keamanan: menurunkan (derive) kunci AES & kunci MAC
//   dari LORA_PSK lewat SHA-256 dengan domain separation (mis. hash dari
//   PSK+"AES" untuk kunci enkripsi, PSK+"MAC" untuk kunci HMAC -- lihat
//   implementasi di lora_security.cpp), DAN memuat/menyiapkan counter seq
//   pengirim dari NVS (supaya seq TIDAK reset ke 0 setelah reboot, yang
//   akan berisiko mengulang nonce AES-CTR yang sudah pernah dipakai
//   sebelum reboot -- lihat penjelasan bahaya reuse nonce di atas).

bool loraSecureWrap(const uint8_t *body, size_t bodyLen,
                     uint8_t *outFrame, size_t outFrameCap, size_t &outFrameLen);
// Versi INTI (paling dasar) fungsi enkripsi+bungkus: terima body mentah
//   sebagai buffer byte + panjangnya, tulis hasil frame terenkripsi ke
//   `outFrame` (buffer milik PEMANGGIL, dengan kapasitas maksimum
//   `outFrameCap` -- fungsi ini TIDAK mengalokasikan memori sendiri),
//   panjang frame HASIL ditulis balik lewat referensi `outFrameLen`.
//   Return `false` kalau body terlalu panjang / buffer output tidak cukup
//   -- pemanggil WAJIB memeriksa return value ini sebelum memakai
//   outFrame/outFrameLen.

bool loraSecureWrap(const String &body,
                     uint8_t *outFrame, size_t outFrameCap, size_t &outFrameLen);
// Overload (fungsi dengan nama sama, parameter beda) yang menerima
//   Arduino String langsung -- kenyamanan untuk pemanggil (main.cpp) yang
//   biasanya sudah punya body dalam bentuk String hasil serialisasi JSON
//   (ArduinoJson), supaya tidak perlu manual convert ke (const uint8_t*,
//   size_t) sendiri di setiap tempat pemanggilan.

bool loraSecureUnwrap(const uint8_t *frame, size_t frameLen,
                       uint8_t *outBody, size_t outBodyCap, size_t &outBodyLen);
// Kebalikan dari loraSecureWrap(): terima frame biner MENTAH yang baru
//   diterima radio, verifikasi MAC-nya (encrypt-then-MAC berarti MAC
//   diverifikasi SEBELUM dekripsi dilakukan), cek seq belum pernah dipakai
//   sebelumnya (anti-replay), baru DEKRIPSI ciphertext-nya ke `outBody`
//   kalau semua verifikasi lolos. Return `false` untuk SEMUA kasus gagal
//   (MAC tidak cocok, seq replay, frame terlalu pendek/panjang, dst) --
//   TANPA membedakan alasan gagalnya ke pemanggil, supaya penyerang yang
//   mencoba paket palsu tidak mendapat petunjuk bagian mana yang perlu
//   diperbaiki (mirip filosofi pesan error generik di server, lihat
//   server/src/middleware/deviceAuth.js).

#endif
