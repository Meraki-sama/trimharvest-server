// ============================================================================
// lib/logger.js — Structured logger (pino). Menggantikan pemakaian
// console.log/console.error mentah dengan log terstruktur (JSON) yang
// mudah di-parsing oleh aggregator (Railway log, Datadog, dsb) dan
// memudahkan forensik/audit saat ada insiden. Lihat juga lib/audit.js
// untuk log kejadian keamanan yang spesifik.
// ============================================================================
const pino = require('pino');

// Di production (ada env NODE_ENV=production / Railway), pino menulis JSON
// per baris (mudah di-index). Di development, pakai pretty print biar
// enak dibaca di terminal lokal.
const isProd = process.env.NODE_ENV === 'production' || process.env.RAILWAY_ENVIRONMENT !== undefined;
// ^ Railway menyuntikkan env RAILWAY_ENVIRONMENT saat deploy; ini penanda
//   handal bahwa kita berjalan di production.

const logger = pino({
  level: process.env.LOG_LEVEL || (isProd ? 'info' : 'debug'),
  // ^ Level bisa di-tweak lewat env LOG_LEVEL (trace/debug/info/warn/error).
  redact: ['req.headers.authorization', 'req.headers.x-signature'],
  // ^ JANGAN pernah log token/signature mentah ke log (kebocoran kredensial
  //   lewat log adalah vektor umum). redact menyensor field itu otomatis.
  transport: isProd
    ? undefined
    : {
        target: 'pino-pretty',
        options: { colorize: true, translateTime: 'SYS:HH:MM:ss', ignore: 'pid,hostname' },
      },
});

module.exports = logger;
