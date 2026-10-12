// Platform switch: Google-rendered (GIS) button on web, plain Flutter fallback elsewhere.
export 'google_sign_in_button_stub.dart'
    if (dart.library.js_interop) 'google_sign_in_button_web.dart';
