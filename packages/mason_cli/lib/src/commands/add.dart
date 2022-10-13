import 'dart:io';

import 'package:checked_yaml/checked_yaml.dart';
import 'package:mason/mason.dart';
import 'package:mason_cli/src/command.dart';
import 'package:mason_cli/src/install_brick.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// {@template add_command}
/// `mason add` command which adds a brick.
/// {@endtemplate}
class AddCommand extends MasonCommand with InstallBrickMixin {
  /// {@macro add_command}
  AddCommand({Logger? logger}) : super(logger: logger) {
    argParser
      ..addFlag(
        'global',
        abbr: 'g',
        help: 'Adds the brick globally.',
      )
      ..addOption('git-url', help: 'Git URL of the brick')
      ..addOption('git-ref', help: 'Git branch or commit to be used')
      ..addOption('git-path', help: 'Path of the brick in the git repository')
      ..addOption('path', help: 'Local path of the brick');
  }

  @override
  final String description = 'Adds a brick from a local or remote source.';

  @override
  final String name = 'add';

  @override
  Future<int> run() async {
    if (results.rest.isEmpty) usageException('brick name is required.');

    final name = results.rest.first;
    final gitUrl = results['git-url'] as String?;
    final path = results['path'] as String?;
    final isGlobal = results['global'] == true;

    late final Brick brick;
    if (path != null) {
      brick = Brick(name: name, location: BrickLocation(path: path));
    } else if (gitUrl != null) {
      brick = Brick(
        name: name,
        location: BrickLocation(
          git: GitPath(
            gitUrl,
            path: results['git-path'] as String?,
            ref: results['git-ref'] as String?,
          ),
        ),
      );
    } else {
      if (results.rest.length > 2) {
        usageException(
          'Too many arguments, expected arguments <name> <version>',
        );
      }
      final version = results.rest.length == 2 ? results.rest.last : 'any';
      brick = Brick(name: name, location: BrickLocation(version: version));
    }

    final cachedBrick = await addBrick(brick, global: isGlobal);
    final file = File(p.join(cachedBrick.path, BrickYaml.file));

    final brickYaml = checkedYamlDecode(
      file.readAsStringSync(),
      (m) => BrickYaml.fromJson(m!),
    ).copyWith(path: file.path);

    final masonYaml = isGlobal ? globalMasonYaml : localMasonYaml;
    final masonYamlFile = isGlobal ? globalMasonYamlFile : localMasonYamlFile;
    final location = brick.location.version != null
        ? BrickLocation(version: '^${brickYaml.version}')
        : brick.location.path != null
            ? BrickLocation(
                path: p.relative(
                  canonicalize(Directory(brick.location.path!).absolute.path),
                  from: masonYamlFile.parent.path,
                ),
              )
            : brick.location;
    final bricks = Map.of(masonYaml.bricks)..addAll({name: location});
    final addProgress = logger.progress('Adding ${brickYaml.name}');
    try {
      final dependencies = await _handleBrickDependencies(
        brick: brick.name!,
        dependencies: brickYaml.dependencies,
        targetMasonYaml: targetMasonYaml,
        targetMasonYamlFile: targetMasonYamlFile,
        isGlobal: isGlobal,
      );
      bricks.addAll(dependencies);

      if (!targetMasonYaml.bricks.containsKey(name)) {
        await targetMasonYamlFile.writeAsString(
          Yaml.encode(MasonYaml(bricks).toJson()),
        );
      }
      addProgress.complete('Added ${brickYaml.name}');
    } catch (_) {
      addProgress.fail();
      rethrow;
    }

    return ExitCode.success.code;
  }

  Future<Map<String, BrickLocation>> _handleBrickDependencies({
    required String brick,
    required Map<String, BrickLocation> dependencies,
    required MasonYaml targetMasonYaml,
    required File targetMasonYamlFile,
    bool isGlobal = false,
  }) async {
    if (dependencies.isEmpty) {
      return {};
    }

    final dependenciesProgress = logger.progress(
      'Adding brick dependencies of $brick',
    );

    final bricks = Map.of(targetMasonYaml.bricks);

    try {
      for (final dependency in dependencies.entries) {
        final depBrick = Brick(
          name: dependency.key,
          location: dependency.value,
        );

        // // Add brick in queue for mason.yaml
        // if (!bricks.containsKey(depBrick.name)) {
        //   bricks.addAll({depBrick.name!: depBrick.location});
        // }

        final dependencies = await _addBrickDependency(
          brick: depBrick,
          targetMasonYaml: targetMasonYaml,
          targetMasonYamlFile: targetMasonYamlFile,
        );

        // Add brick's dependencies in queue for mason.yaml
        // bricks.addAll(dependencies);

      }

      dependenciesProgress.complete('Added brick dependencies of $brick');
    } catch (_) {
      dependenciesProgress.fail();
      rethrow;
    }
    return bricks;
  }

  Future<Map<String, BrickLocation>> _addBrickDependency({
    required Brick brick,
    required MasonYaml targetMasonYaml,
    required File targetMasonYamlFile,
    bool isGlobal = false,
  }) async {
    // Add brick
    await addBrick(brick, global: isGlobal);

    // Add brick's dependencies recursively (if any)
    final generator = await MasonGenerator.fromBrick(brick);
    if (generator.dependencies.isNotEmpty) {
      final dependencies = await _handleBrickDependencies(
        brick: brick.name!,
        dependencies: generator.dependencies,
        targetMasonYaml: targetMasonYaml,
        targetMasonYamlFile: targetMasonYamlFile,
      );
      return dependencies;
    } else {
      return {};
    }
  }
}
