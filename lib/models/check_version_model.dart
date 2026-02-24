class CheckVersionRequest {
  final DeviceInfo deviceInfo;
  final CurrentVersions currentVersions;

  CheckVersionRequest({
    required this.deviceInfo,
    required this.currentVersions,
  });

  Map<String, dynamic> toJson() {
    return {
      'device_info': deviceInfo.toJson(),
      'current_versions': currentVersions.toJson(),
    };
  }
}

class DeviceInfo {
  final String deviceId;
  final String plateNo;
  final String appVersion;

  DeviceInfo({
    required this.deviceId,
    required this.plateNo,
    required this.appVersion,
  });

  Map<String, dynamic> toJson() {
    return {
      'device_id': deviceId,
      'plate_no': plateNo,
      'app_version': appVersion,
    };
  }
}

class CurrentVersions {
  final String masterDataVersion;
  final int routeId;

  CurrentVersions({required this.masterDataVersion, required this.routeId});

  Map<String, dynamic> toJson() {
    return {'master_data_version': masterDataVersion, 'route_id': routeId};
  }
}

class CheckVersionResponse {
  final bool isSuccess;
  final String message;
  final CheckVersionData? data;

  CheckVersionResponse({
    required this.isSuccess,
    required this.message,
    this.data,
  });

  factory CheckVersionResponse.fromJson(Map<String, dynamic> json) {
    return CheckVersionResponse(
      isSuccess: json['isSuccess'] ?? false,
      message: json['message'] ?? '',
      data: json['data'] != null
          ? CheckVersionData.fromJson(json['data'])
          : null,
    );
  }
}

class CheckVersionData {
  final bool updateRequired;
  final String newVersion;
  final String syncStrategy;
  final AssignedRoute assignedRoute;
  final List<SyncFile> files;

  CheckVersionData({
    required this.updateRequired,
    required this.newVersion,
    required this.syncStrategy,
    required this.assignedRoute,
    required this.files,
  });

  factory CheckVersionData.fromJson(Map<String, dynamic> json) {
    return CheckVersionData(
      updateRequired: json['update_required'] ?? false,
      newVersion: json['new_version'] ?? '',
      syncStrategy: json['sync_strategy'] ?? '',
      assignedRoute: AssignedRoute.fromJson(json['assigned_route'] ?? {}),
      files:
          (json['files'] as List?)
              ?.map((item) => SyncFile.fromJson(item))
              .toList() ??
          [],
    );
  }
}

class AssignedRoute {
  final int routeId;
  final String routeName;

  AssignedRoute({required this.routeId, required this.routeName});

  factory AssignedRoute.fromJson(Map<String, dynamic> json) {
    return AssignedRoute(
      routeId: json['route_id'] ?? 0,
      routeName: json['route_name'] ?? '',
    );
  }
}

class SyncFile {
  final String module;
  final String url;

  SyncFile({required this.module, required this.url});

  factory SyncFile.fromJson(Map<String, dynamic> json) {
    return SyncFile(module: json['module'] ?? '', url: json['url'] ?? '');
  }
}
