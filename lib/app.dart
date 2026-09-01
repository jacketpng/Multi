import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/tool.dart';
import 'services/tool_manager.dart';
import 'ui/pages/convert_page.dart';
import 'ui/pages/download_page.dart';
import 'ui/pages/image_page.dart';
import 'ui/pages/onboarding_page.dart';
import 'ui/pages/settings_page.dart';
import 'ui/pages/tools_page.dart';
import 'ui/widgets/multi_logo.dart';

/// Tells a page whether it is the one currently on screen. Needed
/// because IndexedStack keeps every page mounted, and desktop_drop
/// notifies every mounted DropTarget whose bounds contain the pointer.
class PageVisibility extends InheritedWidget {
  final bool isActive;
  const PageVisibility(
      {super.key, required this.isActive, required super.child});

  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<PageVisibility>()
          ?.isActive ??
      true;

  @override
  bool updateShouldNotify(PageVisibility old) => old.isActive != isActive;
}

class MultiApp extends StatelessWidget {
  const MultiApp({super.key});

  @override
  Widget build(BuildContext context) {
    final seed = const Color(0xFF6C63FF);
    return MaterialApp(
      title: 'Multi',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed),
        visualDensity: VisualDensity.comfortable,
      ),
      darkTheme: ThemeData(
        colorScheme:
            ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        visualDensity: VisualDensity.comfortable,
      ),
      themeMode: ThemeMode.system,
      home: const _Gate(),
    );
  }
}

/// Holds the app at the onboarding screen until the tools are in place,
/// so nothing can be used half-installed. Shown once per launch while
/// setup runs; it steps aside as soon as everything has settled.
class _Gate extends StatefulWidget {
  const _Gate();

  @override
  State<_Gate> createState() => _GateState();
}

class _GateState extends State<_Gate> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final tm = context.watch<ToolManager>();
    // Once setup has finished cleanly, move on without making the user
    // click; only stop for their attention if something is missing.
    if (!_dismissed && tm.setupComplete && !tm.hasProblems) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_dismissed) setState(() => _dismissed = true);
      });
    }
    if (_dismissed) return const _Shell();
    return OnboardingPage(
      onContinue: () => setState(() => _dismissed = true),
    );
  }
}

class _Shell extends StatefulWidget {
  const _Shell();

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final tools = context.watch<ToolManager>();
    final busy = tools.checking ||
        ToolId.values.any((t) =>
            tools.statusOf(t).kind == ToolStatusKind.downloading ||
            tools.statusOf(t).kind == ToolStatusKind.installing);

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (i) => setState(() => _index = i),
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                children: [
                  MultiLogo(
                    size: 34,
                    color: Theme.of(context).colorScheme.primary,
                    gap: Theme.of(context).colorScheme.surface,
                  ),

                  const SizedBox(height: 4),
                  Text('Multi',
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            destinations: [
              const NavigationRailDestination(
                icon: Icon(Icons.download_outlined),
                selectedIcon: Icon(Icons.download),
                label: Text('Download'),
              ),
              const NavigationRailDestination(
                icon: Icon(Icons.movie_outlined),
                selectedIcon: Icon(Icons.movie),
                label: Text('Convert'),
              ),
              const NavigationRailDestination(
                icon: Icon(Icons.image_outlined),
                selectedIcon: Icon(Icons.image),
                label: Text('Images'),
              ),
              NavigationRailDestination(
                icon: Badge(
                  isLabelVisible: busy,
                  label: const SizedBox(
                      width: 8,
                      height: 8,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.5, color: Colors.white)),
                  child: const Icon(Icons.handyman_outlined),
                ),
                selectedIcon: const Icon(Icons.handyman),
                label: const Text('Tools'),
              ),
              const NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('Settings'),
              ),
            ],
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                for (final (i, page) in const <Widget>[
                  DownloadPage(),
                  ConvertPage(),
                  ImagePage(),
                  ToolsPage(),
                  SettingsPage(),
                ].indexed)
                  PageVisibility(isActive: i == _index, child: page),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
