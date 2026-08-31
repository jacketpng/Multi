import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'services/convert_manager.dart';
import 'services/download_manager.dart';
import 'services/image_service.dart';
import 'services/settings.dart';
import 'services/tool_manager.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = Settings();
  final tools = ToolManager();
  final downloads = DownloadManager(tools);
  final converts = ConvertManager(tools)..settings = settings;

  // A finished download hands its files to the Convert page rather than
  // starting a conversion behind the user's back: they get the same
  // plan, codec choices and size estimates as any other conversion.
  downloads.onConvertRequested = (files, containerId) {
    for (final f in files) {
      converts.queueFromDownload(f, containerId);
    }
  };

  settings.load().then((_) {
    downloads.maxConcurrent = settings.maxConcurrent;
    tools.init(checkForUpdates: settings.checkUpdatesOnLaunch);
  });
  downloads.init();

  runApp(MultiProvider(
    providers: [
      ChangeNotifierProvider.value(value: settings),
      ChangeNotifierProvider.value(value: tools),
      ChangeNotifierProvider.value(value: downloads),
      ChangeNotifierProvider.value(value: converts),
      ChangeNotifierProvider(create: (_) => ImageService(tools)),
    ],
    child: const MultiApp(),
  ));
}
