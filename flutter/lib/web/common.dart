import 'dart:js' as js;
// cycle imports, maybe we can improve this
import 'package:flutter_hbb/consts.dart';

final isAndroid_ = false;
final isIOS_ = false;
final isWindows_ = false;
final isMacOS_ = false;
final isLinux_ = false;
final isWeb_ = true;
final isWebDesktop_ = !js.context.callMethod('isMobile');

final isDesktop_ = false;

// Web never opts into the mobile-UI override: it has its own mobile detection
// via isWebDesktop_, and dart:io is not available here.
final forceMobileUi_ = false;

final _localOs = js.context.callMethod('getByName', ['local_os', '']);
final isWebOnWindows_ = _localOs == kPeerPlatformWindows;
final isWebOnLinux_ = _localOs == kPeerPlatformLinux;
final isWebOnMacOS_ = _localOs == kPeerPlatformMacOS;
