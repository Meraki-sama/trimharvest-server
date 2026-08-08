#ifndef LORA_GATEWAY_H
#define LORA_GATEWAY_H
#include <Arduino.h>

void initLoRaGateway();
// Inisialisasi radio LoRa sisi gateway (peran setara initLoRa() di node).

// Non-blocking: coba sambung ulang radio berkala kalau belum siap.
void ensureLoRaReady();
// Self-healing radio, perilaku identik versi node-sawah.

// Cek non-blocking adakah paket sensor masuk dari node. Balik "" kalau kosong/gagal verifikasi (noise). Kalau ada, balik body JSON plaintext hasil dekripsi (tipe "r"/"c").
String receiveLoRa();
// Kebalikan receiveLoRaCommand() di node: gateway MENERIMA data sensor (uplink), bukan command.

// Enkripsi & kirim payload (JSON command, /PROTOCOL.md 1.5) sebagai downlink ke node.
void sendLoRaDownlink(const String &payload);
// Kebalikan sendLoRaData() di node: gateway MENGIRIM command (downlink) pakai enkripsi lora_security.h yang sama.

#endif
