import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const String host = '127.0.0.1';
const int targetPort = 11434;
const int sourcePort = 11435;

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

Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.anyIPv4, sourcePort);
  print('Listening on port $sourcePort');

  await for (final HttpRequest origRequest in server) {
    try {
      // Handle CORS preflight request
      if (origRequest.method == 'OPTIONS') {
        origRequest.response
          ..statusCode = HttpStatus.ok
          ..headers.add('Access-Control-Allow-Origin', '*')
          ..headers.add(
              'Access-Control-Allow-Methods', 'POST, GET, OPTIONS, PUT, DELETE')
          ..headers.add(
              'Access-Control-Allow-Headers', 'content-type, authorization')
          ..close();

        print("CORS request handled");
        continue;
      }

      // Print the incoming request
      print('Received request: ${origRequest.method} ${origRequest.uri}');
      print('Headers: ${origRequest.headers}');

      final Uint8List origContent = combineLists(await origRequest.toList());

      print('Body: ${utf8.decode(origContent)}');

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
      print('Body: ${utf8.decode(forwardContent)}');

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
      } catch (e, s) {
        print('Error sending error response: $e - $s');
      }
    }
  }
}
