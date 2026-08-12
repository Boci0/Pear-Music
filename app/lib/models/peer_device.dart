/// A paired remote device shown in the Devices screen.
class PeerDevice {
  final String deviceId;
  final String deviceName;
  bool online;

  PeerDevice({
    required this.deviceId,
    required this.deviceName,
    this.online = false,
  });

  PeerDevice copyWith({String? deviceName, bool? online}) => PeerDevice(
        deviceId: deviceId,
        deviceName: deviceName ?? this.deviceName,
        online: online ?? this.online,
      );

  Map<String, dynamic> toJson() =>
      {'deviceId': deviceId, 'deviceName': deviceName, 'online': online};

  factory PeerDevice.fromJson(Map<String, dynamic> json) => PeerDevice(
        deviceId: json['deviceId'] as String,
        deviceName: json['deviceName'] as String? ?? 'Unnamed device',
        online: json['online'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is PeerDevice && other.deviceId == deviceId;

  @override
  int get hashCode => deviceId.hashCode;

  @override
  String toString() => 'Peer($deviceName)';
}
