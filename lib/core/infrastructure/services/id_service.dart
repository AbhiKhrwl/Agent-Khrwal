import 'package:uuid/uuid.dart';

class IdService {
  static const _uuid = Uuid();

  /// Generates a unique UUID v4 string.
  static String generate() => _uuid.v4();

  /// Generates a short ID based on timestamp and randomness for UI/Logs.
  static String shortId() => DateTime.now().millisecondsSinceEpoch.toString().substring(7) + 
                             _uuid.v4().substring(0, 4);
}
