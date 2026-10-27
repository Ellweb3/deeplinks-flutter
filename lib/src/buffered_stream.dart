import 'dart:async';
import 'dart:collection';

class BufferedBroadcast<T> {
  BufferedBroadcast({this.capacity = 20}) {
    _controller = StreamController<T>.broadcast(onListen: _flush);
  }

  final int capacity;
  late final StreamController<T> _controller;
  final Queue<T> _pending = Queue<T>();

  Stream<T> get stream => _controller.stream;

  void add(T value) {
    if (_controller.hasListener) {
      _controller.add(value);
      return;
    }
    _pending.addLast(value);
    while (_pending.length > capacity) {
      _pending.removeFirst();
    }
  }

  void _flush() {
    scheduleMicrotask(() {
      while (_pending.isNotEmpty && _controller.hasListener) {
        _controller.add(_pending.removeFirst());
      }
    });
  }

  Future<void> close() => _controller.close();
}
