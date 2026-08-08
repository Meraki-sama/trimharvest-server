#ifndef CONFIG_H
#define CONFIG_H

// Konstanta yang boleh diubah. Penjelasan lengkap di /PROTOCOL.md & /SECURITY.md.

// --- WiFi provisioning (lihat wifi_provision.h/.cpp) ---
#define AP_SETUP_PASSWORD_FALLBACK "gateway-setup"
// Password default AP setup saat unit belum pernah di-setup; dipakai HANYA bila belum ada password kustom di NVS.
#define WIFI_CONNECT_TIMEOUT_MS 15000UL
// Batas waktu koneksi WiFi sebelum gagal & kembali ke mode AP setup (15 detik).
#define WIFI_RESET_BUTTON_PIN 4
// Pin tombol fisik reset WiFi: hapus kredensial & masuk mode setup AP (tanpa flash ulang).

// --- LoRa (radio ke node sawah) ---
#define LORA_SS 5
#define LORA_RST 14
#define LORA_DIO0 26
// Pin SPI/kontrol LoRa berbeda dari node (board lain) — yang HARUS sama: parameter radio & LORA_PSK.
#define LORA_BAND 923E6
// Frekuensi LoRa Indonesia (920-923 MHz), bukan 915 MHz; HARUS sama dengan node-sawah/src/config.h.

// --- Server Node.js (API Gateway) ---
// URL dasar server (tanpa trailing slash, pakai skema https://). Hanya default awal; nilai aktual di NVS & diatur lewat app Flutter.
#define DEFAULT_SERVER_BASE_URL "https://trimharvest-server-production-f7d1.up.railway.app"
// Default awal, bisa ditimpa lewat provisioning app. Server dihosting di Railway (domain *.up.railway.app).

// Root CA (PEM) untuk validasi TLS server. KOSONGKAN ("") hanya untuk dev/lokal — firmware lalu pakai setInsecure() & cetak peringatan. Produksi: isi root CA penerbit (mis. ISRG Root X1).
static const char SERVER_ROOT_CA_PEM[] = 
"-----BEGIN CERTIFICATE-----\n"
"MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw\n"
"TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh\n"
"cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4\n"
"WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu\n"
"ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9v\n"
"dCBYMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54r\n"
"Vygch77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uox\n"
"myF+0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3\n"
"mX6UA5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq\n"
"+sWT8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3\n"
"qyHB5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x\n"
"+UCB5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SH\n"
"zUvKBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ah\n"
"mbWnOlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3Sz\n"
"ynTnjh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEb\n"
"wrbwqHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y\n"
"53CIrU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAP\n"
"BgNVHRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjAN\n"
"BgkqhkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V\n"
"9lZLubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6\n"
"ZGQ3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj\n"
"/KKNFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCg\n"
"KQ5ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu\n"
"7UrTkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8N\n"
"wdCjNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJ\n"
"zVcoyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2\n"
"qxq4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11\n"
"TPAmRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA\n"
"57demyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGC\n"
"c=\n"
"-----END CERTIFICATE-----\n";
// Sertifikat ISRG Root X1 (Let's Encrypt), ditulis sebagai C-string literal berturutan (digabung otomatis compiler). Publik & tak rahasia; yang rahasia: LORA_PSK & DEVICE_SECRET.

// --- Identitas device (lihat device_identity.h/.cpp) ---
// Nilai awal saat boot; device_id & secret aktual disimpan di NVS & diisi lewat app Flutter saat provisioning.
#define DEVICE_ID "EKRON-GATEWAY-1"
#define DEVICE_SECRET "GANTI-SAAT-PROVISIONING-DARI-APP"
// Placeholder aman: tidak terdaftar di server mana pun, sehingga gagal auth (berbeda dari LORA_PSK yang berbahaya kalau dibiarkan).

// Pre-shared key enkripsi+tanda tangan LoRa ke/dari node. HARUS SAMA PERSIS dengan LORA_PSK di config.h node.
#define LORA_PSK "D38A2529E0B8CEA76AD74825FF49FB76E93A29B1939ABE571B0770150CCC07D4"
// Harus sama karakter demi karakter dengan node; sebaiknya diganti acak unik per pasang node+gateway yang dipasang.

// Cegah flash produksi memakai kredensial contoh: kompilasi gagal kalau LORA_PSK masih placeholder.
namespace config_guard {
constexpr bool same(const char *a, const char *b) {
    // Perbandingan string di COMPILE TIME (sama persis dengan node-sawah/src/config.h).
    return (*a == '\0' && *b == '\0') ? true
         : (*a == '\0' || *b == '\0') ? false
         : (*a != *b) ? false
         : same(a + 1, b + 1);
}
static_assert(!same(LORA_PSK, "GANTI-DENGAN-KUNCI-ACAK-UNIK-SEPASANG-DENGAN-NODE"),
              "LORA_PSK masih placeholder -- ganti dulu (harus sama persis dengan node)!");
// DEVICE_ID/SECRET/URL sengaja TIDAK di-static_assert: kalau dibiarkan placeholder cuma "gagal aman" (tidak bisa auth), bukan "gagal tidak aman" seperti LORA_PSK.
}

// Interval heartbeat gateway ke server (sekaligus mengambil perintah tertunda, titipan di respons /api/ingest).
#define HEARTBEAT_INTERVAL_MS 15000UL
// 15 detik — lebih sering dari kirim sensor node (default 5 detik di sisi LoRa) agar server tahu gateway masih hidup.
#define HTTP_REQUEST_TIMEOUT_MS 8000UL
// Batas tunggu satu request HTTPS sebelum gagal & dicoba lagi siklus berikutnya (8 detik).
#define REQUEST_TIMESTAMP_WINDOW_MS 120000UL
// Toleransi jendela waktu tanda tangan request; HARUS sama dengan server/src/config.js. Di gateway hanya dipakai membuat timestamp, validasi sungguhan di server.

#endif
