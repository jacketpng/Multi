import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'models/tool.dart';
import 'services/tool_manager.dart';
import 'ui/pages/convert_page.dart';
import 'ui/pages/download_page.dart';
import 'ui/pages/image_page.dart';
import 'ui/pages/settings_page.dart';
import 'ui/pages/tools_page.dart';

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
      home: const _Shell(),
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
                  Icon(Icons.all_inclusive,
                      size: 32,
                      color: Theme.of(context).colorScheme.primary),
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
              children: const [
                DownloadPage(),
                ConvertPage(),
                ImagePage(),
                ToolsPage(),
                SettingsPage(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
