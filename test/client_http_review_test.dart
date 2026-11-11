import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:netdisk_direct/netdisk_direct.dart';
import 'package:test/test.dart';

const fixtureLink = ParsedShareLink(
    platform: NetdiskPlatform.quark,
    rawUrl: 'https://pan.quark.cn/s/fixture',
    shareId: 'fixture',
    password: 'private-password');
const fixtureFile = NetdiskFile(fileId: 'same-id', name: 'first.bin', size: 1);
Matcher errorCode(NetdiskErrorCode code) =>
    isA<NetdiskException>().having((e) => e.code, 'code', code);

class RecordingClient extends http.BaseClient {
  RecordingClient(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  final requests = <http.BaseRequest>[];
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return handler(request);
  }

  @override
  void close() {
    closed = true;
  }
}

http.StreamedResponse reply(
        {int status = 200, Map<String, String>? headers, String body = '{}'}) =>
    http.StreamedResponse(Stream.value(utf8.encode(body)), status,
        headers: headers ?? {});

class CaptureParser extends NetdiskParser {
  CaptureParser(super.http);
  ParsedShareLink? resolved;
  Future<NetdiskDownloadLink> Function(NetdiskFile)? resolver;
  @override
  NetdiskPlatform get platform => NetdiskPlatform.quark;
  @override
  ParsedShareLink? match(String input) => fixtureLink;
  @override
  Future<NetdiskShare> parse(
    ParsedShareLink link, {
    NetdiskCredential credential = const NetdiskCredential.none(),
  }) async =>
      const NetdiskShare(
          platform: NetdiskPlatform.quark,
          shareId: 'fixture',
          shareUrl: 'https://pan.quark.cn/s/fixture',
          files: [fixtureFile]);
  @override
  Future<NetdiskDownloadLink> resolve(
    ParsedShareLink link,
    NetdiskFile file, {
    NetdiskCredential credential = const NetdiskCredential.none(),
  }) async {
    resolved = link;
    if (resolver != null) return resolver!(file);
    return NetdiskDownloadLink(
        platform: platform,
        url: 'https://cdn.example.test/sample',
        fileName: file.name,
        size: file.size,
        fileId: file.fileId);
  }
}

void main() {
  test(
      'default parsers share the public transport and injected transport is closed',
      () {
    final client = NetdiskClient();
    expect(
        client.parsers.every((parser) => identical(parser.http, client.http)),
        true);
    client.close();
    final inner = RecordingClient((_) async => reply());
    final transport = HttpClient(client: inner);
    final injected = NetdiskClient(http: transport);
    expect(identical(injected.http, transport), true);
    expect(
        injected.parsers.every((parser) => identical(parser.http, transport)),
        true);
    injected.close();
    expect(inner.closed, true);
  });

  test(
      'parse and parseLink privately preserve the effective extraction password',
      () async {
    final transport = HttpClient(client: RecordingClient((_) async => reply()));
    final parser = CaptureParser(transport);
    final client = NetdiskClient(http: transport, parsers: [parser]);
    addTearDown(client.close);
    final share = await client.parse('fixture', password: 'explicit-password');
    expect(share.shareUrl, isNot(contains('explicit-password')));
    await client.resolveDownload(share, fixtureFile);
    expect(parser.resolved?.password, 'explicit-password');
    final linked = await client.parseLink(fixtureLink);
    await client.resolveDownload(linked, fixtureFile);
    expect(parser.resolved?.password, 'private-password');
    expect(fixtureLink.toString(), isNot(contains('private-password')));
    expect(fixtureLink.toString(), isNot(contains('fixture')));
  });

  test(
      'resolveAll preserves positions even with duplicate IDs, failures and out-of-order completion',
      () async {
    final transport = HttpClient(client: RecordingClient((_) async => reply()));
    final parser = CaptureParser(transport);
    final client = NetdiskClient(http: transport, parsers: [parser]);
    addTearDown(client.close);
    var active = 0;
    var peak = 0;
    parser.resolver = (file) async {
      active++;
      if (active > peak) peak = active;
      try {
        await Future<void>.delayed(
            Duration(milliseconds: file.name == 'first.bin' ? 35 : 5));
        if (file.name == 'failure.bin') {
          throw const NetdiskException(
              NetdiskErrorCode.loginRequired, 'fixture');
        }
        return NetdiskDownloadLink(
            platform: NetdiskPlatform.quark,
            url: 'https://cdn.example.test/${file.name}',
            fileName: file.name,
            size: file.size);
      } finally {
        active--;
      }
    };
    final progress = <int>[];
    final results = await client.resolveAll(
        fixtureLink,
        const [
          fixtureFile,
          NetdiskFile(fileId: 'same-id', name: 'second.bin', size: 2),
          NetdiskFile(fileId: 'other', name: 'failure.bin', size: 3),
        ],
        concurrency: 2,
        onProgress: (done, _) => progress.add(done));
    expect(results.map((r) => r.file.name),
        ['first.bin', 'second.bin', 'failure.bin']);
    expect(results[0].link?.fileName, 'first.bin');
    expect(results[1].link?.fileName, 'second.bin');
    expect(results[2].error, errorCode(NetdiskErrorCode.loginRequired));
    expect(peak, 2);
    expect(progress, [1, 2, 3]);
    expect(await client.resolveAll(fixtureLink, []), isEmpty);
  });

  test('resolveAll clamps invalid concurrency to one worker', () async {
    final transport = HttpClient(client: RecordingClient((_) async => reply()));
    final parser = CaptureParser(transport);
    final client = NetdiskClient(http: transport, parsers: [parser]);
    addTearDown(client.close);
    var active = 0;
    var peak = 0;
    parser.resolver = (file) async {
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      active--;
      return const NetdiskDownloadLink(
          platform: NetdiskPlatform.quark,
          url: 'https://cdn.example.test/file',
          fileName: 'sample.bin',
          size: 1);
    };
    await client.resolveAll(fixtureLink, [fixtureFile, fixtureFile],
        concurrency: -10);
    expect(peak, 1);
  });

  test(
      'same-origin redirects preserve credentials and final URL but convert POST on 303',
      () async {
    late RecordingClient inner;
    inner = RecordingClient((request) async => inner.requests.length == 1
        ? reply(status: 303, headers: {'location': '/next'})
        : reply(body: '{"ok":true}'));
    final client = HttpClient(client: inner);
    addTearDown(client.close);
    final response = await client.postJson(
        Uri.parse('https://api.example.test/start'),
        body: {'data': 'fixture'},
        headers: {'Cookie': 'private-cookie=fixture'});
    expect(inner.requests, hasLength(2));
    expect(inner.requests.last.method, 'GET');
    expect((inner.requests.last as http.Request).body, isEmpty);
    expect(inner.requests.last.headers['Cookie'], 'private-cookie=fixture');
    expect(inner.requests.every((r) => r.followRedirects == false), true);
    expect(response.url.path, '/next');
    expect(response.jsonMap?['ok'], true);
  });

  test('307 redirects preserve POST body', () async {
    late RecordingClient inner;
    inner = RecordingClient((_) async => inner.requests.length == 1
        ? reply(status: 307, headers: {'location': '/next'})
        : reply());
    final client = HttpClient(client: inner);
    addTearDown(client.close);
    await client.postForm(Uri.parse('https://api.example.test/start'),
        fields: {'pwd': 'a+b /'});
    expect(inner.requests.last.method, 'POST');
    expect((inner.requests.last as http.Request).bodyFields, {'pwd': 'a+b /'});
  });

  for (final location in [
    'https://other.example.test/steal',
    'http://api.example.test/plain',
    'https://private:secret@api.example.test/next',
    'https://api.example.test:444/next'
  ]) {
    test('credentials never follow disallowed redirect $location', () async {
      final inner = RecordingClient(
          (_) async => reply(status: 302, headers: {'location': location}));
      final client = HttpClient(client: inner);
      addTearDown(client.close);
      final result = await client
          .get(Uri.parse('https://api.example.test/start'), headers: {
        'Cookie': 'private-cookie=fixture',
        'Authorization': 'Bearer private-token'
      });
      expect(result.status, 302);
      expect(inner.requests, hasLength(1));
    });
  }

  test('redirect loops terminate with a typed response error after three hops',
      () async {
    final inner = RecordingClient(
        (_) async => reply(status: 302, headers: {'location': '/again'}));
    final client = HttpClient(client: inner);
    addTearDown(client.close);
    await expectLater(client.get(Uri.parse('https://api.example.test/start')),
        throwsA(errorCode(NetdiskErrorCode.badResponse)));
    expect(inner.requests, hasLength(4));
  });

  test('declared oversized responses cancel without collecting the body',
      () async {
    var canceled = false;
    final controller = StreamController<List<int>>(onCancel: () {
      canceled = true;
    });
    final inner = RecordingClient((_) async => http.StreamedResponse(
        controller.stream, 200,
        contentLength: 8 * 1024 * 1024 + 1));
    final client = HttpClient(client: inner);
    addTearDown(client.close);
    await expectLater(client.get(Uri.parse('https://api.example.test/large')),
        throwsA(errorCode(NetdiskErrorCode.badResponse)));
    expect(canceled, true);
    await controller.close();
  });

  test(
      'unknown-length responses accept the exact byte limit and reject overflow',
      () async {
    const limit = 8 * 1024 * 1024;
    for (final overflow in [false, true]) {
      final inner = RecordingClient((_) async => http.StreamedResponse(
          Stream.fromIterable([
            Uint8List(limit),
            if (overflow) [1],
          ]),
          200));
      final client = HttpClient(client: inner);
      addTearDown(client.close);
      final result = client.get(Uri.parse('https://api.example.test/bytes'));
      if (overflow) {
        await expectLater(
            result, throwsA(errorCode(NetdiskErrorCode.badResponse)));
      } else {
        expect((await result).bodyBytes, hasLength(limit));
      }
    }
  });

  test(
      'timeout aborts and cancels continuous response data at a total deadline',
      () async {
    var aborted = false;
    var canceled = false;
    Timer? ticker;
    late StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () {
        ticker = Timer.periodic(
            const Duration(milliseconds: 10), (_) => controller.add([1]));
      },
      onCancel: () {
        canceled = true;
        ticker?.cancel();
      },
    );
    final inner = RecordingClient((request) async {
      expect(request, isA<http.Abortable>());
      unawaited((request as http.Abortable).abortTrigger!.then((_) {
        aborted = true;
      }));
      return http.StreamedResponse(controller.stream, 200);
    });
    final client =
        HttpClient(client: inner, timeout: const Duration(milliseconds: 80));
    addTearDown(client.close);
    final elapsed = Stopwatch()..start();
    await expectLater(
        client.get(Uri.parse('https://api.example.test/private?pwd=secret')),
        throwsA(errorCode(NetdiskErrorCode.network)));
    await Future<void>.delayed(Duration.zero);
    expect(elapsed.elapsedMilliseconds, lessThan(750));
    expect(aborted, true);
    expect(canceled, true);
    ticker?.cancel();
    await controller.close();
  });

  test('a custom client completing late after timeout has its body canceled',
      () async {
    final pending = Completer<http.StreamedResponse>();
    final canceled = Completer<void>();
    final body = StreamController<List<int>>(onCancel: () {
      canceled.complete();
    });
    final client = HttpClient(
        client: RecordingClient((_) => pending.future),
        timeout: const Duration(milliseconds: 15));
    addTearDown(client.close);
    await expectLater(client.get(Uri.parse('https://api.example.test/late')),
        throwsA(errorCode(NetdiskErrorCode.network)));
    pending.complete(http.StreamedResponse(body.stream, 200));
    await canceled.future.timeout(const Duration(seconds: 1));
    await body.close();
  });

  test('microtask response chunks cannot starve the total deadline timer',
      () async {
    final inner = RecordingClient((_) async => http.StreamedResponse(
        Stream.fromIterable(Iterable.generate(1000000, (_) => [1])), 200));
    final client =
        HttpClient(client: inner, timeout: const Duration(milliseconds: 2));
    addTearDown(client.close);
    await expectLater(
        client.get(Uri.parse('https://api.example.test/microtasks')),
        throwsA(errorCode(NetdiskErrorCode.network)));
  });

  test('timeout also aborts a request waiting for response headers', () async {
    var aborted = false;
    final inner = RecordingClient((request) async {
      final result = Completer<http.StreamedResponse>();
      unawaited((request as http.Abortable).abortTrigger!.then((_) {
        aborted = true;
        result.completeError(http.RequestAbortedException(request.url));
      }));
      return result.future;
    });
    final client =
        HttpClient(client: inner, timeout: const Duration(milliseconds: 30));
    addTearDown(client.close);
    await expectLater(client.get(Uri.parse('https://api.example.test/private')),
        throwsA(errorCode(NetdiskErrorCode.network)));
    await Future<void>.delayed(Duration.zero);
    expect(aborted, true);
  });

  for (final closeInstead in [false, true]) {
    test(
        'real loopback connection is disconnected by ${closeInstead ? 'close' : 'timeout'}',
        () async {
      final server =
          await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<void>();
      final disconnected = Completer<void>();
      final sockets = <io.Socket>[];
      final subscription = server.listen((request) async {
        final socket = await request.response.detachSocket(writeHeaders: false);
        sockets.add(socket);
        if (!accepted.isCompleted) accepted.complete();
        socket.listen((_) {}, onDone: () {
          if (!disconnected.isCompleted) disconnected.complete();
        }, onError: (Object _) {
          if (!disconnected.isCompleted) disconnected.complete();
        });
      });
      final client = HttpClient(
          timeout: Duration(milliseconds: closeInstead ? 2000 : 150));
      addTearDown(() async {
        client.close();
        for (final socket in sockets) {
          socket.destroy();
        }
        await subscription.cancel();
        await server.close(force: true);
      });
      final response =
          client.get(Uri.parse('http://127.0.0.1:${server.port}/fixture'));
      final expectation =
          expectLater(response, throwsA(errorCode(NetdiskErrorCode.network)));
      await accepted.future.timeout(const Duration(seconds: 2));
      if (closeInstead) client.close();
      await expectation;
      await disconnected.future.timeout(const Duration(seconds: 2));
    });
  }

  test('network errors never echo credentials, URLs, or transport diagnostics',
      () async {
    final inner = RecordingClient((_) async {
      throw StateError('private-cookie=secret https://private.example/secret');
    });
    final client = HttpClient(client: inner);
    addTearDown(client.close);
    try {
      await client
          .get(Uri.parse('https://api.example.test/private?pwd=secret'));
      fail('Expected network error');
    } on NetdiskException catch (error) {
      expect(error.code, NetdiskErrorCode.network);
      expect(error.toString(), isNot(contains('secret')));
      expect(error.toString(), isNot(contains('example')));
    }
  });

  test(
      'URL extraction handles JSON escapes, quotes, Markdown and HTML ampersands',
      () {
    for (final input in [
      r'{"url":"https:\/\/pan.baidu.com\/s\/1fixture?pwd=abcd"}',
      '[share](https://pan.baidu.com/s/1fixture?pwd=abcd).',
      'HTTPS://pan.baidu.com/s/1fixture?x=1&amp;pwd=abcd',
    ]) {
      final uri = extractFirstUrl(input)!;
      expect(uri.host, 'pan.baidu.com');
      expect(queryParam(uri, 'pwd'), 'abcd');
    }
    expect(extractFirstUrl('no URL'), isNull);
    expect(
        queryParam(
            Uri.parse('https://pan.baidu.com/s/1fixture#pwd=abcd'), 'pwd'),
        'abcd');
    expect(
        queryParam(
            Uri.parse('https://pan.baidu.com/s/1fixture?pwd=%FF'), 'pwd'),
        isNull);
    expect(
        queryParam(
            Uri.parse('https://pan.baidu.com/s/1fixture#pwd=%FF'), 'pwd'),
        isNull);
  });
}
