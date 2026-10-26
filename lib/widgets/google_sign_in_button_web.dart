import 'package:flutter/widgets.dart';
import 'package:google_sign_in_web/web_only.dart' as gsi;

/// Web: Google Identity Services must render its own button; results arrive on
/// GoogleSignIn.instance.authenticationEvents. Label = "Sign up with Google".
Widget buildGoogleSignUpButton({required bool isDark, required double width, required Widget fallback}) {
  return gsi.renderButton(
    configuration: gsi.GSIButtonConfiguration(
      type: gsi.GSIButtonType.standard,
      text: gsi.GSIButtonText.signupWith,
      theme: isDark ? gsi.GSIButtonTheme.filledBlack : gsi.GSIButtonTheme.outline,
      size: gsi.GSIButtonSize.large,
      shape: gsi.GSIButtonShape.pill,
      logoAlignment: gsi.GSIButtonLogoAlignment.left,
      minimumWidth: width.clamp(200, 400).toDouble(),
    ),
  );
}
