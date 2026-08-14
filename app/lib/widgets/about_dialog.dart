import 'package:flutter/material.dart';

import '../services/update_service.dart';

void showPearMusicAboutDialog(BuildContext context) {
  showAboutDialog(
    context: context,
    applicationName: 'Pear Music',
    applicationVersion: UpdateService.currentVersion,
    applicationIcon: Image.asset(
      'assets/pear_logo.png',
      width: 56,
      height: 56,
    ),
    applicationLegalese: 'Copyright (c) 2026 Boci0\nLicensed under the MIT License.',
    children: [
      const SizedBox(height: 16),
      Text(
        'Pear Music is a peer-to-peer music sync application for Windows and Android. '
        'Your music library stays directly synchronized between your devices without '
        'cloud storage or accounts.',
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      const SizedBox(height: 16),
      const Text(
        'MIT License:\n'
        'Permission is hereby granted, free of charge, to any person obtaining a copy '
        'of this software and associated documentation files, to deal in the Software '
        'without restriction, including without limitation the rights to use, copy, modify, '
        'merge, publish, distribute, sublicense, and/or sell copies of the Software.',
        style: TextStyle(fontSize: 11, color: Colors.grey),
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: () => UpdateService.checkForUpdates(context),
        icon: const Icon(Icons.system_update_outlined),
        label: const Text('Check for Updates'),
      ),
      const SizedBox(height: 12),
      SelectableText(
        'GitHub: https://github.com/Boci0/Pear-Music',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    ],
  );
}
