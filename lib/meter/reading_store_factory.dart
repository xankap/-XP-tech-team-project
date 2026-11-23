import 'package:flutter/foundation.dart' show kIsWeb;

import 'local_reading_store.dart';

/// SQLite on the phone; in-memory on web (no Bluetooth meter there).
Future<ReadingStore> openPlatformReadingStore() async =>
    kIsWeb ? MemoryReadingStore() : await SqfliteReadingStore.open();
