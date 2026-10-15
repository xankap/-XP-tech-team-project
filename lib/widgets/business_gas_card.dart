import 'package:flutter/material.dart';

import '../services/xp_api.dart';

/// Server-side gas level + weekly usage for the signed-in business.
class BusinessGasCard extends StatefulWidget {
  const BusinessGasCard({super.key});
  @override
  State<BusinessGasCard> createState() => _BusinessGasCardState();
}

class _BusinessGasCardState extends State<BusinessGasCard> {
  final _api = XpApi();
  late Future<BusinessGasSummary> _future = _api.myGas();

  void _reload() => setState(() => _future = _api.myGas());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: FutureBuilder<BusinessGasSummary>(
          future: _future,
          builder: (context, snap) {
            final header = Row(children: [
              Icon(Icons.local_fire_department_rounded, color: cs.primary),
              const SizedBox(width: 8),
              Expanded(child: Text('Business gas (cloud)',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
              IconButton(tooltip: 'Refresh', onPressed: _reload, icon: const Icon(Icons.refresh_rounded)),
            ]);
            if (snap.connectionState != ConnectionState.done) {
              return Column(children: [header, const Padding(
                  padding: EdgeInsets.all(12), child: LinearProgressIndicator())]);
            }
            if (snap.hasError) {
              final e = snap.error;
              final msg = e is XpApiException && e.statusCode == 404
                  ? 'No business profile on the server yet.'
                  : e.toString();
              return Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [header, Text(msg, style: TextStyle(color: cs.onSurfaceVariant))]);
            }
            final s = snap.data!;
            final maxKg = s.weekly.fold<double>(0, (m, w) => w.kgUsed > m ? w.kgUsed : m);
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              header,
              Text(
                s.latestKg != null
                    ? '${s.latestKg!.toStringAsFixed(2)} kg left'
                    : s.latestPercent != null ? '${s.latestPercent!.toStringAsFixed(0)}% left' : 'No readings yet',
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900, color: cs.primary),
              ),
              if (s.latestAt != null)
                Text('Updated ${s.latestAt}'.split('.').first,
                    style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 12),
              ...s.weekly.map((w) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      SizedBox(width: 64, child: Text('${w.weekStart.day}/${w.weekStart.month}',
                          style: theme.textTheme.bodySmall)),
                      Expanded(child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          minHeight: 10,
                          value: maxKg == 0 ? 0 : w.kgUsed / maxKg,
                          backgroundColor: cs.surfaceContainerHighest,
                        ),
                      )),
                      SizedBox(width: 72, child: Text('${w.kgUsed.toStringAsFixed(1)} kg', textAlign: TextAlign.right,
                          style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700))),
                    ]),
                  )),
            ]);
          },
        ),
      ),
    );
  }
}
