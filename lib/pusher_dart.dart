library pusher_dart;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

@immutable
class PusherAuth {
  final Map<String, String> headers;

  PusherAuth({this.headers});
}

@immutable
class PusherOptions {
  final String authEndpoint;
  final PusherAuth auth;
  final String cluster;

  PusherOptions({this.authEndpoint, this.auth, this.cluster = 'ap2'});
}

class Channel with _EventEmitter {
  final String name;
  Connection _connection;

  Channel(this.name, this._connection, [String _data]);

  bool trigger(String eventName, Object data) {
    try {
      _connection.webSocketChannel.sink.add(jsonEncode({
        'event': eventName,
        'data': data,
      }));
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> connect(Function(dynamic) onError) async {
    String auth;
    dynamic channelData;

    if (name.startsWith('private-') || name.startsWith('presence-')) {
      try {
        Map<dynamic, dynamic> data = await _connection.authenticate(name);
        channelData = data['channel_data'];
        auth = data['auth'];
      } catch (e) {
        onError(e);
      }
    }

    return trigger('pusher:subscribe', {
      'channel': name,
      'auth': auth,
      'channel_data': channelData,
    });
  }
}

mixin _EventEmitter {
  static final Map<String, Set<Function(Object data)>> _listeners = {};

  void bind(String eventName, Function(Object data) callback) {
    if (_listeners[eventName] == null) {
      _listeners[eventName] = Set<Function(Object data)>();
    }
    _listeners[eventName].add(callback);
  }

  void unbind(String eventName, Function(Object data) callback) {
    if (_listeners[eventName] != null) {
      _listeners[eventName].remove(callback);
    }
  }

  void _broadcast(String eventName, [Object data]) {
    (_listeners[eventName] ?? Set()).forEach((listener) {
      listener(data);
    });
  }
}

class Connection with _EventEmitter {
  String state = 'initialized';
  String socketId;
  String apiKey;
  PusherOptions options;
  int _retryIn = 1;
  WebSocketChannel webSocketChannel;
  final Map<String, Channel> channels = {};
  Function(dynamic) onError;

  Connection(this.apiKey, this.options, this.onError) {
    _connect();
  }

  _connect() {
    try {
      state = 'connecting';
      _broadcast('connecting');

       webSocketChannel = IOWebSocketChannel.connect(
        'ws://${options.cluster}/app/$apiKey?protocol=7&client=js&version=4.3.1&flash=false',
      );

      webSocketChannel.stream.listen(
        _handleMessage,
        onError: (error) {
          onError(PusherConnectionException());
        },
        cancelOnError: true,
      );
    } catch (e) {
      onError(PusherConnectionException());
      // Give up if we have to tray again after an hour
      if (_retryIn > 3600) return;
      _retryIn++;
      Future.delayed(Duration(seconds: _retryIn ^ 2), _connect);
    }
  }

  Future<Map<dynamic, dynamic>> authenticate(String channelName) async {
    if (socketId == null) {
      throw WebSocketChannelException(
        'Pusher has not yet established connection',
      );
    }
    try {
      final response = await http.post(options.authEndpoint,
          headers: options.auth.headers,
          body: jsonEncode({
            'channel_name': channelName,
            'socket_id': socketId,
          }));
      if (response.statusCode != 200) {
        throw NotAuthorizedException();
      }
      return jsonDecode(response.body);
    } catch (e) {
      throw NotAuthorizedException();
    }
  }

  _handleMessage(Object message) {
    if (Pusher.log != null) Pusher.log(message);
    final json = Map<String, Object>.from(jsonDecode(message));
    final String eventName = json['event'];
    final data = json['data'] ?? {};
    _broadcast(eventName, data);
    switch (eventName) {
      case 'pusher:connection_established':
        socketId = jsonDecode(data)['socket_id'];
        state = 'connected';
        _broadcast('connected', data);
        _subscribeAll();
        break;
      case 'pusher:error':
        _broadcast('error', data);
        _handlePusherError(data);
        break;
      default:
        _handleChannelMessage(json);
    }
  }

  _handleChannelMessage(Map<String, Object> message) {
    final channel = channels[message['channel']];
    if (channel != null) {
      channel._broadcast(message['event'], message['data']);
    }
  }

  Future disconnect() {
    state = 'disconnected';
    return webSocketChannel.sink.close();
  }

  Channel subscribe(String channelName, [String data]) {
    final channel = Channel(channelName, this, data);
    channels[channelName] = channel;
    if (state == 'connected') {
      channel.connect(this.onError);
    }
    return channel;
  }

  _subscribeAll() {
    channels.forEach((channelName, channel) {
      channel.connect(this.onError);
    });
  }

  void unsubscribe(String channelName) {
    channels.remove(channelName);
    webSocketChannel.sink.add(jsonEncode({
      'event': 'pusher:unsubscribe',
      'data': {'channel': channelName}
    }));
  }

  void _handlePusherError(Map<String, Object> json) {
    if (json['code'] == null) {
      throw WebSocketChannelException(
          json['message'] ?? "Failed to connect to pusher channel");
    }
    final int errorCode = json['code'];

    if (errorCode >= 4200) {
      _connect();
    } else if (errorCode > 4100) {
      Future.delayed(Duration(seconds: 2), _connect);
    }
  }
}

class Pusher with _EventEmitter {
  static Function log = (Object message) {
    print('Pusher: $message');
  };
  Connection _connection;

  Pusher(String apiKey, PusherOptions options, Function(dynamic) onError) {
    _connection = Connection(apiKey, options, onError);
  }

  void disconnect() {
    _connection.disconnect();
  }

  Channel channel(String channelName) {
    return _connection.channels[channelName];
  }

  Channel subscribe(String channelName, [String data]) {
    return _connection.subscribe(channelName, data);
  }

  void unsubscribe(String channelName) {
    _connection.unsubscribe(channelName);
  }
}

class PusherConnectionException implements Exception {
  final message;

  PusherConnectionException({
    this.message = "Failed to connect to pusher.",
  });

  @override
  String toString() {
    return message;
  }
}

class NotAuthorizedException implements Exception {
  final message;

  NotAuthorizedException({
    this.message = "You are not authorized to access this channel.",
  });

  @override
  String toString() {
    return message;
  }
}
