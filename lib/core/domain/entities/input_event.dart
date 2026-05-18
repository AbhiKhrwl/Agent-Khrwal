enum InputType { text, barcode, voice, image }

class InputEvent {
  final InputType type;
  final String data;
  final DateTime timestamp;
  final Map<String, dynamic> metadata;

  InputEvent({
    required this.type,
    required this.data,
    DateTime? timestamp,
    this.metadata = const {},
  }) : timestamp = timestamp ?? DateTime.now();
}
