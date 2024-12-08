import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const bool handleCors = true;
const String host = '127.0.0.1';
const int targetPort = 11434;
const int sourcePort = 11435;

HttpServer? server;

class OutData {
  final String filePath;
  final StringBuffer buffer = StringBuffer();

  OutData(this.filePath);

  void write() {
    File(filePath)
      ..createSync(recursive: true)
      ..writeAsStringSync(buffer.toString());
  }
}

OutData? outData;
bool closeHandlerInvoked = false;

Uint8List combineLists(List<Uint8List> lists) {
  final length = lists.fold<int>(0, (prev, element) => prev + element.length);
  final result = Uint8List(length);
  int offset = 0;

  for (final Uint8List list in lists) {
    result.setAll(offset, list);
    offset += list.length;
  }

  return result;
}

void _closeHandler(final ProcessSignal signal) {
  if (closeHandlerInvoked) return;
  closeHandlerInvoked = true;

  print('Received signal $signal');

  if (outData != null) {
    print('File Output enabled to ${outData!.filePath} - writing now...');

    final OutData outDataCopy = outData!;
    outData = null;

    outDataCopy.write();

    print('File written');
  }

  server?.close(force: true).then((_) {
    print('Server closed');
    exit(0);
  });
}

Future<void> main(List<String> args) async {
  ProcessSignal.sigint.watch().listen(_closeHandler);
  ProcessSignal.sigterm.watch().listen(_closeHandler);

  server = await HttpServer.bind(InternetAddress.anyIPv4, sourcePort);

  print('Listening on port $sourcePort');

  if (args.isNotEmpty) {
    outData = OutData(args[0]);
  }

  await for (final HttpRequest origRequest in server!) {
    try {
      // Handle CORS preflight request
      if (handleCors) {
        if (origRequest.method == 'OPTIONS') {
          origRequest.response
            ..statusCode = HttpStatus.ok
            ..headers.add('Access-Control-Allow-Origin', '*')
            ..headers.add('Access-Control-Allow-Methods',
                'POST, GET, OPTIONS, PUT, DELETE')
            ..headers.add(
                'Access-Control-Allow-Headers', 'content-type, authorization')
            ..close();

          print("CORS request handled");
          continue;
        }
      }

      // Print the incoming request
      print('Request: ${origRequest.method} ${origRequest.uri}');
      print('Headers: ${origRequest.headers}');

      final Uint8List origContent = combineLists(await origRequest.toList());

      print('Body: ');
      print(utf8.decode(origContent));

      // Write to file if enabled
      outData?.buffer
          .writeln('Request: ${origRequest.method} ${origRequest.uri}');
      outData?.buffer.writeln('Headers: ${origRequest.headers}');
      outData?.buffer.writeln('Body:');
      outData?.buffer.writeln(utf8.decode(origContent));
      outData?.buffer.writeln();

      // Forward the request to host:targetPort
      final forwardRequest = await HttpClient().openUrl(origRequest.method,
          Uri.parse('http://$host:$targetPort${origRequest.uri}'));

      // Copy headers to the forwarded request
      origRequest.headers.forEach((name, values) {
        for (final value in values) {
          forwardRequest.headers.add(name, value);
        }
      });

      // Forward the body if the method supports a body
      if (origRequest.method == 'POST' || origRequest.method == 'PUT') {
        forwardRequest.add(origContent);
      }

      final forwardResponse = await forwardRequest.close();

      // Print the response received from host:targetPort
      print('Response from $host:$targetPort: ${forwardResponse.statusCode}');
      print('Headers: ${forwardResponse.headers}');

      // Get content
      final List<List<int>> forwardContentParts =
          await forwardResponse.toList();

      final List<int> forwardContent = [];

      for (final part in forwardContentParts) {
        forwardContent.addAll(part);
      }

      // Print
      print('Body:');
      print(utf8.decode(forwardContent));

      // Write to file if enabled
      outData?.buffer.writeln(
          'Response from $host:$targetPort: ${forwardResponse.statusCode}');
      outData?.buffer.writeln('Headers: ${forwardResponse.headers}');
      outData?.buffer.writeln('Body:');
      outData?.buffer.writeln(utf8.decode(forwardContent));
      outData?.buffer.writeln();

      // Send the response back to the original client
      origRequest.response.statusCode = forwardResponse.statusCode;
      forwardResponse.headers.forEach((name, values) {
        for (final value in values) {
          origRequest.response.headers.add(name, value);
        }
      });

      origRequest.response.add(forwardContent);

      await origRequest.response.close();
    } catch (e, s) {
      print('Error: $e - $s');

      try {
        origRequest.response
          ..statusCode = HttpStatus.internalServerError
          ..write('Internal Server Error')
          ..close();

        _closeHandler(ProcessSignal.sigterm);
      } catch (e, s) {
        print('Error sending error response: $e - $s');
        _closeHandler(ProcessSignal.sigterm);
      }
    }
  }
}
