import 'package:auto_route/annotations.dart';
import 'package:dawarich/core/di/providers/viewmodel_providers.dart';
import 'package:dawarich/core/theme/app_gradients.dart';
import 'package:dawarich/shared/widgets/app_scaffold.dart';
import 'package:dawarich/shared/widgets/custom_loading_indicator.dart';
import 'package:flutter/material.dart';
import 'package:dawarich/core/shell/drawer/drawer.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_animations/flutter_map_animations.dart';
import 'package:flutter_map_location_marker/flutter_map_location_marker.dart';
import 'package:dawarich/features/family/presentation/family_layer.dart';
import 'package:dawarich/features/timeline/presentation/models/timeline_page_viewmodel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

@RoutePage()
final class TimelineView extends ConsumerStatefulWidget {
  const TimelineView({super.key});

  @override
  ConsumerState<TimelineView> createState() => _TimelinePageState();
}

class _TimelinePageState extends ConsumerState<TimelineView> with TickerProviderStateMixin {
  late final AnimatedMapController _animatedMapController;

  @override
  void initState() {
    super.initState();
    _animatedMapController = AnimatedMapController(vsync: this);
  }

  @override
  Widget build(BuildContext context) {
    final vmAsync = ref.watch(timelineViewModelProvider);

    return vmAsync.when(
      loading: () => _loadingScaffold(context, 'Preparing the map...'),
      error: (e, _) => _errorScaffold(context, e),
      data: (vm) {
        vm.setAnimatedMapController(_animatedMapController);
        return ListenableBuilder(
          listenable: vm,
          builder: (context, _) {
            if (vm.currentLocation == null) {
              return _loadingScaffold(context, 'Preparing the map...');
            }
            return _pageBase(context, vm);
          },
        );
      },
    );
  }

  Widget _loadingScaffold(BuildContext context, String message) {
    return Container(
      decoration: BoxDecoration(gradient: Theme.of(context).pageBackground),
      child: AppScaffold(
        title: "Timeline",
        titleFontSize: 20,
        appBarBackgroundColor: Colors.transparent,
        scaffoldBackgroundColor: Colors.transparent,
        drawer: CustomDrawer(),
        body: Center(child: TextLoadingIndicator(message: message)),
      ),
    );
  }

  Widget _errorScaffold(BuildContext context, Object error) {
    return Container(
      decoration: BoxDecoration(gradient: Theme.of(context).pageBackground),
      child: AppScaffold(
        title: "Timeline",
        titleFontSize: 20,
        appBarBackgroundColor: Colors.transparent,
        scaffoldBackgroundColor: Colors.transparent,
        drawer: CustomDrawer(),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(error.toString(), textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }

  // Compact bar under the map: just the day selector (and a loading hint).
  // A fixed-height bar replaces the draggable sheet, which left a large empty
  // dark block over the map.
  Widget _buildBottomSheet(TimelineViewModel mapModel) {
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: Theme.of(context).pageBackground,
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(24.0),
            topRight: Radius.circular(24.0),
          ),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 6.0,
              offset: Offset(0, -2),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_new),
                      onPressed: mapModel.isLoading
                          ? null
                          : () async {
                              await mapModel.loadPreviousDay();
                            },
                    ),
                    Expanded(
                      child: Center(
                        child: TextButton(
                          onPressed: mapModel.isLoading
                              ? null
                              : () {
                                  _datePicker(context, mapModel);
                                },
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                vertical: 10, horizontal: 16),
                            backgroundColor: Colors.transparent,
                            foregroundColor: Theme.of(context).primaryColor,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8.0),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                mapModel.displayDate(),
                                style: Theme.of(context).textTheme.bodyLarge,
                              ),
                              Icon(
                                Icons.arrow_drop_down,
                                color: Theme.of(context).iconTheme.color,
                                size: 20,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (!mapModel.isTodaySelected())
                      IconButton(
                        icon: const Icon(Icons.arrow_forward_ios),
                        onPressed: mapModel.isLoading
                            ? null
                            : () {
                                mapModel.loadNextDay();
                              },
                      )
                    else
                      const SizedBox(width: 48),
                  ],
                ),
                if (mapModel.isLoading)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: TextLoadingIndicator(
                        message: "Loading your timeline..."),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _mapButton({required IconData icon, required VoidCallback onTap}) {
    return Material(
      shape: const CircleBorder(),
      elevation: 2,
      color: Colors.white,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 20, color: Colors.black87),
        ),
      ),
    );
  }

  Future<void> _datePicker(BuildContext context, TimelineViewModel mapModel) async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: mapModel.selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );

    if (pickedDate != null) {
      await mapModel.processNewDate(pickedDate);
    }
  }

  Widget _pageContent(TimelineViewModel mapModel) {

    return Stack(
      children: [
        FlutterMap(
          mapController: _animatedMapController.mapController,
          options: MapOptions(
            initialCenter: mapModel.currentLocation!,
            initialZoom: 14.0,
            onMapReady: () {
              mapModel.markMapReady();
            }
          ),
          children: [
            TileLayer(
              urlTemplate:
                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.sunstep.travel',
              maxNativeZoom: 19,
            ),
            // --- API points (historical) ---
            if (mapModel.points.isNotEmpty)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: mapModel.points,
                    strokeWidth: 6.0,
                    color: Colors.blue.withValues(alpha: 0.8),
                    borderStrokeWidth: 2.0,
                    borderColor: Colors.white.withValues(alpha: 0.7),
                  ),
                ],
              ),
            if (mapModel.points.isNotEmpty)
              MarkerLayer(
                markers: mapModel.points.map((p) {
                  return Marker(
                    point: p,
                    width: 5,
                    height: 5,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.blue,
                        border: Border.all(color: Colors.white, width: 1),
                      ),
                    ),
                  );
                }).toList(),
              ),

            // --- Local points (live) - drawn ABOVE API points ---
            if (mapModel.localPoints.isNotEmpty)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: mapModel.localPoints,
                    strokeWidth: 6.0,
                    color: Colors.orange.withValues(alpha: 0.85),
                    borderStrokeWidth: 2.0,
                    borderColor: Colors.black.withValues(alpha: 0.5),
                  ),
                ],
              ),
            if (mapModel.localPoints.isNotEmpty)
              MarkerLayer(
                markers: mapModel.localPoints.map((p) {
                  return Marker(
                    point: p,
                    width: 6,
                    height: 6,
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.orange,
                        border: Border.all(color: Colors.black.withValues(alpha: 0.6), width: 1),
                      ),
                    ),
                  );
                }).toList(),
              ),
            const FamilyLayer(),
            const CurrentLocationLayer(),
          ],
        ),
        _buildBottomSheet(mapModel),
        Positioned(
          top: 16,
          right: 16,
          child: Column(
            children: [
              _mapButton(icon: Icons.add, onTap: () => mapModel.zoomIn()),
              const SizedBox(height: 8),
              _mapButton(icon: Icons.remove, onTap: () => mapModel.zoomOut()),
              const SizedBox(height: 8),
              _mapButton(
                  icon: Icons.my_location, onTap: () => mapModel.centerMap()),
            ],
          ),
        ),
      ],
    );
  }

  Widget _pageBase(BuildContext context, TimelineViewModel vm) {
    return Container(
      decoration: BoxDecoration(gradient: Theme.of(context).pageBackground),
      child: AppScaffold(
        title: "Timeline",
        titleFontSize: 20,
        appBarBackgroundColor: Colors.transparent,
        scaffoldBackgroundColor: Colors.transparent,
        drawer: CustomDrawer(),
        body: _pageContent(vm),
      ),
    );
  }


}
