import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/alert.dart';
import '../services/notif_history_service.dart';
import '../theme.dart';

// =============================================================================
// NotificationHistoryView — isi tab "Notifikasi" di home.
//
// Menampilkan RIWAYAT peringatan tanaman (kondisi yang menyimpang dari
// threshold: tanah kering/basah, pupuk kurang/pekat, hama) yang tersimpan
// lokal oleh NotifHistoryService — terbaru di atas, dengan waktu & nama
// device. Beda dari popup status bar yang hilang, di sini pengguna bisa
// menelusuri kembali apa yang pernah terjadi pada tanamannya.
//
// Ini WIDGET BODY (bukan Scaffold penuh) supaya bisa ditanam di dalam tab
// DashboardScreen. Aksi "Tandai semua dibaca" & "Hapus semua" diekspos lewat
// tombol di header internal.
// =============================================================================
class NotificationHistoryView extends StatelessWidget {
  const NotificationHistoryView({super.key});

  Color _levelColor(BuildContext context, AlertLevel level) {
    switch (level) {
      case AlertLevel.critical:
        return AppColors.danger(context);
      case AlertLevel.warning:
        return AppColors.alert(context);
      case AlertLevel.info:
        return AppColors.success(context);
    }
  }

  IconData _levelIcon(AlertLevel level) {
    switch (level) {
      case AlertLevel.critical:
        return Icons.warning_amber_rounded;
      case AlertLevel.warning:
        return Icons.info_outline;
      case AlertLevel.info:
        return Icons.check_circle_outline;
    }
  }

  String _relativeTime(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'Baru saja';
    if (d.inMinutes < 60) return '${d.inMinutes} menit lalu';
    if (d.inHours < 24) return '${d.inHours} jam lalu';
    if (d.inDays < 7) return '${d.inDays} hari lalu';
    return DateFormat('d MMM yyyy, HH:mm').format(t);
  }

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hapus Semua Riwayat?'),
        content: const Text(
            'Seluruh riwayat peringatan akan dihapus. Tindakan ini tidak bisa dibatalkan.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColors.danger(context)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    if (ok == true) await NotifHistoryService.instance.clearAll();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<NotifRecord>>(
      valueListenable: NotifHistoryService.instance.records,
      builder: (context, records, _) {
        return Column(
          children: [
            // Header aksi (tandai dibaca / hapus semua).
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.md, AppSpacing.sm, AppSpacing.sm, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      records.isEmpty
                          ? 'Riwayat Peringatan'
                          : '${records.length} peringatan tercatat',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  if (records.isNotEmpty) ...[
                    TextButton.icon(
                      onPressed: () =>
                          NotifHistoryService.instance.markAllRead(),
                      icon: const Icon(Icons.done_all, size: 20),
                      label: const Text('Tandai dibaca'),
                    ),
                    IconButton(
                      tooltip: 'Hapus semua',
                      onPressed: () => _confirmClear(context),
                      icon: const Icon(Icons.delete_sweep_outlined),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: records.isEmpty
                  ? _EmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.md,
                          AppSpacing.sm, AppSpacing.md, AppSpacing.xxl),
                      itemCount: records.length,
                      itemBuilder: (context, i) {
                        final r = records[i];
                        final color = _levelColor(context, r.level);
                        return Card(
                          margin:
                              const EdgeInsets.only(bottom: AppSpacing.sm),
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.md),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: color.withValues(alpha: 0.14),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(_levelIcon(r.level),
                                      color: color, size: 22),
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              r.title,
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .titleMedium
                                                  ?.copyWith(
                                                      fontWeight:
                                                          FontWeight.w700),
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (!r.read)
                                            Container(
                                              width: 10,
                                              height: 10,
                                              margin: const EdgeInsets.only(
                                                  left: 6, top: 4),
                                              decoration: const BoxDecoration(
                                                color: AppColors.leaf,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        r.message,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium
                                            ?.copyWith(
                                                color: AppColors.inkMuted),
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          const Icon(Icons.router_outlined,
                                              size: 14,
                                              color: AppColors.inkMuted),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              r.deviceLabel,
                                              style: const TextStyle(
                                                  fontSize: AppText.caption,
                                                  color:
                                                      AppColors.inkMuted),
                                              maxLines: 1,
                                              overflow:
                                                  TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            _relativeTime(r.time),
                                            style: const TextStyle(
                                                fontSize: AppText.caption,
                                                color: AppColors.inkMuted),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: AppSpacing.xxl),
        Icon(Icons.notifications_none_rounded,
            size: AppSpacing.xl + 16,
            color: AppColors.leaf.withValues(alpha: 0.4)),
        const SizedBox(height: AppSpacing.md),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Text(
              'Belum ada peringatan.\nSaat kondisi tanaman menyimpang dari batas '
              '(tanah kering/basah, pupuk kurang/pekat, atau ada hama), '
              'riwayatnya akan muncul di sini.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: AppColors.inkMuted),
            ),
          ),
        ),
      ],
    );
  }
}
