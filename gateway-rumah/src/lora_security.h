#ifndef LORA_SECURITY_H
#define LORA_SECURITY_H
#include <Arduino.h>

// File ini SALINAN persis node-sawah/src/lora_security.h — WAJIB identik di kedua firmware agar bisa saling baca frame terenkripsi (lihat /PROTOCOL.md 1).

// Keamanan kanal LoRa: KERAHASIAAN (AES-128-CTR) + INTEGRITAS/ANTI-PALSU (HMAC-SHA256, encrypt-then-MAC) + ANTI-REPLAY (rolling seq). Format & alasan di /PROTOCOL.md 1.
// Modul ini pakai BUFFER BYTE mentah (uint8_t*), bukan String, karena ciphertext bisa mengandung byte 0x00. Konversi ke String hanya setelah dekripsi.
// Format bingkai: [0] version (0x01); [1..4] seq uint32 big-endian (juga nonce AES-CTR); [5..N-9] ciphertext AES-128-CTR; [N-8..N-1] 8 byte awal HMAC-SHA256(MAC_KEY, version||seq||ciphertext).
// encrypt-then-MAC: selalu enkripsi dulu, MAC dihitung atas ciphertext. seq dipakai ganda: nonce AES-CTR (harus unik) & anti-replay. MAC dipotong 8 byte (trade-off airtime LoRa).

#define LORA_SEC_MAX_BODY_LEN 220
// Batas panjang plaintext per frame agar total frame tetap di bawah batas payload LoRa.
#define LORA_SEC_FRAME_OVERHEAD 13
// Overhead per frame: 1 byte version + 4 byte seq + 8 byte MAC.
#define LORA_SEC_MAX_FRAME_LEN (LORA_SEC_MAX_BODY_LEN + LORA_SEC_FRAME_OVERHEAD)
// Total frame maksimum; dipakai menentukan ukuran buffer statis (hindari alokasi dinamis di RAM terbatas).

void loraSecurityBegin();
// Turunkan kunci AES & MAC dari LORA_PSK via SHA-256 (domain separation), lalu muat counter seq pengirim dari NVS (seq tak reset ke 0 setelah reboot agar nonce AES tak berulang).

bool loraSecureWrap(const uint8_t *body, size_t bodyLen,
                     uint8_t *outFrame, size_t outFrameCap, size_t &outFrameLen);
// Enkripsi+bungkus versi buffer: tulis frame ke outFrame (milik pemanggil), panjang hasil via outFrameLen. False kalau body terlalu panjang/buffer kurang — pemanggil wajib cek.

bool loraSecureWrap(const String &body,
                     uint8_t *outFrame, size_t outFrameCap, size_t &outFrameLen);
// Overload terima Arduino String (nyaman untuk pemanggil yang sudah punya JSON String).

bool loraSecureUnwrap(const uint8_t *frame, size_t frameLen,
                       uint8_t *outBody, size_t outBodyCap, size_t &outBodyLen);
// Kebalikan wrap: verifikasi MAC (encrypt-then-MAC) lalu cek seq anti-replay, baru dekripsi ke outBody. False untuk semua kegagalan tanpa membedakan alasan (anti petunjuk penyerang).

#endif
