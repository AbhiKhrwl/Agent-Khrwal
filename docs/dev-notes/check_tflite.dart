// ignore_for_file: avoid_print
import 'dart:io';

void main() async {
  final file = File('dummy.bin');
  // Create a fake TFLite file
  final bytes = [0x00, 0x00, 0x00, 0x00, 0x54, 0x46, 0x4C, 0x33]; // 'TFL3'
  file.writeAsBytesSync(bytes);

  final raf = await file.open(mode: FileMode.read);
  final readBytes = await raf.read(8);
  await raf.close();
  
  if (readBytes.length >= 8) {
    final magic = String.fromCharCodes(readBytes.sublist(4, 8));
    print('Magic: $magic');
    print('Is TFLite: ${magic == 'TFL3'}');
  }
}
