import 'package:dawarich/core/data/repositories/local_point_repository_interfaces.dart';
import 'package:dawarich/core/domain/models/point/local/local_point.dart';
import 'package:dawarich/core/domain/models/point/local/local_point_geometry.dart';
import 'package:dawarich/core/domain/models/point/local/local_point_properties.dart';
import 'package:dawarich/core/network/repositories/api_point_repository_interfaces.dart';
import 'package:dawarich/features/batch/application/usecases/batch_upload_workflow_usecase.dart';
import 'package:dawarich/features/tracking/data/data_transfer_objects/point/upload/dawarich_point_batch_dto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:option_result/option_result.dart';

class _Api implements IApiPointRepository {
  bool online = false;
  int calls = 0;

  @override
  Future<Result<(), String>> uploadBatch(DawarichPointBatchDto batch) async {
    calls++;
    return online ? const Ok(()) : const Err('connection error');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class _Local implements IPointLocalRepository {
  final uploaded = <int>[];

  @override
  Future<int> markBatchAsUploaded(int userId, List<int> pointIds) async {
    uploaded.addAll(pointIds);
    return pointIds.length;
  }

  @override
  Future<int> deleteUploadedPointsExceptLast(int userId) async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

LocalPoint _point(int id) => LocalPoint(
      id: id,
      type: 'Feature',
      geometry: LocalPointGeometry(type: 'Point', longitude: 4.8 + id / 1000, latitude: 43.9),
      properties: LocalPointProperties(
        batteryState: 'unknown',
        batteryLevel: 0.5,
        wifi: '',
        recordTimestamp: DateTime.utc(2026, 1, 1, 12, 0, id),
        providerTimestamp: DateTime.utc(2026, 1, 1, 12, 0, id),
        horizontalAccuracy: 10,
        verticalAccuracy: 10,
        altitude: 0,
        speed: 0,
        speedAccuracy: 0,
        course: 0,
        courseAccuracy: 0,
        deviceId: 'Pixel 8',
      ),
      userId: 1,
      isUploaded: false,
    );

void main() {
  test('réseau indisponible : l\'envoi abandonne vite et aucun point n\'est marqué envoyé', () async {
    final api = _Api();
    final local = _Local();
    final workflow = BatchUploadWorkflowUseCase(api, local);

    final result = await workflow([for (var i = 1; i <= 40; i++) _point(i)], 1);

    expect(result, isA<Err>());
    expect(local.uploaded, isEmpty, reason: 'les points restent en local');
    // 1 envoi du lot + 3 essais individuels, au lieu de 1 + 40 timeouts.
    expect(api.calls, 4);
  });

  test('retour du réseau : les points conservés repartent et sont marqués envoyés', () async {
    final api = _Api();
    final local = _Local();
    final workflow = BatchUploadWorkflowUseCase(api, local);
    final pending = [for (var i = 1; i <= 5; i++) _point(i)];

    expect(await workflow(pending, 1), isA<Err>());
    expect(local.uploaded, isEmpty);

    api.online = true;
    final result = await workflow(pending, 1);

    expect(result, isA<Ok>());
    expect(local.uploaded, unorderedEquals([1, 2, 3, 4, 5]));
  });
}
