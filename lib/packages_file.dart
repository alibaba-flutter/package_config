// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library package_config.packages_file;

import "package:charcode/ascii.dart";

import "src/util.dart" show isValidPackageName;

/// Parses a `.packages` file into a map from package name to base URI.
///
/// The [source] is the byte content of a `.packages` file, assumed to be
/// UTF-8 encoded. In practice, all significant parts of the file must be ASCII,
/// so Latin-1 or Windows-1252 encoding will also work fine.
///
/// If the file content is available as a string, its [String.codeUnits] can
/// be used as the `source` argument of this function.
///
/// The [baseLocation] is used as a base URI to resolve all relative
/// URI references against.
/// If the content was read from a file, `baseLocation` should be the
/// location of that file.
///
/// If [allowDefaultPackage] is set to true, an entry with an empty package name
/// is accepted. This entry does not correspond to a package, but instead
/// represents a *default package* which non-package libraries may be considered
/// part of in some cases. The value of that entry must be a valid package name.
///
/// Returns a simple mapping from package name to package location.
/// If default package is allowed, the map maps the empty string to the default package's name.
Map<String, Uri> parse(List<int> source, Uri baseLocation,
    {bool allowDefaultPackage = false}) {
  int index = 0;
  Map<String, Uri> result = <String, Uri>{};
  while (index < source.length) {
    bool isComment = false;
    int start = index;
    int separatorIndex = -1;
    int end = source.length;
    int char = source[index++];
    if (char == $cr || char == $lf) {
      continue;
    }
    if (char == $colon) {
      if (!allowDefaultPackage) {
        throw FormatException("Missing package name", source, index - 1);
      }
      separatorIndex = index - 1;
    }
    isComment = char == $hash;
    while (index < source.length) {
      char = source[index++];
      if (char == $colon && separatorIndex < 0) {
        separatorIndex = index - 1;
      } else if (char == $cr || char == $lf) {
        end = index - 1;
        break;
      }
    }
    if (isComment) continue;
    if (separatorIndex < 0) {
      throw FormatException("No ':' on line", source, index - 1);
    }
    var packageName = new String.fromCharCodes(source, start, separatorIndex);
    if (packageName.isEmpty
        ? !allowDefaultPackage
        : !isValidPackageName(packageName)) {
      throw FormatException("Not a valid package name", packageName, 0);
    }
    var packageValue =
        new String.fromCharCodes(source, separatorIndex + 1, end);
    Uri packageLocation;
    if (packageName.isEmpty) {
      if (!isValidPackageName(packageValue)) {
        throw FormatException(
            "Default package entry value is not a valid package name");
      }
      packageLocation = Uri(path: packageValue);
    } else {
      packageLocation = baseLocation.resolve(packageValue);
      if (!packageLocation.path.endsWith('/')) {
        packageLocation =
            packageLocation.replace(path: packageLocation.path + "/");
      }
    }
    if (result.containsKey(packageName)) {
      if (packageName.isEmpty) {
        throw FormatException(
            "More than one default package entry", source, start);
      }
      throw FormatException("Same package name occured twice", source, start);
    }
    result[packageName] = packageLocation;
  }
  return result;
}

/// Writes the mapping to a [StringSink].
///
/// If [comment] is provided, the output will contain this comment
/// with `# ` in front of each line.
/// Lines are defined as ending in line feed (`'\n'`). If the final
/// line of the comment doesn't end in a line feed, one will be added.
///
/// If [baseUri] is provided, package locations will be made relative
/// to the base URI, if possible, before writing.
///
/// If [allowDefaultPackage] is `true`, the [packageMapping] may contain an
/// empty string mapping to the _default package name_.
///
/// All the keys of [packageMapping] must be valid package names,
/// and the values must be URIs that do not have the `package:` scheme.
void write(StringSink output, Map<String, Uri> packageMapping,
    {Uri baseUri, String comment, bool allowDefaultPackage = false}) {
  ArgumentError.checkNotNull(allowDefaultPackage, 'allowDefaultPackage');

  if (baseUri != null && !baseUri.isAbsolute) {
    throw new ArgumentError.value(baseUri, "baseUri", "Must be absolute");
  }

  if (comment != null) {
    var lines = comment.split('\n');
    if (lines.last.isEmpty) lines.removeLast();
    for (var commentLine in lines) {
      output.write('# ');
      output.writeln(commentLine);
    }
  } else {
    output.write("# generated by package:package_config at ");
    output.write(new DateTime.now());
    output.writeln();
  }

  packageMapping.forEach((String packageName, Uri uri) {
    // If [packageName] is empty then [uri] is the _default package name_.
    if (allowDefaultPackage && packageName.isEmpty) {
      final defaultPackageName = uri.toString();
      if (!isValidPackageName(defaultPackageName)) {
        throw ArgumentError.value(
          defaultPackageName,
          'defaultPackageName',
          '"$defaultPackageName" is not a valid package name',
        );
      }
      output.write(':');
      output.write(defaultPackageName);
      output.writeln();
      return;
    }
    // Validate packageName.
    if (!isValidPackageName(packageName)) {
      throw new ArgumentError('"$packageName" is not a valid package name');
    }
    if (uri.scheme == "package") {
      throw new ArgumentError.value(
          "Package location must not be a package: URI", uri.toString());
    }
    output.write(packageName);
    output.write(':');
    // If baseUri provided, make uri relative.
    if (baseUri != null) {
      uri = _relativize(uri, baseUri);
    }
    output.write(uri);
    if (!uri.path.endsWith('/')) {
      output.write('/');
    }
    output.writeln();
  });
}

/// Attempts to return a relative URI for [uri].
///
/// The result URI satisfies `baseUri.resolveUri(result) == uri`,
/// but may be relative.
/// The `baseUri` must be absolute.
Uri _relativize(Uri uri, Uri baseUri) {
  assert(baseUri.isAbsolute);
  if (uri.hasQuery || uri.hasFragment) {
    uri = new Uri(
        scheme: uri.scheme,
        userInfo: uri.hasAuthority ? uri.userInfo : null,
        host: uri.hasAuthority ? uri.host : null,
        port: uri.hasAuthority ? uri.port : null,
        path: uri.path);
  }

  // Already relative. We assume the caller knows what they are doing.
  if (!uri.isAbsolute) return uri;

  if (baseUri.scheme != uri.scheme) {
    return uri;
  }

  // If authority differs, we could remove the scheme, but it's not worth it.
  if (uri.hasAuthority != baseUri.hasAuthority) return uri;
  if (uri.hasAuthority) {
    if (uri.userInfo != baseUri.userInfo ||
        uri.host.toLowerCase() != baseUri.host.toLowerCase() ||
        uri.port != baseUri.port) {
      return uri;
    }
  }

  baseUri = baseUri.normalizePath();
  List<String> base = baseUri.pathSegments.toList();
  if (base.isNotEmpty) {
    base = new List<String>.from(base)..removeLast();
  }
  uri = uri.normalizePath();
  List<String> target = uri.pathSegments.toList();
  if (target.isNotEmpty && target.last.isEmpty) target.removeLast();
  int index = 0;
  while (index < base.length && index < target.length) {
    if (base[index] != target[index]) {
      break;
    }
    index++;
  }
  if (index == base.length) {
    if (index == target.length) {
      return new Uri(path: "./");
    }
    return new Uri(path: target.skip(index).join('/'));
  } else if (index > 0) {
    return new Uri(
        path: '../' * (base.length - index) + target.skip(index).join('/'));
  } else {
    return uri;
  }
}
