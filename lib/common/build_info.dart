import 'package:package_info_plus/package_info_plus.dart';

const buildSource = String.fromEnvironment(
  'BUILD_SOURCE',
  defaultValue: 'myFlClash',
);
const buildCommit = String.fromEnvironment('BUILD_COMMIT');
const buildDirty = String.fromEnvironment('BUILD_DIRTY') == 'true';

String buildVersionLabel(PackageInfo packageInfo) {
  final source = buildSource.isNotEmpty ? buildSource : packageInfo.appName;
  return '$source ${packageInfo.version}';
}

String buildCommitLabel() {
  if (buildCommit.isEmpty) return '';
  return buildDirty ? '$buildCommit-dirty' : buildCommit;
}
