import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/app_controller.dart';
import '../models/peer_device.dart';
import 'pair_screen.dart';

/// Devices tab: shows this device + all paired devices, with pair/unpair.
class DevicesScreen extends StatelessWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final peers = controller.pairedDevices;

    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ThisDeviceCard(controller: controller),
          const SizedBox(height: 24),
          Row(
            children: [
              Text('Paired devices',
                  style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text('${peers.length}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      )),
            ],
          ),
          const SizedBox(height: 8),
          if (peers.isEmpty)
            _EmptyPeers(onPair: () => _openPair(context))
          else ...[
            ...peers.map((peer) => _PeerTile(
                  peer: peer,
                  onUnpair: () => _confirmUnpair(context, controller, peer),
                )),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => _openPair(context),
                  icon: const Icon(Icons.link),
                  label: const Text('Pair another device'),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    controller.forceSync();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Force sync initiated with paired devices'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.sync),
                  label: const Text('Force Sync'),
                ),
              ],
            ),
          ],
          const SizedBox(height: 24),
          Text(
            'How it works:\n'
            '1. Tap "Pair a device" and generate a pairing code.\n'
            '2. On the other device, enter that code.\n'
            '3. Devices connect over the internet (P2P) and music you add is '
            'synced to every paired device automatically.\n'
            '4. Unpairing a device automatically removes the songs it '
            'received from you.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }

  void _openPair(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PairScreen()),
    );
  }

  Future<void> _confirmUnpair(
    BuildContext context,
    AppController controller,
    PeerDevice peer,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Unpair ${peer.deviceName}?'),
        content: const Text(
          'This removes the pairing and deletes the songs you received from '
          'this device. Songs you added yourself stay in your library.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unpair'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.unpair(peer);
    }
  }
}

class _ThisDeviceCard extends StatelessWidget {
  final AppController controller;
  const _ThisDeviceCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(Icons.computer,
              color: theme.colorScheme.onPrimaryContainer),
        ),
        title: Text('This device',
            style: theme.textTheme.labelLarge
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        subtitle: Text(controller.identity.deviceName),
        trailing: Icon(
          controller.connectionStatus == 'connected'
              ? Icons.cloud_done
              : Icons.cloud_off,
          color: controller.connectionStatus == 'connected'
              ? Colors.green
              : Colors.grey,
        ),
      ),
    );
  }
}

class _PeerTile extends StatelessWidget {
  final PeerDevice peer;
  final VoidCallback onUnpair;

  const _PeerTile({required this.peer, required this.onUnpair});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: peer.online
                  ? theme.colorScheme.primaryContainer
                  : theme.dividerColor,
              child: Text(
                peer.deviceName.isEmpty
                    ? '?'
                    : peer.deviceName[0].toUpperCase(),
                style: TextStyle(
                  color: peer.online
                      ? theme.colorScheme.onPrimaryContainer
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            title: Text(peer.deviceName),
            subtitle: Row(
              children: [
                Icon(
                  peer.online ? Icons.circle : Icons.circle_outlined,
                  size: 10,
                  color: peer.online ? Colors.green : Colors.grey,
                ),
                const SizedBox(width: 6),
                Text(peer.online ? 'Online · connected' : 'Offline'),
              ],
            ),
            trailing: IconButton(
              tooltip: 'Unpair',
              icon: Icon(Icons.link_off, color: theme.colorScheme.error),
              onPressed: onUnpair,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyPeers extends StatelessWidget {
  final VoidCallback onPair;
  const _EmptyPeers({required this.onPair});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(Icons.devices_other,
              size: 56, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: 8),
          Text('No devices paired yet',
              style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          FilledButton.icon(
            onPressed: onPair,
            icon: const Icon(Icons.link),
            label: const Text('Pair a device'),
          ),
        ],
      ),
    );
  }
}
