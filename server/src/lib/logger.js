// lib/logger.js — Structured logger (pino) menggantikan console.* mentah dengan log JSON yang gampang di-aggregasi (Railway, dsb).

const pino = require('pino');

// Di production tulis JSON per baris; di development pakai pretty print.
const isProd = process.env.NODE_ENV === 'production' || process.env.RAILWAY_ENVIRONMENT !== undefined;
// RAILWAY_ENVIRONMENT disuntikkan saat deploy → penanda handal kita di production.

const logger = pino({
  level: process.env.LOG_LEVEL || (isProd ? 'info' : 'debug'),
  // Level bisa di-tweak via env LOG_LEVEL (trace/debug/info/warn/error).
  redact: ['req.headers.authorization', 'req.headers.x-signature'],
  // Jangan pernah log token/signature mentah; redact menyensor field itu otomatis (cegah kebocoran kredensial lewat log).
  transport: isProd
    ? undefined
    : {
        target: 'pino-pretty',
        options: { colorize: true, translateTime: 'SYS:HH:MM:ss', ignore: 'pid,hostname' },
      },
});

module.exports = logger;
