import 'package:flutter/material.dart';

import '../services/maintenance_service.dart';
import '../theme.dart';

// ============================================================================
// maintenance_log_screen.dart — Tab "Pin / Jurnal Pemeliharaan".
//
// Catatan ringan per modul (node/gateway/sensor) supaya pemilik mudah
// melacak kondisi fisik alat di lapangan, mis. "TDS rusak, ganti kabel".
// Diurutkan: yang di-pin di atas, lalu terbaru. Tidak menyentuh server —
// murni penyimpanan lokal (lihat maintenance_service.dart).
// ============================================================================

class MaintenanceLogScreen extends StatelessWidget {
  const MaintenanceLogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Jurnal Pemeliharaan'),
        actions: [
          IconButton(
            tooltip: 'Tambah Catatan',
            icon: const Icon(Icons.add),
            onPressed: () => _openEditor(context, null),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<MaintenanceEntry>>(
        valueListenable: MaintenanceService.instance.entries,
        builder: (context, list, _) {
          if (list.isEmpty) {
            return ListView(
              children: [
                const SizedBox(height: AppSpacing.xxl),
                Icon(Icons.build_outlined,
                    size: AppSpacing.xl + 16,
                    color: AppColors.leaf.withValues(alpha: 0.5)),
                const SizedBox(height: AppSpacing.md),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                    child: Text(
                      'Belum ada catatan pemeliharaan.\n'
                      'Tekan tombol + untuk menandai modul yang rusak atau '
                      'perlu dicek.',
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
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xxl),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.xs),
            itemBuilder: (context, index) {
              final e = list[index];
              final mod = MaintenanceModule.fromId(e.moduleId);
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: AppColors.leaf.withValues(alpha: 0.12),
                    child: Icon(mod.icon, color: AppColors.leaf),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(mod.label,
                            style:
                                const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                      if (e.pinned)
                        const Icon(Icons.push_pin, size: 16, color: AppColors.sun),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Text(e.note),
                      const SizedBox(height: 4),
                      Text(
                        _formatStamp(e.createdAt) +
                            (e.deviceLabel != null ? ' · ${e.deviceLabel}' : ''),
                        style: const TextStyle(
                            fontSize: AppText.caption, color: AppColors.inkMuted),
                      ),
                    ],
                  ),
                  trailing: PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    onSelected: (action) async {
                      if (action == 'pin') {
                        await MaintenanceService.instance.togglePin(e);
                      } else if (action == 'delete') {
                        final ok = await _confirmDelete(context);
                        if (ok) await MaintenanceService.instance.deleteEntry(e.id);
                      }
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'pin',
                        child: Row(
                          children: [
                            Icon(e.pinned ? Icons.push_pin_outlined : Icons.push_pin,
                                size: 20),
                            const SizedBox(width: 12),
                            Text(e.pinned ? 'Lepas Pin' : 'Pin'),
                          ],
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete_outline,
                                size: 20, color: AppColors.berry),
                            SizedBox(width: 12),
                            Text('Hapus',
                                style: TextStyle(color: AppColors.berry)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(context, null),
        icon: const Icon(Icons.add),
        label: const Text('Catatan'),
      ),
    );
  }

  Future<void> _openEditor(BuildContext context, MaintenanceEntry? existing) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EntrySheet(entry: existing),
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hapus catatan?'),
        content: const Text('Catatan pemeliharaan ini akan dihapus secara permanen.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Hapus'),
          ),
        ],
      ),
    );
    return res == true;
  }

  String _formatStamp(DateTime d) {
    final now = DateTime.now();
    final sameDay = d.year == now.year && d.month == now.month && d.day == now.day;
    final time = '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
    if (sameDay) return 'Hari ini $time';
    return '${d.day}/${d.month}/${d.year} $time';
  }
}

// Sheet tambah/edit catatan pemeliharaan.
class _EntrySheet extends StatefulWidget {
  final MaintenanceEntry? entry;
  const _EntrySheet({this.entry});

  @override
  State<_EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends State<_EntrySheet> {
  MaintenanceModule _module = MaintenanceModule.node;
  final _noteCtrl = TextEditingController();
  bool _pinned = false;

  @override
  void initState() {
    super.initState();
    if (widget.entry != null) {
      _module = MaintenanceModule.fromId(widget.entry!.moduleId);
      _noteCtrl.text = widget.entry!.note;
      _pinned = widget.entry!.pinned;
    }
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(AppSpacing.radiusLg)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.md,
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: AppSpacing.md),
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text('Catatan Pemeliharaan',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: AppSpacing.md),
          DropdownButtonFormField<MaintenanceModule>(
            initialValue: _module,
            decoration: const InputDecoration(labelText: 'Modul'),
            items: MaintenanceModule.values
                .map((m) => DropdownMenuItem(
                      value: m,
                      child: Row(
                        children: [
                          Icon(m.icon, size: 20, color: AppColors.leaf),
                          const SizedBox(width: 12),
                          Text(m.label),
                        ],
                      ),
                    ))
                .toList(),
            onChanged: (m) => setState(() => _module = m ?? MaintenanceModule.node),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _noteCtrl,
            maxLines: 3,
            minLines: 1,
            decoration: const InputDecoration(
              labelText: 'Catatan (mis. "sensor TDS rusak, ganti kabel")',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Pin (tandai penting)'),
            subtitle: const Text('Muncul di atas & lebih mudah ditemukan.'),
            value: _pinned,
            onChanged: (v) => setState(() => _pinned = v),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () async {
                    final note = _noteCtrl.text.trim();
                    if (note.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Catatan tidak boleh kosong.')),
                      );
                      return;
                    }
                    if (widget.entry != null) {
                      await MaintenanceService.instance.saveEntry(
                        widget.entry!.copyWith(note: note, pinned: _pinned),
                      );
                    } else {
                      await MaintenanceService.instance.saveEntry(
                        MaintenanceEntry(
                          id: DateTime.now().microsecondsSinceEpoch.toString(),
                          moduleId: _module.id,
                          note: note,
                          createdAt: DateTime.now(),
                          pinned: _pinned,
                        ),
                      );
                    }
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: Text(widget.entry != null ? 'Simpan' : 'Tambah'),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    );
  }
}
