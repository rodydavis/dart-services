// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library services.common_server;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dartis/dartis.dart' as redis;
import 'package:logging/logging.dart';
import 'package:pedantic/pedantic.dart';
import 'package:quiver/cache.dart';
import 'package:rpc/rpc.dart';

import '../version.dart';
import 'analysis_server.dart';
import 'api_classes.dart';
import 'common.dart';
import 'compiler.dart';
import 'pub.dart';
import 'sdk_manager.dart';
import 'summarize.dart';

final Duration _standardExpiration = Duration(hours: 1);
final Logger log = Logger('common_server');

/// Toggle to on to enable `package:` support.
final bool enablePackages = false;

abstract class ServerCache {
  Future get(String key);

  Future set(String key, String value, {Duration expiration});

  Future remove(String key);

  Future<void> shutdown();
}

abstract class ServerContainer {
  String get version;
}

class SummaryText {
  String text;

  SummaryText.fromString(String this.text);
}

abstract class PersistentCounter {
  Future increment(String name, {int increment = 1});

  Future<int> getTotal(String name);
}

/// A redis-backed implementation of [ServerCache].
class RedisCache implements ServerCache {
  redis.Client redisClient;
  redis.Connection _connection;

  final String redisUriString;

  // Version of the server to add with keys.
  final String serverVersion;
  // pseudo-random is good enough.
  final Random randomSource = Random();
  static const int _connectionRetryBaseMs = 250;
  static const int _connectionRetryMaxMs = 60000;
  static const Duration cacheOperationTimeout = Duration(milliseconds: 10000);

  RedisCache(this.redisUriString, this.serverVersion) {
    _reconnect();
  }

  var _connected = Completer<void>();
  /// Completes when and if the redis server connects.  This future is reset
  /// on disconnection.  Mostly for testing.
  Future get connected => _connected.future;

  var _disconnected = Completer<void>()..complete();
  /// Completes when the server is disconnected (begins completed).  This
  /// future is reset on connection.  Mostly for testing.
  Future get disconnected => _disconnected.future;

  String __logPrefix;
  String get _logPrefix => __logPrefix ??= 'RedisCache [${redisUriString}] (${serverVersion})';

  bool _isConnected() => redisClient != null && !_isShutdown;
  bool _isShutdown = false;

  /// If you will no longer be using the [RedisCache] instance, call this to
  /// prevent reconnection attempts.  All calls to get/remove/set on this object
  /// will return null after this.  Future completes when disconnection is complete.
  @override
  Future<void> shutdown() {
    log.info('${_logPrefix}: shutting down...');
    _isShutdown = true;
    redisClient?.disconnect();
    return disconnected;
  }

  /// Call when an active connection has disconnected.
  void _resetConnection() {
    assert(_connected.isCompleted && !_disconnected.isCompleted);
    _connected = Completer<void>();
    _connection = null;
    redisClient = null;
    _disconnected.complete();
  }

  /// Call when a new connection is established.
  void _setUpConnection(redis.Connection newConnection) {
    assert(_disconnected.isCompleted && !_connected.isCompleted);
    _disconnected = Completer<void>();
    _connection = newConnection;
    redisClient = redis.Client(_connection);
    _connected.complete();
  }

  /// Begin a reconnection loop asynchronously to maintain a connection to the
  /// redis server.  Never stops trying until shutdown() is called.
  void _reconnect([int retryTimeoutMs = _connectionRetryBaseMs])  {
    if (_isShutdown) {
      return;
    }
    log.info('${_logPrefix}: reconnecting to ${redisUriString}...');
    int nextRetryMs = retryTimeoutMs;
    if (retryTimeoutMs < _connectionRetryMaxMs / 2) {
      // 1 <= (randomSource.nextDouble() + 1) < 2
      nextRetryMs = (retryTimeoutMs * (randomSource.nextDouble() + 1)).toInt();
    }
    redis.Connection.connect(redisUriString).then((redis.Connection newConnection) {
      log.info('${_logPrefix}: Connected to redis server');
      _setUpConnection(newConnection);
      // If the client disconnects, discard the client and try to connect again.
      newConnection.done.then((_) {
        _resetConnection();
        log.warning('${_logPrefix}: connection terminated, reconnecting');
        _reconnect();
      }).catchError((e) {
        _resetConnection();
        log.warning('${_logPrefix}: connection terminated with error ${e}, reconnecting');
        _reconnect();
      });
    }).timeout(Duration(milliseconds: _connectionRetryMaxMs)).catchError((_) {
      log.severe('${_logPrefix}: Unable to connect to redis server, reconnecting in ${nextRetryMs}ms ...');
      Future.delayed(Duration(milliseconds: nextRetryMs)).then((_) {
        _reconnect(nextRetryMs);
      });
    });
  }

  /// Build a key that includes the server version.
  ///
  /// We don't use the existing key directly so that different AppEngine versions
  /// using the same redis cache do not have collisions.
  String _genKey(String key) => '${serverVersion}+${key}';

  @override
  Future get(String key) async {
    String value;
    key = _genKey(key);
    if (!_isConnected()) {
      log.warning('${_logPrefix}: no cache available when getting key ${key}');
    } else {
      final commands = redisClient.asCommands<String, String>();
      // commands can return errors synchronously in timeout cases.
      try {
        value = await commands.get(key).timeout(cacheOperationTimeout, onTimeout: () {
          log.warning('${_logPrefix}: timeout on get operation for key ${key}');
          redisClient?.disconnect();
        });
      } catch (e) {
        log.warning('${_logPrefix}: error on get operation for key ${key}: ${e}');
      }
    }
    return value;
  }

  @override
  Future remove(String key) async {
    key = _genKey(key);
    if (!_isConnected()) {
      log.warning('${_logPrefix}: no cache available when removing key ${key}');
      return null;
    }

    final commands = redisClient.asCommands<String, String>();
    // commands can sometimes return errors synchronously in timeout cases.
    try {
      return commands.del(key: key).timeout(cacheOperationTimeout, onTimeout: () {
        log.warning('${_logPrefix}: timeout on remove operation for key ${key}');
        redisClient?.disconnect();
      });
    } catch (e) {
      log.warning('${_logPrefix}: error on remove operation for key ${key}: ${e}');
    }
  }

  @override
  Future set(String key, String value, {Duration expiration}) async {
    key = _genKey(key);
    if (!_isConnected()) {
      log.warning('${_logPrefix}: no cache available when setting key ${key}');
      return null;
    }

    final commands = redisClient.asCommands<String, String>();
    // commands can sometimes return errors synchronously in timeout cases.
    try {
      return Future.sync(() async {
        await commands.multi();
        unawaited(commands.set(key, value));
        if (expiration != null) {
          unawaited(commands.pexpire(key, expiration.inMilliseconds));
        }
        await commands.exec();
      }).timeout(cacheOperationTimeout, onTimeout: () {
        log.warning('${_logPrefix}: timeout on set operation for key ${key}');
        redisClient?.disconnect();
      });
    } catch (e) {
      log.warning('${_logPrefix}: error on set operation for key ${key}: ${e}');
    }
  }
}

/// An in-memory implementation of [ServerCache] which doesn't support
/// expiration of entries based on time.
class InmemoryCache implements ServerCache {
  /// Wrapping an internal cache with a maximum size of 512 entries.
  final Cache<String, String> _lru = MapCache.lru(maximumSize: 512);

  @override
  Future get(String key) async => _lru.get(key);

  @override
  Future set(String key, String value, {Duration expiration}) async =>
      _lru.set(key, value);

  @override
  Future remove(String key) async => _lru.invalidate(key);

  @override
  Future<void> shutdown() => Future.value();
}

@ApiClass(name: 'dartservices', version: 'v1')
class CommonServer {
  final ServerContainer container;
  final ServerCache cache;
  final PersistentCounter counter;

  Pub pub;

  Compiler compiler;
  AnalysisServerWrapper analysisServer;

  String sdkPath;

  CommonServer(String this.sdkPath, this.container, this.cache, this.counter) {
    hierarchicalLoggingEnabled = true;
    log.level = Level.ALL;
  }

  Future init() async {
    pub = enablePackages ? Pub() : Pub.mock();
    compiler = Compiler(sdkPath, pub);
    analysisServer = AnalysisServerWrapper(sdkPath);

    await analysisServer.init();
    unawaited(analysisServer.onExit.then((int code) {
      log.severe('analysisServer exited, code: $code');
      if (code != 0) {
        exit(code);
      }
    }));
  }

  Future warmup({bool useHtml = false}) async {
    await compiler.warmup(useHtml: useHtml);
    await analysisServer.warmup(useHtml: useHtml);
  }

  Future restart() async {
    log.warning('Restarting CommonServer');
    await shutdown();
    log.info('Analysis Servers shutdown');

    await init();
    await warmup();

    log.warning('Restart complete');
  }

  Future shutdown() {
    return Future.wait([analysisServer.shutdown(), Future.sync(cache.shutdown)]);
  }

  @ApiMethod(method: 'GET', path: 'counter')
  @deprecated
  Future<CounterResponse> counterGet({String name}) {
    return counter.getTotal(name).then((total) {
      return CounterResponse(total);
    });
  }

  @ApiMethod(
      method: 'POST',
      path: 'analyze',
      description:
          'Analyze the given Dart source code and return any resulting '
          'analysis errors or warnings.')
  Future<AnalysisResults> analyze(SourceRequest request) {
    return _analyze(request.source);
  }

  @ApiMethod(
      method: 'POST',
      path: 'analyzeMulti',
      description:
          'Analyze the given Dart source code and return any resulting '
          'analysis errors or warnings.')
  @deprecated
  Future<AnalysisResults> analyzeMulti(SourcesRequest request) {
    return _analyzeMulti(request.sources);
  }

  @ApiMethod(
      method: 'POST',
      path: 'summarize',
      description:
          'Summarize the given Dart source code and return any resulting '
          'analysis errors or warnings.')
  @deprecated
  Future<SummaryText> summarize(SourcesRequest request) {
    return _summarize(request.sources['dart'], request.sources['css'],
        request.sources['html']);
  }

  @ApiMethod(method: 'GET', path: 'analyze')
  @deprecated
  Future<AnalysisResults> analyzeGet({String source}) {
    return _analyze(source);
  }

  @ApiMethod(
      method: 'POST',
      path: 'compile',
      description: 'Compile the given Dart source code and return the '
          'resulting JavaScript.')
  Future<CompileResponse> compile(CompileRequest request) =>
      _compile(request.source,
          useCheckedMode: true,
          returnSourceMap: request.returnSourceMap ?? false);

  @ApiMethod(method: 'GET', path: 'compile')
  @deprecated
  Future<CompileResponse> compileGet({String source}) => _compile(source);

  @ApiMethod(
      method: 'POST',
      path: 'complete',
      description:
          'Get the valid code completion results for the given offset.')
  Future<CompleteResponse> complete(SourceRequest request) {
    if (request.offset == null) {
      throw BadRequestError('Missing parameter: \'offset\'');
    }

    return _complete(request.source, request.offset);
  }

  @ApiMethod(
      method: 'POST',
      path: 'completeMulti',
      description:
          'Get the valid code completion results for the given offset.')
  @deprecated
  Future<CompleteResponse> completeMulti(SourcesRequest request) {
    if (request.location == null) {
      throw BadRequestError('Missing parameter: \'location\'');
    }

    return _completeMulti(
        request.sources, request.location.sourceName, request.location.offset);
  }

  @ApiMethod(method: 'GET', path: 'complete')
  Future<CompleteResponse> completeGet({String source, int offset}) {
    if (source == null) {
      throw BadRequestError('Missing parameter: \'source\'');
    }
    if (offset == null) {
      throw BadRequestError('Missing parameter: \'offset\'');
    }

    return _complete(source, offset);
  }

  @ApiMethod(
      method: 'POST',
      path: 'fixes',
      description: 'Get any quick fixes for the given source code location.')
  Future<FixesResponse> fixes(SourceRequest request) {
    if (request.offset == null) {
      throw BadRequestError('Missing parameter: \'offset\'');
    }

    return _fixes(request.source, request.offset);
  }

  @ApiMethod(
      method: 'POST',
      path: 'fixesMulti',
      description: 'Get any quick fixes for the given source code location.')
  @deprecated
  Future<FixesResponse> fixesMulti(SourcesRequest request) {
    if (request.location.sourceName == null) {
      throw BadRequestError('Missing parameter: \'fullName\'');
    }
    if (request.location.offset == null) {
      throw BadRequestError('Missing parameter: \'offset\'');
    }

    return _fixesMulti(
        request.sources, request.location.sourceName, request.location.offset);
  }

  @ApiMethod(method: 'GET', path: 'fixes')
  @deprecated
  Future<FixesResponse> fixesGet({String source, int offset}) {
    if (source == null) {
      throw BadRequestError('Missing parameter: \'source\'');
    }
    if (offset == null) {
      throw BadRequestError('Missing parameter: \'offset\'');
    }

    return _fixes(source, offset);
  }

  @ApiMethod(
      method: 'POST',
      path: 'format',
      description: 'Format the given Dart source code and return the results. '
          'If an offset is supplied in the request, the new position for that '
          'offset in the formatted code will be returned.')
  Future<FormatResponse> format(SourceRequest request) {
    return _format(request.source, offset: request.offset);
  }

  @ApiMethod(method: 'GET', path: 'format')
  @deprecated
  Future<FormatResponse> formatGet({String source, int offset}) {
    if (source == null) {
      throw BadRequestError('Missing parameter: \'source\'');
    }

    return _format(source, offset: offset);
  }

  @ApiMethod(
      method: 'POST',
      path: 'document',
      description: 'Return the relevant dartdoc information for the element at '
          'the given offset.')
  Future<DocumentResponse> document(SourceRequest request) {
    return _document(request.source, request.offset);
  }

  @ApiMethod(method: 'GET', path: 'document')
  @deprecated
  Future<DocumentResponse> documentGet({String source, int offset}) {
    return _document(source, offset);
  }

  @ApiMethod(
      method: 'GET',
      path: 'version',
      description: 'Return the current SDK version for DartServices.')
  Future<VersionResponse> version() => Future.value(_version());

  Future<AnalysisResults> _analyze(String source) async {
    if (source == null) {
      throw BadRequestError('Missing parameter: \'source\'');
    }
    return _analyzeMulti({kMainDart: source});
  }

  Future<SummaryText> _summarize(String dart, String html, String css) async {
    if (dart == null || html == null || css == null) {
      throw BadRequestError('Missing core source parameter.');
    }
    String sourcesJson =
        JsonEncoder().convert({"dart": dart, "html": html, "css": css});
    log.info("About to summarize: ${_hashSource(sourcesJson)}");

    SummaryText summaryString =
        await _analyzeMulti({kMainDart: dart}).then((result) {
      Summarizer summarizer =
          Summarizer(dart: dart, html: html, css: css, analysis: result);
      return SummaryText.fromString(summarizer.returnAsSimpleSummary());
    });
    return Future.value(summaryString);
  }

  Future<AnalysisResults> _analyzeMulti(Map<String, String> sources) async {
    if (sources == null) {
      throw BadRequestError('Missing parameter: \'sources\'');
    }

    Stopwatch watch = Stopwatch()..start();
    try {
      AnalysisServerWrapper server = analysisServer;
      AnalysisResults results = await server.analyzeMulti(sources);
      int lineCount = sources.values
          .map((s) => s.split('\n').length)
          .fold(0, (a, b) => a + b);
      int ms = watch.elapsedMilliseconds;
      log.info('PERF: Analyzed ${lineCount} lines of Dart in ${ms}ms.');
      unawaited(counter.increment("Analyses"));
      unawaited(counter.increment("Analyzed-Lines", increment: lineCount));
      return results;
    } catch (e, st) {
      log.severe('Error during analyze', e, st);
      await restart();
      rethrow;
    }
  }

  Future<CompileResponse> _compile(String source,
      {bool useCheckedMode = true, bool returnSourceMap = false}) async {
    if (source == null) {
      throw BadRequestError('Missing parameter: \'source\'');
    }
    String sourceHash = _hashSource(source);

    // TODO(lukechurch): Remove this hack after
    // https://github.com/dart-lang/rpc/issues/15 lands
    var trimSrc = source.trim();
    bool suppressCache = trimSrc.endsWith("/** Supress-Memcache **/") ||
        trimSrc.endsWith("/** Suppress-Memcache **/");

    String memCacheKey = "%%COMPILE:v0:useCheckedMode:$useCheckedMode"
        "returnSourceMap:$returnSourceMap:"
        "source:$sourceHash";

    return checkCache(memCacheKey).then((dynamic result) {
      if (!suppressCache && result != null) {
        log.info("CACHE: Cache hit for compile");
        var resultObj = JsonDecoder().convert(result);
        return CompileResponse(resultObj["output"],
            returnSourceMap ? resultObj["sourceMap"] : null);
      } else {
        log.info("CACHE: MISS, forced: $suppressCache");
        Stopwatch watch = Stopwatch()..start();

        return compiler
            .compile(source,
                useCheckedMode: useCheckedMode,
                returnSourceMap: returnSourceMap)
            .then((CompilationResults results) async {
          if (results.hasOutput) {
            int lineCount = source.split('\n').length;
            int outputSize = (results.getOutput().length + 512) ~/ 1024;
            int ms = watch.elapsedMilliseconds;
            log.info('PERF: Compiled ${lineCount} lines of Dart into '
                '${outputSize}kb of JavaScript in ${ms}ms.');
            unawaited(counter.increment("Compilations"));
            unawaited(
                counter.increment("Compiled-Lines", increment: lineCount));
            String out = results.getOutput();
            String sourceMap = returnSourceMap ? results.getSourceMap() : null;

            String cachedResult =
                JsonEncoder().convert({"output": out, "sourceMap": sourceMap});
            // Don't block on cache set.
            unawaited(setCache(memCacheKey, cachedResult));
            return CompileResponse(out, sourceMap);
          } else {
            List<CompilationProblem> problems = results.problems;
            String errors = problems.map(_printCompileProblem).join('\n');
            throw BadRequestError(errors);
          }
        }).catchError((e, st) {
          log.severe('Error during compile: ${e}\n${st}');
          throw e;
        });
      }
    });
  }

  Future<DocumentResponse> _document(String source, int offset) async {
    if (source == null) {
      throw BadRequestError('Missing parameter: \'source\'');
    }
    if (offset == null) {
      throw BadRequestError('Missing parameter: \'offset\'');
    }
    Stopwatch watch = Stopwatch()..start();
    try {
      Map<String, String> docInfo =
          await analysisServer.dartdoc(source, offset);
      docInfo ??= {};
      log.info('PERF: Computed dartdoc in ${watch.elapsedMilliseconds}ms.');
      unawaited(counter.increment("DartDocs"));
      return DocumentResponse(docInfo);
    } catch (e, st) {
      log.severe('Error during dartdoc', e, st);
      await restart();
      rethrow;
    }
  }

  VersionResponse _version() => VersionResponse(
      sdkVersion: SdkManager.sdk.version,
      sdkVersionFull: SdkManager.sdk.versionFull,
      runtimeVersion: vmVersion,
      servicesVersion: servicesVersion,
      appEngineVersion: container.version);

  Future<CompleteResponse> _complete(String source, int offset) async {
    if (source == null) {
      throw BadRequestError('Missing parameter: \'source\'');
    }
    if (offset == null) {
      throw BadRequestError('Missing parameter: \'offset\'');
    }

    return _completeMulti({kMainDart: source}, kMainDart, offset);
  }

  Future<CompleteResponse> _completeMulti(
      Map<String, String> sources, String sourceName, int offset) async {
    if (sources == null) {
      throw BadRequestError('Missing parameter: \'source\'');
    }
    if (sourceName == null) {
      throw BadRequestError('Missing parameter: \'name\'');
    }
    if (offset == null) {
      throw BadRequestError('Missing parameter: \'offset\'');
    }

    Stopwatch watch = Stopwatch()..start();
    unawaited(counter.increment("Completions"));
    try {
      var response = await analysisServer.completeMulti(
          sources,
          Location()
            ..sourceName = sourceName
            ..offset = offset);
      log.info('PERF: Computed completions in ${watch.elapsedMilliseconds}ms.');
      return response;
    } catch (e, st) {
      log.severe('Error during _complete', e, st);
      await restart();
      rethrow;
    }
  }

  Future<FixesResponse> _fixes(String source, int offset) async {
    if (source == null) {
      throw BadRequestError('Missing parameter: \'source\'');
    }
    if (offset == null) {
      throw BadRequestError('Missing parameter: \'offset\'');
    }

    return _fixesMulti({kMainDart: source}, kMainDart, offset);
  }

  Future<FixesResponse> _fixesMulti(
      Map<String, String> sources, String sourceName, int offset) async {
    if (sources == null) {
      throw BadRequestError('Missing parameter: \'sources\'');
    }
    if (offset == null) {
      throw BadRequestError('Missing parameter: \'offset\'');
    }

    Stopwatch watch = Stopwatch()..start();
    unawaited(counter.increment("Fixes"));
    var response = await analysisServer.getFixesMulti(
        sources,
        Location()
          ..sourceName = sourceName
          ..offset = offset);
    log.info('PERF: Computed fixes in ${watch.elapsedMilliseconds}ms.');
    return response;
  }

  Future<FormatResponse> _format(String source, {int offset}) async {
    if (source == null) {
      throw BadRequestError('Missing parameter: \'source\'');
    }
    offset ??= 0;

    Stopwatch watch = Stopwatch()..start();
    unawaited(counter.increment("Formats"));

    var response = await analysisServer.format(source, offset);
    log.info('PERF: Computed format in ${watch.elapsedMilliseconds}ms.');
    return response;
  }

  Future<T> checkCache<T>(String query) => cache.get(query);

  Future<T> setCache<T>(String query, String result) =>
      cache.set(query, result, expiration: _standardExpiration);
}

String _printCompileProblem(CompilationProblem problem) => problem.message;

String _hashSource(String str) {
  return sha1.convert(str.codeUnits).toString();
}
