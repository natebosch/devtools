// Copyright 2019 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:math' as math;

import 'package:vm_service_lib/vm_service_lib.dart';

import '../vm_service_wrapper.dart';

class MemoryTracker {
  MemoryTracker(this.service);

  static const Duration kUpdateDelay = Duration(milliseconds: 200);

  VmServiceWrapper service;
  Timer _pollingTimer;
  final StreamController<Null> _changeController =
      StreamController<Null>.broadcast();

  final List<HeapSample> samples = <HeapSample>[];
  final Map<String, List<HeapSpace>> isolateHeaps = <String, List<HeapSpace>>{};
  int heapMax;
  int processRss;

  bool get hasConnection => service != null;

  Stream<Null> get onChange => _changeController.stream;

  int get currentCapacity => samples.last.capacity;
  int get currentUsed => samples.last.used;
  int get currentExternal => samples.last.external;

  void start() {
    _pollingTimer = Timer(const Duration(milliseconds: 500), _pollMemory);
    service.onGCEvent.listen(_handleGCEvent);
  }

  void stop() {
    _pollingTimer?.cancel();
    service = null;
  }

  void _handleGCEvent(Event event) {
    //final bool ignore = event.json['reason'] == 'compact';

    final List<HeapSpace> heaps = <HeapSpace>[
      HeapSpace.parse(event.json['new']),
      HeapSpace.parse(event.json['old'])
    ];
    _updateGCEvent(event.isolate.id, heaps);
    // TODO(terry): expose when GC occured as markers in memory timeline.
  }

  // TODO(terry): Discuss need a record/stop record for memory?  Unless expensive probably not.
  Future<Null> _pollMemory() async {
    if (!hasConnection) {
      return;
    }

    final VM vm = await service.getVM();
    // TODO(terry): Need to handle a possible Sentinel being returned.
    final List<Isolate> isolates =
        await Future.wait(vm.isolates.map((IsolateRef ref) async {
      return await service.getIsolate(ref.id);
    }));
    _update(vm, isolates);

    _pollingTimer = Timer(kUpdateDelay, _pollMemory);
  }

  void _update(VM vm, List<Isolate> isolates) {
    processRss = vm.json['_currentRSS'];

    isolateHeaps.clear();

    for (Isolate isolate in isolates) {
      final List<HeapSpace> heaps = getHeaps(isolate).toList();
      isolateHeaps[isolate.id] = heaps;
    }

    _recalculate();
  }

  void _updateGCEvent(String id, List<HeapSpace> heaps) {
    isolateHeaps[id] = heaps;
    _recalculate(true);
  }

  void _recalculate([bool fromGC = false]) {
    int total = 0;

    int used = 0;
    int capacity = 0;
    int external = 0;
    for (List<HeapSpace> heaps in isolateHeaps.values) {
      used += heaps.fold<int>(0, (int i, HeapSpace heap) => i + heap.used);
      capacity +=
          heaps.fold<int>(0, (int i, HeapSpace heap) => i + heap.capacity);
      external +=
          heaps.fold<int>(0, (int i, HeapSpace heap) => i + heap.external);

      capacity += external;

      total += heaps.fold<int>(
          0, (int i, HeapSpace heap) => i + heap.capacity + heap.external);
    }

    heapMax = total;

    int time = DateTime.now().millisecondsSinceEpoch;
    if (samples.isNotEmpty) {
      time = math.max(time, samples.last.timestamp);
    }

    _addSample(HeapSample(time, processRss, capacity, used, external, fromGC));
  }

  void _addSample(HeapSample sample) {
    samples.add(sample);

    _changeController.add(null);
  }

  // TODO(devoncarew): fix HeapSpace.parse upstream
  static Iterable<HeapSpace> getHeaps(Isolate isolate) {
    final Map<String, dynamic> heaps = isolate.json['_heaps'];
    return heaps.values.map((dynamic json) => HeapSpace.parse(json));
  }
}

class HeapSample {
  HeapSample(this.timestamp, this.rss, this.capacity, this.used, this.external,
      this.isGC);

  final int timestamp;
  final int rss;
  final int capacity;
  final int used;
  final int external;
  final bool isGC;
}

// Heap Statistics

// Wrapper for ClassHeapStats.
//
// {
//   type: ClassHeapStats,
//   class: {type: @Class, fixedId: true, id: classes/5, name: Class},
//   accumulatedSize: 809536
//   bytesCurrent: 809536
//   instancesAccumulated: 3892
//   instancesCurrent: 3892
// }
class ClassHeapDetailStats {
  ClassHeapDetailStats(this.json) :
    classRef = ClassRef.parse(json['class']),
    instancesCurrent = json['instancesCurrent'],
    instancesAccumulated = json['instancesAccumulated'],
    bytesCurrent = json['bytesCurrent'],
    bytesAccumulated = json['bytesAccumulated'];

  final Map<String, dynamic> json;

  int instancesCurrent = 0;
  int instancesAccumulated = 0;
  int bytesCurrent = 0;
  int bytesAccumulated = 0;

  ClassRef classRef;

  String get type => json['type'];

  @override
  String toString() =>
      '[ClassHeapStats type: $type, class: ${classRef.name}, count: $instancesCurrent, bytes: $bytesCurrent]';
}

class InstanceSummary {
  InstanceSummary(this._classRef, this._className, this._objectRef);

  String get classRef => _classRef;
  String _classRef;

  String get objectRef => _objectRef;
  String _objectRef;

  String get className => _className;
  String _className;

  @override
  String toString() => '[InstanceSummary id: $objectRef, class: $classRef]';
}

class InstanceData {
  InstanceData(this._instance, this._name, this._value);

  InstanceSummary _instance;
  InstanceSummary get instance => _instance;

  String get name => _name;
  String _name;

  dynamic get value => _value;
  dynamic _value;

  @override
  String toString() => '[InstanceData name: $name, value: $value]';
}
