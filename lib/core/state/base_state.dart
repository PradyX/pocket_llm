/// Sealed class for representing UI state in controllers.
/// Use pattern matching to handle all cases.
sealed class UiState<T> {
  const UiState();
}

/// Initial state before any operation starts.
class UiInitial<T> extends UiState<T> {
  const UiInitial();
}

/// Loading state while operation is in progress.
class UiLoading<T> extends UiState<T> {
  const UiLoading();
}

/// Success state with data.
class UiSuccess<T> extends UiState<T> {
  final T data;
  const UiSuccess(this.data);
}

/// Error state with message.
class UiError<T> extends UiState<T> {
  final String message;
  const UiError(this.message);
}

/// Extension methods for convenient state checks.
extension UiStateX<T> on UiState<T> {
  bool get isLoading => this is UiLoading<T>;
  bool get isSuccess => this is UiSuccess<T>;
  bool get isError => this is UiError<T>;
  bool get isInitial => this is UiInitial<T>;

  T? get dataOrNull => this is UiSuccess<T> ? (this as UiSuccess<T>).data : null;
  String? get errorOrNull => this is UiError<T> ? (this as UiError<T>).message : null;
}
