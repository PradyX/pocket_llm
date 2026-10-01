/// Cooperative cancellation for long-running local work.
///
/// Ingestion and indexing run on the main isolate with `await` points, so a
/// token is enough: work checks [isCancelled] (or calls [throwIfCancelled])
/// between steps and unwinds, which lets the UI stop a large document without
/// killing the app.
class CancelToken {
  bool _isCancelled = false;

  /// Callback run once when [cancel] is called; used to release resources.
  final void Function()? onCancel;

  CancelToken({this.onCancel});

  bool get isCancelled => _isCancelled;

  /// Requests cancellation. Safe to call more than once.
  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    onCancel?.call();
  }

  /// Throws [OperationCancelledException] when cancellation was requested.
  void throwIfCancelled() {
    if (_isCancelled) throw const OperationCancelledException();
  }
}

/// Thrown when a cancelled operation unwinds.
class OperationCancelledException implements Exception {
  const OperationCancelledException([this.message = 'Operation cancelled.']);

  final String message;

  @override
  String toString() => message;
}
