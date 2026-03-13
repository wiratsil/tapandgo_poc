import 'dart:io';

void main() async {
  final pubspecFile = File('pubspec.yaml');
  
  if (!pubspecFile.existsSync()) {
    print('❌ Error: pubspec.yaml not found in the current directory.');
    exit(1);
  }

  // 1. Read pubspec.yaml
  String content = await pubspecFile.readAsString();

  // 2. Find and increment version
  // Regex to match: version: x.y.z+n
  final versionRegex = RegExp(r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)$', multiLine: true);
  final match = versionRegex.firstMatch(content);

  if (match == null) {
    print('❌ Error: Could not find version format "version: x.y.z+n" in pubspec.yaml');
    print('Make sure your pubspec.yaml uses this exact format.');
    exit(1);
  }

  final baseVersion = match.group(1)!;
  final currentBuildNumber = int.parse(match.group(2)!);
  final newBuildNumber = currentBuildNumber + 1;
  final newVersionString = 'version: $baseVersion+$newBuildNumber';

  // 3. Replace version in pubspec.yaml
  content = content.replaceFirst(match.group(0)!, newVersionString);
  await pubspecFile.writeAsString(content);

  print('✅ Incremented version from $baseVersion+$currentBuildNumber to $baseVersion+$newBuildNumber');

  // 4. Run `fvm flutter build apk`
  print('🚀 Starting APK build...');
  
  final process = await Process.start(
    'fvm',
    ['flutter', 'build', 'apk'],
    mode: ProcessStartMode.inheritStdio, 
    runInShell: true, 
  );

  final exitCode = await process.exitCode;
  
  if (exitCode == 0) {
    print('✅ Build APK completed successfully! (Version: $baseVersion+$newBuildNumber)');
  } else {
    print('❌ Build APK failed with exit code: $exitCode');
    exit(exitCode);
  }
}
