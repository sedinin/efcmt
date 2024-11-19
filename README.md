efcm
=====

Erlang client for [`Firebase Cloud Messaging`](https://firebase.google.com/docs/cloud-messaging) to send notifications
to browser and Android devices (also probably iOS, but untested).

Highly inspired by [`fcm-erlang`](https://github.com/pankajsoni19/fcm-erlang) library and my
work for [`Apns4Erl`](https://github.com/inaka/apns4erl), to make it use http/2 streams.

# Changelog

__1.0.0__

* Initial Release

### How to compile:

    $ rebar3 compile

### How to use:


```

1> {ok, Pid} = efcm:start("google_service_file_path.json").
{ok,<0.65.0>}
2> {ok, MessId} = efcm:push(Pid, RegId, Message).
```

In order to understand `Message` payload see 
[Message Syntax](https://firebase.google.com/docs/cloud-messaging/http-server-ref#send-downstream)
or [Refer to HTTP v1 API](https://firebase.google.com/docs/cloud-messaging/send-message#rest)

## Credits

* [pankajsoni19/fcm-erlang](https://github.com/pankajsoni19/fcm-erlang)
* [inaka/apns4erl](https://github.com/inaka/apns4erl)