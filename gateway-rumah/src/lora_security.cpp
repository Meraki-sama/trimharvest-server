#include "lora_security.h"
#include "config.h"
// CATATAN: file ini adalah SALINAN/CERMIN persis dari node-sawah/src/lora_security.cpp
// -- WAJIB identik logikanya di kedua firmware (lihat lora_security.h untuk
// penjelasan kenapa). Komentar penjelasan di bawah sengaja disalin utuh
// dari sisi node-sawah supaya konsisten.

#include <Preferences.h>
// Library bawaan Arduino-ESP32 untuk baca/tulis NVS (flash persisten)
//   dengan API key-value sederhana (mirip localStorage di web).
#include <string.h>
// Header C standar untuk memcpy/memcmp/memset.
#include "mbedtls/md.h"
// mbedTLS: library kriptografi yang SUDAH TERSEDIA built-in di ESP-IDF
//   (dasar Arduino-ESP32) -- tidak perlu di-install manual lewat
//   platformio.ini. Header ini untuk fungsi hash/HMAC generik (md =
//   "message digest").
#include "mbedtls/aes.h"
// Header mbedTLS untuk operasi AES (di sini dipakai mode CTR).

namespace {
// Anonymous namespace (namespace tanpa nama) -- semua yang dideklarasikan
//   di dalamnya HANYA terlihat/bisa dipakai di dalam file .cpp ini sendiri
//   (mirip `static` untuk variabel/fungsi tunggal, tapi mencakup semuanya
//   sekaligus) -- mencegah nama seperti `txSeq`, `encKey` dkk bentrok
//   dengan variabel bernama sama di file .cpp lain saat linking.

Preferences prefs;
// Objek Preferences (dari library di atas) untuk akses NVS.
const char *PREF_NAMESPACE = "lora_sec";
// NVS di ESP32 dibagi jadi "namespace" (semacam folder) supaya data
//   modul berbeda (mis. kalibrasi vs keamanan LoRa) tidak saling
//   bertabrakan kunci penyimpanannya walau kebetulan nama key-nya sama.
const char *KEY_TX_SEQ = "tx_seq";
const char *KEY_RX_SEQ = "rx_seq";
// Nama key di dalam namespace itu -- tx_seq (counter kirim milik node
//   ini) dan rx_seq (counter terima, anti-replay perintah dari gateway).

// Sama seperti versi sebelumnya: tx_seq (nomor urut KIRIM kita) di-batch ke
// flash tiap TX_SEQ_FLUSH_INTERVAL paket (NVS/flash punya siklus tulis
// terbatas, dan node bisa mengirim tiap 5 detik terus-menerus). rx_seq
// (anti-replay utk perintah MASUK dari gateway) SENGAJA TIDAK di-batch --
// ditulis di SETIAP paket valid yang diterima, karena ini otoritas
// anti-replay dan jauh lebih jarang terjadi (bukan tiap 5 detik).
// PENJELASAN TAMBAHAN: flash NVS (berbasis teknologi seperti EEPROM/
//   flash memory) punya batas jumlah siklus tulis-hapus (umumnya puluhan
//   ribu hingga ratusan ribu siklus per sektor) sebelum sel memorinya
//   mulai rusak/aus (wear-out). Kalau tx_seq ditulis ke flash SETIAP kali
//   kirim data (tiap 5 detik = ~17.280 kali/hari), flash bisa aus dalam
//   hitungan bulan/tahun pemakaian nonstop -- dengan meng-"cache" di RAM
//   dan hanya menulis ke flash tiap 20 paket, jumlah penulisan fisik
//   berkurang 20x lipat, jauh memperpanjang umur pakai modul.
const uint32_t TX_SEQ_FLUSH_INTERVAL = 20;
const uint32_t TX_SEQ_BOOT_MARGIN = TX_SEQ_FLUSH_INTERVAL * 3;
// Margin keamanan SAAT BOOT: karena tx_seq yang tersimpan di flash bisa
//   "ketinggalan" hingga (TX_SEQ_FLUSH_INTERVAL - 1) di belakang nilai
//   SEBENARNYA terakhir dipakai (akibat batching di atas -- kalau node
//   mati listrik mendadak SEBELUM sempat flush), node MELOMPAT counter-nya
//   maju sejumlah margin ini (3x interval flush) setiap kali boot ulang --
//   ini menjamin tx_seq baru SELALU lebih besar dari nilai TERBESAR yang
//   MUNGKIN pernah benar-benar terpakai sebelum mati listrik, mencegah
//   pengulangan nonce AES-CTR yang fatal (lihat lora_security.h) akibat
//   restart/mati listrik tak terduga.

uint32_t txSeq = 0;
uint32_t txSeqFlushedAt = 0;
// Nilai txSeq TERAKHIR yang sudah ditulis ke flash -- dipakai untuk
//   menghitung "sudah berapa paket sejak flush terakhir" (lihat
//   loraSecureWrap di bawah).
uint32_t rxSeq = 0;

uint8_t encKey[16];  // AES-128 -> kunci 16 byte (128 bit)
uint8_t macKey[32];  // HMAC-SHA256 -> kunci 32 byte (256 bit), praktik umum
                      // memakai kunci HMAC sepanjang output hash-nya.

// SHA-256(LORA_PSK || suffix) -- dipakai untuk menurunkan ENC_KEY & MAC_KEY
// dari satu LORA_PSK dengan domain separation (lihat /PROTOCOL.md 1.3).
void deriveKey(const char *suffix, uint8_t *out32) {
    // "Domain separation": walau ENC_KEY & MAC_KEY berasal dari SATU
    //   rahasia sumber (LORA_PSK) yang sama, keduanya dibuat BERBEDA total
    //   secara matematis (lewat suffix "enc" vs "mac" sebelum di-hash) --
    //   ini penting karena mencampur kunci enkripsi & kunci autentikasi
    //   yang SAMA PERSIS antar dua algoritma berbeda adalah praktik
    //   kriptografi yang buruk/berisiko (bisa membuka celah serangan
    //   tertentu tergantung kombinasi algoritmanya).
    String input = String(LORA_PSK) + suffix;
    // Gabungkan PSK + suffix jadi satu string, mis. "D38A25...07D4enc".
    const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    // Ambil "deskriptor" algoritma SHA-256 dari mbedTLS (pola umum API
    //   mbedTLS: pilih algoritma dulu lewat info struct, baru dipakai
    //   fungsi generik seperti mbedtls_md() di bawah).
    mbedtls_md(info, (const unsigned char *)input.c_str(), input.length(), out32);
    // Hitung SHA-256 atas seluruh string input, hasil 32 byte ditulis ke
    //   `out32` (buffer milik pemanggil).
}

// 8 byte pertama HMAC-SHA256(macKey, data[0..len)).
void hmac8(const uint8_t *data, size_t len, uint8_t *out8) {
    uint8_t full[32];
    const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    mbedtls_md_hmac(info, macKey, sizeof(macKey), data, len, full);
    // Hitung HMAC-SHA256 penuh (32 byte) dari `data` memakai `macKey`.
    memcpy(out8, full, 8);
    // HANYA 8 byte PERTAMA yang diambil & disimpan/dikirim (truncated
    //   MAC) -- trade-off menghemat airtime radio, lihat penjelasan di
    //   lora_security.h.
}

// AES-128-CTR adalah stream cipher: fungsi yang sama dipakai untuk enkripsi
// MAUPUN dekripsi (XOR keystream). `seq` dipakai sebagai blok counter awal
// (12 byte nol + seq big-endian 4 byte) -- lihat /PROTOCOL.md 1.4 untuk
// alasan ini aman (seq dijamin unik & naik terus oleh mekanisme anti-replay
// yang sama).
void aesCtrCrypt(uint32_t seq, const uint8_t *in, uint8_t *out, size_t len) {
    // PENJELASAN CARA KERJA AES-CTR (Counter mode) untuk pembaca yang
    //   belum familiar: alih-alih mengenkripsi plaintext LANGSUNG dengan
    //   AES (yang butuh input tepat 16 byte per blok + padding rumit), CTR
    //   mode mengenkripsi sebuah COUNTER (nonce+seq) untuk menghasilkan
    //   "keystream" acak sepanjang plaintext, lalu keystream itu di-XOR
    //   dengan plaintext -- hasilnya stream cipher yang bisa mengenkripsi
    //   data PANJANG BERAPA PUN (bukan cuma kelipatan 16 byte) tanpa
    //   padding, dan dekripsinya adalah OPERASI YANG SAMA PERSIS (XOR lagi
    //   dengan keystream yang sama menghasilkan balik plaintext-nya) --
    //   makanya satu fungsi `aesCtrCrypt` ini dipakai untuk kedua arah.
    mbedtls_aes_context aes;
    mbedtls_aes_init(&aes);
    mbedtls_aes_setkey_enc(&aes, encKey, 128);
    // Selalu pakai "setkey_ENC" (kunci enkripsi) walau untuk operasi
    //   dekripsi -- ini KHUSUS UNTUK MODE CTR (berbeda dari mode CBC/ECB
    //   yang butuh kunci dekripsi terpisah): karena CTR sebenarnya SELALU
    //   mengenkripsi counter (bukan plaintext-nya), baik saat "encrypt"
    //   maupun "decrypt" data pemakainya.

    uint8_t nonceCounter[16];
    memset(nonceCounter, 0, sizeof(nonceCounter));
    nonceCounter[12] = (uint8_t)(seq >> 24);
    nonceCounter[13] = (uint8_t)(seq >> 16);
    nonceCounter[14] = (uint8_t)(seq >> 8);
    nonceCounter[15] = (uint8_t)(seq);
    // Susun blok counter 16-byte: 12 byte pertama NOL, 4 byte terakhir
    //   diisi `seq` dalam format big-endian (byte paling signifikan
    //   duluan) -- karena `seq` DIJAMIN selalu unik & tidak pernah
    //   berulang (naik terus per paket, lihat loraSecurityBegin), blok
    //   counter awal ini juga otomatis selalu unik per paket, memenuhi
    //   syarat keamanan CTR mode (nonce/counter TIDAK BOLEH pernah
    //   berulang untuk kunci yang sama).

    uint8_t streamBlock[16];
    memset(streamBlock, 0, sizeof(streamBlock));
    size_t ncOff = 0;
    // `ncOff` (nonce counter offset) & `streamBlock` adalah state
    //   internal yang dibutuhkan API mbedtls_aes_crypt_ctr untuk menangani
    //   input yang panjangnya BUKAN kelipatan 16 byte persis -- di sini
    //   diinisialisasi 0 karena setiap panggilan fungsi ini SELALU dimulai
    //   dari counter offset 0 (satu panggilan = satu paket independen,
    //   tidak ada enkripsi berkelanjutan lintas panggilan).

    mbedtls_aes_crypt_ctr(&aes, len, &ncOff, nonceCounter, streamBlock, in, out);
    // Panggilan tunggal yang melakukan seluruh proses CTR: hasilkan
    //   keystream dari nonceCounter+kunci, XOR dengan `in` (plaintext atau
    //   ciphertext, tergantung arah pemakaian), tulis hasilnya ke `out`.
    mbedtls_aes_free(&aes);
    // Bersihkan/lepaskan resource internal context AES -- praktik yang
    //   baik walau di sini bukan alokasi dinamis besar, tetap kebiasaan
    //   yang benar untuk API mbedTLS.
}

} // namespace

void loraSecurityBegin() {
    uint8_t fullEnc[32];
    deriveKey("enc", fullEnc);
    memcpy(encKey, fullEnc, 16); // AES-128 hanya butuh 16 byte pertama
    // SHA-256 selalu menghasilkan 32 byte, tapi AES-128 cuma butuh kunci
    //   16 byte -- 16 byte SISANYA dari hash ini SENGAJA DIBUANG (tidak
    //   dipakai untuk apa pun), bukan kesalahan.
    deriveKey("mac", macKey);
    // macKey butuh 32 byte penuh (sesuai ukuran hash SHA-256), jadi
    //   seluruh output deriveKey dipakai langsung tanpa dipotong.

    prefs.begin(PREF_NAMESPACE, false);
    // Buka namespace NVS "lora_sec" dalam mode BACA-TULIS (`false` =
    //   bukan read-only).

    uint32_t storedTx = prefs.getUInt(KEY_TX_SEQ, 0);
    // Baca tx_seq terakhir yang tersimpan, default 0 kalau belum pernah
    //   ada (node benar-benar baru/pertama kali boot).
    txSeq = storedTx + TX_SEQ_BOOT_MARGIN;
    // Lompat maju sejumlah margin (lihat penjelasan TX_SEQ_BOOT_MARGIN
    //   di atas) -- mencegah reuse nonce akibat mati listrik sebelum
    //   sempat flush.
    prefs.putUInt(KEY_TX_SEQ, txSeq);
    // SEGERA tulis nilai yang sudah dilompatkan ini ke flash -- supaya
    //   kalau device mati listrik LAGI tak lama setelah boot ini (sebelum
    //   sempat kirim paket & flush normal), boot BERIKUTNYA tetap
    //   melompat dari titik yang benar (bukan dari nilai storedTx yang
    //   sudah basi).
    txSeqFlushedAt = txSeq;

    rxSeq = prefs.getUInt(KEY_RX_SEQ, 0);
    // rxSeq TIDAK perlu margin lompat seperti txSeq -- karena rxSeq
    //   cuma dipakai untuk MENOLAK seq yang <= nilai ini (anti-replay
    //   command masuk), bukan sebagai nonce yang harus unik untuk
    //   ENKRIPSI kita sendiri. Nilai yang sedikit "ketinggalan" di sini
    //   paling buruk cuma berarti satu command lama (yang seq-nya sedikit
    //   lebih tinggi dari rxSeq tersimpan tapi sudah pernah diproses
    //   sebelum mati listrik) bisa diterima ulang sekali -- risiko yang
    //   jauh lebih ringan dibanding reuse nonce AES.
}

bool loraSecureWrap(const uint8_t *body, size_t bodyLen,
                     uint8_t *outFrame, size_t outFrameCap, size_t &outFrameLen) {
    if (bodyLen > LORA_SEC_MAX_BODY_LEN) return false;
    size_t frameLen = LORA_SEC_FRAME_OVERHEAD + bodyLen;
    if (frameLen > outFrameCap) return false;
    // Dua validasi awal: body tidak melebihi batas desain, dan hasil
    //   frame akhir tidak melebihi kapasitas buffer yang disediakan
    //   pemanggil (lora_node.cpp) -- MENCEGAH BUFFER OVERFLOW dengan
    //   memvalidasi SEBELUM menulis apa pun ke outFrame.

    txSeq++;
    // Naikkan counter SEBELUM dipakai (bukan sesudah) -- memastikan
    //   nilai 0 tidak pernah dipakai sebagai seq sungguhan pertama kali
    //   (walau ini detail kecil, konsisten dengan konvensi "seq mulai
    //   dari 1" yang membuat perbandingan `seq <= lastSeq` di penerima
    //   -- baik di firmware maupun server -- selalu benar sejak awal).
    if (txSeq - txSeqFlushedAt >= TX_SEQ_FLUSH_INTERVAL) {
        prefs.putUInt(KEY_TX_SEQ, txSeq);
        txSeqFlushedAt = txSeq;
        // Baru tulis ke flash setelah 20 paket terlewati sejak flush
        //   terakhir (lihat penjelasan wear-leveling di atas file ini).
    }

    outFrame[0] = 0x01; // version
    outFrame[1] = (uint8_t)(txSeq >> 24);
    outFrame[2] = (uint8_t)(txSeq >> 16);
    outFrame[3] = (uint8_t)(txSeq >> 8);
    outFrame[4] = (uint8_t)(txSeq);
    // Tulis header 5 byte: 1 byte version + 4 byte seq big-endian --
    //   PERSIS sesuai format bingkai yang didokumentasikan di
    //   lora_security.h & /PROTOCOL.md 1.2.

    uint8_t *ctPtr = outFrame + 5;
    aesCtrCrypt(txSeq, body, ctPtr, bodyLen);
    // Enkripsi body (plaintext) langsung ke posisi setelah header
    //   (byte ke-5 dst) di dalam outFrame -- tidak perlu buffer
    //   sementara terpisah untuk ciphertext, ditulis LANGSUNG ke tempat
    //   akhirnya di frame output.

    // mac dihitung atas version||seq||ciphertext (byte 0..5+bodyLen-1)
    uint8_t mac[8];
    hmac8(outFrame, 5 + bodyLen, mac);
    // HMAC dihitung atas SELURUH bagian frame yang SUDAH ditulis sejauh
    //   ini (header 5 byte + ciphertext) -- inilah "encrypt-then-MAC":
    //   MAC melindungi header & ciphertext SEKALIGUS, bukan cuma
    //   ciphertext saja (kalau version/seq dipalsukan tanpa mengubah
    //   ciphertext, MAC akan tetap terdeteksi tidak cocok).
    memcpy(outFrame + 5 + bodyLen, mac, 8);
    // Tulis 8 byte MAC ke posisi PALING AKHIR frame -- melengkapi
    //   format bingkai penuh.

    outFrameLen = frameLen;
    return true;
}

bool loraSecureWrap(const String &body,
                     uint8_t *outFrame, size_t outFrameCap, size_t &outFrameLen) {
    return loraSecureWrap((const uint8_t *)body.c_str(), body.length(),
                           outFrame, outFrameCap, outFrameLen);
    // Overload String cuma "meneruskan" ke versi buffer-byte di atas,
    //   mengubah representasi String jadi (pointer const char*, panjang)
    //   -- tidak ada logika baru di sini, murni kenyamanan pemanggilan.
}

bool loraSecureUnwrap(const uint8_t *frame, size_t frameLen,
                       uint8_t *outBody, size_t outBodyCap, size_t &outBodyLen) {
    if (frameLen <= LORA_SEC_FRAME_OVERHEAD) return false; // terlalu pendek, pasti bukan paket valid
    // Kalau frame lebih pendek dari overhead minimum (13 byte), bahkan
    //   TIDAK ADA RUANG untuk body sama sekali (body implisit akan
    //   negatif) -- ditolak sebelum aritmetika di bawah bisa menghasilkan
    //   underflow ukuran (size_t adalah unsigned, `frameLen - overhead`
    //   yang negatif akan "wrap around" jadi angka raksasa kalau tidak
    //   dicek dulu di sini).
    if (frame[0] != 0x01) return false; // versi tidak dikenal
    // Cek byte version -- kalau suatu saat protokol berubah (mis. jadi
    //   versi 0x02 dengan format berbeda), firmware versi lama akan
    //   dengan aman MENOLAK paket versi baru yang tidak dipahaminya,
    //   bukan salah mem-parsingnya.

    size_t bodyLen = frameLen - LORA_SEC_FRAME_OVERHEAD;
    if (bodyLen > outBodyCap) return false;
    // Pastikan body hasil dekripsi nanti tidak melebihi kapasitas buffer
    //   `outBody` milik pemanggil -- validasi SEBELUM proses dekripsi
    //   apa pun dimulai.

    uint32_t seq = ((uint32_t)frame[1] << 24) | ((uint32_t)frame[2] << 16) |
                   ((uint32_t)frame[3] << 8) | (uint32_t)frame[4];
    // Susun ulang 4 byte big-endian jadi satu uint32_t -- kebalikan
    //   dari cara menulisnya di loraSecureWrap.

    if (seq <= rxSeq) return false; // replay, atau paket lama -- ditolak

    // Verifikasi MAC dulu (atas ciphertext) SEBELUM mendekripsi apa pun --
    // supaya kita tidak pernah memproses/mempercayai ciphertext yang belum
    // terverifikasi keasliannya.
    uint8_t expectedMac[8];
    hmac8(frame, 5 + bodyLen, expectedMac);
    if (memcmp(expectedMac, frame + 5 + bodyLen, 8) != 0) {
        // CATATAN UNTUK DIDISKUSIKAN: perbandingan MAC di sini memakai
        //   memcmp() BIASA (bukan fungsi tahan timing-attack seperti
        //   crypto.timingSafeEqual() yang dipakai di server, lihat
        //   server/src/lib/crypto.js) -- secara teori ini rentan timing
        //   side-channel yang sama seperti dijelaskan di sana. Dalam
        //   praktiknya risikonya JAUH lebih rendah di sini karena kanal
        //   radio LoRa: (1) latensi & jitter transmisi radio itu sendiri
        //   jauh lebih besar & tidak stabil dibanding perbedaan waktu
        //   memcmp() (orde nanodetik), menutupi sinyal timing apa pun,
        //   dan (2) penyerang butuh mengukur waktu proses INTERNAL
        //   mikrokontroler dari luar lewat gelombang radio, yang jauh
        //   lebih sulit dari mengukur waktu respons HTTP biasa seperti
        //   di server. Tetap merupakan praktik yang lebih aman untuk
        //   diganti ke perbandingan konstan-waktu (mis. hitung manual XOR
        //   seluruh byte lalu OR-kan hasilnya) kalau proyek ini
        //   dikembangkan lebih lanjut -- baik disebut sebagai catatan
        //   perbaikan di sidang.
        return false; // tanda tangan tidak cocok -- paket palsu/diubah/beda PSK
    }

    aesCtrCrypt(seq, frame + 5, outBody, bodyLen);
    // Baru dekripsi SETELAH MAC terverifikasi cocok (encrypt-then-MAC:
    //   verifikasi dulu, proses isi baru kalau lolos).
    outBodyLen = bodyLen;

    // SENGAJA ditulis ke flash di SETIAP paket valid (tidak di-batch seperti
    // tx_seq) -- lihat catatan keamanan di bagian atas file ini.
    rxSeq = seq;
    prefs.putUInt(KEY_RX_SEQ, rxSeq);
    return true;
}
