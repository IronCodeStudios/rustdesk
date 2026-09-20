import 'dart:io';

final isAndroid_ = Platform.isAndroid;
final isIOS_ = Platform.isIOS;
final isWindows_ = Platform.isWindows;
final isMacOS_ = Platform.isMacOS;
final isLinux_ = Platform.isLinux;
final isWeb_ = false;
final isWebDesktop_ = false;

final isDesktop_ = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

// Linux phones (PinePhone, Librem 5, postmarketOS devices) run desktop Linux on
// a handset-sized screen, so they get the desktop UI and it is unusable there.
// This opt-in lets such a build render the existing mobile UI instead. Linux
// only, and off unless explicitly asked for, so no current user sees a change.
const _kForceMobileUiDefine =
    bool.fromEnvironment('RUSTDESK_FORCE_MOBILE_UI', defaultValue: false);
final forceMobileUi_ = Platform.isLinux &&
    (_kForceMobileUiDefine ||
        Platform.environment['RUSTDESK_MOBILE_UI'] == '1');

final isWebOnWindows_ = false;
final isWebOnLinux_ = false;
final isWebOnMacOS_ = false;
