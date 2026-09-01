import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/tool.dart';
import '../../services/tool_manager.dart';
import '../widgets/multi_logo.dart';

/// First-run screen: the app waits here while the media tools are
/// fetched, so nothing can be used half-installed. It shows the logo,
/// the app name, and a progress bar per tool.
class OnboardingPage extends StatelessWidget {
  final VoidCallback onContinue;
  const OnboardingPage({super.key, required this.onContinue});

  @override
  Widget build(BuildContext context) {
    final tm = context.watch<ToolManager>();
    final cs = Theme.of(context).colorScheme;
    final done = tm.setupComplete;

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                MultiLogo(size: 76, color: cs.primary, gap: cs.surface),
                const SizedBox(height: 12),

                Text('Multi',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.bold, letterSpacing: -1)),
                const SizedBox(height: 6),
                Text(
                  done
                      ? (tm.hasProblems
                          ? 'Setup finished, but some tools are unavailable.'
                          : 'Everything is ready.')
                      : 'Updating tools.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: cs.outline),
                ),
                const SizedBox(height: 28),
                for (final spec in toolSpecs) _ToolRow(spec: spec),
                const SizedBox(height: 28),
                FilledButton.icon(
                  onPressed: done ? onContinue : null,
                  icon: Icon(done ? Icons.arrow_forward : Icons.hourglass_top),
                  label: Text(done
                      ? 'Launch app.'
                      : '${tm.readyCount} of ${ToolId.values.length} ready…'),
                ),
                if (done && tm.hasProblems)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Multi will still work, but with some features missing.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: cs.outline),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolRow extends StatelessWidget {
  final ToolSpec spec;
  const _ToolRow({required this.spec});

  @override
  Widget build(BuildContext context) {
    final tm = context.watch<ToolManager>();
    final st = tm.statusOf(spec.id);
    final cs = Theme.of(context).colorScheme;

    final (value, label, color) = switch (st.kind) {
      ToolStatusKind.ready => (
          1.0,
          st.installedVersion == null ? 'ready' : 'v${st.installedVersion}',
          Colors.green
        ),
      ToolStatusKind.usingSystem => (1.0, 'using system copy', cs.tertiary),
      ToolStatusKind.downloading => (
          st.progress,
          st.progress == null
              ? 'downloading…'
              : 'downloading ${(st.progress! * 100).round()}%',
          cs.primary
        ),
      ToolStatusKind.installing => (null, 'installing…', cs.primary),
      ToolStatusKind.checking => (null, 'checking…', cs.secondary),
      ToolStatusKind.missing => (0.0, 'not available', cs.error),
      ToolStatusKind.error => (0.0, 'failed', cs.error),
      _ => (0.0, 'waiting…', cs.outline),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(spec.id.displayName,
                    style: Theme.of(context).textTheme.bodyMedium),
              ),
              Text(label,
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: color)),
            ],
          ),
          const SizedBox(height: 5),
          LinearProgressIndicator(
            value: value,
            minHeight: 5,
            borderRadius: BorderRadius.circular(3),
            color: color,
            backgroundColor: cs.surfaceContainerHighest,
          ),
        ],
      ),
    );
  }
}
