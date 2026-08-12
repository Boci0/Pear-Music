import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

void showPearMusicAboutDialog(BuildContext context) {
  showAboutDialog(
    context: context,
    applicationName: 'Pear Music',
    applicationVersion: '1.0.0',
    applicationIcon: const Icon(
      Icons.music_note_rounded,
      size: 48,
      color: Colors.greenAccent,
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
      const SizedBox(height: 12),
      TextButton.icon(
        onPressed: () async {
          final uri = Uri.parse('https://github.com/Boci0/Pear-Music');
          if (await canLaunchUrl(uri)) {
            await launchUrl(uri);
          }
        },
        icon: const Icon(Icons.code),
        label: const Text('View GitHub Repository'),
      ),
    ],
  );
}
